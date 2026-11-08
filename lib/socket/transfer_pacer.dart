import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

/// Keeps transfers from crowding out what is live on the same devices and
/// link: sound and keyboard and mouse, which need little bandwidth but must
/// not wait behind a queue of file data. While something live is going
/// ([active]) the rate grows while all is well and drops as soon as anything
/// says otherwise: the sound running low or late, this device's own event
/// loop falling behind, or the receiver's answers coming back later than the
/// link takes empty, which is file data piling up in a queue somewhere. It
/// remembers how fast it was going when the sound began to suffer and stays
/// below that for a while. With nothing live it holds nothing back.
///
/// Whatever is going, frames are kept to a quarter second of what the link
/// has been seen to carry, and, with a receiver that answers every second,
/// what is unconfirmed to two seconds of it: on a slow link a whole file
/// handed to the connection at once would hold up every message behind it
/// for minutes.
class TransferPacer {
  TransferPacer({
    required bool Function() audioStrained,
    bool Function()? active,
    this.floor = 64e3,
    this.start = 24e6,
    this.ceiling = 2e9,
    DateTime Function()? now,
  }) : _audioStrained = audioStrained,
       _active = active ?? _always,
       _now = now ?? DateTime.now,
       _rate = start;

  static bool _always() => true;

  /// Bytes per second.
  final double floor, start, ceiling;
  final bool Function() _audioStrained;
  final bool Function() _active;
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

  /// The rate the sound began to suffer at last, forgotten after a while.
  double? _troubleAt;
  DateTime? _troubleWhen;

  /// When each frame of each transfer went: its end offset and the time.
  final Map<String, Queue<(int, DateTime)>> _sent = {};

  /// The last answer of each transfer: where it was and when it came.
  final Map<String, (int, DateTime)> _answered = {};

  /// Bytes per second each transfer's receiver confirmed, smoothed.
  final Map<String, double> _rateOf = {};

  /// Transfers whose receiver was seen answering before a whole interval
  /// came in: it answers every second (`IncomingAckClock`).
  final Set<String> _timely = {};

  /// Bytes per second the receivers confirmed, smoothed.
  double? _confirmed;

  /// How long a byte takes to be confirmed: the least seen lately (the link
  /// with nothing queued), and now (smoothed).
  Duration? _quickest;
  DateTime? _quickestSeen;
  Duration? _answerTime;

  static const tick = Duration(milliseconds: 250);
  static const _lagLimit = Duration(milliseconds: 40);
  static const _queueLimit = Duration(milliseconds: 80);
  static const _troubleMemory = Duration(minutes: 1);
  static const _quickestMemory = Duration(seconds: 30);
  static const _minFrame = 16 * 1024;

  /// Bytes per second now.
  double get rate => _rate;

  /// What the receivers have confirmed lately, in bytes per second.
  double? get confirmedRate => _confirmed;

  /// How much longer an answer takes than with nothing queued.
  Duration get queueDelay {
    final now = _answerTime;
    final quickest = _quickest;
    if (now == null || quickest == null || now < quickest) {
      return Duration.zero;
    }
    return now - quickest;
  }

  /// How much of [transferId] may be on its way unconfirmed, at most
  /// [window]. Only a receiver that answers every second ([timely], or seen
  /// doing so) can be held to less: another would never answer at all.
  int inFlight(String transferId, int window, {required bool timely}) {
    if (!timely && !_timely.contains(transferId)) return window;
    final confirmed = _rateOf[transferId];
    // Until the first answer says how fast the link is, little: on a slow
    // link even a few megabytes queue for minutes.
    final limit = confirmed == null ? 128 << 10 : (confirmed * 2).round();
    return math.max(4 * _minFrame, math.min(window, limit));
  }

  /// How big the next frame of [transferId] may be, at most [chunk].
  int frameBytes(int chunk, [String? transferId]) {
    final confirmed = _rateOf[transferId] ?? _confirmed;
    // Not known yet: start no bigger than the frames of old versions.
    final wanted = confirmed == null
        ? 512 * 1024
        : (confirmed / 4).floor() ~/ _minFrame * _minFrame;
    return math.max(_minFrame, math.min(chunk, wanted));
  }

