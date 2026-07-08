import 'package:whisper/model/file_transfer.dart';

/// interrupted 与 terminal 的原生展示相同(showTerminal),但语义不同:
/// interrupted 只是全员停滞的通知形态,聚合器这一代尚未终结,
/// 消费方不得据此丢弃聚合器,否则分批停滞会重复弹"已中断"且计数漂移。
enum TransferNotificationKind { progress, interrupted, terminal, cancel }

class TransferNotificationCommand {
  const TransferNotificationCommand({
    required this.kind,
    this.title = '',
    this.text = '',
    this.progress = 0,
    this.success = false,
  });

  final TransferNotificationKind kind;
  final String title;
  final String text;
  final int progress;
  final bool success;
}

/// 文案由调用方注入(l10n 留在 UI 层)。
class TransferNotificationStrings {
  const TransferNotificationStrings({
    required this.title,
    required this.bodySending,
    required this.bodyReceiving,
    required this.bodyMixed,
    required this.completed,
    required this.interrupted,
  });

  final String Function(int count) title;
  final String Function(int percent, String speed, String remaining)
      bodySending;
  final String Function(int percent, String speed, String remaining)
      bodyReceiving;
  final String Function(int percent, String speed, String remaining) bodyMixed;
  final String Function(int count) completed;
  final String Function() interrupted;
}

String formatBytesForNotification(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// 把逐笔 TransferSnapshot 聚合成单条通知的状态流:
/// 字节加权进度、显示值单调不回退、≥1s 节流(终态豁免)。
class TransferNotificationAggregator {
  TransferNotificationAggregator({
    int Function()? nowMillis,
    required this.strings,
  }) : _nowMillis = nowMillis ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;
  static const int _throttleMillis = 300;

  final TransferNotificationStrings strings;
  final int Function() _nowMillis;
  final Map<String, TransferSnapshot> _active = <String, TransferSnapshot>{};
  final Map<String, TransferSnapshot> _terminal = <String, TransferSnapshot>{};
  int _lastEmitMillis = -_throttleMillis;
  int _displayedPercent = 0;
  int _lastBytes = 0;
  int _lastBytesMillis = 0;
  bool _stalledNotified = false;

  TransferNotificationCommand? onSnapshot(TransferSnapshot snapshot) {
    if (isTerminalFileTransferState(snapshot.state)) {
      if (!_active.containsKey(snapshot.transferId) &&
          !_terminal.containsKey(snapshot.transferId)) {
        return null; // 不认识的传输,忽略
      }
      _active.remove(snapshot.transferId);
      _terminal[snapshot.transferId] = snapshot;
      if (_active.isNotEmpty) {
        return _stalledOrProgress(forceProgress: true);
      }
      return _finishGeneration();
    }

    _active[snapshot.transferId] = snapshot;
    if (_isResumingState(snapshot.state)) {
      final wasStalled = _stalledNotified;
      _stalledNotified = false;
      return _progressCommand(force: wasStalled);
    }
    return _stalledOrProgress(forceProgress: false);
  }

  TransferNotificationCommand? _stalledOrProgress({
    required bool forceProgress,
  }) {
    if (_isStalled()) {
      if (_stalledNotified) {
        return null;
      }
      _stalledNotified = true;
      return TransferNotificationCommand(
        kind: TransferNotificationKind.interrupted,
        title: strings.title(_active.length + _terminal.length),
        text: strings.interrupted(),
        success: false,
      );
    }
    return _progressCommand(force: forceProgress);
  }

  bool _isResumingState(FileTransferState state) {
    return state == FileTransferState.transferring ||
        state == FileTransferState.negotiating;
  }

  bool _isStalled() {
    return _active.isNotEmpty &&
        _active.values.every((s) =>
            s.state == FileTransferState.waitingReconnect ||
            s.state == FileTransferState.paused);
  }

  TransferNotificationCommand? _progressCommand({required bool force}) {
    final now = _nowMillis();
    if (!force && now - _lastEmitMillis < _throttleMillis) {
      return null;
    }
    _lastEmitMillis = now;

    final all = <TransferSnapshot>[..._active.values, ..._terminal.values];
    final totalBytes =
        all.fold<int>(0, (sum, s) => sum + (s.size > 0 ? s.size : 0));
    final doneBytes =
        all.fold<int>(0, (sum, s) => sum + s.committedBytes.clamp(0, s.size));
    final rawPercent =
        totalBytes <= 0 ? 0 : (doneBytes * 100 ~/ totalBytes).clamp(0, 100);
    if (rawPercent > _displayedPercent) {
      _displayedPercent = rawPercent;
    }

    final speed = _speedText(doneBytes, now);
    final remaining = formatBytesForNotification(
        (totalBytes - doneBytes).clamp(0, totalBytes));
    final hasOutgoing = _active.values
        .any((s) => s.direction == FileTransferDirection.outgoing);
    final hasIncoming = _active.values
        .any((s) => s.direction == FileTransferDirection.incoming);
    final String text;
    if (hasOutgoing && hasIncoming) {
      text = strings.bodyMixed(_displayedPercent, speed, remaining);
    } else if (hasIncoming) {
      text = strings.bodyReceiving(_displayedPercent, speed, remaining);
    } else {
      text = strings.bodySending(_displayedPercent, speed, remaining);
    }
    return TransferNotificationCommand(
      kind: TransferNotificationKind.progress,
      title: strings.title(all.length),
      text: text,
      progress: _displayedPercent,
    );
  }

  String _speedText(int doneBytes, int now) {
    if (_lastBytesMillis == 0 || now <= _lastBytesMillis) {
      _lastBytes = doneBytes;
      _lastBytesMillis = now;
      return '${formatBytesForNotification(0)}/s';
    }
    final deltaBytes = (doneBytes - _lastBytes).clamp(0, doneBytes);
    final deltaMillis = now - _lastBytesMillis;
    _lastBytes = doneBytes;
    _lastBytesMillis = now;
    final perSecond = deltaBytes * 1000 ~/ deltaMillis;
    return '${formatBytesForNotification(perSecond)}/s';
  }

  TransferNotificationCommand _finishGeneration() {
    final results = _terminal.values.toList(growable: false);
    _reset();
    final allCanceled =
        results.every((s) => s.state == FileTransferState.canceled);
    if (allCanceled) {
      return const TransferNotificationCommand(
          kind: TransferNotificationKind.cancel);
    }
    final anyFailed = results.any((s) =>
        s.state == FileTransferState.failed ||
        s.state == FileTransferState.canceled);
    if (anyFailed) {
      return TransferNotificationCommand(
        kind: TransferNotificationKind.terminal,
        title: strings.title(results.length),
        text: strings.interrupted(),
        success: false,
      );
    }
    return TransferNotificationCommand(
      kind: TransferNotificationKind.terminal,
      title: strings.title(results.length),
      text: strings.completed(results.length),
      progress: 100,
      success: true,
    );
  }

  void _reset() {
    _active.clear();
    _terminal.clear();
    _displayedPercent = 0;
    _lastBytes = 0;
    _lastBytesMillis = 0;
    _lastEmitMillis = -_throttleMillis;
    _stalledNotified = false;
  }
}
