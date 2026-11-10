import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/datagram_endpoint.dart';

/// Keyboard and mouse over UDP beside the WebSocket. On a weak link TCP
/// holds every packet behind a lost one until it is sent again (a few
/// hundred milliseconds); the pointer then freezes and jumps.
///
/// Every packet carries how far the pointer has gone in all this session
/// (`travel`) and the sequence of the last event before it that must not be
/// skipped (`fence`): a button, key, wheel, entry or release. Then:
/// - a move goes only by UDP. One that is lost or late costs nothing: the
///   next says where the pointer is, and the receiver moves it the
///   difference.
/// - an event that must not be skipped goes by the WebSocket, which never
///   loses it, and by UDP three times, which is usually faster. The receiver
///   takes the first copy and applies events in fence order, and holds back
///   a move until the events before it are in: a drag never starts before
///   its button is down.
/// When the lane is not answering everything goes by the WebSocket.

/// Which end of the lane a log line comes from.
enum RemoteInputLaneSide { sender, receiver }

/// Whether [packet] must reach the other side, in order.
bool isFencedInput(RemoteInputPacketFrame packet) {
  return switch (packet.eventType) {
    RemoteInputEventType.heartbeat => false,
    RemoteInputEventType.mouseMove =>
      _movePayload(packet)?['activeStart'] == true,
    _ => true,
  };
}

