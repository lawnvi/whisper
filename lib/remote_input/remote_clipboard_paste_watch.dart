import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';

/// How long a paste shortcut is held back for its files. Keyboard and mouse
/// wait behind it, so it is short: a small file is here by then and pastes as
/// usual. Past it the shortcut is put aside and the paste waits on screen
/// (`RemoteClipboardPasteWatch`), while input goes on.
const Duration remoteClipboardPasteHoldLimit = Duration(milliseconds: 300);

enum RemoteClipboardPasteStage { receiving, pasted, ready, failed, canceled }

/// A paste waiting for its files, as the floating island shows it.
@immutable
final class RemoteClipboardPasteState {
  const RemoteClipboardPasteState({
    required this.id,
    required this.peerId,
    required this.names,
    required this.totalBytes,
    required this.receivedBytes,
    required this.stage,
    this.secondsLeft,
  });

  /// The same while one paste is followed, a new one for the next.
  final int id;
  final String peerId;
  final List<String> names;
  final int totalBytes;
  final int receivedBytes;
  final RemoteClipboardPasteStage stage;

  /// Null until the pace is known.
  final int? secondsLeft;

  double? get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'peerId': peerId,
    'names': names,
    'totalBytes': totalBytes,
    'receivedBytes': receivedBytes,
    'stage': stage.name,
    'secondsLeft': secondsLeft,
  };

  static RemoteClipboardPasteState? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final stage = RemoteClipboardPasteStage.values
        .where((value) => value.name == raw['stage'])
        .firstOrNull;
    final id = raw['id'];
    if (stage == null || id is! int) return null;
    return RemoteClipboardPasteState(
      id: id,
      peerId: raw['peerId'] as String? ?? '',
      names: [
        for (final name in raw['names'] as List? ?? const [])
          if (name is String) name,
      ],
      totalBytes: raw['totalBytes'] as int? ?? 0,
      receivedBytes: raw['receivedBytes'] as int? ?? 0,
      stage: stage,
      secondsLeft: raw['secondsLeft'] as int?,
    );
  }
}

/// What is in front: the window a paste was asked for in. Null where it can't
/// be told.
Future<Object?> foregroundWindowToken() async {
  try {
    return await const MethodChannel(
      'com.vireen.whisper/window_theme',
    ).invokeMethod<Object?>('foregroundWindow');
  } on Object {
    return null;
  }
}

/// A paste whose shortcut could not wait for its files. Shows them coming,
/// and once they are here says whether to paste: only into the window the
/// shortcut was pressed in. Over another one it waits for the next shortcut.
final class RemoteClipboardPasteWatch extends ChangeNotifier {
  RemoteClipboardPasteWatch({
    required RemoteClipboardDownload? Function(String sessionId) download,
    required Future<void> Function(String sessionId) cancelDownload,
    void Function(String sessionId)? pasted,
    Future<Object?> Function() foreground = foregroundWindowToken,
    Duration poll = const Duration(milliseconds: 250),
  }) : _download = download,
       _cancelDownload = cancelDownload,
       _pasted = pasted,
       _foreground = foreground,
       _poll = poll;

  final RemoteClipboardDownload? Function(String sessionId) _download;
  final Future<void> Function(String sessionId) _cancelDownload;
  final void Function(String sessionId)? _pasted;
  final Future<Object?> Function() _foreground;
  final Duration _poll;

  RemoteClipboardPasteState? _current;
  _Follow? _following;
  Timer? _timer;
  int _ids = 0;

  /// The pace over the last few seconds, for the time left.
  final List<(DateTime, int)> _samples = <(DateTime, int)>[];
  static const _paceWindow = Duration(seconds: 3);

  RemoteClipboardPasteState? get current => _current;

