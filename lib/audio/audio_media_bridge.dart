part of 'audio_media_isolate.dart';

// What the main isolate answers the audio isolate besides its commands:
// whether a token is good (the token table lives in the main isolate), and
// how long the sound lanes wait (for transfers there to give way).

class _PendingClaim {
  _PendingClaim(this.claim, this.sessionId, this.token, this.expires);

  final SessionUpgradeClaim claim;
  final String sessionId;
  final String token;
  final Timer expires;
}

extension on _PendingClaim {
  void _release() {
    expires.cancel();
    claim.destroy();
  }
}

/// Token checks for the audio isolate's own media port.
extension _ClaimAnswers on _IsolateClient {
  void _lookupClaim(_ClaimLookup lookup) {
    final broker = _media._manager.claimBroker;
    final claim = broker?.lookup(
      sessionId: lookup.sessionId,
      token: lookup.token,
      remoteAddress: lookup.remoteAddress,
    );
    final sendKey = claim != null && claim.reverse
        ? broker?.sendKeyFor(claim)
        : null;
    if (claim != null && claim.reverse && sendKey == null) claim.destroy();
    if (claim == null || claim.isDestroyed) {
      send(_ClaimAnswer(lookup.requestId, null));
      return;
    }
    // Released if the proof never comes.
    final expires = Timer(const Duration(seconds: 10), () {
      _claims.remove(lookup.requestId)?._release();
    });
    _claims[lookup.requestId] = _PendingClaim(
      claim,
      lookup.sessionId,
      lookup.token,
      expires,
    );
    send(
      _ClaimAnswer(
        lookup.requestId,
        claim.withMediaPacketContext(
          (mediaMacKey, channelBinding) => _ClaimData(
            namespace: claim.namespace,
            sessionId: claim.sessionId,
            peerId: claim.peerId,
            connectionGeneration: claim.connectionGeneration,
            mediaMacKey: Uint8List.fromList(mediaMacKey),
            channelBinding: Uint8List.fromList(channelBinding),
            sendKey: sendKey,
          ),
        ),
      ),
    );
  }

  void _consumeClaim(int requestId) {
    final pending = _claims.remove(requestId);
    if (pending == null) {
      send(_ConsumeAnswer(requestId, false));
      return;
    }
    final consumed = _media._manager.claimBroker?.consume(
      sessionId: pending.sessionId,
      token: pending.token,
      expected: pending.claim,
    );
    pending._release();
    consumed?.destroy();
    send(_ConsumeAnswer(requestId, consumed != null));
  }
}

/// What the audio isolate's sound lanes wait, by device: microseconds, -1
/// when not known. Sent every [_LaneReporter.every] while it has lanes, and
/// once more, empty, when the last one goes.
class _LaneReport {
  const _LaneReport(this.queueMicros);

  final Map<String, int> queueMicros;
}

/// Whether the main isolate wants the sound lanes to ask for answers often
/// (a transfer goes by what they say).
class _ProbeLanes {
  const _ProbeLanes(this.on);

  final bool on;
}

/// In the audio isolate: tells the main isolate what its lanes, in this
/// isolate's own [LinkDelay.shared], wait.
class _LaneReporter {
  _LaneReporter(this._send);

  static const every = Duration(milliseconds: 100);

  final void Function(Object message) _send;
  Timer? _timer;
  bool _had = false;

  void start() => _timer ??= Timer.periodic(every, (_) => _report());

  void _report() {
    final byPeer = LinkDelay.shared.queueingByPeer();
    if (byPeer.isEmpty && !_had) return;
    _had = byPeer.isNotEmpty;
    _send(
      _LaneReport({
        for (final MapEntry(key: peer, value: queue) in byPeer.entries)
          peer: queue?.inMicroseconds ?? -1,
      }),
    );
  }

  void probe(bool on) => LinkDelay.shared.want(#mainIsolate, on);
}

/// In the main isolate: a stand-in lane in [LinkDelay.shared] for each
/// device the audio isolate's sound goes to or comes from.
class _ReportedLanes {
  _ReportedLanes(this._send);

  final void Function(Object message) _send;
  final Map<String, _ReportedLane> _lanes = <String, _ReportedLane>{};
  bool? _probing;

  void update(_LaneReport report) {
    for (final peer in _lanes.keys.toList()) {
      if (!report.queueMicros.containsKey(peer)) {
        LinkDelay.shared.detach(_lanes.remove(peer)!);
      }
    }
    final now = DateTime.now();
    for (final MapEntry(key: peer, value: micros)
        in report.queueMicros.entries) {
      final lane = _lanes.putIfAbsent(peer, () {
        final lane = _ReportedLane(this);
        LinkDelay.shared.attach(lane, peerId: peer);
        return lane;
      });
      lane._queue = micros < 0 ? null : Duration(microseconds: micros);
      lane._at = now;
    }
  }

  void _setProbing(bool on) {
    if (on == _probing) return;
    _probing = on;
    _send(_ProbeLanes(on));
  }
}

class _ReportedLane implements TimedLane {
  _ReportedLane(this._owner);

  /// Reports come ten times a second; one this old is from a gone isolate.
  static const _stale = Duration(seconds: 1);

  final _ReportedLanes _owner;
  Duration? _queue;
  DateTime? _at;

  @override
  Duration? get queueing {
    final at = _at;
    return at == null || DateTime.now().difference(at) > _stale ? null : _queue;
  }

  @override
  set probing(bool value) => _owner._setProbing(value);
}
