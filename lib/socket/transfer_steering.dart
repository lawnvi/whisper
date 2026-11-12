import 'dart:math' as math;

/// What the link carries, worked out from how long the keyboard and mouse
/// datagrams wait (`LinkDelay`) instead of from bytes counted seconds
/// apart: the steered mode of `TransferPacer`, which goes a little under
/// what this says.
///
/// - More queued than [target]: the link carries less now. Less by how
///   much more is queued, half at three times the target, a quarter at
///   most, and again only once what is queued stops clearing: until a cut
///   shows, and while the queue gets shorter, it is enough. Cutting on
///   while it cleared halved and halved down to nothing.
/// - Little queued, looked at every so often, and the transfers use what
///   they may (a slow disk or a late receiver would never show the link
///   full): it may carry more. Quickly at first, with nothing known, and
///   back to what it carried before a cut; past that, a little at a time,
///   and while the pointer moves seldom and by less, since every try
///   queues for a moment. With the pointer still and next to nothing
///   queued (under a quarter of the target), twice as often and by twice
///   as much. Not while it moves: going over a steady link that often
///   cuts it that often, and left it a fifth short in the simulation.
///
/// A round trip also waits for both ends' event loops. So a single late
/// one neither cuts (the lanes tell the least of 200 ms, and it has to be
/// over twice running) nor keeps it from going faster: asking for none at
/// all for a whole half second, one late answer kept it from ever getting
/// up. Measured between a Mac debug build and a Windows laptop with the
/// pointer moving and nothing sent: the least of 200 ms was under 2 ms nine
/// times in ten, but over 14 ms once in a hundred.
final class TransferSteering {
  /// How long a datagram may wait before it slows down.
  static const target = Duration(milliseconds: 10);

  /// How often it steps.
  static const every = Duration(milliseconds: 40);

  /// Where it starts with nothing known: a slow Wi-Fi link takes that, a
  /// fast one is reached within a couple of seconds.
  static const start = 2e6;

  static const _startUp = 0.25;
  static const _back = 0.15;
  static const _up = 0.05;
  static const _quiet = Duration(milliseconds: 500);
  static const _upBusy = 0.02;
  static const _quietBusy = Duration(seconds: 2);
  static const _upClear = 0.10;
  static const _quietClear = Duration(milliseconds: 250);
  static const _deepest = 0.25;
  static const _usedOver = Duration(milliseconds: 500);

  /// How long a cut takes to show in the lanes: a round trip, and the
  /// least of the last 200 ms is what they tell.
  static const _cutShows = Duration(milliseconds: 250);

  DateTime? _steppedAt;
  DateTime? _cutUntil;
  Duration? _leastSinceCut;
  Duration? _queueAtCut;
  double? _beforeCut;
  DateTime? _upAt;
  bool _startingUp = false;
  bool _overBefore = false;
  (int, DateTime)? _usedFrom;
  double? _used;
  Duration? _worst;

  /// Starts afresh: steering begins, or begins again.
  void reset() {
    _steppedAt = null;
    _cutUntil = null;
    _leastSinceCut = null;
    _queueAtCut = null;
    _beforeCut = null;
    _upAt = null;
    _startingUp = false;
    _overBefore = false;
  }

  /// The longest wait told since the last call.
  Duration? takeWorst() {
    final worst = _worst;
    _worst = null;
    return worst;
  }

  /// What the link carries after one step, from [link] (null when nothing
  /// is known), with [queue] waiting now, [taken] bytes let go so far and
  /// [share] of the link used; or null when the last step is too recent
  /// and [fresh] does not ask for one anyway.
  double? step({
    required Duration queue,
    required DateTime now,
    required double? link,
    required int taken,
    required double share,
    required bool busy,
    bool fresh = false,
  }) {
    final worst = _worst;
    if (worst == null || queue > worst) _worst = queue;
    final last = _steppedAt;
    if (!fresh && last != null && now.difference(last) < every) return null;
    _steppedAt = now;
    _measureUse(taken, now);
    if (link == null) {
      _startingUp = true;
      return start;
    }
    // Over it twice running, or what was over may have been one end's
    // event loop standing still for a moment.
    final over = queue > target;
    final again = _overBefore;
    _overBefore = over;
    if (over) return again ? _cut(queue, now, link) : link;
    _cutUntil = null;
    _leastSinceCut = null;
    _queueAtCut = null;
    final upAt = _upAt;
    final used = _used;
    final using = used == null || used >= link * share / 2;
    if (upAt == null) {
      _upAt = now.add(_startingUp ? every : _quiet);
      return link;
    }
    if (now.isBefore(upAt) || queue * 2 >= target || !using) return link;
    final before = _beforeCut;
    final clear = queue * 4 < target;
    final (more, next) = _startingUp
        ? (_startUp, every * 2)
        : before != null && link < before * share
        ? (_back, every * 4)
        : busy
        ? (_upBusy, _quietBusy)
        : (clear ? (_upClear, _quietClear) : (_up, _quiet));
    _upAt = now.add(next);
    return link * (1 + more);
  }

  double _cut(Duration queue, DateTime now, double link) {
    _startingUp = false;
    _upAt = null;
    final cut = _cutUntil;
    final least = _leastSinceCut;
    final atCut = _queueAtCut;
    if (least != null && queue < least) _leastSinceCut = queue;
    // Unless it has grown to twice what it was: the link has slowed down
    // at once, and what one cut asked for is not enough.
    if (cut != null &&
        (now.isBefore(cut) || (least != null && queue < least)) &&
        (atCut == null || queue <= atCut * 2)) {
      return link;
    }
    if (cut == null) _beforeCut = link;
    _cutUntil = now.add(_cutShows);
    _leastSinceCut = queue;
    _queueAtCut = queue;
    final aim = target.inMicroseconds;
    return link * math.max(_deepest, 2 * aim / (queue.inMicroseconds + aim));
  }

  /// What the transfers let go lately, over half a second at least: at a
  /// few frames a second a single step sees none or two.
  void _measureUse(int taken, DateTime now) {
    final from = _usedFrom;
    if (from == null) {
      _usedFrom = (taken, now);
    } else if (now.difference(from.$2) >= _usedOver) {
      _used =
          (taken - from.$1) /
          now.difference(from.$2).inMicroseconds *
          Duration.microsecondsPerSecond;
      _usedFrom = (taken, now);
    }
  }
}