  /// Follows [pending], the paste's files on their way. True when they are
  /// here and the window in front is still the one from [front]: paste now.
  /// A shortcut pressed again while they come takes over, and only that one
  /// pastes.
  Future<bool> follow({
    required String sessionId,
    required Future<RemoteClipboardPasteResult> pending,
    required Future<Object?> front,
  }) async {
    final previous = _following;
    final sameFiles = previous != null && previous.sessionId == sessionId;
    final follow = _Follow(
      id: sameFiles ? previous.id : ++_ids,
      sessionId: sessionId,
    );
    _following = follow;
    if (!sameFiles) _samples.clear();
    _timer ??= Timer.periodic(_poll, (_) => _refresh());
    _refresh();
    RemoteClipboardPasteResult result;
    try {
      result = await pending;
    } on Object {
      result = RemoteClipboardPasteResult.failed;
    }
    if (!identical(_following, follow)) {
      return false;
    }
    _refresh();
    _following = null;
    _timer?.cancel();
    _timer = null;
    if (result != RemoteClipboardPasteResult.prepared) {
      _settle(
        follow,
        follow.canceled || result == RemoteClipboardPasteResult.notAvailable
            ? RemoteClipboardPasteStage.canceled
            : RemoteClipboardPasteStage.failed,
      );
      return false;
    }
    final asked = await front.catchError((Object _) => null);
    final now = await _foreground().catchError((Object _) => null);
    // Where the window can't be told, it pastes: a paste that never came
    // would be worse, and nothing on screen would say why.
    final same = asked == null || now == null || asked == now;
    _settle(
      follow,
      same ? RemoteClipboardPasteStage.pasted : RemoteClipboardPasteStage.ready,
    );
    if (same) _pasted?.call(sessionId);
    return same;
  }

  /// The user put the paste away: what is still coming stops.
  void cancel() {
    final follow = _following;
    if (follow == null) return;
    follow.canceled = true;
    unawaited(_cancelDownload(follow.sessionId).catchError((Object _) {}));
  }

  void _refresh() {
    final follow = _following;
    if (follow == null) return;
    final download = _download(follow.sessionId);
    final previous = _current;
    final keep = previous != null && previous.id == follow.id;
    final names = download?.names ?? (keep ? previous.names : const <String>[]);
    final total = download?.totalBytes ?? (keep ? previous.totalBytes : 0);
    final received =
        download?.receivedBytes ?? (keep ? previous.receivedBytes : 0);
    final next = RemoteClipboardPasteState(
      id: follow.id,
      peerId: download?.peerId ?? (keep ? previous.peerId : ''),
      names: names,
      totalBytes: total,
      receivedBytes: received,
      stage: RemoteClipboardPasteStage.receiving,
      secondsLeft: _secondsLeft(total, received),
    );
    if (_same(previous, next)) return;
    _current = next;
    notifyListeners();
  }

  int? _secondsLeft(int total, int received) {
    final now = DateTime.now();
    _samples.add((now, received));
    _samples.removeWhere((sample) => now.difference(sample.$1) > _paceWindow);
    final first = _samples.first;
    final elapsed = now.difference(first.$1).inMilliseconds;
    final moved = received - first.$2;
    if (elapsed < 1000 || moved <= 0 || total <= received) {
      return _current?.secondsLeft;
    }
    final seconds = (total - received) * elapsed / moved / 1000;
    return seconds.ceil();
  }

  void _settle(_Follow follow, RemoteClipboardPasteStage stage) {
    final previous = _current;
    _current = RemoteClipboardPasteState(
      id: follow.id,
      peerId: previous?.peerId ?? '',
      names: previous?.names ?? const <String>[],
      totalBytes: previous?.totalBytes ?? 0,
      receivedBytes:
          stage == RemoteClipboardPasteStage.pasted ||
              stage == RemoteClipboardPasteStage.ready
          ? previous?.totalBytes ?? 0
          : previous?.receivedBytes ?? 0,
      stage: stage,
    );
    notifyListeners();
  }

  static bool _same(
    RemoteClipboardPasteState? a,
    RemoteClipboardPasteState b,
  ) =>
      a != null &&
      a.id == b.id &&
      a.stage == b.stage &&
      a.peerId == b.peerId &&
      a.totalBytes == b.totalBytes &&
      a.receivedBytes == b.receivedBytes &&
      a.secondsLeft == b.secondsLeft &&
      listEquals(a.names, b.names);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final class _Follow {
  _Follow({required this.id, required this.sessionId});

  final int id;
  final String sessionId;
  bool canceled = false;
}
