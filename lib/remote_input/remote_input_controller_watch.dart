import 'dart:async';

/// Notices, on the controlled computer, that the controlling one is gone
/// when nothing closed the connection: it slept, or left the network. The
/// WebSocket finds out only once its pings go unanswered, 15 to 30 seconds,
/// and until then this side holds down every key and button the controller
/// had down: a stuck Ctrl or Command turns whatever is typed here into
/// shortcuts.
///
/// A controlling computer sends nothing while its pointer rests here, so the
/// input itself can't tell. Its UDP lane keeps talking four times a second,
/// though: once the lane has been heard, [quietFor] of silence while the
/// pointer is here ([controlled]) means the controller is gone, and
/// [onGone] runs once. Without a lane ([laneHealthy] null), or before it
/// answered once, the WebSocket decides as before. A phone has its own
/// deadline on its heartbeats.
final class RemoteInputControllerWatch {
  RemoteInputControllerWatch({
    required bool? Function() laneHealthy,
    required bool Function() controlled,
    required void Function() onGone,
    this.quietFor = const Duration(seconds: 3),
  }) : _laneHealthy = laneHealthy,
       _controlled = controlled,
       _onGone = onGone {
    _timer = Timer.periodic(_tick, (_) => _check());
  }

  final bool? Function() _laneHealthy;
  final bool Function() _controlled;
  final void Function() _onGone;
  final Duration quietFor;
  late final Timer _timer;

  /// Counted in ticks rather than by a clock: an event loop that stalls
  /// delays the ticks, and errs towards keeping the session.
  Duration get _tick => quietFor ~/ 6;
  bool _heard = false;
  int _quietTicks = 0;

  void _check() {
    final healthy = _laneHealthy();
    if (healthy == null) return;
    if (healthy) {
      _heard = true;
      _quietTicks = 0;
      return;
    }
    if (!_heard || !_controlled()) {
      _quietTicks = 0;
      return;
    }
    _quietTicks += 1;
    if (_quietTicks < 6) return;
    cancel();
    _onGone();
  }

  void cancel() => _timer.cancel();
}
