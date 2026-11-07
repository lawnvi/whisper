import 'dart:async';
import 'dart:math' as math;

/// Keeps a transfer from crowding out what is live on the same devices and
/// link: sound and keyboard and mouse, which need little bandwidth but must
/// not wait. The rate grows while they are fine and drops as soon as
/// anything says otherwise: the sound running low or late, or this device's
/// own event loop falling behind. It remembers how fast it was going when
/// trouble began and stays below that for a while, so it does not keep
/// running into it. With nothing live it soon stops holding the transfer
/// back.
class TransferPacer {
  TransferPacer({
    required bool Function() audioStrained,
    this.floor = 4e6,
    this.start = 24e6,
    this.ceiling = 2e9,
    DateTime Function()? now,
  }) : _audioStrained = audioStrained,
       _now = now ?? DateTime.now,
       _rate = start;

  /// Bytes per second.
  final double floor, start, ceiling;
  final bool Function() _audioStrained;
  final DateTime Function() _now;

  double _rate;
  DateTime? _nextSend;
  DateTime? _lastUse;
  DateTime? _lastTick;
  DateTime? _holdUntil;
  Timer? _timer;

  /// What went since the last look: the speed actually reached, which the
  /// rate is kept close to (a rate far above it says nothing).
  int _bytesSinceTick = 0;

  /// The rate trouble began at last, forgotten after a while.
  double? _troubleAt;
  DateTime? _troubleWhen;

  static const tick = Duration(milliseconds: 250);
  static const _lagLimit = Duration(milliseconds: 40);
  static const _troubleMemory = Duration(minutes: 1);

  /// Bytes per second now.
  double get rate => _rate;

  /// Waits until [bytes] more may go.
  Future<void> take(int bytes) async {
    final now = _now();
    _lastUse = now;
    _timer ??= Timer.periodic(tick, (_) => evaluate());
    _lastTick ??= now;
    final next = _nextSend;
    // Idle time is not saved up: no burst after a pause.
    final at = next == null || next.isBefore(now) ? now : next;
    _nextSend = at.add(
      Duration(
        microseconds: (bytes / _rate * Duration.microsecondsPerSecond).round(),
      ),
    );
    _bytesSinceTick += bytes;
    final wait = at.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// Looks at how things are and sets the rate. Runs by itself while the
  /// pacer is in use.
  void evaluate() {
    final now = _now();
    final lastTick = _lastTick ?? now;
    _lastTick = now;
    final elapsed = now.difference(lastTick);
    final lag = elapsed - tick;
    final sent = _bytesSinceTick;
    _bytesSinceTick = 0;
    final lastUse = _lastUse;
    if (lastUse == null ||
        now.difference(lastUse) > const Duration(seconds: 2)) {
      // Idle: the next transfer starts from the start again.
      _timer?.cancel();
      _timer = null;
      _lastTick = null;
      _rate = start;
      return;
    }
    final actual = elapsed > Duration.zero
        ? sent / elapsed.inMicroseconds * Duration.microsecondsPerSecond
        : 0.0;
    final hold = _holdUntil;
    final waiting = hold != null && now.isBefore(hold);
    final audio = _audioStrained();
    if (audio || lag > _lagLimit) {
      // Once per bout: what is already on its way takes a moment to clear,
      // and cutting again meanwhile would go far too low.
      if (waiting) return;
      final reached = math.min(_rate, math.max(actual, floor));
      // Only the sound says how fast is too fast; a busy moment here does
      // not.
      if (audio) {
        _troubleAt = reached;
        _troubleWhen = now;
      }
      _rate = math.max(floor, reached * 0.6);
      _holdUntil = now.add(const Duration(seconds: 1));
      return;
    }
    if (waiting) return;
    // The link or the window holds it back, not the pacer: stay close to
    // what it reaches.
    if (actual < _rate * 0.8) {
      _rate = math.max(floor, math.min(_rate, actual * 1.3 + 2e6));
      return;
    }
    final trouble = _troubleAt;
    final when = _troubleWhen;
    final recent = when != null && now.difference(when) < _troubleMemory;
    // Below where the sound began to suffer while that is fresh; past it
    // later only gently, to find out whether it still does.
    final limit = trouble != null && recent
        ? math.max(start / 2, trouble * 0.85)
        : ceiling;
    final careful = trouble != null && _rate >= trouble * 0.85;
    final step = careful
        ? math.max(0.5e6, _rate * 0.02)
        : math.max(2e6, _rate * 0.15);
    _rate = math.max(floor, math.min(limit, _rate + step));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
