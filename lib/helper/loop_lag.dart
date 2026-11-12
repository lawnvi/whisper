import 'dart:async';

/// How far behind this isolate's event loop runs: the most a short timer
/// fired late since last asked. Keyboard and mouse events on their way
/// through this device wait that long.
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
    _timer = Timer.periodic(every, (_) {
      final late = _clock.elapsedMicroseconds - every.inMicroseconds;
      _clock.reset();
      if (late > _worstMicros) _worstMicros = late;
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
