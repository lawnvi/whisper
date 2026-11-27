import 'dart:async';

import 'package:whisper/socket/transfer_ack_watchdog.dart';

/// Schedules automatic backoff retries for a single outgoing transfer whose
/// ACK watchdog expired, without tearing down the peer connection.
///
/// Resets the stalled-retry count whenever durable progress advances; returns
/// `false` once [delays.length] consecutive retries make no durable progress.
final class TransferTimeoutRetryTracker {
  TransferTimeoutRetryTracker({
    TransferAckTimerFactory? timerFactory,
    this.delays = defaultDelays,
  }) : _timerFactory = timerFactory ?? Timer.new;

  static const List<Duration> defaultDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  final TransferAckTimerFactory _timerFactory;
  final List<Duration> delays;
  final Map<String, _TimeoutRetryState> _states =
      <String, _TimeoutRetryState>{};

  bool scheduleRetry({
    required String transferId,
    required String peerId,
    required int durableOffset,
    required Future<void> Function() onRetry,
  }) {
    final existing = _states[transferId];
    existing?.timer?.cancel();
    existing?.timer = null;

    var stalledRetries = existing?.stalledRetries ?? 0;
    if (existing != null && durableOffset > existing.lastProgressOffset) {
      stalledRetries = 0;
    }
    if (stalledRetries >= delays.length) {
      _states.remove(transferId);
      return false;
    }
    final delay = delays[stalledRetries];
    final state = _TimeoutRetryState(
      peerId: peerId,
      lastProgressOffset: durableOffset,
      stalledRetries: stalledRetries + 1,
    );
    _states[transferId] = state;
    state.timer = _timerFactory(delay, () {
      if (!identical(_states[transferId], state)) {
        return;
      }
      state.timer = null;
      unawaited(onRetry());
    });
    return true;
  }

  /// Watches a re-sent `fileOffer` so a silent receiver that never replies
  /// `fileReady` still advances to the next backoff retry or terminal failure.
  void scheduleOfferTimeout({
    required String transferId,
    required Duration delay,
    required Future<void> Function() onTimeout,
  }) {
    final state = _states[transferId];
    if (state == null) {
      return;
    }
    state.offerTimer?.cancel();
    state.offerTimer = _timerFactory(delay, () {
      if (!identical(_states[transferId], state)) {
        return;
      }
      state.offerTimer = null;
      unawaited(onTimeout());
    });
  }

  void cancelOfferTimeout(String transferId) {
    final state = _states[transferId];
    state?.offerTimer?.cancel();
    state?.offerTimer = null;
  }

  void noteProgress(String transferId, int durableOffset) {
    final state = _states[transferId];
    if (state != null && durableOffset > state.lastProgressOffset) {
      state.timer?.cancel();
      state.offerTimer?.cancel();
      _states.remove(transferId);
    }
  }

  void clear(String transferId) {
    final state = _states.remove(transferId);
    state?.timer?.cancel();
    state?.offerTimer?.cancel();
  }

  void clearPeer(String peerId) {
    final ids = <String>[
      for (final entry in _states.entries)
        if (entry.value.peerId == peerId) entry.key,
    ];
    for (final id in ids) {
      clear(id);
    }
  }

  void clearAll() {
    for (final state in _states.values) {
      state.timer?.cancel();
      state.offerTimer?.cancel();
    }
    _states.clear();
  }
}

final class _TimeoutRetryState {
  _TimeoutRetryState({
    required this.peerId,
    required this.lastProgressOffset,
    required this.stalledRetries,
  });

  final String peerId;
  final int lastProgressOffset;
  final int stalledRetries;
  Timer? timer;
  Timer? offerTimer;
}