  /// Waits until [bytes] more may go.
  Future<void> take(int bytes) async {
    final now = _now();
    _lastUse = now;
    _timer ??= Timer.periodic(tick, (_) => evaluate());
    _lastTick ??= now;
    _bytesSinceTick += bytes;
    if (!_active()) {
      _nextSend = null;
      return;
    }
    final next = _nextSend;
    // Idle time is not saved up: no burst after a pause.
    final at = next == null || next.isBefore(now) ? now : next;
    _nextSend = at.add(
      Duration(
        microseconds: (bytes / _rate * Duration.microsecondsPerSecond).round(),
      ),
    );
    final wait = at.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// A frame of [transferId] ending at [endOffset] has gone.
  void sent(String transferId, int endOffset) {
    final frames = _sent.putIfAbsent(transferId, Queue.new);
    frames.addLast((endOffset, _now()));
    // Only the recent past matters; a stuck transfer must not hold much.
    while (frames.length > 512) {
      frames.removeFirst();
    }
  }

  /// The receiver of [transferId] has everything before [durableOffset], of
  /// [size], answering every [interval] bytes or sooner; it had [since]
  /// before.
  void acknowledged(
    String transferId,
    int durableOffset, {
    int? interval,
    int? size,
    int? since,
  }) {
    final now = _now();
    final frames = _sent[transferId];
    DateTime? sentAt;
    while (frames != null &&
        frames.isNotEmpty &&
        frames.first.$1 <= durableOffset) {
      sentAt = frames.removeFirst().$2;
    }
    if (sentAt != null) {
      final took = now.difference(sentAt);
      final quickest = _quickest;
      final seen = _quickestSeen;
      if (quickest == null || took < quickest) {
        _quickest = took;
        _quickestSeen = now;
      } else if (seen == null || now.difference(seen) > _quickestMemory) {
        // Not seen lately: the link may have changed. Start again from the
        // better of this answer and the usual one.
        final usual = _answerTime ?? took;
        _quickest = took < usual ? took : usual;
        _quickestSeen = now;
      }
      final before = _answerTime;
      _answerTime = before == null ? took : (before * 3 + took) ~/ 4;
    }
    final last = _answered[transferId];
    _answered[transferId] = (durableOffset, now);
    final previous = last?.$1 ?? since;
    if (interval != null &&
        size != null &&
        previous != null &&
        durableOffset < size &&
        durableOffset - previous < interval) {
      _timely.add(transferId);
    }
    if (last == null) return;
    final elapsed = now.difference(last.$2);
    if (elapsed < const Duration(milliseconds: 200)) return;
    final sample =
        (durableOffset - last.$1) /
        elapsed.inMicroseconds *
        Duration.microsecondsPerSecond;
    final before = _confirmed;
    _confirmed = before == null ? sample : before * 0.7 + sample * 0.3;
    final own = _rateOf[transferId];
    _rateOf[transferId] = own == null ? sample : own * 0.7 + sample * 0.3;
  }

  /// [transferId] is over.
  void forget(String transferId) {
    _sent.remove(transferId);
    _answered.remove(transferId);
    _rateOf.remove(transferId);
    _timely.remove(transferId);
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
    final confirmed = _confirmed;
    if (!_active()) {
      // Free to go as fast as it can; ready to give way at about the speed
      // the link carries once something live starts.
      if (confirmed != null) _rate = math.max(floor, confirmed);
      return;
    }
    final hold = _holdUntil;
    final waiting = hold != null && now.isBefore(hold);
    final audio = _audioStrained();
    final queued = queueDelay > _queueLimit;
    if (audio || queued || lag > _lagLimit) {
      // Once per bout: what is already on its way takes a moment to clear,
      // and cutting again meanwhile would go far too low.
      if (waiting) return;
      final reached = math.min(_rate, math.max(confirmed ?? actual, floor));
      // Only the sound says how fast is too fast; a busy moment here does
      // not.
      if (audio) {
        _troubleAt = reached;
        _troubleWhen = now;
      }
      _rate = math.max(floor, reached * (audio ? 0.6 : 0.8));
      _holdUntil = now.add(const Duration(seconds: 1));
      return;
    }
    if (waiting) return;
    // The link or the window holds it back, not the pacer: stay close to
    // what it reaches.
    final reached = math.max(actual, confirmed ?? 0);
    if (reached < _rate * 0.8) {
      _rate = math.max(floor, math.min(_rate, reached * 1.3 + floor));
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
    // In proportion: a slow link grows as gently as a fast one.
    final step = careful
        ? math.max(floor / 2, _rate * 0.02)
        : math.max(floor, _rate * 0.15);
    _rate = math.max(floor, math.min(limit, _rate + step));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