Map<String, dynamic>? _movePayload(RemoteInputPacketFrame packet) {
  try {
    final value = jsonDecode(utf8.decode(packet.payload));
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

double _number(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : 0;

/// The sending side: stamps each packet and picks its way.
class RemoteInputLaneTransport implements RemoteInputObservablePacketTransport {
  RemoteInputLaneTransport(
    this._socket,
    this._lane, {
    this.repeats = const [
      Duration(milliseconds: 8),
      Duration(milliseconds: 24),
    ],
    this.trailing = const Duration(milliseconds: 16),
  });

  final RemoteInputObservablePacketTransport _socket;
  final DatagramPath _lane;

  /// When an event that must not be skipped is sent again by UDP.
  final List<Duration> repeats;

  /// The last move is sent again this long after the pointer stops, in
  /// case it was the one lost.
  final Duration trailing;

  double _x = 0, _y = 0;
  int _fence = 0;
  Timer? _trailingTimer;
  final Set<Timer> _repeatTimers = {};
  bool _closed = false;

  /// Moves sent by each way, for diagnostics.
  int movesByLane = 0, movesBySocket = 0;

  bool get laneHealthy => _lane.healthy;

  @override
  Stream<void> get done => _socket.done;

  @override
  void send(RemoteInputPacketFrame packet) {
    if (_closed) return;
    final fenced = isFencedInput(packet);
    if (packet.eventType == RemoteInputEventType.mouseMove) {
      final payload = _movePayload(packet);
      _x += _number(payload?['deltaX']);
      _y += _number(payload?['deltaY']);
    }
    final stamped = packet.stamped((_x, _y), _fence);
    if (fenced) _fence = packet.sequence;
    if (packet.eventType == RemoteInputEventType.heartbeat) {
      _socket.send(stamped);
      return;
    }
    if (!fenced) {
      _trailingTimer?.cancel();
      final bytes = stamped.encode();
      if (_lane.healthy && _lane.send(bytes)) {
        movesByLane += 1;
        _trailingTimer = Timer(trailing, () => _lane.send(bytes));
      } else {
        movesBySocket += 1;
        _socket.send(stamped);
      }
      return;
    }
    _socket.send(stamped);
    if (!_lane.healthy) return;
    final bytes = stamped.encode();
    _lane.send(bytes);
    for (final delay in repeats) {
      late final Timer timer;
      timer = Timer(delay, () {
        _repeatTimers.remove(timer);
        _lane.send(bytes);
      });
      _repeatTimers.add(timer);
    }
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      privacyLog.event(PrivacyEvent.remoteInputLane, {
        PrivacyField.role: RemoteInputLaneSide.sender,
        PrivacyField.viaLane: movesByLane,
        PrivacyField.viaSocket: movesBySocket,
      });
    }
    _closed = true;
    _trailingTimer?.cancel();
    for (final timer in _repeatTimers) {
      timer.cancel();
    }
    _repeatTimers.clear();
    _lane.close();
    await _socket.close();
  }
}

/// The receiving side: takes packets from both ways and hands them on
/// once each, in order, with each move's delta made the difference from
/// where the pointer was last put. Packets without a stamp (an older
/// sender) pass straight through.
class RemoteInputLaneMerger {
  RemoteInputLaneMerger(
    void Function(RemoteInputPacketFrame packet) emit, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _emit = (packet) {
      _timeMove(packet);
      emit(packet);
    };
  }

  /// Events waiting for an earlier one; more means that one is not coming
  /// and the session is broken anyway.
  static const int maxWaiting = 256;

  late final void Function(RemoteInputPacketFrame packet) _emit;
  final DateTime Function() _now;
  int _applied = 0;
  int _appliedFence = 0;
  double _x = 0, _y = 0;
  final Map<int, RemoteInputPacketFrame> _waiting = {};
  RemoteInputPacketFrame? _heldMove;
  Map<String, dynamic>? _lastMove;

  /// Copies dropped as already taken or too old, for diagnostics.
  int duplicates = 0;

  /// Packets that came each way; for packets sent both ways (every event
  /// that must not be skipped), which came first and how much later the
  /// WebSocket's copy came than the UDP one.
  int viaLane = 0, viaSocket = 0, laneFirst = 0, socketFirst = 0;
  final Map<int, (DateTime, bool)> _firstCopy = {};
  final List<int> _socketLateMs = [];

  void accept(RemoteInputPacketFrame packet, {bool viaLane = false}) {
    final fence = packet.fence;
    if (fence == null || packet.travel == null) {
      _emit(packet);
      return;
    }
    if (viaLane) {
      this.viaLane += 1;
    } else {
      viaSocket += 1;
    }
    _timeCopies(packet.sequence, viaLane);
    if (isFencedInput(packet)) {
      if (packet.sequence <= _appliedFence) {
        duplicates += 1;
        return;
      }
      if (fence != _appliedFence) {
        if (fence > _appliedFence && _waiting.length < maxWaiting) {
          _waiting[fence] = packet;
        }
        return;
      }
      _applyFenced(packet);
      for (
        var next = _waiting.remove(_appliedFence);
        next != null;
        next = _waiting.remove(_appliedFence)
      ) {
        _applyFenced(next);
      }
      _waiting.removeWhere((waitingFence, _) => waitingFence < _appliedFence);
      final held = _heldMove;
      if (held != null && held.fence! <= _appliedFence) {
        _heldMove = null;
        if (held.sequence > _applied) _applyMove(held);
      }
      return;
    }
    if (packet.sequence <= _applied) {
      duplicates += 1;
      return;
    }
    if (fence > _appliedFence) {
      final held = _heldMove;
      if (held == null || packet.sequence > held.sequence) _heldMove = packet;
      return;
    }
    _applyMove(packet);
  }

  void _timeCopies(int sequence, bool viaLane) {
    final first = _firstCopy[sequence];
    if (first == null) {
      // A copy lost on the way never pairs; don't keep it for ever.
      if (_firstCopy.length >= 4096) _firstCopy.clear();
      _firstCopy[sequence] = (_now(), viaLane);
      return;
    }
    if (first.$2 == viaLane) return;
    _firstCopy.remove(sequence);
    if (first.$2) {
      laneFirst += 1;
      if (_socketLateMs.length < 4096) {
        _socketLateMs.add(_now().difference(first.$1).inMilliseconds);
      }
    } else {
      socketFirst += 1;
    }
  }

  /// How long each move took from its sender's clock to being applied
  /// here. The two clocks differ by a constant, so only what is above the
  /// quickest says anything: how much a move waited on the way.
  final List<int> _moveTransitMs = [];

  void _timeMove(RemoteInputPacketFrame packet) {
    if (packet.eventType != RemoteInputEventType.mouseMove ||
        packet.timestampMicros == 0 ||
        _moveTransitMs.length >= 1 << 16) {
      return;
    }
    _moveTransitMs.add(
      _now().microsecondsSinceEpoch ~/ 1000 - packet.timestampMicros ~/ 1000,
    );
  }

  /// How much longer than the quickest a move waited, at [fraction] of all
  /// moves, in milliseconds.
  int moveWaitMs(double fraction) {
    if (_moveTransitMs.isEmpty) return 0;
    final sorted = [..._moveTransitMs]..sort();
    return sorted[((sorted.length - 1) * fraction).round()] - sorted.first;
  }

  /// How much later the WebSocket's copy came, at the [fraction] of the
  /// events sent both ways (0.5 is the median), in milliseconds.
  int socketLateMs(double fraction) {
    if (_socketLateMs.isEmpty) return 0;
    final sorted = [..._socketLateMs]..sort();
    return sorted[((sorted.length - 1) * fraction).round()];
  }

  void _applyFenced(RemoteInputPacketFrame packet) {
    final (x, y) = packet.travel!;
    final entry = packet.eventType == RemoteInputEventType.mouseMove;
    // Moves lost just before a click: put the pointer where it was when
    // the click happened. An entry places the pointer itself.
    final template = _lastMove;
    if (!entry && template != null && (x != _x || y != _y)) {
      _emit(
        RemoteInputPacketFrame(
          sessionId: packet.sessionId,
          sequence: packet.sequence - 1,
          timestampMicros: packet.timestampMicros,
          eventType: RemoteInputEventType.mouseMove,
          payload: _withDelta(template, x - _x, y - _y),
        ),
      );
    }
    _x = x;
    _y = y;
    _appliedFence = packet.sequence;
    if (packet.sequence > _applied) _applied = packet.sequence;
    // An entry is a move too, and the one every later move is like.
    if (entry) _lastMove = _movePayload(packet) ?? _lastMove;
    _emit(packet);
  }

  void _applyMove(RemoteInputPacketFrame packet) {
    final payload = _movePayload(packet);
    final (x, y) = packet.travel!;
    _applied = packet.sequence;
    if (payload == null) {
      _emit(packet);
      return;
    }
    _lastMove = payload;
    final dx = x - _x, dy = y - _y;
    _x = x;
    _y = y;
    _emit(
      RemoteInputPacketFrame(
        sessionId: packet.sessionId,
        sequence: packet.sequence,
        timestampMicros: packet.timestampMicros,
        eventType: packet.eventType,
        payload: _withDelta(payload, dx, dy),
      ),
    );
  }

  static Uint8List _withDelta(
    Map<String, dynamic> payload,
    double dx,
    double dy,
  ) {
    final copy = Map<String, dynamic>.from(payload)
      ..['deltaX'] = dx
      ..['deltaY'] = dy
      ..['activeStart'] = false;
    return Uint8List.fromList(utf8.encode(jsonEncode(copy)));
  }
}
