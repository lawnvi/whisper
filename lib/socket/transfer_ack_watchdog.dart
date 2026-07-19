import 'dart:async';

import 'package:whisper/socket/peer_connection.dart';

export 'package:whisper/socket/peer_connection.dart'
    show TransferConnectionBinding;

typedef TransferAckTimerFactory = Timer Function(
  Duration delay,
  void Function() callback,
);

final class TransferAckWindow {
  const TransferAckWindow({
    required this.transferId,
    required this.connection,
    required this.durableOffset,
    required this.sentEnd,
    required this.attempt,
  });

  final String transferId;
  final TransferConnectionBinding connection;
  final int durableOffset;
  final int sentEnd;
  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is TransferAckWindow &&
      other.transferId == transferId &&
      other.connection == connection &&
      other.durableOffset == durableOffset &&
      other.sentEnd == sentEnd &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(
        transferId,
        connection,
        durableOffset,
        sentEnd,
        attempt,
      );
}

typedef TransferAckRetransmit = FutureOr<int?> Function(
  TransferAckWindow timeout,
);
typedef TransferAckUnresponsive = FutureOr<void> Function(
  TransferAckWindow timeout,
);

final class TransferAckWatchdog {
  TransferAckWatchdog({
    TransferAckTimerFactory? timerFactory,
    this.timeout = const Duration(seconds: 15),
    DateTime Function()? now,
  })  : _timerFactory = timerFactory ?? Timer.new,
        _now = now ?? DateTime.now;

  final TransferAckTimerFactory _timerFactory;
  final Duration timeout;
  final DateTime Function() _now;
  final Map<String, _TransferAckEntry> _entries = <String, _TransferAckEntry>{};

  /// 最近一次被 acknowledge 的窗口(按 transferId)。
  ///
  /// 引擎收到 ACK 后总是先 acknowledge 再重挂窗口;只有 durableOffset
  /// 真正推进的重挂才把尝试计数复位到 1,无进度的 ACK 不能给停滞的
  /// 对端无限续命——连续 3 次无任何 durable 进度才判失活。
  final Map<String, TransferAckWindow> _acknowledgedWindows =
      <String, TransferAckWindow>{};

  /// 当前"无 durable 进度"回合的截止时间(按 transferId)。
  ///
  /// 无进度的 ACK 重挂窗口时不得重置截止时间,只继承剩余时间,
  /// 否则接收端磁盘卡死但网络栈持续回同 durableOffset ACK 时,
  /// 每个 ACK 都换来一个全新的完整计时,markUnresponsive 永远不会
  /// 触发。只有 durable 进度推进或超时重传才重新起算完整超时。
  final Map<String, ({int durableOffset, DateTime deadline})> _deadlines =
      <String, ({int durableOffset, DateTime deadline})>{};
  bool _closed = false;

  TransferAckWindow armWindow({
    required String transferId,
    required TransferConnectionBinding connection,
    required int durableOffset,
    required int sentEnd,
    required TransferAckRetransmit retransmit,
    required TransferAckUnresponsive markUnresponsive,
  }) {
    if (_closed) {
      throw StateError('Transfer ACK watchdog is closed');
    }
    if (durableOffset < 0 || sentEnd < durableOffset) {
      throw ArgumentError('Invalid ACK window bounds');
    }
    final window = TransferAckWindow(
      transferId: transferId,
      connection: connection,
      durableOffset: durableOffset,
      sentEnd: sentEnd,
      attempt: _initialAttemptFor(transferId, durableOffset),
    );
    _replaceEntry(
      window: window,
      retransmit: retransmit,
      markUnresponsive: markUnresponsive,
      armTimer: true,
      delay: _claimDeadline(transferId, durableOffset),
    );
    return window;
  }

  TransferAckWindow publishWindow({
    required String transferId,
    required TransferConnectionBinding connection,
    required int durableOffset,
    required int sentEnd,
    required TransferAckRetransmit retransmit,
    required TransferAckUnresponsive markUnresponsive,
  }) {
    if (_closed) {
      throw StateError('Transfer ACK watchdog is closed');
    }
    if (durableOffset < 0 || sentEnd < durableOffset) {
      throw ArgumentError('Invalid ACK window bounds');
    }
    final window = TransferAckWindow(
      transferId: transferId,
      connection: connection,
      durableOffset: durableOffset,
      sentEnd: sentEnd,
      attempt: _initialAttemptFor(transferId, durableOffset),
    );
    _replaceEntry(
      window: window,
      retransmit: retransmit,
      markUnresponsive: markUnresponsive,
      armTimer: false,
    );
    return window;
  }

