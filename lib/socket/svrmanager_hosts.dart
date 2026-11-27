part of 'svrmanager.dart';

final class _PeerAuthHost implements PeerAuthHost {
  _PeerAuthHost(this._m);

  final WsSvrManager _m;

  @override
  PeerDirectory get peers => _m._peers;
  @override
  PeerPolicyStore get policy => _m._policy;
  @override
  LocalDatabase get database => _m._database;
  @override
  FileTransferEngine get transferEngine => _m._transferEngine;
  @override
  OutgoingTextRetryRegistry get outgoingTextRetries => _m._outgoingTextRetries;
  @override
  bool get manageSharedCoordinators => _m._manageSharedCoordinators;
  @override
  int get nextConnectionGeneration => _m._nextConnectionGeneration;
  @override
  AuthEnvelopeObserver? get authEnvelopeObserver => _m._authEnvelopeObserver;
  @override
  ConnectionAuthCommitBarrier? get authCommitBarrier => _m._authCommitBarrier;
  @override
  Future<bool> Function() get autoConnectEnabled => _m._autoConnectEnabled;
  @override
  bool? get autoConnectPolicyOverride => _m._dialer.autoConnectPolicyOverride;
  @override
  ISocketEvent? get primaryEvent => _m._primaryEvent;

  @override
  PendingOutgoingConnection? pendingOutgoingForSink(WebSocketSink sink) =>
      _m._dialer.pendingForSink(sink);

  @override
  void bindPendingOutgoingPeer(
    PendingOutgoingConnection attempt,
    String peerId,
  ) => _m._dialer.bindPendingOutgoingPeer(attempt, peerId);

  @override
  bool hasReadyPendingOutgoingForPeer(String peerId) =>
      _m._dialer.hasReadyPendingOutgoingForPeer(peerId);

  @override
  bool hasPendingOutgoingForPeer(String peerId) =>
      _m._dialer.hasPendingOutgoingForPeer(peerId);

  @override
  void cancelLosingOutgoingForPeer(String peerId) =>
      _m._dialer.cancelLosingOutgoingForPeer(peerId);

  @override
  void recordAuthenticatedReconnect(
    PeerSocketSession session,
    WebSocketSink sink,
    DeviceData device,
  ) => _m._dialer.recordAuthenticatedReconnect(session, sink, device);

  @override
  Future<bool> registerPeerConnection({
    required String peerId,
    required WebSocketSink sink,
    required PeerSocketSession session,
    PeerProfile? profile,
  }) => _m._registerPeerConnection(
    peerId: peerId,
    sink: sink,
    session: session,
    profile: profile,
  );

  @override
  Future<void> closeSupersededMediaChannels(PeerSocketSession session) =>
      _m._closeSupersededMediaChannels(session);

  @override
  Future<void> failSocketSession(
    PeerSocketSession session,
    WebSocketSink sink,
    String message, {
    PeerDisconnectCause cause = PeerDisconnectCause.protocolFailure,
  }) => _m._failSocketSession(session, sink, message, cause: cause);

  @override
  MessageData buildAuthMessage({
    required String content,
    required String msg,
    String? senderOverride,
    String? receiverOverride,
  }) => _m._buildMessage(
    MessageEnum.Auth,
    content,
    msg,
    '',
    0,
    false,
    senderOverride: senderOverride,
    receiverOverride: receiverOverride,
  );

  @override
  Future<bool> sendRawAuthMessage(
    MessageData message, {
    required WebSocketSink sink,
  }) => _m._sendMessageData(message, sink: sink, rawAuth: true);

  @override
  void startKeepaliveTimer(String peerId, WebSocketSink sink) =>
      _m._startKeepaliveTimer(peerId, sink);

  @override
  void dispatchConnect() => _m._dispatchToAll((event) => event.onConnect());

  @override
  void dispatchAfterAuth(bool allow, DeviceData? device) =>
      _m._dispatchToAll((event) => event.afterAuth(allow, device));

  @override
  void dispatchPairing(
    ISocketEvent listener,
    PairingRequest request,
    void Function(bool) resolve,
  ) => _m._dispatchGuarded(
    listener,
    (event) => event.onPairing(request, resolve),
  );

  @override
  Future<bool> sendRemoteInputControlTo(
    String peerId,
    RemoteInputControlMessage control,
  ) => _m.sendRemoteInputControlTo(peerId, control);

  @override
  void ignoreFuture(Future<void> future, {required String context}) =>
      _m._ignoreFuture(future, context: context);
}

final class _PeerDialerHost implements PeerDialerHost {
  _PeerDialerHost(this._m);

  final WsSvrManager _m;

