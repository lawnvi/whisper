part of 'audio_media_isolate.dart';

/// A source's packets arriving at this isolate's own port.
class _MediaChannel {
  _MediaChannel(this.claim, this.playback);

  final _ClaimData claim;
  final _IsolatePlayback playback;
  BoundedBinaryWebSocketSession? session;
  AuthenticatedMediaPacketDecoder? decoder;
  DatagramLane? lane;
  bool _expectedClose = false;

  Future<void> close({required bool expected}) async {
    _expectedClose = _expectedClose || expected;
    await session?.close();
  }

  void handleBytes(Uint8List bytes, AudioShareDiagnostics diagnostics) =>
      handlePacket(
        AudioGroupPacketFrame.decode(decoder!.decode(bytes)),
        diagnostics,
      );

  void handlePacket(
    AudioGroupPacketFrame packet,
    AudioShareDiagnostics diagnostics,
  ) {
    final spec = playback.pipeline.spec;
    // Fanned out as is to every sink: sessionId is the shared streamId.
    if (packet.sourcePeerId != claim.peerId ||
        packet.groupId != spec.groupId ||
        packet.streamId != spec.streamId ||
        packet.sessionId != spec.streamId) {
      throw const FormatException('audio group packet claim mismatch');
    }
    diagnostics.groupPacketDelivered(
      groupId: packet.groupId,
      streamId: packet.streamId,
      sequence: packet.sequence,
      payloadBytes: packet.payload.length,
    );
    playback.pipeline.deliver(packet);
  }

  void closed() {
    lane?.close();
    lane = null;
    decoder?.destroy();
    decoder = null;
    playback.channels.remove(this);
    if (!_expectedClose) {
      playback.fail(AudioFailureReason.transport);
    }
  }
}

/// The audio isolate's own port, for sources that know it (`mediaPort` in
/// the accept). Same rules as the main port's /audio: a one-time token the
/// main isolate issued and checks, the media proof, one channel per token,
/// and every packet checked against the playback it belongs to.
class _MediaServer {
  _MediaServer._(this._runtime, this._listening, this._server);

  static Future<_MediaServer> bind(_AudioRuntime runtime) async {
    final listening = await _listen(runtime.mediaPort);
    final server = HttpServer.listenOn(NoDelayServerSocket(listening));
    server.idleTimeout = const Duration(seconds: 10);
    final media = _MediaServer._(runtime, listening, server);
    server.listen(
      (request) => unawaited(media._handle(request)),
      onError: (Object _) {},
    );
    return media;
  }

  /// TCP, and UDP for sound by UDP (`audio_group_lane.dart`), on one
  /// number: [fixed] (`WhisperPorts.audioMedia`) or one of the next few,
  /// else any free one, with UDP beside it if that number is free too.
  static Future<ServerSocket> _listen(int fixed) async {
    for (final port in WhisperPorts.candidates(fixed)) {
      final ServerSocket listening;
      try {
        listening = await ServerSocket.bind('0.0.0.0', port);
      } on SocketException {
        continue;
      }
      if (await AudioGroupDatagrams.listenAt(port)) return listening;
      await listening.close();
    }
    final listening = await ServerSocket.bind('0.0.0.0', 0);
    await AudioGroupDatagrams.listenAt(listening.port);
    return listening;
  }

  final _AudioRuntime _runtime;
  final ServerSocket _listening;
  final HttpServer _server;
  final MediaUpgradeServer _upgrades = MediaUpgradeServer(
    maxProvisional: 8,
    proofTimeout: const Duration(seconds: 3),
  );

