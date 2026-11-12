import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

/// Keeps transfers from filling the link they share with sound, keyboard
/// and mouse. Those need little, but must not wait behind file data. So
/// while something live is going ([active]) a transfer takes what the link
/// carries less a little ([_use]) and leaves the rest to them. With nothing
/// live it holds nothing back.
///
/// What the link carries is counted, not guessed from how late answers
/// come: the bytes the receivers confirmed between two of their answers a
/// couple of seconds apart. A late answer means something else on every
/// receiver (a phone saving power, a slow disk, a large frame), and a pacer
/// that slowed down for them crawled on some of them. Bytes over time mean
/// the same everywhere.
///
/// - Nothing known yet: it goes unheld for the first seconds, as with
///   nothing live, and what arrives then is what the link carries.
/// - From then on it goes a little under that.
/// - Less arriving than goes, or than may go while the sender waits for
///   answers, twice running: the link has become slower, and that is what
///   it carries now.
/// - Every so often it goes a little over for a moment. All of that
///   arriving, the link carries more, and it asks again, for more.
/// - While this device's own event loop falls behind, which is its
///   keyboard and mouse waiting, it gives way, down to half.
///
/// Going a little under the link on the whole is not enough. A frame is
/// handed to the connection at once and fills the link until it is through:
/// megabytes at a time kept it full for most of every quarter second, with
/// all that was left over in one gap at the end, and the pointer waited
/// behind each of them. So while it holds a transfer back, frames are ten
/// milliseconds of what may go ([_slice]), one after the other: the link is
/// never busy for longer than that, and what is live goes in between.
///
/// Trying how much more the link carries fills it for seconds, and the
/// pointer lags for as long. So it is not tried while a key or the pointer
/// is going over the link ([busy]), only once they rest.
///
/// Whatever is going, frames are kept to a quarter second of what the link
/// has been seen to carry, and, with a receiver that answers every second,
/// what is unconfirmed to two seconds of it: on a slow link a whole file
/// handed to the connection at once would hold up every message behind it
/// for minutes.
/// What a pacer is doing: nothing held back while it finds out what the
/// link carries ([measuring], [recounting]) or because the receiver cannot
/// be gone under ([released]); or held, a little under the link ([held]),
/// over it for a moment ([peeking]), or well under while what piled up
/// clears ([draining]).
enum TransferPacerMode {
  measuring,
  recounting,
  released,
  held,
  peeking,
  draining,
}

/// How a pacer was doing over its last few seconds, for diagnostics: bytes
/// per second it allows (infinite when unheld) and takes the link to carry,
/// bytes let go and confirmed, frames, whether keys or the pointer were
/// going, and the furthest its own look and a frame's wait came late.
typedef TransferPacerLook = ({
  TransferPacerMode mode,
  double rate,
  double? link,
  int taken,
  int confirmed,
  int frames,
  bool busy,
  Duration lag,
  Duration wake,
});

class TransferPacer {
  TransferPacer({
    bool Function()? active,
    bool Function()? busy,
    void Function(TransferPacerLook look)? report,
    this.floor = 64e3,
    DateTime Function()? now,
  }) : _active = active ?? _always,
       _busy = busy ?? _never,
       _report = report,
       _now = now ?? DateTime.now;

  static bool _always() => true;
  static bool _never() => false;

  /// The least it ever holds a transfer to, in bytes per second.
  final double floor;
  final bool Function() _active;
  final bool Function() _busy;
  final void Function(TransferPacerLook look)? _report;
  final DateTime Function() _now;

  /// Bytes per second it may go at; infinite while nothing is held back.
  double _rate = double.infinity;
  DateTime? _nextSend;
  DateTime? _lastUse;
  DateTime? _lastAnswer;
  DateTime? _lastTick;
  DateTime? _idleSince;
  Timer? _timer;

  /// What the link carries, in bytes per second. Kept a while after the
  /// last transfer for the next to the same device ([_linkPeer]): it most
  /// likely goes over the same link. Another device's may be far slower or
  /// faster, and a transfer held to that would crawl until it found out.
  double? _link;
  String? _linkPeer;

