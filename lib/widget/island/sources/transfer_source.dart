import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../model/file_transfer.dart';
import '../../../page/remote_files/files_copy_island.dart';
import '../../../remote_files/fs_copies.dart';
import '../../../remote_files/fs_placement.dart';
import '../../../socket/svrmanager.dart';
import '../island_activity.dart';
import '../island_views.dart';
import '../transfer_names.dart';

/// Files sent or received in conversations, together: one activity for
/// what is under way at once (like the system notification), so a dozen
/// photos are one line, not a dozen. Copies made in the file manager have
/// their own activities and are left out.
class TransferIslandSource extends ChangeNotifier implements IslandSource {
  TransferIslandSource({
    Stream<TransferSnapshot>? updates,
    bool Function(String transferId)? isCopy,
    TransferNames? names,
    String? Function(String peerId)? deviceName,
    Future<void> Function(String transferId)? cancel,
    Future<void> Function(String transferId)? retry,
    IslandClock clock = const IslandClock(),
  }) : _isCopy = isCopy ?? _isFileManagerCopy,
       _names = names ?? TransferNames.shared,
       _deviceName = deviceName ?? _liveDeviceName,
       _cancel = cancel ?? ((id) => WsSvrManager().cancelTransfer(id)),
       _retry = retry ?? ((id) => WsSvrManager().retryTransfer(id)),
       _clock = clock {
    _subscription = (updates ?? TransferPlacements.shared.updates).listen(
      _onUpdate,
    );
    _found = _names.found.listen((id) {
      if (_transfers.containsKey(id)) {
        notifyListeners();
      }
    });
  }

  /// Leaves the activity to the file manager's own once it is known as one
  /// of its copies (quiet in the conversation, or part of a paste).
  static bool _isFileManagerCopy(String transferId) {
    if (TransferPlacements.shared.isQuiet(transferId)) {
      return true;
    }
    for (final batch in FileCopies.shared.batches) {
      if (batch.transfers.containsKey(transferId)) {
        return true;
      }
    }
    return false;
  }

  static String? _liveDeviceName(String peerId) {
    final name = WsSvrManager().remoteProfileFor(peerId)?.device.name.trim();
    return name == null || name.isEmpty ? null : name;
  }

  /// Not under way long enough to be worth showing: the conversation shows
  /// it already.
  static const showAfter = Duration(milliseconds: 700);

  final bool Function(String transferId) _isCopy;
  final TransferNames _names;
  final String? Function(String peerId) _deviceName;
  final Future<void> Function(String transferId) _cancel;
  final Future<void> Function(String transferId) _retry;
  final IslandClock _clock;
  late final StreamSubscription<TransferSnapshot> _subscription;
  late final StreamSubscription<String> _found;

  /// This round's transfers (a new round starts once all are over).
  final _transfers = <String, TransferSnapshot>{};
  final _copies = <String>{};
  final _peerNames = <String, String>{};
  int _round = 0;
  DateTime _since = DateTime.fromMillisecondsSinceEpoch(0);
  bool _retired = false;

  // Speed over the last few seconds.
  final _samples = <(int, int)>[];
  double _speed = 0;
  Timer? _ticker;
  Timer? _throttle;
  bool _disposed = false;

  String get _id => 'transfer:$_round';

  @override
  List<IslandActivity> get activities {
    if (_transfers.isEmpty || _retired) {
      return const [];
    }
    final stats = _stats();
    return [
      IslandActivity(
        id: _id,
        kind: IslandKind.transfer,
        status: stats.status,
        since: _since,
        arrival: IslandArrival.quiet,
        showAfter: showAfter,
        presenter: TransferPresenter(
          id: _id,
          stats: stats,
          stop: _stopAll,
          retry: stats.canRetry ? _retryAll : null,
        ),
      ),
    ];
  }