  int get port => _listening.port;

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/audio' ||
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
    final claim = await _runtime.lookupClaim(
      credentials.sessionId,
      credentials.token,
      request.connectionInfo?.remoteAddress.address ?? '',
    );
    // A sink this isolate's source could not reach dials back with the
    // token the source sent it; any other token is for a playback here.
    final playback = claim == null || claim.reverse
        ? null
        : _runtime.playbackFor(claim);
    final dialBack =
        claim != null &&
        claim.reverse &&
        _runtime.dialBacks.isWaiting(
          MediaRoute.audio,
          claim.peerId,
          claim.sessionId,
        );
    if (claim == null ||
        (playback == null && !dialBack) ||
        claim.namespace != 'audio-group') {
      if (claim != null) {
        _runtime.releaseClaim(claim);
      }
      slot.release();
      await _refuse(request, HttpStatus.unauthorized);
      return;
    }
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      _runtime.releaseClaim(claim);
      slot.release();
      return;
    }
    socket.pingInterval = _upgrades.pingInterval;
    // Until the proof holds, the claim is this upgrade's to give back.
    var proven = false;
    slot.onReleased = () {
      if (!proven) _runtime.releaseClaim(claim);
    };
    try {
      slot.prove(
        IOWebSocketChannel(socket),
        MediaUpgradeOffer(
          route: '/audio',
          namespace: claim.namespace,
          sessionId: claim.sessionId,
          peerId: claim.peerId,
          connectionGeneration: claim.connectionGeneration,
          token: credentials.token,
        ),
        mediaMacKey: claim.mediaMacKey,
        // The token is used up only after the proof, as on the main port,
        // and the channel is played from only once it is.
        onProven: (authenticated) async {
          if (playback?.pipeline.isClosed ?? false) return false;
          proven = true;
          final consumed = await _runtime.consumeClaim(claim);
          if (playback == null) {
            final taken = consumed && _takeDialBack(authenticated, claim);
            _runtime.releaseClaim(claim);
            return taken;
          }
          if (!consumed || playback.pipeline.isClosed) {
            _runtime.releaseClaim(claim);
            return false;
          }
          _attach(_MediaChannel(claim, playback), authenticated);
          return true;
        },
      );
    } catch (_) {
      slot.release();
      unawaited(socket.close(4001, 'media_auth_failed'));
    }
  }

  /// Hands a sink's dial back to the source's wait for it, to send the
  /// sound on under this device's own send key (`_AudioRuntime._connect`).
  bool _takeDialBack(WebSocketChannel channel, _ClaimData claim) {
    final reverse = SessionUpgradeClaim(
      route: '/audio',
      namespace: claim.namespace,
      sessionId: claim.sessionId,
      peerId: claim.peerId,
      mediaMacKey: claim.mediaMacKey,
      channelBinding: claim.channelBinding,
      connectionGeneration: claim.connectionGeneration,
      reverse: true,
    );
    final taken = _runtime.dialBacks.attach(
      channel,
      reverse,
      encoder: () => AuthenticatedMediaPacketEncoder(
        route: '/audio',
        namespace: claim.namespace,
        sessionId: claim.sessionId,
        mediaMacKey: claim.sendKey!,
        channelBinding: claim.channelBinding,
        maxPayloadBytes:
            AudioGroupWebSocketPacketTransport.maxPacketPayloadBytes,
      ),
    );
    if (!taken) reverse.destroy();
    return taken;
  }

  void _attach(_MediaChannel media, WebSocketChannel authenticated) {
    media.decoder = AuthenticatedMediaPacketDecoder(
      route: '/audio',
      namespace: media.claim.namespace,
      sessionId: media.claim.sessionId,
      mediaMacKey: media.claim.mediaMacKey,
      channelBinding: media.claim.channelBinding,
      maxPayloadBytes: AudioShareManager.maxPacketPayloadBytes,
    );
    media.playback.channels.add(media);
    final diagnostics = _runtime.diagnostics..audioChannelAttached();
    media.lane = AudioGroupDatagrams.answer(
      mediaKey: media.claim.mediaMacKey,
      channelBinding: media.claim.channelBinding,
      sessionId: media.claim.sessionId,
      onPacket: (packet) {
        try {
          media.handlePacket(packet, diagnostics);
        } on FormatException {
          // Not this session's: the WebSocket would close; UDP just drops.
        }
      },
    );
    media.session = BoundedBinaryWebSocketSession(
      channel: authenticated,
      maxMessageBytes: AudioShareManager.maxChannelMessageBytes,
      onMessage: (bytes) {
        diagnostics.audioChannelMessageBytes(bytes.length);
        media.handleBytes(bytes, diagnostics);
      },
      onError: diagnostics.audioChannelError,
      onClosed: media.closed,
    );
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
