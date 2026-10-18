import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Whether a client is on the local network: loopback, the RFC 1918
/// ranges, IPv4 link-local, IPv6 unique-local and link-local. IPv4-mapped
/// IPv6 addresses count as their IPv4 address. Carrier-grade NAT
/// (100.64/10) is not: mobile carriers and VPN overlays such as Tailscale
/// use it, and those peers are not "on this network".
bool isShareLanAddress(InternetAddress address) {
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && raw.length == 4) {
    return _isLanIpv4(raw);
  }
  if (address.type != InternetAddressType.IPv6 || raw.length != 16) {
    return false;
  }
  final mapped = _mappedIpv4(raw);
  if (mapped != null) {
    return _isLanIpv4(mapped);
  }
  final loopback =
      raw.sublist(0, 15).every((byte) => byte == 0) && raw[15] == 1;
  final uniqueLocal = (raw[0] & 0xfe) == 0xfc; // fc00::/7
  final linkLocal = raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80; // fe80::/10
  return loopback || uniqueLocal || linkLocal;
}

/// The client as a stable key for counting: IPv4 in dotted form (mapped
/// addresses unwrapped), IPv6 as printed.
String shareClientKey(InternetAddress address) {
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv6 && raw.length == 16) {
    final mapped = _mappedIpv4(raw);
    if (mapped != null) {
      return mapped.join('.');
    }
  }
  return address.address;
}

Uint8List? _mappedIpv4(Uint8List raw) {
  for (var i = 0; i < 10; i++) {
    if (raw[i] != 0) {
      return null;
    }
  }
  if (raw[10] != 0xff || raw[11] != 0xff) {
    return null;
  }
  return Uint8List.sublistView(raw, 12, 16);
}

bool _isLanIpv4(List<int> o) =>
    o[0] == 127 ||
    o[0] == 10 ||
    (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
    (o[0] == 192 && o[1] == 168) ||
    (o[0] == 169 && o[1] == 254);

/// A listening socket that drops connections from outside the LAN as they
/// arrive, before any byte of HTTP is read, and keeps the number of open
/// connections bounded, in all and per client.
class ShareLanServerSocket extends Stream<Socket> implements ServerSocket {
  ShareLanServerSocket(
    this._inner, {
    bool Function(InternetAddress address)? allow,
    this.onRejected,
    this.maxConnections = 32,
    this.maxPerClient = 8,
  }) : _allow = allow ?? isShareLanAddress;

  final ServerSocket _inner;
  final bool Function(InternetAddress address) _allow;
  final void Function(InternetAddress? address)? onRejected;
  final int maxConnections;
  final int maxPerClient;

  var _open = 0;
  final _perClient = <String, int>{};

  /// Connections currently open.
  int get openConnections => _open;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _inner
        .map(_admit)
        .where((socket) => socket != null)
        .cast<Socket>()
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
  }

  /// The connection, counted and tracked, or null when it is turned away.
  Socket? _admit(Socket socket) {
    InternetAddress? remote;
    try {
      remote = socket.remoteAddress;
    } on Object {
      remote = null;
    }
    if (remote == null || !_allow(remote)) {
      socket.destroy();
      onRejected?.call(remote);
      return null;
    }
    final client = shareClientKey(remote);
    final mine = _perClient[client] ?? 0;
    if (_open >= maxConnections || mine >= maxPerClient) {
      socket.destroy();
      onRejected?.call(remote);
      return null;
    }
    _open++;
    _perClient[client] = mine + 1;
    return _TrackedSocket(socket, () => _release(client));
  }

  void _release(String client) {
    _open--;
    final left = (_perClient[client] ?? 1) - 1;
    if (left <= 0) {
      _perClient.remove(client);
    } else {
      _perClient[client] = left;
    }
  }

  @override
  InternetAddress get address => _inner.address;

  @override
  int get port => _inner.port;

  @override
  Future<ServerSocket> close() async {
    await _inner.close();
    return this;
  }
}

/// A connection that reports, once, when it is over: the peer closed it,
/// it failed, or the server destroyed or closed it. `Socket.done` is no
/// help here; it does not complete when a socket is destroyed.
class _TrackedSocket extends Stream<Uint8List> implements Socket {
  _TrackedSocket(this._inner, this._onClosed);

  final Socket _inner;
  final void Function() _onClosed;
  bool _closed = false;

  void _end() {
    if (_closed) {
      return;
    }
    _closed = true;
    _onClosed();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inner.listen(
    onData,
    onError: (Object error, StackTrace stack) {
      _end();
      if (onError is void Function(Object, StackTrace)) {
        onError(error, stack);
      } else if (onError is void Function(Object)) {
        onError(error);
      }
    },
    onDone: () {
      _end();
      onDone?.call();
    },
    cancelOnError: cancelOnError,
  );

  @override
  void destroy() {
    _end();
    _inner.destroy();
  }

  @override
  Future<void> close() async {
    try {
      await _inner.close();
    } finally {
      _end();
    }
  }

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  int get port => _inner.port;

  @override
  int get remotePort => _inner.remotePort;

  @override
  InternetAddress get address => _inner.address;

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
}