  /// Counting what arrives: every byte confirmed and every byte let go so
  /// far; those counts when the count began; from when it may begin (after
  /// a change of rate what arrives first still went at the old one); how
  /// many looks it has lasted and in how many of them the sender had as
  /// much on its way as it may; and how often running it came up short.
  int _confirmedBytes = 0;
  int _takenBytes = 0;
  (int confirmed, int taken, DateTime at)? _countFrom;
  DateTime? _countNotBefore;
  int _looks = 0;
  int _waitingLooks = 0;
  int _short = 0;

  /// Going a little over what the link was found to carry, to see whether
  /// all of that arrives: when next, how far apart, how much over, and
  /// since when for the one going on.
  DateTime? _peekAt;
  Duration _peekGap = _peekSoon;
  double _peekStep = _peekLittle;
  DateTime? _peekSince;

  /// Until when it goes at the least, for what piled up while it went
  /// over or unheld to drain.
  DateTime? _drainUntil;

  /// The most that arrived the last time nothing was held back. When the link, held
  /// to, comes to be taken for far less than that, either it is that much
  /// slower now or this is a receiver that gets through less the less it
  /// is sent: one that answers every frame it gets after a pause and takes
  /// long over each answer. Going unheld for a moment tells which
  /// ([_doubted] is what the link was taken for when that began). For such
  /// a receiver the only speed that works is all it takes, so transfers
  /// then go unheld until [_unheldUntil], longer each time.
  double? _unheldRate;
  double? _doubted;

  /// How many counts running nothing was held back for, and how often
  /// running going over showed the link to carry more. The first count of
  /// a link is of a transfer still getting up to speed, so it takes two to
  /// know one; and a link that carries more three times running is not
  /// known at all, which a moment unheld puts right sooner than asking on.
  int _unheldCounts = 0;
  int _more = 0;

  /// How many counts running far less arrived, held, than did unheld.
  int _farShort = 0;

  /// The count before, with nothing held back, and whether the last was
  /// well over it: the transfer was still getting up to speed, and what
  /// arrived is not yet what the link carries.
  double? _unheldBefore;
  bool _rising = false;
  DateTime? _unheldUntil;
  Duration _unheldFor = _unheldAtFirst;

  /// Why nothing is held back until [_unheldUntil]: to count again what
  /// the link carries, which can wait while it is busy, or because this
  /// receiver cannot be gone under.
  bool _recounting = false;
  bool _released = false;

  /// For [_report]: frames let go so far, what was told last, how many
  /// looks ago, and the furthest a look came late since.
  int _frames = 0;
  int _toldTaken = 0;
  int _toldConfirmed = 0;
  int _toldFrames = 0;
  int _looksSinceTold = 0;
  Duration _worstLag = Duration.zero;
  Duration _worstWake = Duration.zero;

  /// Giving way to this device's own work: how much of the rate is left,
  /// how often running it gave way, and until when it waits to see.
  double _left = 1;
  int _gaveWay = 0;
  DateTime? _holdUntil;

  /// When each frame of each transfer went: its end offset and the time.
  final Map<String, Queue<(int, DateTime)>> _sent = {};

  /// How far each transfer has been sent, and how much of it may be on its
  /// way unconfirmed as the sender was last told.
  final Map<String, int> _sentEnd = {};
  final Map<String, int> _mayBeOut = {};

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
  /// with nothing queued), and now (smoothed). Only the cap on what is
  /// unconfirmed goes by these.
  Duration? _quickest;
  DateTime? _quickestSeen;
  Duration? _answerTime;

  static const tick = Duration(milliseconds: 250);
  static const _lagLimit = Duration(milliseconds: 40);
  static const _queueLimit = Duration(milliseconds: 80);
  static const _quickestMemory = Duration(seconds: 30);
  static const _idle = Duration(seconds: 2);
  static const _linkMemory = Duration(minutes: 5);

  /// How much of what the link carries a transfer takes while something
  /// live shares it, leaving at least [_spare] bytes a second: sound and
  /// pointer take a few tens of kilobytes.
  static const _use = 0.9;
  static const _spare = 48e3;

  /// Whatever slows it down, never below this much of the link, and the
  /// link never taken for less than this much of what it was, at a time.
  static const _share = 0.5;