  @override
  PeerDirectory get peers => _m._peers;
  @override
  PeerPolicyStore get policy => _m._policy;
  @override
  PeerAuthCoordinator get auth => _m._auth;
  @override
  LocalDatabase get database => _m._database;
  @override
  Uuid get uuid => _m.uuid;
  @override
  Duration get socketCloseTimeout => _m._socketCloseTimeout;
  @override
  Duration get outgoingConnectionTimeout => _outgoingConnectionTimeout;
  @override
  Duration get serverPingInterval => WsSvrManager._serverPingInterval;
  @override
  Duration get manualPreemptWaitTimeout =>
      WsSvrManager._manualPreemptWaitTimeout;
  @override
  bool get manageSharedCoordinators => _m._manageSharedCoordinators;
  @override
  bool get acceptingOutgoingConnections => _m._acceptingOutgoingConnections;
  @override
  Future<bool> Function() get autoConnectEnabled => _m._autoConnectEnabled;
  @override
  Future<void> Function(bool enabled) get setAutoConnectEnabled =>
      _m._setAutoConnectEnabled;
  @override
  PeerReconnectControllerFactory get reconnectControllerFactory =>
      _m._reconnectControllerFactory;

  @override
  Future<PeerSocketSession> createSocketSession({
    required WebSocketSink sink,
    required PeerSocketRole role,
    String intendedPeerId = '',
    String intendedPublicKeyHash = '',
    int protocolVersion = PeerSocketSession.protocolVersion,
  }) => _m._createSocketSession(
    sink: sink,
    role: role,
    intendedPeerId: intendedPeerId,
    intendedPublicKeyHash: intendedPublicKeyHash,
    protocolVersion: protocolVersion,
  );

  @override
  void attachSocketTransport(
    WebSocketChannel webSocket,
    PeerSocketSession session, {
    required bool asServer,
  }) => _m._attachSocketTransport(webSocket, session, asServer: asServer);

  @override
  Future<void> handlePeerSocketDoneQueued(WebSocketSink sink) =>
      _m._handlePeerSocketDoneQueued(sink);

  @override
  Future<void> removePeerConnection(String peerId, PeerDisconnectCause cause) =>
      _m._removePeerConnection(peerId, cause);

  @override
  void setRemoteProfile(PeerProfile? profile, {String? peerId}) =>
      _m._setRemoteProfile(profile, peerId: peerId);

  @override
  void ignoreFuture(Future<void> future, {required String context}) =>
      _m._ignoreFuture(future, context: context);
}

final class _ChannelRouterHost implements ChannelRouterHost {
  _ChannelRouterHost(this._m);

  final WsSvrManager _m;

  @override
  PeerDirectory get peers => _m._peers;
  @override
  PeerPingTracker get pingTracker => _m._pingTracker;
  @override
  FileTransferEngine get transferEngine => _m._transferEngine;
  @override
  RemoteClipboardTransferEngine get remoteClipboardTransfer =>
      _m._remoteClipboardTransfer;
  @override
  WireMessageReplayGuard get wireMessageReplayGuard =>
      _m._wireMessageReplayGuard;
  @override
  WireControlSessionRegistry get wireControlSessions => _m._wireControlSessions;
  @override
  OutgoingTextAcknowledgementTracker get outgoingTextAcknowledgements =>
      _m._outgoingTextAcknowledgements;
  @override
  FileBrowseTrustCache get fileBrowseTrustCache => _m._fileBrowseTrustCache;
  @override
  LocalDatabase get database => _m._database;
  @override
  bool get manageSharedCoordinators => _m._manageSharedCoordinators;
  @override
  int get maxFileDataPayloadBytes => WsSvrManager._maxFileDataPayloadBytes;
  @override
  String get fileBrowseNamespace => WsSvrManager._fileBrowseNamespace;
  @override
  String get localSenderUid => _m.sender;