  /// durable 进度推进 → 复位到 1;原地重挂(无进度)→ 继承尝试计数。
  int _initialAttemptFor(String transferId, int durableOffset) {
    final prior =
        _entries[transferId]?.window ?? _acknowledgedWindows[transferId];
    if (prior == null || durableOffset > prior.durableOffset) {
      return 1;
    }
    return prior.attempt;
  }

  /// durable 进度推进(或首次挂窗)→ 全新完整超时并记录新截止时间;
  /// 原地重挂(无进度 ACK)→ 只继承本回合剩余时间,截止时间不变。
  Duration _claimDeadline(String transferId, int durableOffset) {
    final now = _now();
    final current = _deadlines[transferId];
    if (current == null || current.durableOffset != durableOffset) {
      _deadlines[transferId] = (
        durableOffset: durableOffset,
        deadline: now.add(timeout),
      );
      return timeout;
    }
    final remaining = current.deadline.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  TransferAckWindow? currentWindow(String transferId) =>
      _entries[transferId]?.window;

  bool acknowledge(TransferAckWindow expected) {
    final entry = _entries[expected.transferId];
    if (entry == null || !identical(entry.window, expected)) {
      return false;
    }
    _entries.remove(expected.transferId);
    _acknowledgedWindows[expected.transferId] = expected;
    entry.timer?.cancel();
    return true;
  }

  void cancel(String transferId) {
    _acknowledgedWindows.remove(transferId);
    _deadlines.remove(transferId);
    _entries.remove(transferId)?.timer?.cancel();
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _acknowledgedWindows.clear();
    _deadlines.clear();
    final entries = _entries.values.toList(growable: false);
    _entries.clear();
    for (final entry in entries) {
      entry.timer?.cancel();
    }
  }

  void _replaceEntry({
    required TransferAckWindow window,
    required TransferAckRetransmit retransmit,
    required TransferAckUnresponsive markUnresponsive,
    required bool armTimer,
    Duration? delay,
  }) {
    _entries.remove(window.transferId)?.timer?.cancel();
    final entry = _TransferAckEntry(
      window: window,
      retransmit: retransmit,
      markUnresponsive: markUnresponsive,
    );
    _entries[window.transferId] = entry;
    if (armTimer) {
      entry.timer = _timerFactory(delay ?? timeout, () {
        unawaited(_handleTimeout(entry));
      });
    }
  }

  Future<void> _handleTimeout(_TransferAckEntry entry) async {
    if (_closed || !_isCurrent(entry)) {
      return;
    }
    entry.timer = null;
    final window = entry.window;
    if (window.attempt == 3) {
      _entries.remove(window.transferId);
      _acknowledgedWindows.remove(window.transferId);
      _deadlines.remove(window.transferId);
      try {
        await entry.markUnresponsive(window);
      } catch (_) {
        // The owning connection lifecycle handles logging and recovery.
      }
      return;
    }

    int? resentEnd;
    try {
      resentEnd = await entry.retransmit(window);
    } catch (_) {
      if (_isCurrent(entry)) {
        _entries.remove(window.transferId);
        _acknowledgedWindows.remove(window.transferId);
        _deadlines.remove(window.transferId);
      }
      return;
    }
    if (!_isCurrent(entry)) {
      return;
    }
    if (resentEnd == null) {
      _entries.remove(window.transferId);
      _acknowledgedWindows.remove(window.transferId);
      _deadlines.remove(window.transferId);
      return;
    }
    final next = TransferAckWindow(
      transferId: window.transferId,
      connection: window.connection,
      durableOffset: window.durableOffset,
      sentEnd: resentEnd,
      attempt: window.attempt + 1,
    );
    // 超时重传开启新一轮完整计时:截止时间从重传时刻重新起算,
    // 之后无进度的 ACK 只能继承这一轮的剩余时间。
    _deadlines[next.transferId] = (
      durableOffset: next.durableOffset,
      deadline: _now().add(timeout),
    );
    _replaceEntry(
      window: next,
      retransmit: entry.retransmit,
      markUnresponsive: entry.markUnresponsive,
      armTimer: true,
    );
  }

  bool _isCurrent(_TransferAckEntry entry) =>
      identical(_entries[entry.window.transferId], entry);
}

final class _TransferAckEntry {
  _TransferAckEntry({
    required this.window,
    required this.retransmit,
    required this.markUnresponsive,
  });

  final TransferAckWindow window;
  final TransferAckRetransmit retransmit;
  final TransferAckUnresponsive markUnresponsive;
  Timer? timer;
}
