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
/// Slowing down only helps against what the transfer itself causes, and the
/// signs are not always its doing: an answer to a large frame takes as long
/// as the frame, a phone saving power answers later the less it is sent, a
/// link may just be bad. So slowing down is tried and checked. Answers as
/// late afterwards as before are how long answers take now, and the rate
/// goes back; nothing slows it more than [_mostCuts] times running; and it
/// never goes below a quarter of what the link has just been carrying,
/// which leaves the rest of the link to what is live.
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

  /// Slowing down in a row with nothing better in between: how often. And
  /// when one of them was for late answers: the rate before it, what the
  /// receivers confirmed then, and whether a queue was seen to drain since.
  int _cuts = 0;
  double? _rateBeforeQueue;
  double? _confirmedAtQueue;
  bool _drained = false;

  /// About what the link carries: what the receivers confirmed when a queue
  /// built up that then drained, and when that was.
  double? _carried;
  DateTime? _carriedWhen;

  /// The most the receivers confirmed in a second lately, and when.
  double? _peak;
  DateTime? _peakWhen;

  /// When each frame of each transfer went: its end offset and the time.
  final Map<String, Queue<(int, DateTime)>> _sent = {};

  /// The last answer of each transfer: where it was and when it came.
  final Map<String, (int, DateTime)> _answered = {};

  /// Bytes per second each transfer's receiver confirmed, smoothed, and
  /// where it was measured from: answers can come every few milliseconds, so
  /// the speed is taken over a fifth of a second at least.
  final Map<String, double> _rateOf = {};
  final Map<String, (int, DateTime)> _measuredFrom = {};

  /// How much of each transfer may be unconfirmed: it starts small and
  /// grows fourfold with every answer that came back without queueing (the
  /// receiver answers as soon as data stops coming), so a fast link is open
  /// within a few round trips; once answers queue it is two seconds of what
  /// the link carries.
  final Map<String, int> _capOf = {};

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

  /// How long the last answer took, unsmoothed, and how many answers there
  /// were: whether a queue drains shows there soon after slowing down, in
  /// [_answerTime] much later.
  Duration? _lastAnswerTime;
  int _answers = 0;
  int _answersAtCut = 0;

  /// The longest an answer took since slowing down. Answers go on getting
  /// later for a moment after it, as they tell of frames that went before:
  /// a queue drains if they are quicker now than at that worst.
  Duration? _worstSinceCut;
  DateTime? _worstWhen;

  /// How late answers stayed when slowing down did not help, and until
  /// when that much counts as usual. The cap on what is unconfirmed does
  /// not use it: that still goes by [queueDelay].
  Duration? _usualLate;
  DateTime? _usualLateUntil;

  static const tick = Duration(milliseconds: 250);
  static const _lagLimit = Duration(milliseconds: 40);
  static const _queueLimit = Duration(milliseconds: 80);
  static const _troubleMemory = Duration(minutes: 1);
  static const _quickestMemory = Duration(seconds: 30);
  static const _usualLateMemory = Duration(seconds: 30);
  static const _peakMemory = Duration(seconds: 20);
  static const _mostCuts = 3;
  static const _relief = Duration(milliseconds: 100);
  static const _minFrame = 16 * 1024;
  static const _firstCap = 128 * 1024;
  static const _largestCap = 1 << 30;

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
    // Until the first answer says how fast the link is, little: on a slow
    // link even a few megabytes queue for minutes.
    final cap = _capOf[transferId] ?? _firstCap;
    return math.max(4 * _minFrame, math.min(window, cap));
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
      _lastAnswerTime = took;
      _answers++;
      final worst = _worstSinceCut;
      if (worst == null || took > worst) {
        _worstSinceCut = took;
        _worstWhen = now;
      }
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
    _measure(transferId, durableOffset, now);
    _resize(transferId);
  }

  void _measure(String transferId, int durableOffset, DateTime now) {
    final from = _measuredFrom[transferId];
    if (from == null) {
      _measuredFrom[transferId] = (durableOffset, now);
      return;
    }
    final elapsed = now.difference(from.$2);
    if (elapsed < const Duration(milliseconds: 200)) return;
    _measuredFrom[transferId] = (durableOffset, now);
    final sample =
        (durableOffset - from.$1) /
        elapsed.inMicroseconds *
        Duration.microsecondsPerSecond;
    final before = _confirmed;
    final confirmed = before == null ? sample : before * 0.7 + sample * 0.3;
    _confirmed = confirmed;
    final peak = _peak;
    final peakWhen = _peakWhen;
    if (peak == null ||
        peakWhen == null ||
        confirmed >= peak ||
        now.difference(peakWhen) > _peakMemory) {
      _peak = confirmed;
      _peakWhen = now;
    }
    final own = _rateOf[transferId];
    _rateOf[transferId] = own == null ? sample : own * 0.7 + sample * 0.3;
  }

  /// After an answer for [transferId]: open the cap while nothing queues,
  /// hold it to two seconds of the link once something does.
  void _resize(String transferId) {
    final cap = _capOf[transferId] ?? _firstCap;
    final delay = queueDelay;
    final rate = _rateOf[transferId];
    // An answer always waits a little: the receiver's pause before it
    // answers, its write to disk. Only well past that is anything queued.
    if (delay <= const Duration(milliseconds: 60)) {
      _capOf[transferId] = math.min(_largestCap, cap * 4);
    } else if (delay > _queueLimit && rate != null) {
      _capOf[transferId] = math.max(4 * _minFrame, (rate * 2).round());
    } else {
      _capOf[transferId] = math.min(_largestCap, cap + cap ~/ 2);
    }
  }

  /// [transferId] is over.
  void forget(String transferId) {
    _sent.remove(transferId);
    _answered.remove(transferId);
    _rateOf.remove(transferId);
    _measuredFrom.remove(transferId);
    _capOf.remove(transferId);
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
    final peak = _peak;
    final peakWhen = _peakWhen;
    final least =
        peak != null &&
            peakWhen != null &&
            now.difference(peakWhen) <= _peakMemory
        ? math.max(floor, peak / 4)
        : floor;
    final hold = _holdUntil;
    final waiting = hold != null && now.isBefore(hold);
    final audio = _audioStrained();
    final late = _lateness(now);
    final queued = late > _queueLimit;
    if (audio || queued || lag > _lagLimit) {
      // Once per bout: what is already on its way takes a moment to clear,
      // and cutting again meanwhile would go far too low.
      if (waiting || _rate <= least) return;
      if (_slowingIsNoUse(audio: audio, late: late, now: now)) return;
      _cuts++;
      final reached = math.min(_rate, math.max(confirmed ?? actual, floor));
      if (!audio && queued) {
        _rateBeforeQueue = _rate;
        _confirmedAtQueue = reached;
        _answersAtCut = _answers;
        _worstSinceCut = _lastAnswerTime;
        _worstWhen = now;
      }
      // Only the sound says how fast is too fast; a busy moment here does
      // not.
      if (audio) {
        _troubleAt = reached;
        _troubleWhen = now;
      }
      _rate = math.max(least, reached * (audio ? 0.6 : 0.8));
      _holdUntil = now.add(_settle(queued));
      return;
    }
    if (waiting) return;
    _calm();
    // The link or the window holds it back, not the pacer: stay close to
    // what it reaches.
    final reached = math.max(actual, confirmed ?? 0);
    if (reached < _rate * 0.8) {
      _rate = math.max(least, math.min(_rate, reached * 1.3 + floor));
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
    // The same near where a queue was seen to build and drain: that is
    // about what the link carries, and coming up to it slowly a queue is
    // small when it shows.
    final carried = _carried;
    final carriedWhen = _carriedWhen;
    final careful =
        (trouble != null && _rate >= trouble * 0.85) ||
        (carried != null &&
            carriedWhen != null &&
            now.difference(carriedWhen) < _troubleMemory &&
            _rate >= carried * 0.85);
    // In proportion: a slow link grows as gently as a fast one.
    final step = careful
        ? math.max(floor / 2, _rate * 0.02)
        : math.max(floor, _rate * 0.15);
    _rate = math.max(least, math.min(limit, _rate + step));
  }

  /// How long to wait after slowing down before looking again. An answer
  /// is as old as it took: after a queue ([queued]) the next ones still
  /// tell of frames that went before, so wait that much longer.
  Duration _settle(bool queued) {
    const atLeast = Duration(seconds: 1);
    final last = _lastAnswerTime;
    if (!queued || last == null) return atLeast;
    final wait = atLeast + last;
    return wait > const Duration(seconds: 4)
        ? const Duration(seconds: 4)
        : wait;
  }

  /// How much later answers come than is usual, see [_usualLate].
  Duration _lateness(DateTime now) {
    final delay = queueDelay;
    final usual = _usualLate;
    final until = _usualLateUntil;
    if (usual == null || until == null || !now.isBefore(until)) return delay;
    return delay > usual ? delay - usual : Duration.zero;
  }

  /// Whether slowing down again would be for nothing, after it has just
  /// been tried.
  ///
  /// The sound still suffering or this device still behind: [_mostCuts]
  /// times running are enough. Answers still late: a queue of this
  /// transfer's making drains once it is slower, so while they get quicker
  /// there is only to wait. Answers that stay as late were not late because
  /// of it: that is how long they take now, and if slowing down never
  /// helped the rate goes back to where it was.
  bool _slowingIsNoUse({
    required bool audio,
    required Duration late,
    required DateTime now,
  }) {
    if (_cuts == 0) return false;
    final before = _rateBeforeQueue;
    if (audio || late <= _queueLimit || before == null) {
      return _cuts >= _mostCuts;
    }
    // No answer since, or the worst only just now: nothing to go by yet.
    final worstWhen = _worstWhen;
    if (_answers == _answersAtCut ||
        (worstWhen != null &&
            now.difference(worstWhen) < const Duration(seconds: 1))) {
      return true;
    }
    final worst = _worstSinceCut;
    final last = _lastAnswerTime;
    if (worst != null && last != null && worst - last >= _relief) {
      _drained = true;
      _carried = _confirmedAtQueue;
      _carriedWhen = now;
      _answersAtCut = _answers;
      _worstSinceCut = last;
      _worstWhen = now;
      _holdUntil = now.add(_settle(true));
      return true;
    }
    // As late as the worst since: slower, they were a little less late.
    final quickest = _quickest;
    final usual = queueDelay;
    final atWorst = worst != null && quickest != null && worst > quickest
        ? worst - quickest
        : usual;
    _usualLate = atWorst > usual ? atWorst : usual;
    _usualLateUntil = now.add(_usualLateMemory);
    if (!_drained) _rate = math.max(_rate, before);
    _calm();
    return true;
  }

  /// The bout of slowing down is over.
  void _calm() {
    _cuts = 0;
    _rateBeforeQueue = null;
    _confirmedAtQueue = null;
    _drained = false;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
