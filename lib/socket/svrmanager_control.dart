part of 'svrmanager.dart';

/// Outbound profile/keepalive heartbeats and subsystem control-channel senders
/// (file browse, window stream, audio group, remote input).
extension WsSvrManagerControl on WsSvrManager {
  Future<PeerProfile> _localPeerProfile() async {
    final injected = _localPeerProfileLoader;
    if (injected != null) {
      return injected();
    }
    final device = await LocalSetting().instance(online: true);
    RemoteInputTopology? topology;
    if (supportsNativeRemoteInput()) {
      try {
        topology = await RemoteInputCoordinator.shared.displayTopology();
      } catch (error) {
        _remoteInputTrace('display topology unavailable: $error');
      }
    }
    final hasTopology = topology?.isNotEmpty == true;
    return PeerProfile(
      device: device,
      trustedPeerIds: const <String>[],
      autoApproveNewDevices: false,
      autoConnectEnabled: true,
      protocolVersion: PeerSocketSession.protocolVersion,
      capabilities: PeerCapabilities(
        fileTransferV3: true,
        remoteInputManualSourceV1: supportsManualRemoteInputSource(),
        remoteInputManualSinkV1: supportsManualRemoteInputSink(),
        remoteInputSourceV1: supportsNativeRemoteInput(),
        remoteInputSinkV1: supportsNativeRemoteInput(),
        remoteInputTopologyV1: hasTopology,
        remoteInputWorkspaceGraphV1: hasTopology,
        windowStreamSourceV1: supportsWindowStreamSource(),
        windowStreamSinkV1: supportsWindowStreamSink(),
        windowStreamOfferV1: supportsWindowStreamSink(),
        remoteFilesV1: true,
        transferChannelV1: _enableTransferChannel,
      ),
      displayTopology: topology,
      formFactor: await localFormFactor(),
      wake: await localWakeTargetsForProfile(),
      appVersion: await localAppVersion(),
    );
  }

