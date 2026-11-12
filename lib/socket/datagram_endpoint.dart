import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:whisper/socket/datagram_seal.dart';
import 'package:whisper/socket/link_delay.dart';

/// One UDP socket that serves every lane of an isolate. Datagrams find
/// their lane by the id in clear at their start ([DatagramFormat]); a lane
/// then checks they are genuine. Anything else is dropped unread.
final class DatagramEndpoint {
  DatagramEndpoint._(this._socket) {
    _subscription = _socket.listen(
      _onEvent,
      // Windows reports an ICMP "port unreachable" from an earlier send as
      // an error on the socket; the socket itself keeps working.
      onError: (Object _) {},
      onDone: () => _closed = true,
      cancelOnError: false,
    );
  }

  /// Binds on all IPv4 addresses, on [port] when it is free, else on any,
  /// or not at all when [exact] (the other end expects that port).
  static Future<DatagramEndpoint> bind({
    int port = 0,
    bool exact = false,
  }) async {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      if (port == 0 || exact) rethrow;
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _markInteractive(socket);
    return DatagramEndpoint._(socket);
  }

  /// Asks the network to treat these datagrams as interactive voice: on
  /// Wi-Fi that is the queue that waits least. macOS needs no permission;
  /// Windows ignores it without a system policy, which is fine.
  static void _markInteractive(RawDatagramSocket socket) {
    void attempt(RawSocketOption option) {
      try {
        socket.setRawOption(option);
      } on Object {
        // Not supported here: the datagrams go as best effort.
      }
    }

    if (Platform.isMacOS) {
      // SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VO; it sets the DSCP too.
      attempt(RawSocketOption.fromInt(RawSocketOption.levelSocket, 0x1116, 4));
    } else if (Platform.isLinux || Platform.isAndroid) {
      // IP_TOS = DSCP 46 (expedited forwarding).
      attempt(RawSocketOption.fromInt(RawSocketOption.levelIPv4, 1, 0xb8));
    } else if (Platform.isWindows) {
      attempt(RawSocketOption.fromInt(RawSocketOption.levelIPv4, 3, 0xb8));
    }
  }

  final RawDatagramSocket _socket;
  late final StreamSubscription<RawSocketEvent> _subscription;
  final Map<int, void Function(Datagram datagram)> _lanes = {};
  bool _closed = false;

  int get port => _socket.port;
  bool get isClosed => _closed;

  static int _key(Uint8List laneId) =>
      ByteData.sublistView(laneId).getUint64(0);

  void attach(Uint8List laneId, void Function(Datagram datagram) onDatagram) {
    _lanes[_key(laneId)] = onDatagram;
  }

  void detach(Uint8List laneId) => _lanes.remove(_key(laneId));

  /// False when the datagram could not go now (the socket is full or gone).
  bool send(Uint8List datagram, InternetAddress address, int port) {
    if (_closed) return false;
    try {
      return _socket.send(datagram, address, port) == datagram.length;
    } on SocketException {
      return false;
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    while (true) {
      final Datagram? datagram;
      try {
        datagram = _socket.receive();
      } on SocketException {
        return;
      }
      if (datagram == null) return;
      final laneId = DatagramOpener.laneIdOf(datagram.data);
      if (laneId == null) continue;
      _lanes[_key(laneId)]?.call(datagram);
    }
  }

  Future<void> close() async {
    _closed = true;
    _lanes.clear();
    await _subscription.cancel();
    _socket.close();
  }
}

/// What a sender needs of a lane: whether it is answering, and a way to
/// send on it.
abstract interface class DatagramPath {
  bool get healthy;
  bool send(Uint8List payload);
  void close();
}

/// One session's datagrams both ways. The dialer knows where to send from
/// the start; the other end learns it from the first genuine datagram, and
/// answers wherever the latest one came from. Both send a keepalive every
/// [keepalive]; the lane is [healthy] while the other end was heard within
/// [healthyWithin], which is what decides whether anything is sent on it.
///
/// While data comes in, the receiving end also answers at least every
/// [answerEvery]. A Wi-Fi card that only receives dozes between beacons,
/// and the access point holds what comes for it until it wakes: up to a few
/// hundred milliseconds. Over TCP the ACKs keep it awake.
///
/// Keepalives carry stamps, and the other end's answers echo them, so each
/// end knows how long the way there and back takes now and with nothing
/// queued ([queueing]). While [probing] it asks for an answer every
/// [probeEvery]. [delay] is told about the lane for as long as it is open.
final class DatagramLane implements DatagramPath, TimedLane {
  DatagramLane({
    required DatagramEndpoint endpoint,
    required DatagramKeys keys,
    required bool dialer,
    required void Function(Uint8List payload) onData,
    InternetAddress? peer,
    int peerPort = 0,
    this.keepalive = const Duration(milliseconds: 250),
    this.healthyWithin = const Duration(milliseconds: 1000),
    this.answerEvery = const Duration(milliseconds: 40),
    this.probeEvery = const Duration(milliseconds: 25),
    LinkDelay? delay,
    DateTime Function()? now,
  }) : _endpoint = endpoint,
       _delay = delay,
       _keys = keys,
       _sealer = keys.sealer(
         dialer ? DatagramDirection.fromDialer : DatagramDirection.toDialer,
       ),
       _opener = keys.opener(
         dialer ? DatagramDirection.toDialer : DatagramDirection.fromDialer,
       ),
       _onData = onData,
       _peer = peer,
       _peerPort = peerPort,
       _now = now ?? DateTime.now {
    _endpoint.attach(_opener.laneId, _receive);
    _timer = Timer.periodic(keepalive, (_) => _sendKeepalive());
    _sendKeepalive();
    delay?.attach(this);
  }

