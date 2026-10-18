import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Sends small writes at once instead of waiting for the previous one to be
/// acknowledged (Nagle's algorithm). Input, control and audio packets are
/// small and must not wait; video frames are large and unaffected.
void setTcpNoDelay(Socket socket) {
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } on Object {
    // Best effort: a socket that refuses keeps working, only slower.
  }
}

/// Deeper socket buffers for the connection that carries files, on Windows.
///
/// dart:io keeps one write of at most 64 KiB outstanding per socket and
/// issues the next one from the isolate's event loop. With Windows' default
/// 64 KiB send buffer the connection sits idle whenever the isolate is busy
/// (encrypting the next frame), so files went at two thirds of the link: a
/// slow Windows PC sent to a Mac at 65 MiB/s, and at 91 with these buffers
/// (the link carries 94). Not for media connections: there a deep buffer
/// only delays live video and input.
void widenTransferBuffers(Socket socket) {
  if (!Platform.isWindows) {
    return;
  }
  try {
    for (final option in const [_soSndBuf, _soRcvBuf]) {
      socket.setRawOption(
        RawSocketOption.fromInt(_solSocket, option, _transferBufferBytes),
      );
    }
  } on Object {
    // Best effort: the transfer still works, only slower.
  }
}

// Winsock's SOL_SOCKET, SO_SNDBUF and SO_RCVBUF.
const _solSocket = 0xffff;
const _soSndBuf = 0x1001;
const _soRcvBuf = 0x1002;
const _transferBufferBytes = 16 * 1024 * 1024;

/// A listening socket whose accepted connections have TCP_NODELAY set, for
/// [HttpServer.listenOn] (shelf's own `serve` gives no way to set it).
class NoDelayServerSocket extends Stream<Socket> implements ServerSocket {
  NoDelayServerSocket(this._inner);

  final ServerSocket _inner;

  /// Accepted connections no route has claimed yet, by the other end's
  /// address and port.
  final _unclaimed = <String, Socket>{};

  /// The accepted socket an HTTP request came in on, for a route that tunes
  /// it once it knows what the connection is for. Each is handed out once.
  Socket? claim(HttpConnectionInfo connection) => _unclaimed.remove(
    _keyOf(connection.remoteAddress, connection.remotePort),
  );

  static String _keyOf(InternetAddress address, int port) =>
      '${address.address}:$port';

  @override
  int get port => _inner.port;

  @override
  InternetAddress get address => _inner.address;

  @override
  Future<ServerSocket> close() async {
    await _inner.close();
    return this;
  }

  /// When the HTTP server stops listening (its `close`), the listening
  /// socket closes too: [HttpServer.listenOn] leaves that to its owner.
  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    late final StreamSubscription<Socket> inner;
    final controller = StreamController<Socket>(
      sync: true,
      onCancel: () async {
        await inner.cancel();
        await _inner.close();
      },
    );
    inner = _inner.listen(
      (socket) {
        setTcpNoDelay(socket);
        String? key;
        try {
          key = _keyOf(socket.remoteAddress, socket.remotePort);
        } on SocketException {
          // Already closed: nothing to tune later.
        }
        if (key != null) {
          final remembered = key;
          _unclaimed[remembered] = socket;
          // Forgotten with the connection, claimed or not.
          socket.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(
            () {
              if (identical(_unclaimed[remembered], socket)) {
                _unclaimed.remove(remembered);
              }
            },
          );
        }
        controller.add(socket);
      },
      onError: controller.addError,
      onDone: controller.close,
    );
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

/// Opens a WebSocket over a socket with TCP_NODELAY set (dart:io's
/// `WebSocket.connect` gives no access to its socket).
Future<WebSocket> connectNoDelayWebSocket(
  Uri uri, {
  required HttpClient client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final http = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
  final nonce = base64.encode(
    List<int>.generate(16, (_) => Random.secure().nextInt(256)),
  );
  final request = await client.openUrl('GET', http).timeout(timeout);
  request.followRedirects = false;
  request.headers
    ..set(HttpHeaders.connectionHeader, 'Upgrade')
    ..set(HttpHeaders.upgradeHeader, 'websocket')
    ..set('Sec-WebSocket-Key', nonce)
    ..set(HttpHeaders.cacheControlHeader, 'no-cache')
    ..set('Sec-WebSocket-Version', '13');
  final response = await request.close().timeout(timeout);
  final socket = await response.detachSocket();
  final upgrade = response.headers.value(HttpHeaders.upgradeHeader);
  final accept = response.headers.value('Sec-WebSocket-Accept');
  if (response.statusCode != HttpStatus.switchingProtocols ||
      upgrade?.trim().toLowerCase() != 'websocket' ||
      accept?.trim() != WebSocketChannel.signKey(nonce) ||
      response.headers.value('Sec-WebSocket-Extensions') != null) {
    socket.destroy();
    throw WebSocketException('Connection to $uri was not upgraded');
  }
  setTcpNoDelay(socket);
  return WebSocket.fromUpgradedSocket(
    socket,
    serverSide: false,
    compression: CompressionOptions.compressionOff,
  );
}
