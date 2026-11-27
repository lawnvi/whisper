part of 'svrmanager.dart';

/// The media connections beside `/chat` as this device's server and its
/// sessions see them: which upgrades the main port takes, the checks on
/// their claims, the tokens this device issues and the keys it lends.
/// See docs/internals/media-channels.md.
extension _MediaChannels on WsSvrManager {
  Future<shelf.Response> _handleMediaUpgrade({
    required shelf.Request request,
    required String route,
    required String sessionId,
    required String token,
    required SessionUpgradeClaim provisionalClaim,
    required bool Function(SessionUpgradeClaim claim) canAttach,
    required bool Function(WebSocketChannel channel, SessionUpgradeClaim claim)
    attach,
  }) => _mediaUpgrades.upgradeShelf(
    request,
    MediaUpgradeOffer.forClaim(provisionalClaim, token),
    mediaMacKey: provisionalClaim.withMediaMacKey,
    // Its token comes from a peer that already authenticated.
    onReserved: () =>
        _acceptedSockets?.trust(request.context['shelf.io.connection_info']),
    onProven: (authenticated) {
      if (!canAttach(provisionalClaim)) return false;
      final consumed = _sessionUpgradeTokens.consume(
        route: route,
        sessionId: sessionId,
        token: token,
        now: DateTime.now(),
        expected: provisionalClaim,
      );
      if (consumed == null) return false;
      var attached = false;
      try {
        attached = attach(authenticated, consumed);
        return attached;
      } finally {
        if (!attached) consumed.destroy();
      }
    },
    onReleased: provisionalClaim.destroy,
  );

  /// `/audio`, `/input` and `/window` on the main port: the token, then
  /// the proof ([_handleMediaUpgrade]); null for `/chat`.
  FutureOr<shelf.Response>? _routeMediaUpgrade(
    shelf.Request request,
    String path,
  ) {
    if (path == 'audio') {
      final credentials = mediaUpgradeCredentials(request.url);
      final claim = credentials == null
          ? null
          : _sessionUpgradeTokens.lookup(
              route: '/audio',
              sessionId: credentials.sessionId,
              token: credentials.token,
              now: DateTime.now(),
            );
      // A dial back here is only for sound sent from this isolate (when
      // the audio isolate is not running); see [_awaitAudioDialBackHere].
      bool admits(SessionUpgradeClaim candidate) =>
          _isExpectedMediaPeerClaim(candidate) &&
          (candidate.reverse
              ? _dialBacks.canAttach(candidate)
              : _isExpectedAudioUpgradeClaim(candidate));
      if (claim == null || !admits(claim)) {
        return shelf.Response.unauthorized('Unauthorized');
      }
      return _handleMediaUpgrade(
        request: request,
        route: '/audio',
        sessionId: credentials!.sessionId,
        token: credentials.token,
        provisionalClaim: claim,
        canAttach: admits,
        attach: (channel, consumed) => consumed.reverse
            ? _dialBacks.attach(
                channel,
                consumed,
                encoder: () => _dialBackEncoder(
                  consumed,
                  maxPayloadBytes:
                      AudioGroupWebSocketPacketTransport.maxPacketPayloadBytes,
                ),
              )
            : _audioManager.attachChannel(
                channel,
                claim: consumed,
                additionalValidator: _isExpectedAudioGroupUpgradeClaim,
                groupPacketValidator: _isExpectedAudioGroupPacket,
                claimValidator: _isExpectedMediaPeerClaim,
              ),
      );
    }
    if (path == 'input') {
      final credentials = mediaUpgradeCredentials(request.url);
      final claim = credentials == null
          ? null
          : _sessionUpgradeTokens.lookup(
              route: '/input',
              sessionId: credentials.sessionId,
              token: credentials.token,
              now: DateTime.now(),
            );
      // A token this device issued to be dialled back on only reaches the
      // wait for that dial; any other only the sessions it accepted.
      bool admits(SessionUpgradeClaim candidate) =>
          _isExpectedMediaPeerClaim(candidate) &&
          (candidate.reverse
              ? _dialBacks.canAttach(candidate)
              : _remoteInputManager.canAttachClaim(candidate));
      if (claim == null || !admits(claim)) {
        return shelf.Response.unauthorized('Unauthorized');
      }
      return _handleMediaUpgrade(
        request: request,
        route: '/input',
        sessionId: credentials!.sessionId,
        token: credentials.token,
        provisionalClaim: claim,
        canAttach: admits,
        attach: (channel, consumed) => consumed.reverse
            ? _dialBacks.attach(
                channel,
                consumed,
                encoder: () => _dialBackEncoder(
                  consumed,
                  maxPayloadBytes: RemoteInputManager.maxPacketPayloadBytes,
                ),
              )
            : _remoteInputManager.attachChannel(
                channel,
                claim: consumed,
                claimValidator: _isExpectedMediaPeerClaim,
              ),
      );
    }

    if (path == 'window') {
      final credentials = mediaUpgradeCredentials(request.url);
      final claim = credentials == null
          ? null
          : _sessionUpgradeTokens.lookup(
              route: WindowStreamHost.route,
              sessionId: credentials.sessionId,
              token: credentials.token,
              now: DateTime.now(),
            );
      // A host dialling this viewer back carries the token this viewer
      // gave it (WindowStreamMediaDial); it never matches a host stream.
      final inbound =
          claim != null &&
          _isExpectedMediaPeerClaim(claim) &&
          WindowStreamViewer.shared.canAttachInbound(claim);
      if (claim == null ||
          !_isExpectedMediaPeerClaim(claim) ||
          (!inbound && !WindowStreamHost.shared.canAttachClaim(claim))) {
        return shelf.Response.unauthorized('Unauthorized');
      }
      if (inbound) {
        return _handleMediaUpgrade(
          request: request,
          route: WindowStreamHost.route,
          sessionId: credentials!.sessionId,
          token: credentials.token,
          provisionalClaim: claim,
          canAttach: (candidate) =>
              _isExpectedMediaPeerClaim(candidate) &&
              WindowStreamViewer.shared.canAttachInbound(candidate),
          attach: WindowStreamViewer.shared.attachInbound,
        );
      }
      return _handleMediaUpgrade(
        request: request,
        route: WindowStreamHost.route,
        sessionId: credentials!.sessionId,
        token: credentials.token,
        provisionalClaim: claim,
        canAttach: (candidate) =>
            _isExpectedMediaPeerClaim(candidate) &&
            WindowStreamHost.shared.canAttachClaim(candidate),
        attach: (channel, consumed) => WindowStreamHost.shared.attachChannel(
          channel,
          claim: consumed,
          sendKeyScope: _withMediaSendKeyFor,
        ),
      );
    }
    return null;
  }