  void _onUpdate(TransferSnapshot snapshot) {
    final id = snapshot.transferId;
    if (_copies.contains(id)) {
      return;
    }
    final known = _transfers.containsKey(id);
    if (!known) {
      if (_isCopy(id)) {
        _copies.add(id);
        if (_copies.length > 1024) {
          _copies.remove(_copies.first);
        }
        return;
      }
      if (isTerminalFileTransferState(snapshot.state)) {
        return; // Not one of ours (or long over).
      }
      if (_transfers.isEmpty || _roundOver || _retired) {
        _transfers.clear();
        _samples.clear();
        _speed = 0;
        _round++;
        _retired = false;
        _since = _clock.now();
      }
      final peer = _deviceName(snapshot.peerUid);
      if (peer != null) {
        _peerNames[snapshot.peerUid] = peer;
      }
    }
    final before = _transfers[id]?.state;
    _transfers[id] = snapshot;
    _names.nameOf(snapshot);
    _sample();
    if (before != snapshot.state || !known) {
      _throttle?.cancel();
      _throttle = null;
      notifyListeners();
    } else {
      _throttle ??= Timer(const Duration(milliseconds: 250), () {
        _throttle = null;
        if (!_disposed) {
          notifyListeners();
        }
      });
    }
    _keepTicking();
  }

  bool get _roundOver =>
      _transfers.values.every((s) => isTerminalFileTransferState(s.state));

  int get _doneBytes => _transfers.values.fold<int>(
    0,
    (sum, s) =>
        sum +
        (s.state == FileTransferState.completed
            ? math.max(0, s.size)
            : s.committedBytes.clamp(0, math.max(0, s.size))),
  );

  void _sample() {
    final now = _clock.now().millisecondsSinceEpoch;
    if (_stats().status != IslandStatus.live) {
      _samples.clear();
      _speed = 0;
      return;
    }
    _samples.add((now, _doneBytes));
    _samples.removeWhere((sample) => now - sample.$1 > 3000);
    if (_samples.length < 2) {
      return;
    }
    final first = _samples.first;
    final last = _samples.last;
    final span = last.$1 - first.$1;
    if (span < 400) {
      return;
    }
    final now0 = math.max(0, last.$2 - first.$2) * 1000 / span;
    _speed = _speed == 0 ? now0 : _speed * 0.5 + now0 * 0.5;
  }

  /// Speed and time left keep up between updates (and fall when nothing
  /// arrives).
  void _keepTicking() {
    final moving = _transfers.isNotEmpty && !_roundOver;
    if (moving && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        _sample();
        notifyListeners();
      });
    } else if (!moving) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  TransferStats _stats() {
    final all = _transfers.values.toList(growable: false);
    var total = 0;
    var outgoing = 0;
    var incoming = 0;
    var completed = 0;
    var canceled = 0;
    var failed = 0;
    var active = 0;
    var waiting = 0;
    var started = 0;
    for (final s in all) {
      total += math.max(0, s.size);
      if (s.direction == FileTransferDirection.outgoing) {
        outgoing++;
      } else {
        incoming++;
      }
      switch (s.state) {
        case FileTransferState.completed:
          completed++;
        case FileTransferState.canceled:
          canceled++;
        case FileTransferState.failed:
          failed++;
        case FileTransferState.waitingReconnect || FileTransferState.paused:
          waiting++;
        case FileTransferState.queued || FileTransferState.negotiating:
          active++;
        case FileTransferState.transferring || FileTransferState.verifying:
          active++;
          started++;
      }
    }
    final IslandStatus status;
    if (active > 0) {
      status = IslandStatus.live;
    } else if (waiting > 0) {
      status = IslandStatus.waiting;
    } else if (canceled == all.length) {
      status = IslandStatus.ended;
    } else if (failed > 0 || canceled > 0) {
      status = IslandStatus.failed;
    } else {
      status = IslandStatus.done;
    }
    final done = _doneBytes;
    final peers = {for (final s in all) s.peerUid};
    final single = all.length == 1 ? all.single : null;
    Duration? left;
    if (status == IslandStatus.live && _speed >= 1 && total > done) {
      left = Duration(seconds: ((total - done) / _speed).ceil());
    }
    return TransferStats(
      status: status,
      count: all.length,
      completed: completed,
      outgoing: outgoing,
      incoming: incoming,
      totalBytes: total,
      doneBytes: done,
      speed: status == IslandStatus.live ? _speed : 0,
      remaining: left,
      starting: status == IslandStatus.live && started == 0 && done == 0,
      name: single == null ? null : _names.nameOf(single),
      device: peers.length == 1 ? _peerNames[peers.single] : null,
      canRetry: all.any(
        (s) =>
            s.direction == FileTransferDirection.outgoing &&
            (s.state == FileTransferState.failed ||
                s.state == FileTransferState.paused ||
                s.state == FileTransferState.waitingReconnect),
      ),
    );
  }

  Future<void> _stopAll() async {
    for (final entry in _transfers.entries.toList()) {
      if (!isTerminalFileTransferState(entry.value.state)) {
        await _cancel(entry.key);
      }
    }
  }

  Future<void> _retryAll() async {
    for (final entry in _transfers.entries.toList()) {
      final s = entry.value;
      if (s.direction == FileTransferDirection.outgoing &&
          (s.state == FileTransferState.failed ||
              s.state == FileTransferState.paused ||
              s.state == FileTransferState.waitingReconnect)) {
        await _retry(entry.key);
      }
    }
  }

  @override
  Stream<String> get spotlights => const Stream<String>.empty();

  @override
  void retired(String id) {
    if (id == _id && _roundOver) {
      _retired = true;
      _transfers.clear();
      _samples.clear();
      _speed = 0;
    }
  }

  @override
  void dismissed(IslandActivity activity) {}

  @override
  void expired(IslandActivity activity) {}

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _throttle?.cancel();
    unawaited(_subscription.cancel());
    unawaited(_found.cancel());
    super.dispose();
  }
}

