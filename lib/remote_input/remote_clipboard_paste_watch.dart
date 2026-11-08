import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';

/// How long a paste shortcut is held back for its files. Keyboard and mouse
/// wait behind it, so it is short: a small file is here by then and pastes as
/// usual. Past it the shortcut is put aside and the paste waits on screen
/// (`RemoteClipboardPasteWatch`), while input goes on.
const Duration remoteClipboardPasteHoldLimit = Duration(milliseconds: 300);

enum RemoteClipboardPasteStage {
  receiving,
  pasted,

  /// Put straight into the folder the paste was asked in: another window was
  /// in front by the time the files came.
  placed,
  ready,
  failed,
  canceled,
}

/// A folder a paste was asked in (File Explorer, Finder or the desktop).
typedef PasteFolder = ({String path, String name});

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
    this.folder = '',
    this.queued = false,
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

  /// Where the files were put, by the name the system shows it by.
  final String folder;

  /// Nothing has come yet while an earlier paste's files are coming: this
  /// one waits its turn.
  final bool queued;

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
    'folder': folder,
    'queued': queued,
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
      folder: raw['folder'] as String? ?? '',
      queued: raw['queued'] == true,
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

/// The folder shown in front, when a file manager or the desktop is.
Future<PasteFolder?> foregroundFolder() async {
  const asking = Duration(seconds: 3);
  try {
    final found = await const MethodChannel(
      'com.vireen.whisper/window_theme',
    ).invokeMethod<Object?>('foregroundFolder').timeout(asking);
    if (found is! Map) return null;
    final path = found['path'];
    final name = found['name'];
    if (path is! String || path.isEmpty) return null;
    return (path: path, name: name is String && name.isNotEmpty ? name : path);
  } on Object {
    return null;
  }
}

/// A paste whose shortcut could not wait for its files. Shows them coming,
/// and once they are here says whether to paste: only into the window the
/// shortcut was pressed in. Over another one it waits for the next shortcut.
final class RemoteClipboardPasteWatch extends ChangeNotifier {
  RemoteClipboardPasteWatch({
    required RemoteClipboardDownload? Function(String key) download,
    required Future<void> Function(String key) cancelDownload,
    String? Function(String sessionId)? pasteKey,
    void Function(String key)? pasted,
    Future<bool> Function(String key, String directory)? place,
    Future<Object?> Function() foreground = foregroundWindowToken,
    Duration poll = const Duration(milliseconds: 250),
    Duration keepSettled = const Duration(seconds: 30),
  }) : _download = download,
       _cancelDownload = cancelDownload,
       _pasteKey = pasteKey,
       _pasted = pasted,
       _place = place,
       _foreground = foreground,
       _poll = poll,
       _keepSettled = keepSettled;

  final RemoteClipboardDownload? Function(String key) _download;
  final Future<void> Function(String key) _cancelDownload;
  final String? Function(String sessionId)? _pasteKey;
  final void Function(String key)? _pasted;
  final Future<bool> Function(String key, String directory)? _place;
  final Future<Object?> Function() _foreground;
  final Duration _poll;
  final Duration _keepSettled;

  /// The pastes followed now, by key: what was copied (one per offer).
  final Map<String, _Follow> _follows = <String, _Follow>{};

  /// What the island shows, by paste id: the ones under way, and those over
  /// for a little while after.
  final Map<int, RemoteClipboardPasteState> _states =
      <int, RemoteClipboardPasteState>{};
  Timer? _timer;
  int _ids = 0;

  static const _paceWindow = Duration(seconds: 3);

  /// Every paste to show, oldest first.
  List<RemoteClipboardPasteState> get pastes {
    final ids = _states.keys.toList()..sort();
    return [for (final id in ids) _states[id]!];
  }

  /// The latest paste.
  RemoteClipboardPasteState? get current => pastes.lastOrNull;

