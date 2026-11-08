import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How good the link to a device is, from round trips measured lately.
enum LinkGrade { measuring, good, fair, poor, unreachable }

/// How the link to one device is doing, measured while someone looks at it:
/// every [every] a connection to its port, which is one round trip and says
/// nothing on the wire (as the connection check does). The last [keep]
/// tries give the latency, how much it varies, and how many got no answer.
class PeerLinkQuality extends ChangeNotifier {
  PeerLinkQuality({
    required this.host,
    required this.port,
    Future<void> Function(String host, int port)? reach,
    this.every = const Duration(seconds: 2),
    this.timeout = const Duration(milliseconds: 1500),
    this.keep = 20,
  }) : _reach = reach ?? _connect;

  final String host;
  final int port;
  final Duration every, timeout;
  final int keep;
  final Future<void> Function(String host, int port) _reach;

  /// Newest last; null for a try that got no answer in time.
  final List<Duration?> _tries = [];
  Timer? _timer;
  bool _busy = false;

  static Future<void> _connect(String host, int port) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 3),
    );
    socket.destroy();
  }

  List<Duration?> get tries => List.unmodifiable(_tries);

  /// Starts measuring, at once and then every [every].
  void start() {
    if (_timer != null) return;
    unawaited(_try());
    _timer = Timer.periodic(every, (_) => unawaited(_try()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _try() async {
    if (_busy) return;
    _busy = true;
    final watch = Stopwatch()..start();
    Duration? took;
    try {
      await _reach(host, port).timeout(timeout);
      took = watch.elapsed;
    } catch (_) {
      took = null;
    } finally {
      _busy = false;
    }
    if (_timer == null && _tries.isNotEmpty) return;
    record(took);
  }

  /// One try's round trip, or null for one that got no answer.
  @visibleForTesting
  void record(Duration? took) {
    _tries.add(took);
    while (_tries.length > keep) {
      _tries.removeAt(0);
    }
    notifyListeners();
  }

  List<Duration> get _answered => [
    for (final took in _tries)
      if (took != null) took,
  ];

  /// The usual round trip: the median of those answered.
  Duration? get latency {
    final answered = _answered..sort();
    if (answered.isEmpty) return null;
    return answered[answered.length ~/ 2];
  }

  /// How much one round trip differs from the one before, on average.
  Duration? get jitter {
    final answered = _answered;
    if (answered.length < 2) return null;
    var total = 0;
    for (var i = 1; i < answered.length; i++) {
      total += (answered[i] - answered[i - 1]).inMicroseconds.abs();
    }
    return Duration(microseconds: total ~/ (answered.length - 1));
  }

  /// The share of tries that got no answer, 0 to 1.
  double get loss => _tries.isEmpty
      ? 0
      : _tries.where((took) => took == null).length / _tries.length;

  LinkGrade get grade => gradeOf(tries);

  /// Good enough for keyboard and mouse to feel direct and files to go at
  /// the link's speed; fair still works but drags; poor drops and stalls.
  static LinkGrade gradeOf(List<Duration?> tries) {
    if (tries.length < 3) return LinkGrade.measuring;
    final answered = [
      for (final took in tries)
        if (took != null) took.inMicroseconds / 1000,
    ];
    if (answered.isEmpty) return LinkGrade.unreachable;
    final sorted = [...answered]..sort();
    final median = sorted[sorted.length ~/ 2];
    var varies = 0.0;
    for (var i = 1; i < answered.length; i++) {
      varies += (answered[i] - answered[i - 1]).abs();
    }
    varies /= math.max(1, answered.length - 1);
    final lost = 1 - answered.length / tries.length;
    if (median <= 20 && varies <= 15 && lost == 0) return LinkGrade.good;
    if (median <= 80 && varies <= 50 && lost <= 0.1) return LinkGrade.fair;
    return LinkGrade.poor;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