  /// A media connection to the audio isolate's own port: the checks the main
  /// port makes for /audio before the proof.
  SessionUpgradeClaim? _lookupIsolateAudioClaim({
    required String sessionId,
    required String token,
    required Object remoteAddress,
  }) {
    if (!_acceptingUpgrades || _systemSleeping) {
      return null;
    }
    if (_admission.tryUpgrade(remoteAddress, DateTime.now()) != null) {
      return null;
    }
    final claim = _sessionUpgradeTokens.lookup(
      route: '/audio',
      sessionId: sessionId,
      token: token,
      now: DateTime.now(),
    );
    if (claim == null) {
      return null;
    }
    if (claim.namespace != 'audio-group' ||
        !_isExpectedMediaPeerClaim(claim) ||
        !_isIsolateAudioClaim(claim)) {
      claim.destroy();
      return null;
    }
    return claim;
  }

  /// After the proof: uses the token up, as the main port does.
  SessionUpgradeClaim? _consumeIsolateAudioClaim({
    required String sessionId,
    required String token,
    required SessionUpgradeClaim expected,
  }) {
    if (!_isExpectedMediaPeerClaim(expected) ||
        !_isIsolateAudioClaim(expected)) {
      return null;
    }
    return _sessionUpgradeTokens.consume(
      route: '/audio',
      sessionId: sessionId,
      token: token,
      now: DateTime.now(),
      expected: expected,
    );
  }

