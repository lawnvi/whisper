import 'dart:math' as math;

/// The way there and back of one UDP lane, from the stamps its keepalives
/// carry, or one way, from the other end's stamps: the least lately, which
/// is the way with nothing queued, and the least of the last moment, which
/// is the way now. The difference is how long a datagram waits behind
/// whatever else is queued on the link, a file most of all.
final class RoundTrips {
  RoundTrips({
    this.recent = const Duration(milliseconds: 200),
    this.fresh = const Duration(milliseconds: 500),
  });

  /// The least of this long a while back is the way now: single datagrams
  /// wait for a dozing card, a retry on Wi-Fi or a busy event loop at
  /// either end, and that is not a queue.
  final Duration recent;

  /// With no answer for this long nothing is known.
  final Duration fresh;

  /// The least of every five seconds, the last thirty seconds of them: a
  /// link that changed is known by its new least within that.
  static const int _bucketMicros = 5000000;
  static const int _buckets = 6;
  final List<(int bucket, int least)> _leasts = [];
  final List<(int at, int took)> _lately = [];

  /// A way there and back of [tookMicros], answered at [atMicros].
  void add(int tookMicros, int atMicros) {
    final bucket = atMicros ~/ _bucketMicros;
    if (_leasts.isNotEmpty && _leasts.last.$1 == bucket) {
      final least = _leasts.last.$2;
      if (tookMicros < least) _leasts.last = (bucket, tookMicros);
    } else {
      _leasts.add((bucket, tookMicros));
    }
    while (_leasts.isNotEmpty && _leasts.first.$1 <= bucket - _buckets) {
      _leasts.removeAt(0);
    }
    _lately.add((atMicros, tookMicros));
    while (_lately.length > 1 &&
        _lately.first.$1 < atMicros - fresh.inMicroseconds) {
      _lately.removeAt(0);
    }
  }

  /// How much longer the way takes now than with nothing queued, or null
  /// when nothing was answered lately.
  Duration? queueing(int nowMicros) {
    if (_lately.isEmpty || _leasts.isEmpty) return null;
    if (_lately.last.$1 < nowMicros - fresh.inMicroseconds) return null;
    var now = _lately.last.$2;
    for (final (at, took) in _lately) {
      if (at >= nowMicros - recent.inMicroseconds) now = math.min(now, took);
    }
    var least = now;
    for (final (_, took) in _leasts) {
      least = math.min(least, took);
    }
    return Duration(microseconds: now - least);
  }
}

/// A lane whose round trips are known ([LinkDelay]).
abstract interface class TimedLane {
  /// Asks the other end for an answer to a stamp every few tens of
  /// milliseconds, instead of a few times a second.
  set probing(bool value);

  /// How long its datagrams wait in a queue now, on the way they go; null
  /// when not known (an older version does not answer stamps).
  Duration? get queueing;
}

/// The live lanes of this isolate (keyboard and mouse; the sound of the
/// audio isolate as it reports it), each with the device at its other end,
/// for a transfer to tell how long they wait behind it.
final class LinkDelay {
  static final LinkDelay shared = LinkDelay();

  final Map<TimedLane, String?> _lanes = {};
  final Set<Object> _wanting = {};

  /// [peerId]: the device at the lane's other end, when known.
  void attach(TimedLane lane, {String? peerId}) {
    _lanes[lane] = peerId;
    lane.probing = _wanting.isNotEmpty;
  }

  void detach(TimedLane lane) => _lanes.remove(lane);

  /// Whether [who] (a transfer pacer) wants the lanes to ask for answers
  /// often: while it goes by what they say. They do while anyone does.
  void want(Object who, bool wanted) {
    final before = _wanting.isNotEmpty;
    if (wanted) {
      _wanting.add(who);
    } else {
      _wanting.remove(who);
    }
    final now = _wanting.isNotEmpty;
    if (now == before) return;
    for (final lane in _lanes.keys) {
      lane.probing = now;
    }
  }

  /// Whether anyone wants the lanes to ask for answers often.
  bool get wanted => _wanting.isNotEmpty;

  /// The longest any lane to [peerId] (or any lane at all) waits now, or
  /// null when none knows.
  Duration? queueing({String? peerId}) {
    Duration? worst;
    for (final MapEntry(key: lane, value: peer) in _lanes.entries) {
      if (peerId != null && peer != peerId) continue;
      final queue = lane.queueing;
      if (queue != null && (worst == null || queue > worst)) worst = queue;
    }
    return worst;
  }

  /// What each device's lanes wait now, at worst; null where none knows.
  Map<String, Duration?> queueingByPeer() => {
    for (final peer in _lanes.values.whereType<String>().toSet())
      peer: queueing(peerId: peer),
  };
}
