import 'dart:async';

import 'package:whisper/helper/loop_lag.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/remote_input/remote_input_lane.dart';

/// Says every few seconds, while the pointer is being moved, how its moves
/// fared at this end and how late this device's own event loop ran. With
/// the pacer's lines (`transfer_pacing`) the log then tells where a pointer
/// that lagged during a transfer was held up: on the sending device, on the
/// way, or here.
final class RemoteInputLaneReport {
  RemoteInputLaneReport(
    this.side,
    this._take, {
    Duration every = const Duration(seconds: 5),
  }) {
    _timer = Timer.periodic(every, (_) {
      final window = _take();
      if (window == null) {
        // The pointer rests: nothing to watch the event loop for.
        _lag.stop();
        _watched = false;
        return;
      }
      privacyLog.event(PrivacyEvent.remoteInputLane, {
        PrivacyField.role: side,
        PrivacyField.running: true,
        // Watched only from the second stretch of moves on.
        if (_watched) PrivacyField.loopLagMs: _lag.takeWorstMs(),
        ...window,
      });
      _lag.start();
      _watched = true;
    });
  }

  final RemoteInputLaneSide side;
  final Map<PrivacyField, Object>? Function() _take;
  final LoopLag _lag = LoopLag();
  late final Timer _timer;
  bool _watched = false;

  void close() {
    _timer.cancel();
    _lag.stop();
  }
}

/// How long the moves of a few seconds waited: at the sending end from
/// being captured to being sent, at the receiving end longer on the way
/// than the quickest of the session. Fewer than [least] say nothing.
final class MoveWaits {
  final List<int> _ms = [];
  static const least = 20;

  void add(int ms) {
    if (_ms.length < 4096) _ms.add(ms);
  }

  /// The count and the waits of the moves since the last call, less
  /// [quickest], or null when there were too few.
  Map<PrivacyField, Object>? take({int quickest = 0}) {
    if (_ms.length < least) {
      _ms.clear();
      return null;
    }
    _ms.sort();
    int at(double fraction) =>
        _ms[((_ms.length - 1) * fraction).round()] - quickest;
    final fields = <PrivacyField, Object>{
      PrivacyField.count: _ms.length,
      PrivacyField.waitP50Ms: at(0.5),
      PrivacyField.waitP95Ms: at(0.95),
      PrivacyField.waitMaxMs: at(1),
    };
    _ms.clear();
    return fields;
  }
}
