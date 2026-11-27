import 'dart:async';
import 'dart:convert';

const String heartbeatPingTag = 'ping';
const String heartbeatPongTag = 'pong';
const String heartbeatProfileTag = 'profile';
const String heartbeatProfileRequestTag = 'profile-refresh-request';

/// Tracks lightweight application-layer `/chat` ping/pong RTT measurements and
/// per-peer monotonic inbound activity.
///
/// The RTT measured here is application-layer round-trip time over the
/// authenticated `/chat` WebSocket and therefore includes the remote peer's
/// inbound receive-queue wait time. Dead-peer detection never uses RTT
/// magnitude; it checks solely whether zero inbound frames arrived within
/// [silenceLimit] (45s by default).
final class PeerPingTracker {
  PeerPingTracker({
    int Function()? nowUs,
    this.silenceLimit = const Duration(seconds: 45),
  }) : _nowUs = nowUs ?? _defaultNowUs;

  static final Stopwatch _monotonicClock = Stopwatch()..start();
  static int _defaultNowUs() => _monotonicClock.elapsedMicroseconds;

  final int Function() _nowUs;
  final Duration silenceLimit;

  int _nextSeq = 0;
  final Map<String, int> _lastInboundUs = <String, int>{};
  final Map<String, Duration> _lastRtt = <String, Duration>{};
  final Map<String, Map<int, _PendingPing>> _pending =
      <String, Map<int, _PendingPing>>{};
  final Map<Object, Timer> _keepaliveTimers = <Object, Timer>{};

  bool get hasActiveKeepalives => _keepaliveTimers.isNotEmpty;

  /// Records that an authenticated frame arrived from [peerId] (or that
  /// [peerId] just completed authentication).
  void noteInboundActivity(String peerId) {
    if (peerId.isEmpty) return;
    _lastInboundUs[peerId] = _nowUs();
  }

  /// True only when [peerId] has had zero inbound frames for at least
  /// [silenceLimit]. Never considers RTT magnitude.
  bool isSilentPastLimit(String peerId) {
    final last = _lastInboundUs[peerId];
    if (last == null) return false;
    return _nowUs() - last >= silenceLimit.inMicroseconds;
  }

  Duration? lastRttFor(String peerId) => _lastRtt[peerId];

  /// Starts periodic keepalive pings bound to [token] (typically a socket sink).
  /// When [peerId] has received zero inbound frames for [silenceLimit], invokes
  /// [onSilent] instead of sending another ping.
  void startKeepalive({
    required Object token,
    required String peerId,
    required Duration interval,
    required Future<bool> Function(String payload) sendPing,
    required Future<void> Function() onSilent,
    Duration pingTimeout = const Duration(seconds: 10),
  }) {
    noteInboundActivity(peerId);
    _keepaliveTimers.remove(token)?.cancel();
    _keepaliveTimers[token] = Timer.periodic(interval, (_) {
      if (!_keepaliveTimers.containsKey(token)) return;
      if (isSilentPastLimit(peerId)) {
        unawaited(onSilent());
        return;
      }
      unawaited(
        dispatchPing(peerId: peerId, sendPing: sendPing, timeout: pingTimeout),
      );
    });
  }

  void stopKeepalive(Object token) {
    _keepaliveTimers.remove(token)?.cancel();
  }

  /// Sends a tracked ping and awaits its pong RTT (or `null` on send failure
  /// or timeout).
  Future<Duration?> measure({
    required String peerId,
    required Future<bool> Function(String payload) sendPing,
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final ping = startPing(peerId, timeout: timeout);
    final sent = await sendPing(ping.payload);
    if (!sent) {
      cancelPing(peerId, ping.seq);
      return null;
    }
    return ping.rtt;
  }

  /// Sends a tracked ping and returns once the frame has been handed to the
  /// transport, without waiting for the pong.
  Future<bool> dispatchPing({
    required String peerId,
    required Future<bool> Function(String payload) sendPing,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final ping = startPing(peerId, timeout: timeout);
    final sent = await sendPing(ping.payload);
    if (!sent) {
      cancelPing(peerId, ping.seq);
    }
    return sent;
  }

  ({int seq, String payload, Future<Duration?> rtt}) startPing(
    String peerId, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) {
    final seq = ++_nextSeq;
    final completer = Completer<Duration?>();
    final peerPending = _pending.putIfAbsent(
      peerId,
      () => <int, _PendingPing>{},
    );
    late final _PendingPing entry;
    final timer = Timer(timeout, () {
      if (identical(peerPending[seq], entry)) {
        peerPending.remove(seq);
        if (peerPending.isEmpty) {
          _pending.remove(peerId);
        }
      }
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });
    entry = _PendingPing(sentUs: _nowUs(), timer: timer, completer: completer);
    peerPending[seq] = entry;
    return (
      seq: seq,
      payload: jsonEncode(<String, Object>{'seq': seq}),
      rtt: completer.future,
    );
  }

  void cancelPing(String peerId, int seq) {
    final peerPending = _pending[peerId];
    final entry = peerPending?.remove(seq);
    if (peerPending != null && peerPending.isEmpty) {
      _pending.remove(peerId);
    }
    if (entry != null) {
      entry.timer.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.complete(null);
      }
    }
  }

  /// Parses an incoming ping payload and builds the matching pong JSON, or
  /// returns `null` when the payload is malformed.
  String? buildPongPayload(String? content) {
    final seq = _parseSeq(content);
    if (seq == null) return null;
    return jsonEncode(<String, Object>{'seq': seq});
  }

  /// Resolves a matching pending ping for [peerId] and returns the measured
  /// application-layer RTT, or `null` if unknown/expired.
  Duration? completePong(String peerId, String? content) {
    final seq = _parseSeq(content);
    if (seq == null) return null;
    final peerPending = _pending[peerId];
    final entry = peerPending?.remove(seq);
    if (peerPending != null && peerPending.isEmpty) {
      _pending.remove(peerId);
    }
    if (entry == null) return null;
    entry.timer.cancel();
    final elapsedUs = _nowUs() - entry.sentUs;
    final rtt = Duration(microseconds: elapsedUs < 0 ? 0 : elapsedUs);
    _lastRtt[peerId] = rtt;
    if (!entry.completer.isCompleted) {
      entry.completer.complete(rtt);
    }
    return rtt;
  }

  void clearPeer(String peerId) {
    _lastInboundUs.remove(peerId);
    _lastRtt.remove(peerId);
    final peerPending = _pending.remove(peerId);
    if (peerPending == null) return;
    for (final entry in peerPending.values) {
      entry.timer.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.complete(null);
      }
    }
  }

  void clearAll() {
    for (final timer in _keepaliveTimers.values) {
      timer.cancel();
    }
    _keepaliveTimers.clear();
    _lastInboundUs.clear();
    _lastRtt.clear();
    for (final peerPending in _pending.values) {
      for (final entry in peerPending.values) {
        entry.timer.cancel();
        if (!entry.completer.isCompleted) {
          entry.completer.complete(null);
        }
      }
    }
    _pending.clear();
  }

  static int? _parseSeq(String? content) {
    if (content == null || content.isEmpty || content.length > 64) {
      return null;
    }
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      final seq = decoded['seq'];
      if (seq is! int || seq <= 0) return null;
      return seq;
    } on FormatException {
      return null;
    }
  }
}

final class _PendingPing {
  _PendingPing({
    required this.sentUs,
    required this.timer,
    required this.completer,
  });

  final int sentUs;
  final Timer timer;
  final Completer<Duration?> completer;
}