  bool _isExpectedMediaPeerClaim(SessionUpgradeClaim claim) {
    final injected = _mediaPeerClaimValidator;
    if (injected != null) {
      return injected(claim);
    }
    final session = _sessionsByPeerId[claim.peerId];
    if (session == null ||
        !session.isAuthenticated ||
        session.connectionGeneration != claim.connectionGeneration) {
      return false;
    }
    return session.withMediaReceiveKey(claim.matchesMediaMacKey);
  }

  bool _isExpectedAudioUpgradeClaim(SessionUpgradeClaim claim) {
    return _audioManager.canAttachClaim(
      claim,
      additionalValidator: _isExpectedAudioGroupUpgradeClaim,
    );
  }

  bool _isExpectedAudioGroupUpgradeClaim(SessionUpgradeClaim claim) {
    final injected = _audioGroupClaimValidator;
    if (injected != null) {
      return injected(claim);
    }
    final group = AudioGroupCoordinator.shared.session;
    if (claim.route != '/audio' ||
        group == null ||
        group.sourcePeerId != claim.peerId) {
      return false;
    }
    return group.sinks.values.any(
      (sink) => sink.sessionId == claim.sessionId && !sink.isTerminal,
    );
  }

  bool _isExpectedAudioGroupPacket(
    SessionUpgradeClaim claim,
    AudioGroupPacketFrame packet,
  ) {
    final injected = _audioGroupPacketValidator;
    if (injected != null) {
      return injected(claim, packet);
    }
    final group = AudioGroupCoordinator.shared.session;
    final sink = group?.sinks.values
        .where((candidate) => candidate.sessionId == claim.sessionId)
        .firstOrNull;
    return claim.route == '/audio' &&
        group != null &&
        sink != null &&
        !sink.isTerminal &&
        group.sourcePeerId == claim.peerId &&
        packet.groupId == group.groupId &&
        packet.streamId == group.streamId &&
        // 组播包原样 fanout 给全部 sink,sessionId 即共享 streamId;
        // claim 与每-sink sessionId 的绑定已在媒体通道 attach 时完成。
        packet.sessionId == group.streamId &&
        packet.sourcePeerId == claim.peerId;
  }

  Future<void> _closeSupersededMediaChannels(PeerSocketSession session) async {
    final peerId = session.remotePeerId;
    await session.withMediaReceiveKeyAsync(
      (key) => Future.wait(<Future<void>>[
        _audioManager.closeSupersededPeerChannels(peerId, mediaMacKey: key),
        _remoteInputManager.closeSupersededPeerChannels(
          peerId,
          mediaMacKey: key,
        ),
        // Hosted window streams keep no claim; none is under the new keys.
        WindowStreamHost.shared.closePeer(peerId),
      ]),
    );
  }

  /// A session on [route] ended: its tokens go, and so do its channels and
  /// what else of it is still open.
  Future<void> _releaseTerminalControl({
    required String namespace,
    required String route,
    required String peerId,
    required String sessionId,
  }) async {
    _sessionUpgradeTokens.revoke(
      route: route,
      namespace: namespace,
      sessionId: sessionId,
      peerId: peerId,
    );
    if (route == '/audio') {
      await _audioManager.closeSessionChannels(
        sessionId,
        peerId: peerId,
        namespace: namespace,
      );
    } else if (route == WindowStreamHost.route) {
      await WindowStreamHost.shared.handleControl(
        WindowStreamControlMessage(
          action: WindowStreamControlAction.stop,
          sessionId: sessionId,
          viewerPeerId: peerId,
          hostPeerId: '',
        ),
        remotePeerId: peerId,
        send: (_) async => false,
      );
    } else if (route == '/input') {
      await _remoteClipboardTransfer.clearSession(sessionId, endsPaste: true);
      await _remoteInputManager.closeSessionChannels(
        sessionId,
        peerId: peerId,
        namespace: namespace,
      );
    }
    _wireControlSessions.forget(namespace: namespace, sessionId: sessionId);
  }

  Future<bool> _sendControlWithLifecycle({
    required Future<bool> send,
    required bool isTerminal,
    required String namespace,
    required String route,
    required String peerId,
    required String sessionId,
  }) {
    if (!isTerminal) {
      return send;
    }
    return send.whenComplete(() {
      return _releaseTerminalControl(
        namespace: namespace,
        route: route,
        peerId: peerId,
        sessionId: sessionId,
      );
    });
  }