  @override
  void requireCurrentBusinessSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) => _m._auth.requireCurrentBusinessSession(session, sink, generation);

  @override
  Future<void> handleAuthMessage(
    MessageData message, {
    required WebSocketSink sink,
    required PeerSocketSession session,
  }) => _m._auth.handleAuthMessage(message, sink: sink, session: session);

  @override
  Future<bool> sendMessageData(
    MessageData message, {
    String? peerId,
    WebSocketSink? sink,
  }) => _m._sendMessageData(message, peerId: peerId, sink: sink);

  @override
  Future<bool> sendHeartbeatControl(
    String tag,
    String content,
    String peerId, {
    WebSocketSink? sink,
  }) => _m._sendHeartbeatControl(tag, content, peerId, sink: sink);

  @override
  Future<void> sendHeartbeat({
    bool profileRefreshRequest = false,
    WebSocketSink? sink,
    String? peerId,
  }) => _m._heartBeat(
    profileRefreshRequest: profileRefreshRequest,
    sink: sink,
    peerId: peerId,
  );

  @override
  void setRemoteProfile(PeerProfile? profile, {String? peerId}) =>
      _m._setRemoteProfile(profile, peerId: peerId);

  @override
  void dispatchMessage(MessageData message) =>
      _m._dispatchToAll((event) => event.onMessage(message));

  @override
  void dispatchConnect() => _m._dispatchToAll((event) => event.onConnect());

  @override
  Future<void> handleWorkspaceClipboardOffer({
    required String peerId,
    required String sessionId,
  }) => _m._handleWorkspaceClipboardOffer(peerId: peerId, sessionId: sessionId);

  @override
  Future<void> handleWorkspaceClipboardClear({
    required String peerId,
    required String sessionId,
  }) => _m._handleWorkspaceClipboardClear(peerId: peerId, sessionId: sessionId);

  @override
  Future<void> relayWorkspaceClipboardText(
    MessageData message, {
    required String sourcePeerId,
  }) => _m._relayWorkspaceClipboardText(message, sourcePeerId: sourcePeerId);

  @override
  Future<bool> sendWindowStreamControlTo(
    String peerId,
    WindowStreamControlMessage control,
  ) => _m.sendWindowStreamControlTo(peerId, control);

  @override
  Future<bool> sendFileBrowseControlTo(
    String peerId,
    FileBrowseMessage control,
  ) => _m.sendFileBrowseControlTo(peerId, control);

  @override
  Future<bool> sendAudioGroupControlTo(
    String peerId,
    AudioGroupControlMessage control,
  ) => _m.sendAudioGroupControlTo(peerId, control);

  @override
  Future<bool> sendRemoteInputControlTo(
    String peerId,
    RemoteInputControlMessage control,
  ) => _m.sendRemoteInputControlTo(peerId, control);

  @override
  void answerAudioDialBack(
    PeerSocketSession session,
    AudioGroupControlMessage request,
  ) => _m._answerAudioDialBack(session, request);

  @override
  void answerInputDialBack(
    PeerSocketSession session,
    RemoteInputControlMessage request,
  ) => _m._answerInputDialBack(session, request);

  @override
  Future<void> handleTransferChannelControl(
    PeerSocketSession session,
    TransferChannelControlMessage control,
  ) => _m._transferChannels.handleControl(
    remotePeerId: session.remotePeerId,
    localGeneration: session.connectionGeneration,
    control: control,
  );

  @override
  Future<void> releaseTerminalControl({
    required String namespace,
    required String route,
    required String peerId,
    required String sessionId,
  }) => _m._releaseTerminalControl(
    namespace: namespace,
    route: route,
    peerId: peerId,
    sessionId: sessionId,
  );

  @override
  void remoteInputTrace(String message) => _m._remoteInputTrace(message);

  @override
  String remoteInputControlSummary(RemoteInputControlMessage control) =>
      _m._remoteInputControlSummary(control);

  @override
  String shortSessionId(String sessionId) => _m._shortSessionId(sessionId);
}

final class _TransferChannelHost implements TransferChannelHost {
  _TransferChannelHost(this._m);

  final WsSvrManager _m;

  @override
  bool get enabled => _m._enableTransferChannel;

  @override
  String localPeerIdFor(String peerId) => _m._peers.localPeerIdFor(peerId);

  @override
  bool peerSupportsTransferChannel(String peerId) =>
      _m.remoteProfileFor(peerId)?.capabilities.transferChannelV1 == true;

  @override
  TransferConnectionBinding? currentBinding(String peerId) =>
      _m._peers.currentBinding(peerId);

  @override
  String? dialHostFor(String peerId, int generation) =>
      _m._transferDialHostFor(peerId, generation);

  @override
  T? withSessionKeys<T>(
    String peerId,
    int generation,
    T Function(Uint8List sendKey, Uint8List receiveKey) action,
  ) => _m._withTransferSessionKeys(peerId, generation, action);

  @override
  String? issueTransferToken({
    required String peerId,
    required int generation,
    required String sessionId,
    required bool reverse,
  }) => _m._issueTransferUpgradeToken(
    peerId: peerId,
    generation: generation,
    sessionId: sessionId,
    reverse: reverse,
  );

  @override
  void revokeTransferToken({
    required String peerId,
    required String sessionId,
  }) => _m._sessionUpgradeTokens.revoke(
    route: MediaRoute.transfer.path,
    namespace: MediaRoute.transfer.namespace,
    sessionId: sessionId,
    peerId: peerId,
  );

  @override
  Future<bool> sendControl(
    String peerId,
    TransferChannelControlMessage control,
  ) => _m._sendTransferChannelControlTo(peerId, control);

  @override
  Future<bool> sendFallbackOnChat(
    TransferConnectionBinding binding,
    Object payload,
  ) => _m._peers.sendToAwaitedIfCurrent(binding, payload);

  @override
  Future<void> handleInboundFrame(TransferDataInboundFrame frame) =>
      _m._handleInboundTransferFrame(frame);

  @override
  void onUnexpectedChannelDrop(
    String peerId,
    int generation,
    TransferChannelKind kind,
  ) => _m._onUnexpectedTransferChannelDrop(peerId, generation, kind);
}

final class _TransferClaimBroker implements TransferClaimBroker {
  _TransferClaimBroker(this._m, this._manager);

  final WsSvrManager _m;
  final TransferChannelManager _manager;

  @override
  TransferClaimLookupResult? lookup({
    required String sessionId,
    required String token,
    required Object remoteAddress,
  }) => _m._lookupIsolateTransferClaim(
    manager: _manager,
    sessionId: sessionId,
    token: token,
    remoteAddress: remoteAddress,
  );

  @override
  bool consume({
    required String sessionId,
    required String token,
    required SessionUpgradeClaim expected,
  }) => _m._consumeIsolateTransferClaim(
    manager: _manager,
    sessionId: sessionId,
    token: token,
    expected: expected,
  );
}