  static const int _kindKeepalive = 0;
  static const int _kindData = 1;

  /// After a keepalive's kind (older versions read nothing more): flags,
  /// this end's clock, the last stamp heard from the other end and how long
  /// ago it came, in microseconds, each in 32 bits. An end takes its way
  /// there and back from the echo of its own stamp.
  static const int _stampBytes = 13;
  static const int _asks = 1, _echoes = 2;
  static const int _mask = 0xffffffff;
  static const int _longestTrip = 10 * Duration.microsecondsPerSecond;

  /// Answers to asks no closer together than this.
  static const int _answerAskEvery = 10000;
  static final Stopwatch _clock = Stopwatch()..start();

  final DatagramEndpoint _endpoint;
  final DatagramKeys _keys;
  final DatagramSealer _sealer;
  final DatagramOpener _opener;
  final void Function(Uint8List payload) _onData;
  final DateTime Function() _now;
  final Duration keepalive, healthyWithin, answerEvery, probeEvery;
  final LinkDelay? _delay;
  final RoundTrips _trips = RoundTrips();
  int? _heardStamp;
  int _heardStampAt = 0;
  int _answeredAsk = -_longestTrip;
  Timer? _probeTimer;
  InternetAddress? _peer;
  int _peerPort;
  DateTime? _heard, _answered;
  Timer? _timer;
  bool _closed = false;

  /// Datagrams taken and sent with data in them, for diagnostics.
  int received = 0, sent = 0;

  @override
  bool get healthy {
    final heard = _heard;
    return !_closed &&
        !_endpoint.isClosed &&
        heard != null &&
        _now().difference(heard) <= healthyWithin;
  }

  @override
  Duration? get queueing => _trips.queueing(_clock.elapsedMicroseconds);

  @override
  set probing(bool value) {
    if (!value || _closed) {
      _probeTimer?.cancel();
      _probeTimer = null;
    } else {
      _probeTimer ??= Timer.periodic(
        probeEvery,
        (_) => _sendKeepalive(ask: true),
      );
    }
  }

  /// Sends [payload] at once; false when it could not go.
  @override
  bool send(Uint8List payload) {
    if (!_put(_kindData, payload)) return false;
    sent += 1;
    return true;
  }

  bool _put(int kind, Uint8List payload) {
    final peer = _peer;
    if (_closed || peer == null || _peerPort == 0) return false;
    final framed = Uint8List(payload.length + 1)
      ..[0] = kind
      ..setAll(1, payload);
    if (!_endpoint.send(_sealer.seal(framed), peer, _peerPort)) return false;
    _answered = _now();
    return true;
  }

  void _sendKeepalive({bool ask = false}) {
    final now = _clock.elapsedMicroseconds;
    final heard = _heardStamp;
    final body = ByteData(_stampBytes)
      ..setUint8(0, (ask ? _asks : 0) | (heard == null ? 0 : _echoes))
      ..setUint32(1, now & _mask);
    if (heard != null) {
      body
        ..setUint32(5, heard)
        ..setUint32(9, math.min(now - _heardStampAt, _mask));
    }
    _put(_kindKeepalive, body.buffer.asUint8List());
  }

  /// A keepalive with stamps: the other end's to echo, an echo of this
  /// end's, and maybe an ask for an answer now. The answer asks nothing, or
  /// two ends that both ask would answer each other on and on.
  void _readStamps(Uint8List payload) {
    final now = _clock.elapsedMicroseconds;
    final body = ByteData.sublistView(payload, 1, 1 + _stampBytes);
    final flags = body.getUint8(0);
    _heardStamp = body.getUint32(1);
    _heardStampAt = now;
    if (flags & _echoes != 0) {
      final took = (now - body.getUint32(5) - body.getUint32(9)) & _mask;
      if (took < _longestTrip) _trips.add(took, now);
    }
    if (flags & _asks != 0 && now - _answeredAsk >= _answerAskEvery) {
      _answeredAsk = now;
      _sendKeepalive();
    }
  }

  void _receive(Datagram datagram) {
    if (_closed) return;
    final payload = _opener.open(datagram.data);
    if (payload == null || payload.isEmpty) return;
    final firstHeard = _heard == null;
    _heard = _now();
    _peer = datagram.address;
    _peerPort = datagram.port;
    // Answer at once, so the dialer knows the lane works without waiting
    // for the next keepalive.
    if (firstHeard) _sendKeepalive();
    if (payload[0] == _kindKeepalive && payload.length > _stampBytes) {
      _readStamps(payload);
    }
    if (payload[0] != _kindData) return;
    final answered = _answered;
    if (answered == null || _heard!.difference(answered) >= answerEvery) {
      _sendKeepalive();
    }
    received += 1;
    _onData(Uint8List.sublistView(payload, 1));
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _probeTimer?.cancel();
    _delay?.detach(this);
    _endpoint.detach(_opener.laneId);
    _keys.destroy();
  }
}
