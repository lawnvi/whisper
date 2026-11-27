import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A [WebSocketChannel] directly backed by a `dart:io` [WebSocket] and its
/// underlying [Socket].
///
/// Unlike `IOWebSocketChannel` from `web_socket_channel` 3.x (which routes
/// writes through `AdapterWebSocketChannel` → synchronous `WebSocket.add` and
/// drops TCP backpressure), [BackpressureWebSocketChannel.sink.addStream]
/// delegates directly to `dart:io` [WebSocket.addStream], propagating real
/// socket backpressure to callers.
///
/// Keeping the underlying [Socket] reference allows [WebSocketSink.close] to
/// tear down the connection immediately via [Socket.destroy] even while an
/// [addStream] write is blocked on a slow or dead peer (calling
/// `WebSocket.close` while `addStream` is active throws `StateError`).
final class BackpressureWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  BackpressureWebSocketChannel(this._webSocket, {required Socket socket})
    : _socket = socket;

  final WebSocket _webSocket;
  final Socket _socket;

  @override
  String? get protocol => _webSocket.protocol;

  @override
  int? get closeCode => _webSocket.closeCode;

  @override
  String? get closeReason => _webSocket.closeReason;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => _webSocket;

  @override
  late final WebSocketSink sink = _BackpressureWebSocketSink(
    _webSocket,
    _socket,
  );
}

final class _BackpressureWebSocketSink implements WebSocketSink {
  _BackpressureWebSocketSink(this._webSocket, this._socket);

  final WebSocket _webSocket;
  final Socket _socket;
  bool _writingStream = false;
  bool _closed = false;
  Future<dynamic>? _closeFuture;

  @override
  void add(dynamic data) {
    if (_closed || _writingStream) {
      return;
    }
    try {
      _webSocket.add(data);
    } on StateError {
      // Closed or bound concurrently; callers observe closure via done/stream.
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed || _writingStream) {
      return;
    }
    try {
      _webSocket.addError(error, stackTrace);
    } on StateError {
      // Ignore concurrent close races.
    }
  }

  @override
  Future<dynamic> addStream(Stream<dynamic> stream) async {
    if (_closed) {
      await stream.drain<void>().catchError((Object _) {});
      return;
    }
    _writingStream = true;
    try {
      await _webSocket.addStream(stream);
    } finally {
      _writingStream = false;
    }
  }

  @override
  Future<dynamic> close([int? closeCode, String? closeReason]) {
    if (_closeFuture != null) {
      return _closeFuture!;
    }
    _closed = true;
    if (_writingStream) {
      // dart:io WebSocket.close() throws StateError while addStream is active;
      // destroying the underlying socket aborts the blocked write immediately.
      _socket.destroy();
      return _closeFuture = Future<void>.value();
    }
    return _closeFuture = _closeGracefully(closeCode, closeReason);
  }

  Future<void> _closeGracefully(int? closeCode, String? closeReason) async {
    try {
      await _webSocket.close(closeCode, closeReason);
    } on StateError {
      _socket.destroy();
    } catch (_) {
      _socket.destroy();
    }
  }

  @override
  Future<dynamic> get done => _webSocket.done;
}

/// Validates and upgrades an incoming `/chat` HTTP request to a
/// [BackpressureWebSocketChannel] without `shelf_web_socket`'s
/// `IOWebSocketChannel` wrapper.
///
/// Preserves the pre-authentication security boundary:
/// - rejects any request carrying an `Origin` header (403);
/// - rejects any `Sec-WebSocket-Protocol` negotiation (400) and disables
///   WebSocket compression/extensions;
/// - validates RFC 6455 headers including a 16-byte base64 `Sec-WebSocket-Key`;
/// - passes the hijacked `Socket` (which is the `PreAuthCappedSocket` from
///   `NoDelayServerSocket`) directly to `WebSocket.fromUpgradedSocket`.
shelf.Response upgradeChatWebSocket(
  shelf.Request request, {
  required Duration pingInterval,
  required void Function(WebSocketChannel channel) onConnection,
}) {
  if (request.method != 'GET') {
    return shelf.Response.notFound('Only WebSocket connections are supported.');
  }
  final connection = request.headers['Connection'];
  if (connection == null) {
    return shelf.Response.notFound('Only WebSocket connections are supported.');
  }
  final tokens = connection
      .toLowerCase()
      .split(',')
      .map((token) => token.trim());
  if (!tokens.contains('upgrade')) {
    return shelf.Response.notFound('Only WebSocket connections are supported.');
  }
  final upgrade = request.headers['Upgrade'];
  if (upgrade == null || upgrade.toLowerCase() != 'websocket') {
    return shelf.Response.notFound('Only WebSocket connections are supported.');
  }
  final version = request.headers['Sec-WebSocket-Version'];
  if (version == null) {
    return shelf.Response(400, body: 'missing Sec-WebSocket-Version header.');
  }
  if (version != '13') {
    return shelf.Response.notFound('Only WebSocket connections are supported.');
  }
  if (request.protocolVersion != '1.1') {
    return shelf.Response(
      400,
      body: 'unexpected HTTP version "${request.protocolVersion}".',
    );
  }
  final key = request.headers['Sec-WebSocket-Key'];
  if (key == null || !_isValidWebSocketKey(key)) {
    return shelf.Response(400, body: 'invalid Sec-WebSocket-Key header.');
  }
  if (request.headers['Origin'] != null) {
    return shelf.Response.forbidden('invalid origin');
  }
  final requestedProtocol = request.headers['Sec-WebSocket-Protocol'];
  if (requestedProtocol != null && requestedProtocol.trim().isNotEmpty) {
    return shelf.Response(400, body: 'unexpected Sec-WebSocket-Protocol.');
  }
  if (!request.canHijack) {
    throw ArgumentError('Server must support request hijacking.');
  }

  request.hijack((channel) {
    if (channel.sink is! Socket) {
      throw ArgumentError('channel.sink must be a dart:io Socket.');
    }
    final socket = channel.sink as Socket;
    socket.add(
      ascii.encode(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Accept: ${WebSocketChannel.signKey(key)}\r\n'
        '\r\n',
      ),
    );
    final webSocket = WebSocket.fromUpgradedSocket(
      socket,
      serverSide: true,
      compression: CompressionOptions.compressionOff,
    )..pingInterval = pingInterval;
    onConnection(BackpressureWebSocketChannel(webSocket, socket: socket));
  });
}

bool _isValidWebSocketKey(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  try {
    return base64.decode(trimmed).length == 16;
  } on FormatException {
    return false;
  }
}
