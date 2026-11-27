import 'dart:async';
import 'dart:math' as math;

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/folder_transfer_source.dart';
import 'package:whisper/socket/outgoing_progress_estimator.dart';
import 'package:whisper/socket/transfer_ack_watchdog.dart';

/// Tracks smoothed UI progress for active outgoing transfers so the UI moves
/// steadily between coarse ACK intervals without exceeding sent bytes.
final class OutgoingProgressHub {
  OutgoingProgressHub({
    required DateTime Function() now,
    required TransferAckTimerFactory timerFactory,
    required Duration dispatchInterval,
    required int? Function(String transferId) sentEndFor,
    required FileTransferSource? Function(String transferId) sourceFor,
    required void Function(TransferSnapshot snapshot) onSnapshot,
  }) : _now = now,
       _timerFactory = timerFactory,
       _dispatchInterval = dispatchInterval,
       _sentEndFor = sentEndFor,
       _sourceFor = sourceFor,
       _onSnapshot = onSnapshot;

  final DateTime Function() _now;
  final TransferAckTimerFactory _timerFactory;
  final Duration _dispatchInterval;
  final int? Function(String transferId) _sentEndFor;
  final FileTransferSource? Function(String transferId) _sourceFor;
  final void Function(TransferSnapshot snapshot) _onSnapshot;

  final Map<String, _TrackedOutgoingProgress> _trackers =
      <String, _TrackedOutgoingProgress>{};
  final Map<String, double> _lastRateByPeer = <String, double>{};
  Timer? _timer;

  void track(
    FileTransferData transfer, {
    required int durableOffset,
    required bool followsConfirmed,
  }) {
    final nowMs = _now().millisecondsSinceEpoch;
    final existing = _trackers[transfer.transferId];
    if (existing != null) {
      existing.transfer = transfer;
      existing.estimator.reset(durableOffset, nowMs);
    } else {
      _trackers[transfer.transferId] = _TrackedOutgoingProgress(
        transfer: transfer,
        estimator: OutgoingProgressEstimator(
          durableOffset: durableOffset,
          nowMs: nowMs,
          seedRateBytesPerMs: _lastRateByPeer[transfer.peerUid] ?? 0,
          followsConfirmed: followsConfirmed,
        ),
      );
    }
    _timer ??= _timerFactory(_dispatchInterval, _tick);
  }

  void onAck(String transferId, int durableOffset) {
    _trackers[transferId]?.estimator.onAck(
      durableOffset,
      _now().millisecondsSinceEpoch,
    );
  }

  TransferSnapshot maybeSmoothSnapshot(
    FileTransferData data,
    TransferSnapshot snapshot,
  ) {
    final tracker = _trackers[data.transferId];
    if (tracker == null || data.direction != FileTransferDirection.outgoing) {
      return snapshot;
    }
    tracker.transfer = data;
    if (data.state != FileTransferState.transferring) {
      return snapshot;
    }
    final smoothed = _displaySnapshot(tracker, _now().millisecondsSinceEpoch);
    tracker.lastEmitted = smoothed.committedBytes;
    return smoothed;
  }

  void untrack(String transferId) {
    final tracker = _trackers.remove(transferId);
    if (tracker == null) {
      return;
    }
    final rate = tracker.estimator.rateBytesPerMs;
    if (rate > 0) {
      _lastRateByPeer[tracker.transfer.peerUid] = rate;
    }
    if (_trackers.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void clear() {
    for (final transferId in _trackers.keys.toList()) {
      untrack(transferId);
    }
  }

  TransferSnapshot _displaySnapshot(
    _TrackedOutgoingProgress tracker,
    int nowMs,
  ) {
    final transfer = tracker.transfer;
    final sentEnd =
        _sentEndFor(transfer.transferId) ?? tracker.estimator.durableOffset;
    final displayed = tracker.estimator.estimate(
      nowMs: nowMs,
      sentEnd: sentEnd,
      size: transfer.size,
    );
    // A folder's display walks towards what the receiver has confirmed and
    // is deliberately a little behind it; see the estimator.
    final committedBytes = tracker.estimator.followsConfirmed
        ? displayed
        : math.max(displayed, transfer.committedBytes);
    final source = _sourceFor(transfer.transferId);
    return TransferSnapshot(
      transferId: transfer.transferId,
      messageUuid: transfer.messageUuid,
      peerUid: transfer.peerUid,
      direction: transfer.direction,
      state: FileTransferState.transferring,
      finalPath: transfer.finalPath,
      tempPath: transfer.tempPath,
      size: transfer.size,
      committedBytes: committedBytes,
      lastError: transfer.lastError,
      updatedAt: nowMs,
      filesDone: source is FolderTransferSource
          ? source.filesBefore(committedBytes)
          : null,
    );
  }

  void _tick() {
    final nowMs = _now().millisecondsSinceEpoch;
    for (final tracker in _trackers.values.toList()) {
      if (tracker.transfer.state != FileTransferState.transferring) {
        continue;
      }
      final snapshot = _displaySnapshot(tracker, nowMs);
      if (snapshot.committedBytes == tracker.lastEmitted) {
        continue;
      }
      tracker.lastEmitted = snapshot.committedBytes;
      _onSnapshot(snapshot);
    }
    _timer = _trackers.isEmpty ? null : _timerFactory(_dispatchInterval, _tick);
  }
}

final class _TrackedOutgoingProgress {
  _TrackedOutgoingProgress({required this.transfer, required this.estimator});

  FileTransferData transfer;
  final OutgoingProgressEstimator estimator;
  int lastEmitted = -1;
}