  String? _issueSessionUpgradeToken({
    required String route,
    required String namespace,
    required String peerId,
    required String sessionId,
    required String sourcePeerId,
    required String sinkPeerId,
  }) {
    final session = _sessionsByPeerId[peerId];
    if (session == null ||
        !session.isAuthenticated ||
        sourcePeerId != peerId ||
        sinkPeerId != session.localProfile.uid) {
      return null;
    }
    return session.withMediaReceiveKey(
      (mediaReceiveKey) => _sessionUpgradeTokens.issue(
        route: route,
        namespace: namespace,
        sessionId: sessionId,
        peerId: peerId,
        mediaMacKey: mediaReceiveKey,
        connectionGeneration: session.connectionGeneration,
        now: DateTime.now(),
      ),
    );
  }

  /// Runs [action] with this device's media send key for [peerId], or
  /// returns null when that peer has no authenticated session.
  T? _withMediaSendKeyFor<T>(String peerId, T Function(Uint8List key) action) {
    final session = _sessionsByPeerId[peerId];
    if (session == null || !session.isAuthenticated) {
      return null;
    }
    return session.withMediaSendKey(action);
  }

  /// A one-time `/window` token for [hostPeerId] to dial this viewer back
  /// on, with the port to dial; proved with that host's media send key.
  ({String token, int port})? _issueInboundWindowToken(
    String hostPeerId,
    String sessionId,
  ) {
    final port = _server?.port;
    final token = _issueReverseToken(MediaRoute.window, hostPeerId, sessionId);
    return port == null || token == null ? null : (token: token, port: port);
  }

  /// For a viewer connected now: the address its `/chat` came from or went
  /// to, whether this device dialled it, and this device's media keys, so a
  /// host can dial that viewer's `/window` (WindowStreamMediaDial).
  T? _windowDialScope<T>(
    String peerId,
    T Function(
      String host,
      bool dialledSession,
      Uint8List sendKey,
      Uint8List receiveKey,
    )
    action,
  ) {
    final session = _sessionsByPeerId[peerId];
    final host = session == null ? null : _mediaDialHost(session);
    if (session == null || !session.isAuthenticated || host == null) {
      return null;
    }
    final dialled = session.role == PeerSocketRole.client;
    return session.withMediaSendKey(
      (sendKey) => session.withMediaReceiveKey(
        (receiveKey) => action(host, dialled, sendKey, receiveKey),
      ),
    );
  }

  /// The address to dial [session]'s device back at: the one its `/chat`
  /// came from or went to, never one a message names.
  String? _mediaDialHost(PeerSocketSession session) {
    final host = _endpointsBySink[_findSinkForSession(session)]?.host;
    return host == null || host.isEmpty ? null : plainPeerHost(host);
  }

  /// A token for [peerId] to dial this device's [route] for [sessionId],
  /// only while this device waits for that dial (`media_dial_back.dart`).
  String? _issueDialBackToken(
    MediaRoute route,
    String peerId,
    String sessionId,
  ) => _dialBacks.isWaiting(route, peerId, sessionId)
      ? _issueReverseToken(route, peerId, sessionId)
      : null;

  /// For sound: the audio isolate waits for the dial, not this one, so the
  /// group says whether one may come: [sinkPeerId] is a sink of this
  /// device's group, still in [sessionId].
  String? _issueAudioDialBackToken(String sinkPeerId, String sessionId) =>
      _awaitsAudioDialBack(sinkPeerId, sessionId)
      ? _issueReverseToken(MediaRoute.audio, sinkPeerId, sessionId)
      : null;

  bool _awaitsAudioDialBack(String sinkPeerId, String sessionId) {
    final group = AudioGroupCoordinator.shared.session;
    final sink = group?.sinks[sinkPeerId];
    return group != null &&
        group.sourcePeerId == _sessionsByPeerId[sinkPeerId]?.localProfile.uid &&
        sink != null &&
        sink.sessionId == sessionId &&
        !sink.isTerminal;
  }

