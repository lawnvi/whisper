import 'dart:async';

/// How far behind this isolate's event loop runs: the most a short timer
/// fired after it was due, since last asked. Keyboard and mouse events on
/// their way through this device wait as long.
///
/// Each timer is set when the one before fires. A periodic timer keeps to
/// its first schedule, so a loop that stays behind fires it at the usual
/// spacing, and the gaps between firings looked punctual. On Windows a
/// timer comes up to about 16 ms late with nothing behind.
final class LoopLag {
  LoopLag({this.every = const Duration(milliseconds: 50)});

  final Duration every;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _worstMicros = 0;

  void start() {
    if (_timer != null) return;
    _clock
      ..reset()
      ..start();
    _arm();
  }

  void _arm() {
    final due = _clock.elapsedMicroseconds + every.inMicroseconds;
    _timer = Timer(every, () {
      final late = _clock.elapsedMicroseconds - due;
      if (late > _worstMicros) _worstMicros = late;
      _arm();
    });
  }

  /// The worst since the last call, in milliseconds.
  int takeWorstMs() {
    final worst = _worstMicros;
    _worstMicros = 0;
    return worst ~/ 1000;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }
}