  Future<PeerProfile?> requestRemoteProfileRefresh({
    required String peerId,
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    if (peerId.isEmpty || !isConnectedTo(peerId)) {
      return remoteProfileFor(peerId);
    }
    return _peers.profileRefreshTracker.request(
      peerId: peerId,
      timeout: timeout,
      sendRequest: () =>
          _heartBeat(profileRefreshRequest: true, peerId: peerId),
      currentProfile: remoteProfileFor,
    );
  }

  void _setRemoteProfile(PeerProfile? profile, {String? peerId}) {
    final hasPeerId = peerId != null && peerId.isNotEmpty;
    if (hasPeerId) {
      if (profile == null) {
        _peers.removeStoredRemoteProfile(peerId);
        WindowStreamViewer.shared.peerDisconnected(peerId);
      } else {
        _peers.setStoredRemoteProfile(peerId, profile);
        if (_manageSharedCoordinators) {
          AudioGroupCoordinator.shared.peerConnected(peerId);
        }
        rememberPeerTraits(peerId, profile);
        WindowStreamViewer.shared.peerConnected(
          WindowStreamPeer(
            peerId: peerId,
            name: profile.device.label,
            platform: windowStreamPlatformOf(profile.device.platform),
            takesWindows: profile.capabilities.windowStreamOfferV1,
          ),
        );
        if (_manageSharedCoordinators) {
          unawaited(
            profile.capabilities.remoteFilesV1
                ? RemoteMounts.shared.peerConnected(
                    peerId,
                    profile.device.label,
                    identityPublicKey: remoteIdentityPublicKeyFor(peerId),
                  )
                : RemoteMounts.shared.peerRevoked(peerId),
          );
        }
        if (profile.capabilities.windowStreamSourceV1 &&
            supportsWindowStreamSink()) {
          WindowStreamViewer.shared.peerAvailable(
            peerId: peerId,
            name: profile.device.label,
            platform: windowStreamPlatformOf(profile.device.platform),
            host: profile.device.host,
            port: profile.device.port,
          );
        } else {
          WindowStreamViewer.shared.peerGone(peerId);
        }
      }
    } else if (profile == null) {
      _peers.clearStoredRemoteProfiles();
    }

    _completeRemoteProfileRefreshWaiters(peerId: hasPeerId ? peerId : null);
  }

  void _completeRemoteProfileRefreshWaiters({String? peerId}) {
    _peers.completeProfileRefreshWaiters(
      peerId: peerId,
      currentProfile: remoteProfileFor,
    );
  }

  Future<void> _ackMessage(MessageData data) => _channelRouter.ackMessage(data);

  void _startKeepaliveTimer(String peerId, WebSocketSink sink) {
    _pingTracker.startKeepalive(
      token: sink,
      peerId: peerId,
      interval: WsSvrManager._clientHeartbeatInterval,
      sendPing: (payload) =>
          _sendHeartbeatControl(heartbeatPingTag, payload, peerId, sink: sink),
      onSilent: () => _closeSocketSink(sink),
    );
  }

  /// Measures application-layer round-trip time over `/chat` ping/pong
  /// (includes the peer's inbound receive-queue wait). Returns `null` when
  /// disconnected or timed out.
  Future<Duration?> measurePeerRtt(
    String peerId, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    if (peerId.isEmpty || !isConnectedTo(peerId)) return null;
    return _pingTracker.measure(
      peerId: peerId,
      timeout: timeout,
      sendPing: (payload) =>
          _sendHeartbeatControl(heartbeatPingTag, payload, peerId),
    );
  }

  Future<bool> _sendHeartbeatControl(
    String tag,
    String content,
    String peerId, {
    WebSocketSink? sink,
  }) async {
    if (sink != null && !_isCurrentSinkForPeer(sink, peerId)) return false;
    final localUid = _peers.sessionForPeer(peerId)?.localProfile.uid ?? sender;
    final message = _buildMessage(
      MessageEnum.Heartbeat,
      content,
      tag,
      '',
      0,
      false,
      senderOverride: localUid,
      receiverOverride: peerId,
    );
    return _sendMessageData(
      message,
      peerId: sink == null ? peerId : null,
      sink: sink,
    );
  }

  bool _isCurrentSinkForPeer(WebSocketSink sink, String peerId) {
    final session = _peers.sessionForSink(sink);
    if (session == null || session.remotePeerId != peerId) return false;
    try {
      _auth.requireCurrentBusinessSession(
        session,
        sink,
        session.connectionGeneration,
      );
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _heartBeat({
    bool profileRefreshRequest = false,
    WebSocketSink? sink,
    String? peerId,
  }) async {
    final targetPeerId = peerId?.isNotEmpty == true
        ? peerId!
        : _peerIdForSink(sink) ?? '';
    if (targetPeerId.isEmpty) return;
    if (sink != null && !_isCurrentSinkForPeer(sink, targetPeerId)) return;
    final profile = await _localPeerProfile();
    final message = _buildMessage(
      MessageEnum.Heartbeat,
      jsonEncode(profile.toWireProfile().toJson()),
      profileRefreshRequest ? heartbeatProfileRequestTag : heartbeatProfileTag,
      '',
      0,
      false,
      senderOverride: profile.device.uid,
      receiverOverride: targetPeerId,
    );
    await _sendMessageData(
      message,
      peerId: sink == null ? targetPeerId : null,
      sink: sink,
    );
  }

  Future<void> refreshConnectionLiveness([String? peerId]) async {
    final targets = peerId != null
        ? (peerId.isNotEmpty && isConnectedTo(peerId)
              ? <String>[peerId]
              : const <String>[])
        : connectedPeerIds.toList(growable: false);
    for (final targetPeerId in targets) {
      await _pingTracker.dispatchPing(
        peerId: targetPeerId,
        sendPing: (payload) =>
            _sendHeartbeatControl(heartbeatPingTag, payload, targetPeerId),
      );
    }
  }

  Future<void> broadcastLocalProfileUpdate() async {
    for (final peerId in connectedPeerIds) {
      await _heartBeat(peerId: peerId);
    }
  }

  bool _validateOutgoingControlSession({
    required String namespace,
    required String peerId,
    required String sessionId,
    required String sourcePeerId,
    required String sinkPeerId,
    required bool isInitialOffer,
    bool reverseInitialDirection = false,
    String context = '',
  }) {
    final session = _peers.sessionForPeer(peerId);
    if (session == null || !session.isAuthenticated) {
      return false;
    }
    final result = _wireControlSessions.validateAndRemember(
      namespace: namespace,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      authenticatedPeerId: peerId,
      localPeerId: session.localProfile.uid,
      isInitialOffer: isInitialOffer,
      isIncoming: false,
      reverseInitialDirection: reverseInitialDirection,
      context: context,
    );
    return result.isAccepted;
  }

  /// [peerId] is connected and speaks the file-browse protocol.
  bool canBrowseFilesOf(String peerId) => _peers.canBrowseFilesOf(peerId);

  /// Sends a file-browse control message (see [FileBrowseMessage]).
  Future<bool> sendFileBrowseControlTo(
    String peerId,
    FileBrowseMessage control,
  ) {
    if (!canBrowseFilesOf(peerId) ||
        !_validateOutgoingControlSession(
          namespace: WsSvrManager._fileBrowseNamespace,
          peerId: peerId,
          sessionId: control.sessionId,
          sourcePeerId: control.clientPeerId,
          sinkPeerId: control.hostPeerId,
          isInitialOffer: control.isInitial,
        )) {
      return Future<bool>.value(false);
    }
    final message = _buildMessage(
      MessageEnum.FileBrowseControl,
      jsonEncode(control.toJson()),
      '',
      '',
      0,
      false,
      uid: control.sessionId,
      receiverOverride: peerId,
    );
    final sent = _sendMessageData(message, peerId: peerId);
    if (!control.isTerminal) {
      return sent;
    }
    return sent.whenComplete(
      () => _wireControlSessions.forget(
        namespace: WsSvrManager._fileBrowseNamespace,
        sessionId: control.sessionId,
      ),
    );
  }

  Future<void> _closeHttpServer(
    HttpServer server, {
    required bool force,
  }) async {
    final listening = _listeningSockets[server];
    _listeningSockets[server] = null;
    await listening?.close();
    await server.close(force: force);
  }

  /// Sends a `/transfer` negotiation control envelope on `/chat`.
  Future<bool> _sendTransferChannelControlTo(
    String peerId,
    TransferChannelControlMessage control,
  ) {
    final session = _peers.sessionForPeer(peerId);
    if (session == null || !session.isAuthenticated) {
      return Future<bool>.value(false);
    }
    final message = _buildMessage(
      MessageEnum.TransferChannelControl,
      jsonEncode(control.toJson()),
      '',
      '',
      0,
      false,
      senderOverride: session.localProfile.uid,
      receiverOverride: peerId,
      uid: control.sessionId,
    );
    return _sendMessageData(message, peerId: peerId);
  }

  /// Routes outgoing `fileData` frames over the dedicated `bulk` `/transfer`
  /// channel when available, falling back to `/chat` transparently.
  Future<bool> _sendBulkTransferFrame(
    TransferConnectionBinding binding,
    Object payload,
  ) {
    final Uint8List bytes;
    if (payload is AuthenticatedPayloadBuffer) {
      if (payload.isValid?.call() == false) {
        return Future<bool>.value(false);
      }
      bytes = payload.payload;
    } else if (payload is Uint8List) {
      bytes = payload;
    } else if (payload is List<int>) {
      bytes = Uint8List.fromList(payload);
    } else {
      return _peers.sendToAwaitedIfCurrent(binding, payload);
    }
    final paced =
        _transferPacing.general.rate.isFinite ||
        _transferPacing.clipboard.rate.isFinite;
    return _transferChannels.sendFrame(
      binding: binding,
      kind: TransferChannelKind.bulk,
      encodedFrame: bytes,
      fallbackPayload: payload,
      paced: paced,
    );
  }

  @visibleForTesting
  Future<void> debugRegisterPeerConnection(
    String peerId,
    PeerConnection connection,
  ) => _peers.connections.register(connection);

  @visibleForTesting
  bool debugSendMalformedTransportFrame(String peerId) =>
      _peers.debugSendMalformedTransportFrame(peerId);

  @visibleForTesting
  Future<bool> debugDropPeerTransport(String peerId) =>
      _peers.debugDropPeerTransport(peerId);

  @visibleForTesting
  Future<bool> debugRemovePeerForWatchdog(String peerId) {
    final binding = _peers.currentBinding(peerId);
    if (binding == null) {
      return Future<bool>.value(false);
    }
    return _removeUnresponsivePeerIfCurrent(binding);
  }

  @visibleForTesting
  int get debugTransferWorkerPort => _transferChannels.workerPort;

  @visibleForTesting
  int? debugActiveTransferChannelId(String peerId, TransferChannelKind kind) {
    final binding = _peers.currentBinding(peerId);
    if (binding == null) return null;
    return _transferChannels.activeChannelIdFor(
      peerId,
      binding.generation,
      kind,
    );
  }

  @visibleForTesting
  ({
    int bulkSent,
    int browseSent,
    int bulkReceived,
    int browseReceived,
    int staleDropped,
  })
  get debugTransferChannelStats => _transferChannels.stats;

  @visibleForTesting
  void debugDropTransferChannel(String peerId, TransferChannelKind kind) =>
      _transferChannels.debugCloseActiveChannel(peerId, kind);

  @visibleForTesting
  Future<bool> debugSendFileBrowseData(
    String peerId,
    String sessionId,
    int requestId,
    int offset,
    Uint8List data,
  ) => _sendFileBrowseData(peerId, sessionId, requestId, offset, data);

  @visibleForTesting
  Future<bool> debugSendFileBrowseWrite(
    String peerId,
    String transferId,
    int requestId,
    int offset,
    Uint8List data,
  ) => _sendFileBrowseWrite(peerId, transferId, requestId, offset, data);

  /// The bytes a mounted folder on [peerId] asked for, sent over the
  /// dedicated `browse` `/transfer` channel (or `/chat` fallback).
  Future<bool> _sendFileBrowseData(
    String peerId,
    String sessionId,
    int requestId,
    int offset,
    Uint8List data,
  ) {
    final binding = _peers.currentBinding(peerId);
    if (binding == null || !canBrowseFilesOf(peerId)) {
      return Future<bool>.value(false);
    }
    final frame = WhisperFrameV3(
      type: WhisperFrameType.browseData,
      transferId: sessionId,
      offset: offset,
      sequence: requestId,
      payload: data,
    );
    return _transferChannels.sendFrame(
      binding: binding,
      kind: TransferChannelKind.browse,
      encodedFrame: frame.encode(),
    );
  }

  /// Bytes a folder of [peerId]'s mounted here writes into one of its
  /// files ([transferId] is `<session>/<upload>`).
  Future<bool> _sendFileBrowseWrite(
    String peerId,
    String transferId,
    int requestId,
    int offset,
    Uint8List data,
  ) {
    final binding = _peers.currentBinding(peerId);
    if (binding == null || !canBrowseFilesOf(peerId)) {
      return Future<bool>.value(false);
    }
    final frame = WhisperFrameV3(
      type: WhisperFrameType.browseWrite,
      transferId: transferId,
      offset: offset,
      sequence: requestId,
      payload: data,
    );
    return _transferChannels.sendFrame(
      binding: binding,
      kind: TransferChannelKind.browse,
      encodedFrame: frame.encode(),
    );
  }

  Future<bool> _sendCopiedFile(String peerId, String path, String id) {
    TransferPlacements.shared.markQuiet(id);
    return sendFileTo(peerId, path, messageId: id);
  }

  Future<bool> _sendCopiedFolder(
    String peerId,
    String path,
    String id, {
    FsSharePolicy? policy,
  }) async {
    TransferPlacements.shared.markQuiet(id);
    return await sendFolderTo(
          peerId,
          path,
          messageId: id,
          sharePolicy: policy,
        ) ==
        FolderSendOutcome.sent;
  }

  /// A file-manager copy completed: its chat message goes, the file stays.
  Future<void> _forgetCopiedTransfer(String transferId) async {
    final message = await _database.fetchMessageByUuid(transferId);
    if (message != null) {
      await _database.deleteMessage(message.id);
    }
  }

  /// Sends a window-stream control message. The viewer starts every session
  /// (wire "source"); an `accept` from this host carries a one-time token
  /// for `/window`, issued like the audio and input routes.
  Future<bool> sendWindowStreamControlTo(
    String peerId,
    WindowStreamControlMessage control,
  ) {
    if (!_validateOutgoingControlSession(
      namespace: WindowStreamHost.namespace,
      peerId: peerId,
      sessionId: control.sessionId,
      sourcePeerId: control.viewerPeerId,
      sinkPeerId: control.hostPeerId,
      isInitialOffer: control.isInitial,
      reverseInitialDirection: control.isHostInitiated,
    )) {
      return Future<bool>.value(false);
    }
    var outgoing = control;
    if (control.action == WindowStreamControlAction.accept) {
      final token = _issueSessionUpgradeToken(
        route: WindowStreamHost.route,
        namespace: WindowStreamHost.namespace,
        peerId: peerId,
        sessionId: control.sessionId,
        sourcePeerId: control.viewerPeerId,
        sinkPeerId: control.hostPeerId,
      );
      if (token == null) {
        return Future<bool>.value(false);
      }
      outgoing = control.withTransport(token, port: _server?.port);
    }
    final message = _buildMessage(
      MessageEnum.WindowStreamControl,
      jsonEncode(outgoing.toJson()),
      '',
      '',
      0,
      false,
      uid: control.sessionId,
      receiverOverride: peerId,
    );
    return _sendControlWithLifecycle(
      send: _sendMessageData(message, peerId: peerId),
      isTerminal: control.isTerminal,
      namespace: WindowStreamHost.namespace,
      route: WindowStreamHost.route,
      peerId: peerId,
      sessionId: control.sessionId,
    );
  }

  Future<bool> sendAudioGroupControlTo(
    String peerId,
    AudioGroupControlMessage control,
  ) {
    if (!_validateOutgoingControlSession(
      namespace: 'audio-group',
      peerId: peerId,
      sessionId: control.sessionId,
      sourcePeerId: control.sourcePeerId,
      sinkPeerId: control.sinkPeerId,
      isInitialOffer:
          control.action == AudioGroupControlAction.groupOffer ||
          control.action == AudioGroupControlAction.sinkJoinRequest,
      reverseInitialDirection:
          control.action == AudioGroupControlAction.sinkJoinRequest,
      context: '${control.groupId}\u0000${control.streamId}',
    )) {
      return Future<bool>.value(false);
    }
    var outgoing = control.withTransportToken('');
    if (control.action == AudioGroupControlAction.groupAccept) {
      final acceptedGroup = AudioGroupCoordinator.shared.session;
      final acceptedSink = acceptedGroup?.sinks[control.sinkPeerId];
      if (acceptedGroup?.groupId != control.groupId ||
          acceptedGroup?.streamId != control.streamId ||
          acceptedGroup?.sourcePeerId != control.sourcePeerId ||
          acceptedSink?.sessionId != control.sessionId ||
          acceptedSink?.isTerminal != false) {
        return Future<bool>.value(false);
      }
      final token = _issueSessionUpgradeToken(
        route: '/audio',
        namespace: 'audio-group',
        peerId: peerId,
        sessionId: control.sessionId,
        sourcePeerId: control.sourcePeerId,
        sinkPeerId: control.sinkPeerId,
      );
      if (token == null) {
        return Future<bool>.value(false);
      }
      outgoing = control.withTransportToken(token);
    } else if (control.action == AudioGroupControlAction.groupDialBack) {
      final token = _issueAudioDialBackToken(peerId, control.sessionId);
      if (token == null) return Future<bool>.value(false);
      outgoing = control.withTransportToken(token);
    }
    final message = _buildMessage(
      MessageEnum.AudioGroupControl,
      jsonEncode(outgoing.toJson()),
      '',
      '',
      0,
      false,
      uid: control.sessionId,
      receiverOverride: peerId,
    );
    return _sendControlWithLifecycle(
      send: _sendMessageData(message, peerId: peerId),
      isTerminal:
          control.action == AudioGroupControlAction.groupReject ||
          control.action == AudioGroupControlAction.groupStop ||
          control.action == AudioGroupControlAction.error,
      namespace: 'audio-group',
      route: '/audio',
      peerId: peerId,
      sessionId: control.sessionId,
    );
  }

  Future<bool> sendRemoteInputControlTo(
    String peerId,
    RemoteInputControlMessage control,
  ) {
    if (control.mode == RemoteInputMode.manual &&
        control.action == RemoteInputControlAction.offer &&
        (!supportsManualRemoteInputSource() ||
            !supportsManualInputFor(peerId))) {
      return Future<bool>.value(false);
    }
    if (!_validateOutgoingControlSession(
      namespace: 'remote-input',
      peerId: peerId,
      sessionId: control.sessionId,
      sourcePeerId: control.sourcePeerId,
      sinkPeerId: control.sinkPeerId,
      isInitialOffer: control.action == RemoteInputControlAction.offer,
    )) {
      return Future<bool>.value(false);
    }
    var outgoing = control.withTransportToken('');
    if (control.action == RemoteInputControlAction.accept) {
      final acceptedSession = _remoteInputManager.session(control.sessionId);
      if (acceptedSession?.state != RemoteInputSessionState.connected ||
          acceptedSession?.sourcePeerId != control.sourcePeerId ||
          acceptedSession?.sinkPeerId != control.sinkPeerId) {
        return Future<bool>.value(false);
      }
      final token = _issueSessionUpgradeToken(
        route: '/input',
        namespace: 'remote-input',
        peerId: peerId,
        sessionId: control.sessionId,
        sourcePeerId: control.sourcePeerId,
        sinkPeerId: control.sinkPeerId,
      );
      if (token == null) {
        return Future<bool>.value(false);
      }
      outgoing = control.withTransportToken(
        token,
        port: control.mode == RemoteInputMode.manual ? _server?.port : null,
      );
    } else if (control.action == RemoteInputControlAction.dialBack) {
      final token = _issueDialBackToken(
        MediaRoute.input,
        peerId,
        control.sessionId,
      );
      if (token == null) return Future<bool>.value(false);
      outgoing = control.withTransportToken(token, port: _server?.port);
    }
    _remoteInputTrace(
      'remote input send control ${_remoteInputControlSummary(control)} '
      'sender=$sender receiver=$peerId connected=$isConnected '
      'remoteSupports=${supportsRemoteInputFor(peerId)}',
    );
    final message = _buildMessage(
      MessageEnum.RemoteInputControl,
      jsonEncode(outgoing.toJson()),
      '',
      '',
      0,
      false,
      uid: control.sessionId,
      receiverOverride: peerId,
    );
    return _sendControlWithLifecycle(
      send: _sendMessageData(message, peerId: peerId),
      isTerminal:
          control.action == RemoteInputControlAction.reject ||
          control.action == RemoteInputControlAction.stop ||
          control.action == RemoteInputControlAction.error,
      namespace: 'remote-input',
      route: '/input',
      peerId: peerId,
      sessionId: control.sessionId,
    );
  }
}