  /// How long what arrives is counted for, and how long after a change of
  /// rate the count waits.
  static const _count = Duration(seconds: 2);
  static const _countAfter = Duration(seconds: 1);
  static const _peekSoon = Duration(seconds: 10);
  static const _peekEvery = Duration(seconds: 30);
  static const _peekSeldom = Duration(minutes: 2);
  static const _peekLongest = Duration(seconds: 8);
  static const _peekLittle = 0.05;
  static const _peekMuch = 0.2;
  static const _drainFor = Duration(milliseconds: 1500);
  static const _farLess = 0.7;
  static const _farMore = 1.4;
  static const _checkFor = Duration(seconds: 8);
  static const _mostCounts = 6;
  static const _unheldAtFirst = Duration(minutes: 2);
  static const _unheldAtMost = Duration(minutes: 10);
  static const _mostCuts = 3;
  static const _longestWait = Duration(seconds: 1);

  /// How much of what may go a frame is while transfers are held back, and
  /// how far behind its times a sender may fall and still make it up: a
  /// timer fires late, by up to 15 ms on Windows, and that must not come
  /// off every frame. No further: what is made up goes at once, and the
  /// link is busy for that long.
  static const _slice = Duration(milliseconds: 10);
  static const _closeEnough = 0.015;
  static const _makeUp = Duration(milliseconds: 20);

  /// How many looks apart it says how things are, while something is live.
  static const _tellEvery = 20;
  static const _minFrame = 16 * 1024;
  static const _firstCap = 128 * 1024;
  static const _largestCap = 1 << 30;

  /// Bytes per second it holds transfers to now; infinite while it holds
  /// nothing back.
  double get rate => _rate;

  /// What the link was last found to carry, in bytes per second.
  double? get link => _link;

