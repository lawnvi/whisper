part of 'transfer_data_isolate.dart';

/// Worker-isolate HTTP/WebSocket server for `/transfer` (default port
/// `main + 3` = 10005, trying 8 ports before falling back to ephemeral).
///
/// Mirrors `audio_media_server.dart`: validates one-time tokens through the
/// main isolate's [TransferClaimBroker], runs [MediaUpgradeServer] challenge
/// proof, consumes the token only after proof passes, tunes the accepted
/// socket by [TransferChannelKind], and wraps it in
/// [BackpressureWebSocketChannel] for real TCP backpressure.
final class _TransferDataServer {
  _TransferDataServer._(
    this._runtime,
    this._listening,
    this._acceptedSockets,
    this._server,
  );

  static Future<_TransferDataServer> bind(
    _TransferWorkerRuntime runtime,
    int preferredPort,
  ) async {
    final listening = await _listen(preferredPort);
    final accepting = NoDelayServerSocket(listening);
    final server = HttpServer.listenOn(accepting);
    server.idleTimeout = const Duration(seconds: 10);
    final media = _TransferDataServer._(runtime, listening, accepting, server);
    server.listen(
      (request) => unawaited(media._handle(request)),
      onError: (Object _) {},
    );
    return media;
  }

  static Future<ServerSocket> _listen(int preferredPort) async {
    for (final port in WhisperPorts.candidates(preferredPort)) {
      try {
        return await ServerSocket.bind('0.0.0.0', port);
      } on SocketException {
        continue;
      }
    }
    return ServerSocket.bind('0.0.0.0', 0);
  }

  final _TransferWorkerRuntime _runtime;
  final ServerSocket _listening;
  final NoDelayServerSocket _acceptedSockets;
  final HttpServer _server;
  final MediaUpgradeServer _upgrades = MediaUpgradeServer(
    maxProvisional: 16,
    proofTimeout: const Duration(seconds: 3),
  );

  int get port => _listening.port;

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != MediaRoute.transfer.path ||
        request.method != 'GET' ||
        !WebSocketTransformer.isUpgradeRequest(request) ||
        (request.headers.value('origin')?.trim().isNotEmpty ?? false) ||
        request.headers.value('sec-websocket-version')?.trim() != '13') {
      await _refuse(request, HttpStatus.badRequest);
      return;
    }
    final credentials = mediaUpgradeCredentials(request.uri);
    if (credentials == null) {
      await _refuse(request, HttpStatus.unauthorized);
      return;
    }
    final slot = _upgrades.reserve();
    if (slot == null || !slot.ready) {
      slot?.release();
      await _refuse(
        request,
        slot == null
            ? HttpStatus.tooManyRequests
            : HttpStatus.internalServerError,
      );
      return;
    }
    final connectionInfo = request.connectionInfo;
    final claim = await _runtime.lookupClaim(
      credentials.sessionId,
      credentials.token,
      connectionInfo?.remoteAddress.address ?? '',
    );
    if (claim == null) {
      slot.release();
      await _refuse(request, HttpStatus.unauthorized);
      return;
    }
    final accepted = connectionInfo == null
        ? null
        : _acceptedSockets.claim(connectionInfo);
    if (accepted != null) {
      // Token came from an already-authenticated peer; lift pre-auth cap and
      // apply kind-specific socket tuning.
      accepted.liftWhen(() => true);
      if (claim.kind == TransferChannelKind.bulk) {
        tuneTransferBulkSocket(accepted);
      } else {
        tuneTransferBrowseSocket(accepted);
      }
    }
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
      );
    } catch (_) {
      _runtime.releaseClaim(claim);
      slot.release();
      return;
    }
    socket.pingInterval = _upgrades.pingInterval;
    final WebSocketChannel channel = accepted != null
        ? BackpressureWebSocketChannel(socket, socket: accepted)
        : BackpressureWebSocketChannel(socket, socket: _FallbackSocket(socket));
    var proven = false;
    slot.onReleased = () {
      if (!proven) {
        _runtime.releaseClaim(claim);
      }
    };
    try {
      slot.prove(
        channel,
        MediaUpgradeOffer(
          route: MediaRoute.transfer.path,
          namespace: MediaRoute.transfer.namespace,
          sessionId: claim.sessionId,
          peerId: claim.peerId,
          connectionGeneration: claim.connectionGeneration,
          token: credentials.token,
        ),
        mediaMacKey: claim.receiveKey,
        onProven: (authenticated) async {
          proven = true;
          final consumed = await _runtime.consumeClaim(claim);
          if (!consumed || _runtime._shuttingDown) {
            _runtime.releaseClaim(claim);
            return false;
          }
          try {
            _runtime.attachChannel(
              channel: authenticated,
              peerId: claim.peerId,
              connectionGeneration: claim.connectionGeneration,
              kind: claim.kind,
              sessionId: claim.sessionId,
              reverse: claim.reverse,
              sendKey: claim.sendKey,
              receiveKey: claim.receiveKey,
              channelBinding: claim.channelBinding,
            );
            return true;
          } finally {
            claim.zeroKeys();
          }
        },
      );
    } catch (_) {
      slot.release();
      unawaited(channel.sink.close(4001, 'media_auth_failed'));
    }
  }

  Future<void> _refuse(HttpRequest request, int status) async {
    try {
      request.response.statusCode = status;
      await request.response.close();
    } catch (_) {}
  }

  Future<void> close() async {
    await _server.close(force: true);
    await _listening.close();
  }
}

/// Fallback when [HttpRequest.connectionInfo] is unavailable; closes via the
/// [WebSocket] itself.
final class _FallbackSocket implements Socket {
  _FallbackSocket(this._ws);

  final WebSocket _ws;

  @override
  void destroy() {
    unawaited(_ws.close().catchError((Object _) {}));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