/// Where this round of transfers stands.
@immutable
class TransferStats {
  const TransferStats({
    required this.status,
    required this.count,
    required this.completed,
    required this.outgoing,
    required this.incoming,
    required this.totalBytes,
    required this.doneBytes,
    required this.speed,
    required this.remaining,
    required this.starting,
    required this.name,
    required this.device,
    required this.canRetry,
  });

  final IslandStatus status;
  final int count;
  final int completed;
  final int outgoing;
  final int incoming;
  final int totalBytes;
  final int doneBytes;
  final double speed;
  final Duration? remaining;
  final bool starting;

  /// The file's name when there is one file (once known).
  final String? name;

  /// The other device, when all go to or come from one.
  final String? device;
  final bool canRetry;

  double get fraction =>
      totalBytes <= 0 ? 0 : (doneBytes / totalBytes).clamp(0.0, 1.0);

  int get percent => (fraction * 100).floor();

  bool get sending => incoming == 0;
  bool get receiving => outgoing == 0;
}

/// A round of conversation transfers on the island.
class TransferPresenter extends IslandPresenter {
  const TransferPresenter({
    required this.id,
    required this.stats,
    required this.stop,
    this.retry,
  });

  final String id;
  final TransferStats stats;
  final Future<void> Function() stop;
  final Future<void> Function()? retry;

  Color get _tint => switch (stats.status) {
    IslandStatus.live => IslandColors.blue,
    IslandStatus.paused || IslandStatus.waiting => IslandColors.paused,
    IslandStatus.failed => IslandColors.failed,
    IslandStatus.done => IslandColors.live,
    IslandStatus.ended => IslandColors.gray,
  };

  IconData get _icon => switch (stats.status) {
    IslandStatus.done => CupertinoIcons.checkmark_alt,
    IslandStatus.failed => CupertinoIcons.exclamationmark,
    IslandStatus.waiting || IslandStatus.paused => CupertinoIcons.pause_fill,
    IslandStatus.ended => CupertinoIcons.xmark,
    IslandStatus.live =>
      stats.sending
          ? CupertinoIcons.arrow_up
          : stats.receiving
          ? CupertinoIcons.arrow_down
          : CupertinoIcons.arrow_up_arrow_down,
  };

  Widget _ring(double size) => IslandRing(
    value: stats.starting ? null : stats.fraction,
    tint: _tint,
    icon: _icon,
    size: size,
    full: stats.status.finished,
  );

  String _title(AppLocalizations l10n) =>
      stats.name ?? l10n.islandTransferFiles(stats.count);

  String _route(AppLocalizations l10n) {
    final device = stats.device;
    if (device == null) {
      return stats.sending || stats.receiving
          ? l10n.islandTransferFiles(stats.count)
          : l10n.islandTransferMixed;
    }
    if (stats.sending) {
      return l10n.islandTransferTo(device);
    }
    if (stats.receiving) {
      return l10n.islandTransferFrom(device);
    }
    return '${l10n.islandTransferMixed} · $device';
  }