  /// Follows [pending], the paste's files on their way. Files asked for in a
  /// folder ([folder]) are put into it once here. Otherwise true when they
  /// are here and the window in front is still the one from [front]: paste
  /// now. Several pastes are followed at once, each to
  /// its own end; a shortcut pressed again for the same files while they come
  /// takes over, and only that one pastes.
  Future<bool> follow({
    required String sessionId,
    required Future<RemoteClipboardPasteResult> pending,
    required Future<Object?> front,
    Future<PasteFolder?>? folder,
  }) async {
    final key = _pasteKey?.call(sessionId) ?? sessionId;
    final previous = _follows[key];
    final follow = _Follow(id: previous?.id ?? ++_ids, key: key);
    if (previous != null) follow.samples.addAll(previous.samples);
    _follows[key] = follow;
    _timer ??= Timer.periodic(_poll, (_) => _refreshAll());
    _refresh(follow);
    RemoteClipboardPasteResult result;
    try {
      result = await pending;
    } on Object {
      result = RemoteClipboardPasteResult.failed;
    }
    if (!identical(_follows[key], follow)) {
      return false;
    }
    _refresh(follow);
    _follows.remove(key);
    if (_follows.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
    if (result != RemoteClipboardPasteResult.prepared) {
      _settle(
        follow,
        follow.canceled || result == RemoteClipboardPasteResult.notAvailable
            ? RemoteClipboardPasteStage.canceled
            : RemoteClipboardPasteStage.failed,
      );
      return false;
    }
    // Asked in a folder: the files go into that folder, wherever the user
    // is by now. Pressing paste again would put them wherever that window
    // has gone since, or nowhere when its keyboard is somewhere else.
    final target = await folder?.catchError((Object _) => null);
    final place = _place;
    if (target != null &&
        place != null &&
        await place(key, target.path).catchError((Object _) => false)) {
      _settle(follow, RemoteClipboardPasteStage.placed, folder: target.name);
      // What was copied since comes back, as after a paste.
      _pasted?.call(key);
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
    if (same) _pasted?.call(key);
    return same;
  }

  /// The user put the paste [id] away (the latest when null): what is still
  /// coming for it stops.
  void cancel([int? id]) {
    final follow = id == null
        ? _follows.values.lastOrNull
        : _follows.values.where((follow) => follow.id == id).firstOrNull;
    if (follow == null) return;
    follow.canceled = true;
    unawaited(_cancelDownload(follow.key).catchError((Object _) {}));
  }

  void _refreshAll() {
    for (final follow in [..._follows.values]) {
      _refresh(follow);
    }
  }

  void _refresh(_Follow follow) {
    final download = _download(follow.key);
    final previous = _states[follow.id];
    final names = download?.names ?? previous?.names ?? const <String>[];
    final total = download?.totalBytes ?? previous?.totalBytes ?? 0;
    final received = download?.receivedBytes ?? previous?.receivedBytes ?? 0;
    final next = RemoteClipboardPasteState(
      id: follow.id,
      peerId: download?.peerId ?? previous?.peerId ?? '',
      names: names,
      totalBytes: total,
      receivedBytes: received,
      stage: RemoteClipboardPasteStage.receiving,
      secondsLeft: _secondsLeft(follow, total, received, previous),
      queued:
          received == 0 &&
          _follows.values.any(
            (other) =>
                other.id < follow.id &&
                (_states[other.id]?.receivedBytes ?? 0) > 0,
          ),
    );
    if (_same(previous, next)) return;
    _states[follow.id] = next;
    notifyListeners();
  }

  int? _secondsLeft(
    _Follow follow,
    int total,
    int received,
    RemoteClipboardPasteState? previous,
  ) {
    final now = DateTime.now();
    final samples = follow.samples;
    samples.add((now, received));
    samples.removeWhere((sample) => now.difference(sample.$1) > _paceWindow);
    final first = samples.first;
    final elapsed = now.difference(first.$1).inMilliseconds;
    final moved = received - first.$2;
    if (elapsed < 1000 || moved <= 0 || total <= received) {
      // Waiting its turn behind another paste: no time to tell yet.
      return moved <= 0 && received == 0 ? null : previous?.secondsLeft;
    }
    final seconds = (total - received) * elapsed / moved / 1000;
    return seconds.ceil();
  }

  void _settle(
    _Follow follow,
    RemoteClipboardPasteStage stage, {
    String folder = '',
  }) {
    final previous = _states[follow.id];
    _states[follow.id] = RemoteClipboardPasteState(
      id: follow.id,
      peerId: previous?.peerId ?? '',
      names: previous?.names ?? const <String>[],
      totalBytes: previous?.totalBytes ?? 0,
      receivedBytes:
          stage == RemoteClipboardPasteStage.pasted ||
              stage == RemoteClipboardPasteStage.placed ||
              stage == RemoteClipboardPasteStage.ready
          ? previous?.totalBytes ?? 0
          : previous?.receivedBytes ?? 0,
      stage: stage,
      folder: folder,
    );
    notifyListeners();
    final id = follow.id;
    Timer(_keepSettled, () {
      final state = _states[id];
      if (state != null && state.stage != RemoteClipboardPasteStage.receiving) {
        _states.remove(id);
        notifyListeners();
      }
    });
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
      a.queued == b.queued &&
      listEquals(a.names, b.names);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final class _Follow {
  _Follow({required this.id, required this.key});

  final int id;
  final String key;
  bool canceled = false;

  /// The pace over the last few seconds, for the time left.
  final List<(DateTime, int)> samples = <(DateTime, int)>[];
}