  /// What the audio isolate's port takes: a token a sink of this device's
  /// group was given, or one this device issued for a sink to dial back on.
  bool _isIsolateAudioClaim(SessionUpgradeClaim claim) => claim.reverse
      ? _awaitsAudioDialBack(claim.peerId, claim.sessionId)
      : _isExpectedAudioUpgradeClaim(claim);

  /// This device's send key of [claim]'s connection, for the audio isolate
  /// to send on a channel dialled back to it; null once that connection is
  /// gone or replaced.
  Uint8List? _dialBackSendKey(SessionUpgradeClaim claim) {
    final session = _sessionsByPeerId[claim.peerId];
    if (!claim.reverse ||
        session == null ||
        !session.isAuthenticated ||
        session.connectionGeneration != claim.connectionGeneration) {
      return null;
    }
    return session.withMediaSendKey(Uint8List.fromList);
  }

  String? _issueReverseToken(
    MediaRoute route,
    String peerId,
    String sessionId,
  ) {
    final session = _sessionsByPeerId[peerId];
    if (_server == null || session == null || !session.isAuthenticated) {
      return null;
    }
    try {
      return session.withMediaReceiveKey(
        (mediaReceiveKey) => _sessionUpgradeTokens.issue(
          route: route.path,
          namespace: route.namespace,
          sessionId: sessionId,
          peerId: peerId,
          mediaMacKey: mediaReceiveKey,
          connectionGeneration: session.connectionGeneration,
          reverse: true,
          now: DateTime.now(),
        ),
      );
    } on StateError {
      return null;
    }
  }

  /// What this device sends on a channel dialled back to it, under its own
  /// send key of the connection the token was issued on; null once that
  /// connection is gone or replaced.
  AuthenticatedMediaPacketEncoder? _dialBackEncoder(
    SessionUpgradeClaim claim, {
    required int maxPayloadBytes,
  }) {
    final session = _sessionsByPeerId[claim.peerId];
    if (session == null ||
        !session.isAuthenticated ||
        session.connectionGeneration != claim.connectionGeneration) {
      return null;
    }
    return session.withMediaSendKey(
      (sendKey) => claim.withMediaPacketContext(
        (_, binding) => AuthenticatedMediaPacketEncoder(
          route: claim.route,
          namespace: claim.namespace,
          sessionId: claim.sessionId,
          mediaMacKey: sendKey,
          channelBinding: binding,
          maxPayloadBytes: maxPayloadBytes,
        ),
      ),
    );
  }

  /// The controlled side of [accept]'s session could not be reached: asks
  /// it to dial this device's `/input` instead.
  Future<MediaDialedBack?> _askInputDialBack(RemoteInputControlMessage accept) {
    final peerId = accept.sinkPeerId;
    return _dialBacks.wait(
      MediaRoute.input,
      peerId: peerId,
      sessionId: accept.sessionId,
      ask: () => sendRemoteInputControlTo(peerId, accept.dialBackRequest()),
      onGiveUp: () => _sessionUpgradeTokens.revoke(
        route: '/input',
        sessionId: accept.sessionId,
        peerId: peerId,
      ),
    );
  }

  /// This device's source could not reach [sinkPeerId]: asks it to dial
  /// [port] for [sessionId] instead.
  Future<bool> _askAudioDialBack(
    String sinkPeerId,
    String sessionId,
    int port,
  ) {
    final group = AudioGroupCoordinator.shared.session;
    final sink = group?.sinks[sinkPeerId];
    if (group == null || sink == null || sink.sessionId != sessionId) {
      return Future<bool>.value(false);
    }
    return sendAudioGroupControlTo(
      sinkPeerId,
      group.dialBackFor(sink, port: port),
    );
  }

  /// The same, for sound sent from this isolate: the sink dials the main
  /// port, where [_dialBacks] waits for it.
  Future<MediaDialedBack?> _awaitAudioDialBackHere(
    String sinkPeerId,
    String sessionId,
  ) {
    final port = _server?.port;
    if (port == null) return Future<MediaDialedBack?>.value();
    return _dialBacks.wait(
      MediaRoute.audio,
      peerId: sinkPeerId,
      sessionId: sessionId,
      ask: () => _askAudioDialBack(sinkPeerId, sessionId, port),
      onGiveUp: () => _sessionUpgradeTokens.revoke(
        route: '/audio',
        sessionId: sessionId,
        peerId: sinkPeerId,
      ),
    );
  }