  String _status(AppLocalizations l10n) {
    switch (stats.status) {
      case IslandStatus.live:
        if (stats.starting) {
          return l10n.remoteFilesCopyStarting;
        }
        final left = stats.remaining;
        return [
          if (stats.speed >= 1) '${copySize(stats.speed.round())}/s',
          if (left != null) l10n.remoteFilesCopyLeft(copyDuration(l10n, left)),
        ].join(' · ');
      case IslandStatus.waiting || IslandStatus.paused:
        final device = stats.device;
        return device == null
            ? l10n.remoteFilesCopyPaused
            : l10n.remoteFilesCopyWaiting(device);
      case IslandStatus.failed:
        return l10n.islandTransferFailed;
      case IslandStatus.ended:
        return l10n.remoteFilesCopyCanceledShort;
      case IslandStatus.done:
        return stats.sending
            ? l10n.islandTransferSent
            : l10n.islandTransferReceived;
    }
  }

  String _compactFigure(AppLocalizations l10n) => switch (stats.status) {
    IslandStatus.live when stats.totalBytes > 0 && !stats.starting =>
      '${stats.percent}%',
    IslandStatus.live => '',
    IslandStatus.waiting || IslandStatus.paused => l10n.remoteFilesCopyPaused,
    _ => _status(l10n),
  };

  String _bytes() {
    final total = stats.totalBytes;
    if (total <= 0) {
      return '';
    }
    if (stats.status == IslandStatus.done) {
      return copySize(total);
    }
    final done = copySize(stats.doneBytes);
    final all = copySize(total);
    final unit = all.substring(all.lastIndexOf(' '));
    if (done.endsWith(unit)) {
      return '${done.substring(0, done.length - unit.length)} / $all';
    }
    return '$done / $all';
  }

  @override
  Widget compact(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final figure = _compactFigure(l10n);
    return IslandCompactLine(
      leading: _ring(20),
      title: _title(l10n),
      trailing: figure.isEmpty
          ? null
          : Text(
              figure,
              style: IslandText.compactFigure(
                stats.status == IslandStatus.live ? IslandColors.dim : _tint,
              ),
            ),
    );
  }

  @override
  Widget glyph(BuildContext context, double size) => _ring(size);

  List<Widget> _actions(AppLocalizations l10n, {double size = 32}) {
    final retry = this.retry;
    return [
      if (retry != null &&
          (stats.status == IslandStatus.failed ||
              stats.status == IslandStatus.waiting))
        IslandRoundButton(
          icon: CupertinoIcons.arrow_clockwise,
          size: size,
          label: stats.status == IslandStatus.failed
              ? l10n.remoteFilesCopyRetry
              : l10n.remoteFilesCopyResume,
          tint: _tint,
          onPressed: () => unawaited(retry()),
        ),
      if (!stats.status.finished)
        IslandRoundButton(
          icon: CupertinoIcons.xmark,
          size: size,
          label: l10n.islandTransferStop,
          onPressed: () => unawaited(stop()),
        ),
    ];
  }

  @override
  Widget featured(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    final status = _status(l10n);
    final count = stats.count > 1
        ? l10n.remoteFilesCopyItemsDone(stats.completed, stats.count)
        : null;
    final bytes = _bytes();
    final left = [?count, if (bytes.isNotEmpty) bytes].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IslandHead(
            leading: IslandTile(tint: _tint, child: _ring(24)),
            title: _title(l10n),
            subtitle: _route(l10n),
            trailing: _actions(l10n),
          ),
          const SizedBox(height: 14),
          IslandBar(
            value: stats.status == IslandStatus.done ? 1 : stats.fraction,
            tint: _tint,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 16 * MediaQuery.textScalerOf(context).scale(12) / 12,
            child: CopyFigures(
              left: left,
              right: status,
              leftStyle: IslandText.figures,
              rightStyle: IslandText.figures.copyWith(
                color: stats.status == IslandStatus.live
                    ? IslandColors.dim
                    : _tint,
                fontWeight: stats.status == IslandStatus.live
                    ? FontWeight.w400
                    : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget row(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    final actions = _actions(l10n, size: 28);
    return IslandRowLine(
      leading: _ring(18),
      title: _title(l10n),
      status: stats.status == IslandStatus.live && stats.totalBytes > 0
          ? '${stats.percent}%'
          : _status(l10n),
      statusColor: stats.status == IslandStatus.live ? null : _tint,
      onTap: () => controls.feature(id),
      trailing: actions.isEmpty ? null : actions.last,
    );
  }

  @override
  String describe(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [
      _title(l10n),
      _route(l10n),
      if (stats.status == IslandStatus.live && stats.totalBytes > 0)
        '${stats.percent}%'
      else
        _status(l10n),
    ].where((part) => part.isNotEmpty).join(', ');
  }
}