  /// What it is doing now.
  TransferPacerMode get mode {
    if (_rate.isInfinite) {
      if (_released) return TransferPacerMode.released;
      return _recounting
          ? TransferPacerMode.recounting
          : TransferPacerMode.measuring;
    }
    if (_peekSince != null) return TransferPacerMode.peeking;
    final drain = _drainUntil;
    return drain != null && _now().isBefore(drain)
        ? TransferPacerMode.draining
        : TransferPacerMode.held;
  }

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
    final int most;
    if (!timely && !_timely.contains(transferId)) {
      most = window;
    } else {
      // Until the first answer says how fast the link is, little: on a slow
      // link even a few megabytes queue for minutes.
      final cap = _capOf[transferId] ?? _firstCap;
      most = math.max(4 * _minFrame, math.min(window, cap));
    }
    _mayBeOut[transferId] = most;
    return most;
  }

  /// How big the next frame of [transferId] may be, at most [chunk].
  int frameBytes(int chunk, [String? transferId]) {
    final confirmed = _rateOf[transferId] ?? _confirmed;
    // Not known yet: start no bigger than the frames of old versions.
    var wanted = confirmed == null ? 512 * 1024 : (confirmed / 4).floor();
    final rate = _rate;
    // Held back: a slice of what may go, so the link is free again soon.
    // Not on a link so slow that the smallest frames would come further
    // apart than a receiver waits before it answers (20 ms): it would
    // answer every one of them, and write to disk each time.
    if (rate.isFinite && _minFrame / rate <= _closeEnough) {
      final slice =
          rate * _slice.inMicroseconds ~/ Duration.microsecondsPerSecond;
      wanted = math.min(wanted, slice);
    }
    return math.max(
      _minFrame,
      math.min(chunk, wanted ~/ _minFrame * _minFrame),
    );
  }

  /// Waits until [bytes] more, to device [peer], may go.
  Future<void> take(int bytes, {String? peer}) async {
    final now = _now();
    _lastUse = now;
    if (_timer == null) {
      // In use again. What the link carried a while ago, or to another
      // device, may be another link's.
      final idleSince = _idleSince;
      final peerBefore = _linkPeer;
      _linkPeer = peer;
      if (peer != peerBefore ||
          (idleSince != null && now.difference(idleSince) > _linkMemory)) {
        _link = null;
        _unheldRate = null;
        _doubted = null;
        _unheldUntil = null;
        _unheldFor = _unheldAtFirst;
        _recounting = false;
        _released = false;
      }
      _timer = Timer.periodic(tick, (_) => evaluate());
      _lastTick = now;
      _countFrom = null;
      _countNotBefore = now.add(_countAfter);
      _decide(now, Duration.zero, fresh: true);
    }
    _takenBytes += bytes;
    _frames++;
    final rate = _rate;
    if (rate.isInfinite) {
      _nextSend = null;
      return;
    }
    final next = _nextSend;
    // Idle time is not saved up: no burst after a pause. A little lateness
    // is made up.
    final earliest = now.subtract(_makeUp);
    final at = next == null ? now : (next.isBefore(earliest) ? earliest : next);
    // A frame is a quarter second of what the link carries. One that would
    // take far longer at this rate does not fit it, and a transfer must
    // not stand still for that.
    final cost = Duration(
      microseconds: (bytes / rate * Duration.microsecondsPerSecond).round(),
    );
    _nextSend = at.add(cost > _longestWait ? _longestWait : cost);
    final wait = at.difference(now);
    if (wait > Duration.zero) {
      await Future<void>.delayed(wait);
      final late = _now().difference(at);
      if (late > _worstWake) _worstWake = late;
    }
  }

  /// A frame of [transferId] ending at [endOffset] has gone.
  void sent(String transferId, int endOffset) {
    _sentEnd[transferId] = endOffset;
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
    _lastAnswer = now;
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
    if (previous != null && durableOffset > previous) {
      _confirmedBytes += durableOffset - previous;
    }
    if (interval != null &&
        size != null &&
        previous != null &&
        durableOffset < size &&
        durableOffset - previous < interval) {
      _timely.add(transferId);
    }
    _measure(transferId, durableOffset, now);
    _resize(transferId);
    _counted(now);
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
    _confirmed = before == null ? sample : before * 0.7 + sample * 0.3;
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
    _sentEnd.remove(transferId);
    _mayBeOut.remove(transferId);
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
    final lag = now.difference(lastTick) - tick;
    // In use while frames go or answers come: a sender that has as much on
    // its way as it may waits for answers, and is not done.
    final lastUse = _lastUse;
    final lastAnswer = _lastAnswer;
    if (lastUse == null ||
        (now.difference(lastUse) > _idle &&
            (lastAnswer == null || now.difference(lastAnswer) > _idle))) {
      _timer?.cancel();
      _timer = null;
      _lastTick = null;
      _idleSince = now;
      _rate = double.infinity;
      _unheldCounts = 0;
      _rising = false;
      _more = 0;
      _nextSend = null;
      _countFrom = null;
      _peekSince = null;
      _drainUntil = null;
      _left = 1;
      _gaveWay = 0;
      _short = 0;
      return;
    }
    _looks++;
    if (_senderWaits) _waitingLooks++;
    _decide(now, lag);
    if (lag > _worstLag) _worstLag = lag;
    if (++_looksSinceTold >= _tellEvery) _tell();
  }

  void _tell() {
    final report = _report;
    if (report != null && _active()) {
      report((
        mode: mode,
        rate: _rate,
        link: _link,
        taken: _takenBytes - _toldTaken,
        confirmed: _confirmedBytes - _toldConfirmed,
        frames: _frames - _toldFrames,
        busy: _busy(),
        lag: _worstLag,
        wake: _worstWake,
      ));
    }
    _looksSinceTold = 0;
    _toldTaken = _takenBytes;
    _toldConfirmed = _confirmedBytes;
    _toldFrames = _frames;
    _worstLag = Duration.zero;
    _worstWake = Duration.zero;
  }

  /// Whether a sender has as much on its way as it may, and waits for an
  /// answer before it sends more.
  bool get _senderWaits {
    for (final entry in _sentEnd.entries) {
      final confirmed = _answered[entry.key]?.$1;
      final may = _mayBeOut[entry.key];
      if (confirmed != null &&
          may != null &&
          entry.value - confirmed + _minFrame >= may) {
        return true;
      }
    }
    return false;
  }

  /// Sets the rate. [fresh] at the start of a transfer: nothing has piled
  /// up that would have to drain.
  void _decide(DateTime now, Duration lag, {bool fresh = false}) {
    final link = _link;
    final busy = _busy();
    // Counting again what the link carries can wait until it is not busy:
    // it goes on as it was.
    final putOff = busy && _recounting && link != null;
    if (putOff) _unheldUntil = null;
    final unheld = _unheldUntil;
    if (!_active() ||
        link == null ||
        (_rate.isInfinite && !fresh && !_upToSpeed && !putOff) ||
        (unheld != null && now.isBefore(unheld))) {
      // Nothing to give way to, nothing known to go a little under, or a
      // receiver that cannot be gone under: unheld, and what arrives says
      // what the link carries.
      _peekSince = null;
      _drainUntil = null;
      _left = 1;
      _gaveWay = 0;
      _setRate(double.infinity, now);
      return;
    }
    final least = math.max(floor, link * _share);
    final room = math.max(least, math.min(link * _use, link - _spare));
    if (_rate.isInfinite) {
      _doubted = null;
      _recounting = false;
      _released = false;
      _askSoon(now);
      if (!fresh) _drainUntil = now.add(_drainFor);
    }
    final hold = _holdUntil;
    final waiting = hold != null && now.isBefore(hold);
    if (lag > _lagLimit) {
      // Once per bout: what is already on its way takes a moment to clear.
      if (!waiting && _gaveWay < _mostCuts) {
        _gaveWay++;
        _left *= 0.8;
        _holdUntil = now.add(const Duration(seconds: 1));
        _peekSince = null;
      }
    } else if (!waiting) {
      _gaveWay = 0;
      _left = math.min(1, _left * 1.15);
    }
    final drain = _drainUntil;
    final draining = drain != null && now.isBefore(drain);
    if (busy && _peekSince != null) {
      // Going over is given up, and asked again as soon as it is quiet.
      _peekSince = null;
      _peekAt = now;
    }
    final peekAt = _peekAt;
    if (_peekSince == null &&
        !busy &&
        !draining &&
        _left == 1 &&
        peekAt != null &&
        !now.isBefore(peekAt)) {
      _peekSince = now;
    }
    final peekSince = _peekSince;
    if (peekSince != null && now.difference(peekSince) > _peekLongest) {
      // No answers to tell by: an old receiver, or a very slow link.
      _askLater(now);
    }
    final double rate;
    if (_peekSince != null) {
      rate = link * (1 + _peekStep);
    } else if (draining) {
      rate = least;
    } else {
      rate = math.max(least, room * _left);
    }
    _setRate(rate, now);
  }

  /// Whether a transfer with nothing held back has shown what the link
  /// carries: two counts, and more while each is well over the one before.
  bool get _upToSpeed =>
      _unheldCounts >= 2 && (!_rising || _unheldCounts >= _mostCounts);

  void _setRate(double rate, DateTime now) {
    if (rate == _rate) return;
    if (rate.isInfinite) {
      _unheldCounts = 0;
      _rising = false;
      // Held back, nothing queued and the caps opened all the way: let go
      // now, a whole window would go at once. They start again from two
      // seconds of the link, and open from there as answers come. Not held
      // to that for good: less on its way makes a receiver that is slow to
      // answer slower, and the link look slower still.
      final link = _link;
      if (link != null) {
        final most = math.max(4 * _minFrame, (link * 2).round());
        _capOf.updateAll((_, cap) => math.min(cap, most));
      }
    }
    _rate = rate;
    // What arrives next still went at the rate before.
    _countFrom = null;
    _countNotBefore = now.add(_countAfter);
    _short = 0;
  }

  /// An answer has come: when the count has run long enough, what arrived.
  void _counted(DateTime now) {
    final notBefore = _countNotBefore;
    if (notBefore != null && now.isBefore(notBefore)) return;
    final from = _countFrom;
    if (from == null) {
      _countFrom = (_confirmedBytes, _takenBytes, now);
      _looks = 0;
      _waitingLooks = 0;
      return;
    }
    final took = now.difference(from.$3);
    if (took < _count) return;
    double perSecond(int bytes) =>
        bytes / took.inMicroseconds * Duration.microsecondsPerSecond;
    final arrived = perSecond(_confirmedBytes - from.$1);
    final went = perSecond(_takenBytes - from.$2);
    final waited = _looks > 0 && _waitingLooks * 2 > _looks;
    _countFrom = (_confirmedBytes, _takenBytes, now);
    _looks = 0;
    _waitingLooks = 0;
    _arrived(arrived, went: went, waited: waited, now: now);
  }

  /// [arrived] bytes a second came in over the last count, of [went] that
  /// were let go; [waited] when the sender spent most of it with as much on
  /// its way as it may.
  void _arrived(
    double arrived, {
    required double went,
    required bool waited,
    required DateTime now,
  }) {
    final link = _link;
    final may = _rate;
    if (may.isInfinite) {
      // Nothing held it back. A sender that waited for answers sent all
      // the link takes; one that did not had no more to send, and the link
      // carries that much at least.
      _link = math.max(
        floor,
        waited || link == null ? arrived : math.max(link, arrived),
      );
      final most = _unheldCounts == 0
          ? arrived
          : math.max(_unheldRate ?? 0, arrived);
      final before = _unheldBefore;
      _rising = _unheldCounts > 0 && before != null && arrived > before * 1.1;
      _unheldBefore = arrived;
      _unheldRate = most;
      _unheldCounts++;
      final doubted = _doubted;
      if (doubted == null || !_upToSpeed) return;
      _doubted = null;
      if (most < doubted * _farMore) {
        // No more than it was held to: the link is slower. Under that.
        _unheldUntil = null;
        return;
      }
      _released = true;
      _unheldUntil = now.add(_unheldFor);
      final longer = _unheldFor * 2;
      _unheldFor = longer > _unheldAtMost ? _unheldAtMost : longer;
      return;
    }
    if (link == null) return;
    // The link is never taken for less than half of what it was at a time:
    // a receiver that stood still for a moment is not a slower link.
    double atLeast(double rate) =>
        math.max(floor, math.max(link * _share, rate));
    if (_peekSince != null) {
      if (arrived >= may * 0.96) {
        // All of it: the link carries that, and maybe more. Ask at once,
        // for more.
        _link = may;
        _peekStep = math.min(_peekMuch, _peekStep * 2);
        _peekSince = now;
        if (++_more >= 3) {
          _more = 0;
          _recounting = true;
          _unheldUntil = now.add(_checkFor);
        }
      } else {
        _more = 0;
        // Not all of it: no more than was known. Less is not concluded
        // from this, a receiver may have stood still for a moment.
        _askLater(now);
        _drainUntil = now.add(_drainFor);
      }
      return;
    }
    // Far less gets through held than did with nothing held back, count
    // after count: this may be a receiver that cannot be gone under, see
    // [_unheldRate]. Not while it is giving way itself.
    final unheldRate = _unheldRate;
    if (unheldRate != null && _left == 1 && arrived < unheldRate * _farLess) {
      if (++_farShort >= 3) {
        _farShort = 0;
        _short = 0;
        _doubted = arrived;
        _unheldUntil = now.add(_checkFor);
        return;
      }
    } else {
      _farShort = 0;
    }
    final behind = arrived < went * 0.9 || (waited && arrived < may * 0.9);
    if (!behind) {
      _short = 0;
      return;
    }
    if (++_short < 2) return;
    // Less arrives than goes, and has for a while: the link is slower now.
    _short = 0;
    final slower = atLeast(arrived);
    _link = slower;
    _askSoon(now);
    final unheld = _unheldRate;
    if (unheld != null && slower < unheld * _farLess) {
      // Or is it: see [_unheldRate].
      _doubted = slower;
      _unheldUntil = now.add(_checkFor);
    }
  }

  /// What the link carries is new: whether it carries more is asked soon.
  void _askSoon(DateTime now) {
    _peekSince = null;
    _peekGap = _peekSoon;
    _peekStep = _peekLittle;
    _peekAt = now.add(_peekGap);
  }

  /// Going over did not show the link to carry more: it need not be asked
  /// so soon again.
  void _askLater(DateTime now) {
    _peekSince = null;
    _peekStep = _peekLittle;
    final longer = _peekGap * 2;
    _peekGap = longer < _peekEvery
        ? _peekEvery
        : (longer > _peekSeldom ? _peekSeldom : longer);
    _peekAt = now.add(_peekGap);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