  /// [session]'s device could not reach this device's [route] for
  /// [sessionId] and sent a token for its own, on [port]: dial it once, if
  /// the claim that token makes is one [admits] (a session this device
  /// accepted, with no channel yet). Not awaited: the dial must not hold up
  /// the messages behind it.
  void _answerDialBack(
    PeerSocketSession session,
    MediaRoute route, {
    required String sessionId,
    required String token,
    required int port,
    required bool Function(SessionUpgradeClaim claim) admits,
    required bool Function(WebSocketChannel channel, SessionUpgradeClaim claim)
    attach,
  }) {
    final host = _mediaDialHost(session);
    if (host == null || port <= 0 || port > 65535) return;
    final SessionUpgradeClaim claim;
    try {
      claim = session.withMediaReceiveKey(
        (receiveKey) => dialBackClaim(
          route,
          sessionId: sessionId,
          token: token,
          peerId: session.remotePeerId,
          connectionGeneration: session.connectionGeneration,
          receiveKey: receiveKey,
        ),
      );
    } on FormatException {
      return;
    }
    if (!_isExpectedMediaPeerClaim(claim) || !admits(claim)) {
      claim.destroy();
      return;
    }
    // One way in per session: the token this side gave goes.
    _sessionUpgradeTokens.revoke(
      route: route.path,
      namespace: route.namespace,
      sessionId: sessionId,
      peerId: session.remotePeerId,
    );
    unawaited(() async {
      try {
        final channel = await session.withMediaSendKeyAsync(
          (sendKey) => dialBack(
            route,
            host: host,
            port: port,
            sessionId: sessionId,
            token: token,
            localPeerId: session.localProfile.uid,
            sendKey: sendKey,
          ),
        );
        if (attach(channel, claim)) return;
      } on Object {
        // The asking side stops waiting and fails as before.
      }
      claim.destroy();
    }());
  }

  void _answerInputDialBack(
    PeerSocketSession session,
    RemoteInputControlMessage request,
  ) => _answerDialBack(
    session,
    MediaRoute.input,
    sessionId: request.sessionId,
    token: request.transportToken,
    port: request.transportPort,
    admits: _remoteInputManager.canAttachClaim,
    attach: (channel, claim) => _remoteInputManager.attachChannel(
      channel,
      claim: claim,
      claimValidator: _isExpectedMediaPeerClaim,
    ),
  );

  void _answerAudioDialBack(
    PeerSocketSession session,
    AudioGroupControlMessage request,
  ) => _answerDialBack(
    session,
    MediaRoute.audio,
    sessionId: request.sessionId,
    token: request.transportToken,
    port: request.mediaPort,
    admits: _isExpectedAudioUpgradeClaim,
    attach: (channel, claim) => _audioManager.attachChannel(
      channel,
      claim: claim,
      additionalValidator: _isExpectedAudioGroupUpgradeClaim,
      groupPacketValidator: _isExpectedAudioGroupPacket,
      claimValidator: _isExpectedMediaPeerClaim,
    ),
  );

  /// [peerId]'s tokens and dial-back waits end with its connection.
  void _forgetPeerMedia(String peerId) {
    _sessionUpgradeTokens.clearPeer(peerId);
    _dialBacks.cancelPeer(peerId);
  }
}

final class _AudioMediaClaimBroker implements AudioMediaClaimBroker {
  _AudioMediaClaimBroker(this._manager);

  final WsSvrManager _manager;

  @override
  SessionUpgradeClaim? lookup({
    required String sessionId,
    required String token,
    required Object remoteAddress,
  }) => _manager._lookupIsolateAudioClaim(
    sessionId: sessionId,
    token: token,
    remoteAddress: remoteAddress,
  );

  @override
  SessionUpgradeClaim? consume({
    required String sessionId,
    required String token,
    required SessionUpgradeClaim expected,
  }) => _manager._consumeIsolateAudioClaim(
    sessionId: sessionId,
    token: token,
    expected: expected,
  );

  @override
  Uint8List? sendKeyFor(SessionUpgradeClaim claim) =>
      _manager._dialBackSendKey(claim);
}
