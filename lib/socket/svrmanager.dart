import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/backpressure_web_socket.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/audio/audio_group_messages.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_group_media.dart';
import 'package:whisper/helper/clipboard_sync.dart';
import 'package:whisper/helper/folder_transfer_store.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/auth_handshake_lifecycle.dart';
import 'package:whisper/socket/auth_failure_result.dart';
import 'package:whisper/socket/authenticated_frame.dart';
import 'package:whisper/socket/channel_router.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/direct_peer_http_client.dart';
import 'package:whisper/socket/file_browse_trust_cache.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/media_dial_back.dart';
import 'package:whisper/socket/media_upgrade_server.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/outgoing_text_retry.dart';
import 'package:whisper/socket/outbound_frame_class.dart';
import 'package:whisper/socket/pre_auth_byte_cap.dart';
import 'package:whisper/socket/peer_auth_coordinator.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_dialer.dart';
import 'package:whisper/socket/peer_directory.dart';
import 'package:whisper/socket/peer_ping_tracker.dart';
import 'package:whisper/socket/peer_policy_store.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/pending_outgoing_connection.dart';
import 'package:whisper/socket/quick_send_identity_gate.dart';
import 'package:whisper/socket/transfer_ack_watchdog.dart';
import 'package:whisper/socket/transfer_channel_manager.dart';
import 'package:whisper/socket/transfer_channel_protocol.dart';
import 'package:whisper/socket/transfer_data_isolate.dart';
import 'package:whisper/socket/socket_admission.dart';
import 'package:whisper/socket/socket_events.dart';
export 'package:whisper/socket/socket_events.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/mount/remote_mounts.dart';
import 'package:whisper/socket/no_delay_socket.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/fs_copies.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_files/fs_platform.dart';
import 'package:whisper/remote_files/fs_protocol.dart';
import 'package:whisper/remote_files/fs_share_policy.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';
import 'package:whisper/window_stream/window_stream_support.dart';
import 'package:whisper/socket/transfer_pacing.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/socket/wire_message_replay.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_clipboard_paste_watch.dart';
import 'package:whisper/remote_input/remote_clipboard_paths.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/state/peer_traits.dart';

import '../helper/notification.dart';

part 'svrmanager_control.dart';
part 'svrmanager_hosts.dart';
part 'svrmanager_media.dart';
part 'svrmanager_messaging.dart';

const Duration _outgoingConnectionTimeout = Duration(seconds: 8);

final class _WorkspaceClipboardOrigin {
  const _WorkspaceClipboardOrigin({
    required this.revision,
    required this.peerId,
    required this.sessionId,
    required this.offerId,
  });

  final int revision;
  final String peerId;
  final String sessionId;
  final String offerId;
}

class WsSvrManager {
  static const Duration _serverPingInterval = Duration(seconds: 45);
  static const Duration _clientHeartbeatInterval = Duration(seconds: 15);
  static const Duration _manualPreemptWaitTimeout = Duration(seconds: 3);
  static const int _maxPreAuthMessageBytes = 256 * 1024;
  static const int _maxFileDataPayloadBytes = fileTransferV3FramePayloadSize;
  static const int _maxAuthenticatedMessageBytes =
      _maxFileDataPayloadBytes + WhisperFrameV3.headerLength;
  static const int _authenticatedFrameOverhead =
      AuthenticatedFrameCodec.overheadBytes;
  static const String _fileBrowseNamespace = 'remote-files';

  static PeerReconnectController _defaultReconnectControllerFactory({
    required ReconnectAttempt attempt,
    required ReconnectEligibility eligibility,
  }) => PeerReconnectController(attempt: attempt, eligibility: eligibility);
  // 创建一个私有的静态实例变量
  static final WsSvrManager _singleton = WsSvrManager._internal();

  // 私有构造函数，阻止类被直接实例化
  WsSvrManager._internal({
    SocketAdmissionController? admission,
    AudioShareManager? audioManager,
    RemoteInputManager? remoteInputManager,
    SessionUpgradeTokenRegistry? sessionUpgradeTokens,
    bool Function(SessionUpgradeClaim claim)? audioGroupClaimValidator,
    AudioGroupPacketClaimValidator? audioGroupPacketValidator,
    bool Function(SessionUpgradeClaim claim)? mediaPeerClaimValidator,
    LocalDatabase? database,
    Future<bool> Function()? autoConnectEnabled,
    Future<void> Function(bool enabled)? setAutoConnectEnabled,
    PeerReconnectControllerFactory? reconnectControllerFactory,
    DeviceIdentityStore? identityStore,
    LocalPeerProfileLoader? localPeerProfileLoader,
    bool manageSharedCoordinators = true,
    ConnectionAuthCommitBarrier? authCommitBarrier,
    AuthEnvelopeObserver? authEnvelopeObserver,
    Duration socketCloseTimeout = const Duration(seconds: 2),
    Duration mediaProofTimeout = const Duration(seconds: 3),
    int maxProvisionalMediaSockets = 32,
    SecureRandomBytes? mediaProofRandomBytes,
    Future<Directory> Function()? transferDownloadDirectory,
    FolderTransferStore? folderTransferStore,
    TransferAckWatchdog? transferAckWatchdog,
    List<Duration>? transferRetryDelays,
    bool enableTransferChannel = true,
  }) : _admission = admission ?? SocketAdmissionController(),
       _audioManager = audioManager ?? AudioShareManager.shared,
       _remoteInputManager = remoteInputManager ?? RemoteInputManager.shared,
       _sessionUpgradeTokens =
           sessionUpgradeTokens ?? SessionUpgradeTokenRegistry(),
       _audioGroupClaimValidator = audioGroupClaimValidator,
       _audioGroupPacketValidator = audioGroupPacketValidator,
       _mediaPeerClaimValidator = mediaPeerClaimValidator,
       _database = database ?? LocalDatabase(),
       _autoConnectEnabled =
           autoConnectEnabled ?? LocalSetting().autoConnectEnabled,
       _setAutoConnectEnabled =
           setAutoConnectEnabled ?? LocalSetting().setAutoConnectEnabled,
       _reconnectControllerFactory =
           reconnectControllerFactory ?? _defaultReconnectControllerFactory,
       _identityStore = identityStore ?? DeviceIdentityStore(),
       _localPeerProfileLoader = localPeerProfileLoader,
       _manageSharedCoordinators = manageSharedCoordinators,
       _authCommitBarrier = authCommitBarrier,
       _authEnvelopeObserver = authEnvelopeObserver,
       _socketCloseTimeout = socketCloseTimeout,
       _mediaUpgrades = MediaUpgradeServer(
         maxProvisional: maxProvisionalMediaSockets,
         proofTimeout: mediaProofTimeout,
         pingInterval: _serverPingInterval,
         randomBytes: mediaProofRandomBytes,
       ),
       _transferDownloadDirectory = transferDownloadDirectory,
       _folderTransferStore =
           folderTransferStore ?? const FolderTransferStore(),
       _transferAckWatchdog = transferAckWatchdog,
       _transferRetryDelays = transferRetryDelays,
       _enableTransferChannel = enableTransferChannel;

  @visibleForTesting
  WsSvrManager.forTesting({
    SocketAdmissionController? admission,
    AudioShareManager? audioManager,
    RemoteInputManager? remoteInputManager,
    SessionUpgradeTokenRegistry? sessionUpgradeTokens,
    bool Function(SessionUpgradeClaim claim)? audioGroupClaimValidator,
    AudioGroupPacketClaimValidator? audioGroupPacketValidator,
    bool Function(SessionUpgradeClaim claim)? mediaPeerClaimValidator,
    LocalDatabase? database,
    Future<bool> Function()? autoConnectEnabled,
    Future<void> Function(bool enabled)? setAutoConnectEnabled,
    PeerReconnectControllerFactory? reconnectControllerFactory,
    DeviceIdentityStore? identityStore,
    LocalPeerProfileLoader? localPeerProfileLoader,
    bool manageSharedCoordinators = true,
    ConnectionAuthCommitBarrier? authCommitBarrier,
    AuthEnvelopeObserver? authEnvelopeObserver,
    Duration socketCloseTimeout = const Duration(seconds: 2),
    Duration mediaProofTimeout = const Duration(seconds: 3),
    int maxProvisionalMediaSockets = 32,
    SecureRandomBytes? mediaProofRandomBytes,
    Future<Directory> Function()? transferDownloadDirectory,
    FolderTransferStore? folderTransferStore,
    TransferAckWatchdog? transferAckWatchdog,
    List<Duration>? transferRetryDelays,
    bool enableTransferChannel = true,
  }) : this._internal(
         admission: admission, audioManager: audioManager,
         remoteInputManager: remoteInputManager,
         sessionUpgradeTokens: sessionUpgradeTokens,
         audioGroupClaimValidator: audioGroupClaimValidator,
         audioGroupPacketValidator: audioGroupPacketValidator,
         mediaPeerClaimValidator: mediaPeerClaimValidator,
         database: database, autoConnectEnabled: autoConnectEnabled,
         setAutoConnectEnabled: setAutoConnectEnabled,
         reconnectControllerFactory: reconnectControllerFactory,
         identityStore: identityStore,
         localPeerProfileLoader: localPeerProfileLoader,
         manageSharedCoordinators: manageSharedCoordinators,
         authCommitBarrier: authCommitBarrier,
         authEnvelopeObserver: authEnvelopeObserver,
         socketCloseTimeout: socketCloseTimeout,
         mediaProofTimeout: mediaProofTimeout,
         maxProvisionalMediaSockets: maxProvisionalMediaSockets,
         mediaProofRandomBytes: mediaProofRandomBytes,
         transferDownloadDirectory: transferDownloadDirectory,
         folderTransferStore: folderTransferStore,
         transferAckWatchdog: transferAckWatchdog,
         transferRetryDelays: transferRetryDelays,
         enableTransferChannel: enableTransferChannel,
       );

  // 工厂构造函数，返回单例实例
  factory WsSvrManager() {
    return _singleton;
  }

  Uuid uuid = LocalUuid;

  HttpServer? _server;

  NoDelayServerSocket? _acceptedSockets;
  final _listeningSockets = Expando<ServerSocket>('listening socket');
  final bool _enableTransferChannel;
  late final TransferChannelManager _transferChannels = TransferChannelManager(
    _TransferChannelHost(this),
    claimBrokerFactory: (manager) => _TransferClaimBroker(this, manager),
  );

  late final PeerDirectory _peers = PeerDirectory(
    socketCloseTimeout: _socketCloseTimeout,
    maxPreAuthMessageBytes: _maxPreAuthMessageBytes,
    maxAuthenticatedMessageBytes: _maxAuthenticatedMessageBytes,
    authenticatedFrameOverhead: _authenticatedFrameOverhead,
    ignoreFuture: _ignoreFuture,
    logInfo: logger.i,
  );
  late final PeerPolicyStore _policy = PeerPolicyStore(
    fileBrowseTrustCache: _fileBrowseTrustCache,
  );
  late final PeerAuthCoordinator _auth = PeerAuthCoordinator(
    _PeerAuthHost(this),
  );
  late final PeerDialer _dialer = PeerDialer(_PeerDialerHost(this));
  final PeerPingTracker _pingTracker = PeerPingTracker();
  final DeviceIdentityStore _identityStore;
  final AuthEnvelopeObserver? _authEnvelopeObserver;
  int _nextConnectionGeneration = 0;
  final Set<Future<void>> _pendingSocketAttachments = <Future<void>>{};
  final OutgoingTextRetryRegistry _outgoingTextRetries =
      OutgoingTextRetryRegistry();
  final OutgoingTextSendLocks _outgoingTextSendLocks = OutgoingTextSendLocks();
  final OutgoingTextAcknowledgementTracker _outgoingTextAcknowledgements =
      OutgoingTextAcknowledgementTracker();
  final WireMessageReplayGuard _wireMessageReplayGuard =
      WireMessageReplayGuard();
  final WireControlSessionRegistry _wireControlSessions =
      WireControlSessionRegistry();
  final FileBrowseTrustCache _fileBrowseTrustCache = FileBrowseTrustCache();
  final SocketAdmissionController _admission;
  final AudioShareManager _audioManager;
  final RemoteInputManager _remoteInputManager;
  final SessionUpgradeTokenRegistry _sessionUpgradeTokens;
  final MediaDialBackWaits _dialBacks = MediaDialBackWaits();
  final bool Function(SessionUpgradeClaim claim)? _audioGroupClaimValidator;
  final AudioGroupPacketClaimValidator? _audioGroupPacketValidator;
  final bool Function(SessionUpgradeClaim claim)? _mediaPeerClaimValidator;
  final LocalDatabase _database;
  final Future<bool> Function() _autoConnectEnabled;
  final Future<void> Function(bool enabled) _setAutoConnectEnabled;
  final PeerReconnectControllerFactory _reconnectControllerFactory;
  final LocalPeerProfileLoader? _localPeerProfileLoader;
  final bool _manageSharedCoordinators;
  bool _interruptedTransfersReconciled = false;
  final ConnectionAuthCommitBarrier? _authCommitBarrier;
  final Duration _socketCloseTimeout;
  /// `/audio`, `/input` and `/window` upgrades still proving themselves.
  final MediaUpgradeServer _mediaUpgrades;
  final Future<Directory> Function()? _transferDownloadDirectory;
  final FolderTransferStore _folderTransferStore;
  Future<void> _serverLifecycleTail = Future<void>.value();
  final Set<ISocketEvent> _listeners = <ISocketEvent>{};
  ISocketEvent? _primaryEvent;
  bool started = false;
  String sender = "";
  Future<void>? _closeFuture;
  bool _closeServerRequested = false;
  bool _forceServerCloseRequested = false;
  bool _closeOperationQueued = false;
  bool _acceptingUpgrades = false;
  bool _acceptingOutgoingConnections = true;
  bool get _systemSleeping => _dialer.systemSleeping;
  HttpServer? _serverClosing;
  final TransferAckWatchdog? _transferAckWatchdog;
  final List<Duration>? _transferRetryDelays;
  late final FileTransferEngine _transferEngine = FileTransferEngine(
    currentConnectionBinding: _peers.currentBinding,
    outgoingPacerFor: _transferPacing.forTransfer,
    incomingFlowLimitsFor: (transferId) =>
        _remoteClipboardTransfer.carriesTransfer(transferId)
        ? FileTransferV3FlowParameters.sharedLink
        : null,
    authenticatedIdentityHashForConnection: (binding) {
      final session = _peers.sessionForPeer(binding.peerId);
      if (session == null ||
          !session.isAuthenticated ||
          session.connectionGeneration != binding.generation ||
          _peers.currentBinding(binding.peerId) != binding ||
          !_policy.isPeerAuthenticationAllowed(binding.peerId)) {
        return null;
      }
      try {
        return identityPublicKeyHash(session.remoteIdentityPublicKey);
      } on Object {
        return null;
      }
    },
    sendBytesToConnection: _peers.sendToAwaitedIfCurrent,
    enqueueBytesToConnection: _sendBulkTransferFrame,
    pruneInvalidOutbound: (peerId) =>
        _peers.sessionForPeer(peerId)?.dropInvalidOutbound(),
    ackWatchdog: _transferAckWatchdog,
    watchdogRetryDelays: _transferRetryDelays,
    markPeerUnresponsive: _removeUnresponsivePeerIfCurrent,
    emitTransferUpdated: (snapshot) {
      // Copies made in the file manager go to the folder chosen there.
      unawaited(TransferPlacements.shared.onTransferUpdated(snapshot));
      _dispatchToAll((event) => event.onTransferUpdated(snapshot));
    },
    notify: (message) => _dispatchToPrimary((event) => event.onNotice(message)),
    remoteProfileFor: remoteProfileFor,
    isConnectedTo: isConnectedTo,
    connectedPeerIds: () => _peers.connectedPeerIds,
    localPeerIdFor: _peers.localPeerIdFor,
    buildMessage: _buildMessage,
    dispatchOutgoingMessage: _dispatchOutgoingMessage,
    ackMessage: _ackMessage,
    wireMessageReplayGuard: _wireMessageReplayGuard,
    downloadDirectory: _transferDownloadDirectory,
    folderStore: _folderTransferStore,
    database: () => _database,
  );
  late final RemoteClipboardTransferEngine _remoteClipboardTransfer =
      RemoteClipboardTransferEngine(
        sendFrame: (binding, frame) =>
            _peers.sendToAwaitedIfCurrent(binding, frame.encode()),
        currentBinding: _peers.currentBinding,
        sessionValidator: _validateRemoteClipboardSession,
        // Files and screenshots go as quiet transfers, like file-manager
        // copies: no message in the conversation, placed where the paste waits.
        directoryProvider: defaultPrivateClipboardDirectory,
        sendFile: _sendCopiedFile,
        cancelTransfer: cancelTransfer,
        placements: TransferPlacements.shared,
        keepClipboard: keepDesktopClipboard,
      );

  late final TransferPacing _transferPacing = TransferPacing.forApp(
    withCoordinators: _manageSharedCoordinators,
  );

  late final ChannelRouter _channelRouter = ChannelRouter(
    _ChannelRouterHost(this),
  );

  /// Pastes waiting for their files: what the floating island shows.
  late final RemoteClipboardPasteWatch remoteClipboardPasteWatch =
      RemoteClipboardPasteWatch(
        download: _remoteClipboardTransfer.download,
        cancelDownload: _remoteClipboardTransfer.cancelDownload,
        pasteKey: _remoteClipboardTransfer.pasteKey,
        pasted: _remoteClipboardTransfer.restoreAfterPaste,
        place: _remoteClipboardTransfer.placeInto,
      );

  Future<void> _workspaceClipboardSerial = Future<void>.value();
  _WorkspaceClipboardOrigin? _workspaceClipboardOrigin;
  int _workspaceClipboardRevision = 0;

  Set<String> get connectedPeerIds => _peers.connectedPeerIds;

  /// Which connection to [peerId] this is (a new one after a reconnect);
  /// null while not connected.
  int? connectionIdOf(String peerId) => _peers.connectionIdOf(peerId);

  /// [peerId] is connected and accepts windows sent to it ("送出去").
  bool canOfferWindowsTo(String peerId) =>
      supportsWindowStreamSource() &&
      _peers.sessionForPeer(peerId)?.isAuthenticated == true &&
      remoteProfileFor(peerId)?.capabilities.windowStreamOfferV1 == true;

  /// This device's peer id on [peerId]'s authenticated session.
  String localPeerIdFor(String peerId) => _peers.localPeerIdFor(peerId);
  bool get isConnected => _peers.connectedPeerIds.isNotEmpty;

  bool supportsRemoteInputFor(String peerId) =>
      _peers.supportsRemoteInputFor(peerId);

  bool supportsManualInputFor(String peerId) =>
      _peers.supportsManualInputFor(peerId);

  PeerProfile? remoteProfileFor(String peerId) =>
      _peers.remoteProfileFor(peerId);

  /// Every connected device whose profile has come: from protocol 16 all of
  /// them can play a group's sound.
  List<DeviceData> connectedAudioGroupSinkDevices({
    String preferredPeerId = '',
  }) => _peers.connectedAudioGroupSinkDevices(preferredPeerId: preferredPeerId);

  List<DeviceData> connectedRemoteInputDevices({String preferredPeerId = ''}) =>
      _peers.connectedRemoteInputDevices(preferredPeerId: preferredPeerId);

  bool supportsRemoteInputTopologyFor(String peerId) =>
      _peers.supportsRemoteInputTopologyFor(peerId);

  bool supportsRemoteInputWorkspaceGraphFor(String peerId) =>
      _peers.supportsRemoteInputWorkspaceGraphFor(peerId);

  RemoteInputTopology? remoteDisplayTopologyFor(String peerId) =>
      _peers.remoteDisplayTopologyFor(peerId);

  bool remotePeerTrustsPeer(String remotePeerId, String trustedPeerId) {
    return trustedPeerId == sender &&
        _peers.sessionForPeer(remotePeerId)?.isAuthenticated == true;
  }

  bool isConnectedTo(String peerId) => _peers.isConnectedTo(peerId);

  bool isCurrentConnectionGeneration(String peerId, int generation) =>
      _peers.isCurrent(peerId, generation);

  @visibleForTesting
  Future<PeerProfile?> debugWaitForProfileUpdateFor(String peerId) =>
      _peers.profileRefreshTracker.waitForNextUpdate(peerId);

  @visibleForTesting
  Future<void> debugSendProfileHeartbeatTo(String peerId) =>
      _heartBeat(peerId: peerId);

  @visibleForTesting
  int get debugProvisionalMediaSocketCount => _mediaUpgrades.provisionalCount;

  String _shortSessionId(String sessionId) {
    if (sessionId.length <= 8) {
      return sessionId;
    }
    return sessionId.substring(0, 8);
  }

  String _remoteInputControlSummary(RemoteInputControlMessage control) {
    return 'action=${control.action.name} '
        'session=${_shortSessionId(control.sessionId)} '
        'source=${control.sourcePeerId} '
        'sink=${control.sinkPeerId} '
        'edge=${control.layoutEdge?.name ?? '-'} '
        'path=${control.path} '
        'reason=${control.releaseReason} '
        'error=${control.errorMessage}';
  }

  void _remoteInputTrace(String message) {
    logger.i(message);
    if (!kReleaseMode ||
        Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] == '1') {
      debugPrint(message);
    }
  }

  String? _peerIdForSink(WebSocketSink? sink) => _peers.peerIdForSink(sink);

  void setSender(String uid) {
    sender = uid;
  }

  void setEvent(ISocketEvent event) {
    _listeners
      ..clear()
      ..add(event);
    _primaryEvent = event;
  }

  void registerEvent(
    ISocketEvent event, {
    String uid = "",
    bool primary = false,
  }) {
    _listeners.add(event);
    if (_primaryEvent == null || primary) {
      _primaryEvent = event;
    }
    if (uid.isNotEmpty) {
      sender = uid;
    }
  }

  void unregisterEvent([ISocketEvent? event]) {
    if (event == null) {
      return;
    }
    _listeners.remove(event);
    if (identical(_primaryEvent, event)) {
      _primaryEvent = _listeners.isEmpty ? null : _listeners.first;
    }
  }

  void _dispatchToAll(void Function(ISocketEvent event) callback) {
    final listeners = _listeners.toList(growable: false);
    for (final listener in listeners) {
      _dispatchGuarded(listener, callback);
    }
  }

  void _dispatchToPrimary(void Function(ISocketEvent event) callback) {
    final primaryEvent = _primaryEvent;
    if (primaryEvent != null) {
      _dispatchGuarded(primaryEvent, callback);
    }
  }

  // 单个监听器异常只记日志,不得阻断协议事件继续分发给其余监听器。
  void _dispatchGuarded(
    ISocketEvent listener,
    void Function(ISocketEvent event) callback,
  ) {
    try {
      callback(listener);
    } catch (error, stackTrace) {
      logger.i('socket 事件监听器异常: $error\n$stackTrace');
    }
  }

  void debugResetListeners() {
    _listeners.clear();
    _primaryEvent = null;
  }

  void dispatchMessage(MessageData messageData) {
    _dispatchToAll((event) => event.onMessage(messageData));
  }

  void dispatchTransfer(TransferSnapshot snapshot) {
    _dispatchToAll((event) => event.onTransferUpdated(snapshot));
  }

  void _ignoreFuture(Future<void> future, {required String context}) {
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        logger.i('$context failed: $error\n$stackTrace');
      }),
    );
  }

  Future<void> _closeSocketSink(WebSocketSink sink) => _peers.closeSink(sink);

  Future<bool> _registerPeerConnection({
    required String peerId,
    required WebSocketSink sink,
    required PeerSocketSession session,
    PeerProfile? profile,
  }) => _peers.registerConnection(
    peerId: peerId,
    sink: sink,
    session: session,
    onSupersededPreRegister: _handlePeerSupersededPreRegister,
    onRegistered: (_) {
      _setRemoteProfile(profile, peerId: peerId);
    },
  );

  /// Cleans up per-generation state on a superseded connection without taking
  /// the peer offline. Media channels close via [_closeSupersededMediaChannels]
  /// and active outgoing transfers re-offer in [_announceAuthenticatedSession].
  Future<void> _handlePeerSupersededPreRegister(String peerId) async {
    _pingTracker.clearPeer(peerId);
    _completeRemoteProfileRefreshWaiters(peerId: peerId);
    _outgoingTextAcknowledgements.disconnectPeer(peerId);
    _forgetPeerMedia(peerId);
    _transferChannels.closePeer(peerId);
    FileBrowseHost.shared.closePeer(peerId);
    RemoteFilesClient.peerGone(peerId, reason: 'offline');
    await _transferEngine.preparePeerSuperseded(peerId);
  }

  Future<void> _handlePeerSocketDoneQueued(WebSocketSink sink) =>
      _peers.runSocketCleanupQueued(sink, () => _handlePeerSocketDone(sink));

  Future<void> _handlePeerSocketDone(WebSocketSink sink) async {
    final link = _peers.removeLink(sink);
    final disconnectCause =
        link?.takeTerminalDisconnectCause() ?? PeerDisconnectCause.network;
    final session = link?.session;
    final wasAuthenticated = session?.isAuthenticated == true;
    if (link != null) {
      link.authCommitWatermark = null;
      link.supersededOnAuth = false;
      _peers.closeDeferredSupersededSinkOnLink(link);
    }
    if (session != null &&
        !_auth.hasAuthenticationTailForPeer(session.remotePeerId)) {
      _policy.forgetSession(session);
    }
    session?.close();
    await session?.drainOutbound();
    session?.releaseAdmission();
    _auth.clearSinkAuthState(sink, failureMessage: 'connection_closed');
    _pingTracker.stopKeepalive(sink);
    final peerId = link?.registeredPeerId;
    link?.registeredPeerId = null;
    if (peerId == null) {
      return;
    }
    // Wait for any already-verified replacement session for this peer to
    // finish committing before firing offline disconnect cleanup.
    final pendingAuthTail = wasAuthenticated
        ? _auth.authenticationTailForPeer(peerId)
        : null;
    if (pendingAuthTail != null) {
      await pendingAuthTail.catchError((Object _) {});
    }
    if (!await _peers.removeConnectionIfCurrentForDone(
      peerId: peerId,
      closingSession: session,
      cause: disconnectCause,
      afterRemove: (binding, closingSession, cause) => _afterPeerRemoved(
        binding,
        closingSession: closingSession,
        cause: cause,
      ),
    )) {
      return;
    }
  }

  Future<PeerSocketSession> _createSocketSession({
    required WebSocketSink sink,
    required PeerSocketRole role,
    String intendedPeerId = '',
    String intendedPublicKeyHash = '',
    int protocolVersion = PeerSocketSession.protocolVersion,
  }) async {
    late PeerSocketSession session;
    session = await PeerSocketSession.create(
      role: role,
      connectionGeneration: ++_nextConnectionGeneration,
      localIdentity: await _identityStore.loadOrCreate(),
      localProfile: (await _localPeerProfile()).toWireProfile(),
      intendedPeerId: intendedPeerId,
      intendedPublicKeyHash: intendedPublicKeyHash,
      negotiatedProtocolVersion: protocolVersion,
      onTimeout: () {
        if (!identical(_peers.sessionForSink(sink), session)) {
          return;
        }
        _auth.completeSocketAuth(sink, false, 'pairing_expired');
        _ignoreFuture(
          _closeSocketSink(sink),
          context: 'close expired pairing socket',
        );
      },
    );
    _policy.recordSessionStarted(session);
    _peers.attachSession(sink, session);
    return session;
  }

  void _attachSocketTransport(
    WebSocketChannel webSocket,
    PeerSocketSession session, {
    AdmissionLease? admissionLease,
    required bool asServer,
  }) {
    final sink = webSocket.sink;
    late final StreamSubscription<dynamic> subscription;
    subscription = webSocket.stream.listen(
      (message) {
        final handling = _handleIncomingMessage(
          message,
          sink: sink,
          asServer: asServer,
        );
        _ignoreFuture(
          handling.then<void>((_) {}),
          context: 'process websocket message',
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        final session = _peers.sessionForSink(sink);
        final pending = _dialer.pendingForSink(sink);
        final peerId =
            _peers.peerIdForSink(sink) ??
            session?.remotePeerId ??
            pending?.verifiedPeerId ??
            pending?.request.expectedPeerId ??
            '';
        final failingPeerId = peerId.isEmpty ? null : peerId;
        AuthSocketLifecycle.closeBeforeQueuedCleanup(session, () {
          logger.i('${asServer ? '连接服务' : '客户端服务'}异常: ${error.runtimeType}');
          _dispatchToPrimary(
            (event) => event.onError(error.toString(), peerId: failingPeerId),
          );
          _auth.completeSocketAuth(sink, false, 'socket_error');
          _ignoreFuture(
            _handlePeerSocketDoneQueued(sink),
            context: 'cleanup failed websocket',
          );
        });
      },
      onDone: () {
        AuthSocketLifecycle.closeBeforeQueuedCleanup(
          _peers.sessionForSink(sink),
          () => _ignoreFuture(
            _handlePeerSocketDoneQueued(sink),
            context: 'cleanup closed websocket',
          ),
        );
      },
    );
    session.attachTransport(
      subscription: subscription,
      addStream: sink.addStream,
      admissionLease: admissionLease,
      onOverflow: () {
        session.close();
        _ignoreFuture(
          _closeSocketSink(sink),
          context: 'close failed outbound websocket',
        );
        if (!identical(_peers.sessionForSink(sink), session)) {
          return;
        }
        _auth.completeSocketAuth(sink, false, 'queue_overflow');
        _ignoreFuture(
          _handlePeerSocketDoneQueued(sink),
          context: 'cleanup failed outbound websocket',
        );
      },
    );
  }

  Future<void> _attachIncomingSocket(
    WebSocketChannel webSocket,
    AdmissionLease admissionLease,
    String remoteHost,
  ) async {
    final sink = webSocket.sink;
    _peers.setEndpoint(sink, (host: plainPeerHost(remoteHost), port: 0));
    try {
      final session = await _createSocketSession(
        sink: sink,
        role: PeerSocketRole.server,
      );
      admissionLease.evictableWhile(() => serverAwaitsProof(session));
      _attachSocketTransport(
        webSocket,
        session,
        admissionLease: admissionLease,
        asServer: true,
      );
    } catch (_) {
      _peers.removeLink(sink);
      admissionLease.close();
      _auth.completeSocketAuth(sink, false, 'session_setup_failed');
      await _closeSocketSink(sink);
    }
  }

  void _trackIncomingSocketAttachment(
    WebSocketChannel webSocket,
    AdmissionLease admissionLease,
    Completer<void> pendingUpgrade,
    String remoteHost,
  ) {
    final attachment = _attachIncomingSocket(
      webSocket,
      admissionLease,
      remoteHost,
    ).whenComplete(() => _completePendingSocketAttachment(pendingUpgrade));
    _ignoreFuture(attachment, context: 'attach incoming websocket');
  }

  void _completePendingSocketAttachment(Completer<void> pendingUpgrade) {
    _pendingSocketAttachments.remove(pendingUpgrade.future);
    if (!pendingUpgrade.isCompleted) {
      pendingUpgrade.complete();
    }
  }

  Future<void> _failSocketSession(
    PeerSocketSession session,
    WebSocketSink sink,
    String message, {
    PeerDisconnectCause cause = PeerDisconnectCause.protocolFailure,
  }) async {
    _peers.setTerminalDisconnectCause(sink, cause);
    session.close();
    _auth.clearSinkAuthState(sink, failureMessage: message);
    try {
      await _closeSocketSink(sink);
    } catch (error, stackTrace) {
      logger.i('关闭失败的 websocket 失败: $error\n$stackTrace');
    }
  }

  Future<ServerStartResult> startServer(
    int port, [
    void Function(bool ok, Object? message)? callback,
  ]) {
    final operation = _enqueueServerLifecycle(() async {
      await _performCloseGracefully(closeServer: true, forceServerClose: false);
      return _startServer(port);
    });
    if (callback != null) {
      final reporting = operation.then<void>(
        (result) {
          callback(result.isSuccess, result.error);
        },
        onError: (Object error, StackTrace stackTrace) =>
            callback(false, error),
      );
      _ignoreFuture(reporting, context: 'report server start result');
    }
    return operation;
  }

  Future<void> reconcileInterruptedTransfersOnStartup() async {
    if (_interruptedTransfersReconciled) {
      return;
    }
    await _transferEngine.reconcileInterruptedTransfersOnStartup();
    await _remoteClipboardTransfer.cleanupStaleDirectories();
    _interruptedTransfersReconciled = true;
  }

  Future<T> _enqueueServerLifecycle<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    final previous = _serverLifecycleTail;
    _serverLifecycleTail = () async {
      try {
        await previous;
      } catch (_) {
        // Lifecycle failures are returned to their caller, not the queue tail.
      }
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }();
    return result.future;
  }

  Future<ServerStartResult> _startServer(int port) async {
    _audioManager.onGroupPacket = (packet) {
      unawaited(AudioGroupCoordinator.shared.handlePacket(packet));
    };
    _audioManager.claimBroker = _AudioMediaClaimBroker(this);
    if (_manageSharedCoordinators) {
      WindowStreamViewer.shared
        ..sender = sendWindowStreamControlTo
        ..localPeerId = localPeerIdFor
        ..issueInboundToken = _issueInboundWindowToken;
      WindowStreamHost.shared
        ..sender = sendWindowStreamControlTo
        ..dialScope = _windowDialScope
        ..localPeerId = localPeerIdFor
        ..start();
      FileBrowseHost.shared
        ..sender = sendFileBrowseControlTo
        ..sendFile = _sendCopiedFile
        ..sendFolder = _sendCopiedFolder
        ..sendData = _sendFileBrowseData;
      RemoteFilesClient.sender = sendFileBrowseControlTo;
      RemoteFilesClient.localPeerId = localPeerIdFor;
      RemoteFilesClient.sendFile = _sendCopiedFile;
      RemoteFilesClient.sendFolder = _sendCopiedFolder;
      RemoteFilesClient.sendWrite = _sendFileBrowseWrite;
      RemoteInputWebSocketPacketTransport.dialBack = _askInputDialBack;
      AudioGroupDialBack.ask = _askAudioDialBack;
      AudioGroupDialBack.here = _awaitAudioDialBackHere;
      RemoteMounts.shared.peerIdentityKey = remoteIdentityPublicKeyFor;
      TransferPlacements.shared
        ..relocateRecord = _database.relocateCompletedIncomingTransfer
        ..forgetRecord = _forgetCopiedTransfer
        ..resume = retryTransfer
        ..mediaScan = FsPlatform.mediaScan;
      FileCopies.shared
        ..retry = retryTransfer
        ..cancel = cancelTransfer;
    }

    FutureOr<shelf.Response> handler(shelf.Request request) async {
      final path = request.url.path;
      if (path != 'chat' &&
          path != 'audio' &&
          path != 'input' &&
          path != 'window') {
        return shelf.Response.notFound('Not Found');
      }
      if (request.method != 'GET' || !_isValidWebSocketUpgrade(request)) {
        return shelf.Response.badRequest(body: 'Bad Request');
      }
      final origin = request.headers['origin'];
      if (origin?.trim().isNotEmpty == true) {
        return shelf.Response.forbidden('Forbidden');
      }
      if (!_acceptingUpgrades || _systemSleeping) {
        return shelf.Response(
          HttpStatus.serviceUnavailable,
          body: 'Service Unavailable',
        );
      }
      final connectionInfo =
          request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
      final remoteAddress =
          connectionInfo?.remoteAddress ?? request.requestedUri.host;
      final remoteHost =
          connectionInfo?.remoteAddress.address ?? request.requestedUri.host;
      final rateRejection = _admission.tryUpgrade(
        remoteAddress,
        DateTime.now(),
      );
      if (rateRejection != null) {
        return shelf.Response(429, body: 'Too Many Requests');
      }
      final media = _routeMediaUpgrade(request, path);
      if (media != null) return media;

      final admission = _admission.tryOpenChat(remoteAddress);
      final lease = admission.lease;
      if (lease == null) {
        return shelf.Response(429, body: 'Too Many Requests');
      }
      // Files travel on this connection.
      final accepted = connectionInfo == null
          ? null
          : _acceptedSockets?.claim(connectionInfo);
      if (accepted != null) {
        tuneChatSocket(accepted);
        lease.bind(accepted);
      }
      final pendingUpgrade = Completer<void>();
      _pendingSocketAttachments.add(pendingUpgrade.future);
      late final shelf.Response response;
      try {
        response = upgradeChatWebSocket(
          request,
          pingInterval: _serverPingInterval,
          onConnection: (webSocket) {
            _trackIncomingSocketAttachment(
              webSocket,
              lease,
              pendingUpgrade,
              remoteHost,
            );
          },
        );
      } on shelf.HijackException {
        rethrow;
      } catch (_) {
        _completePendingSocketAttachment(pendingUpgrade);
        lease.close();
        rethrow;
      }
      if (response.statusCode != HttpStatus.switchingProtocols) {
        _completePendingSocketAttachment(pendingUpgrade);
        lease.close();
      }
      return response;
    }

    try {
      // Small packets (input, control, audio) go out at once instead of
      // waiting for the previous one's acknowledgement (Nagle).
      final listening = await ServerSocket.bind('0.0.0.0', port, shared: true);
      final accepting = _acceptedSockets = NoDelayServerSocket(listening);
      final server = HttpServer.listenOn(accepting);
      // listenOn leaves the listening socket to its owner: it closes with
      // the server (see _closeHttpServer).
      _listeningSockets[server] = listening;
      shelf_io.serveRequests(server, handler);
      _server = server;
      started = true;
      _dialer.markServerStarted();
      _acceptingUpgrades = !_closeOperationQueued;
      _acceptingOutgoingConnections = !_closeOperationQueued;
      if (_enableTransferChannel) {
        await _transferChannels.startWorker(mainPort: port > 0 ? server.port : 0);
      }
      final host = '${server.address.host}:${server.port}';
      logger.i('Serving at ws://$host');
      return ServerStartResult.success(server.port);
    } catch (error, stackTrace) {
      logger.i("服务启动失败: $error\n$stackTrace");
      started = false;
      _acceptingUpgrades = false;
      _acceptingOutgoingConnections = !_closeOperationQueued;
      return ServerStartResult.failure(error);
    }
  }

  bool _isValidWebSocketUpgrade(shelf.Request request) =>
      isValidWebSocketUpgradeRequest(request);

  void updateReconnectEndpoint(
    String peerId,
    String host,
    int port, {
    bool accelerate = true,
  }) => _dialer.updateReconnectEndpoint(
    peerId,
    host,
    port,
    accelerate: accelerate,
  );

  void scheduleReconnect(String peerId, String host, int port) =>
      _dialer.scheduleReconnect(peerId, host, port);

  @visibleForTesting
  void scheduleReconnectTarget(ReconnectTarget target) =>
      _dialer.scheduleReconnectTarget(target);

  ReconnectTarget? reconnectTargetFor(String peerId) =>
      _dialer.reconnectTargetFor(peerId);

  Set<ReconnectSuppressionReason> reconnectSuppressionsFor(String peerId) =>
      _dialer.reconnectSuppressionsFor(peerId);

  Future<void> setAutoConnectPolicy(bool enabled) =>
      _dialer.setAutoConnectPolicy(enabled);

  Future<bool> setPeerTrust(String peerId, bool trusted) async {
    if (peerId.isEmpty) {
      return false;
    }
    if (!trusted) {
      _policy.addSuppression(peerId, PeerAuthSuppressionReason.trustRevoked);
      _policy.invalidatePeerPolicy(peerId, PeerPolicyDisposition.trustRevoked);
      _auth.cancelPendingAuthSessionsForPeer(peerId);
      _dialer.onPeerTrustRevoked(peerId);
      _outgoingTextRetries.clearPeer(peerId);
      final invalidation = _transferEngine.invalidateOutgoingTransfersForPeer(
        peerId,
        reason: 'trust_revoked',
        revokeDeviceTrust: true,
      );
      final pendingCancellation = _dialer.cancelPendingAttemptsForPeer(
        peerId,
        ConnectionAttemptReason.trustRevoked,
      );
      final removal = _removePeerConnection(
        peerId,
        PeerDisconnectCause.trustRevoked,
      );
      await invalidation;
      await pendingCancellation;
      await _auth.waitForPeerAuthentication(peerId);
      await removal;
      await _revokeRemoteFilesForPeer(peerId);
      return true;
    }
    final stored = await _database.fetchDevice(peerId);
    if (stored == null || stored.identityPublicKey.isEmpty) {
      _dialer.onPeerIdentityUnpinned(peerId);
      return false;
    }
    final updated = await _database.authDeviceIfPinned(
      peerId,
      stored.identityPublicKey,
    );
    if (updated) {
      _fileBrowseTrustCache.invalidate(peerId);
      _policy.removeSuppression(
        peerId,
        PeerAuthSuppressionReason.trustRevoked,
      );
      _dialer.onPeerTrustRestored(peerId);
    }
    return updated;
  }

  Future<void> deletePeer(String peerId) async {
    if (peerId.isEmpty) {
      return;
    }
    _policy.replaceSuppressionForDelete(peerId);
    _policy.invalidatePeerPolicy(peerId, PeerPolicyDisposition.deviceDeleted);
    _auth.cancelPendingAuthSessionsForPeer(peerId);
    _dialer.onPeerTrustRevoked(peerId);
    _outgoingTextRetries.clearPeer(peerId);
    final invalidation = _transferEngine.invalidateOutgoingTransfersForPeer(
      peerId,
      reason: 'device_deleted',
      revokeDeviceTrust: true,
    );
    final pendingCancellation = _dialer.cancelPendingAttemptsForPeer(
      peerId,
      ConnectionAttemptReason.deviceDeleted,
    );
    final removal = _removePeerConnection(
      peerId,
      PeerDisconnectCause.deviceDeleted,
    );
    await invalidation;
    await pendingCancellation;
    await _auth.waitForPeerAuthentication(peerId);
    await removal;
    await _revokeRemoteFilesForPeer(peerId);
    // With this device's own id, 本机: everything it ever sent also has that
    // id as its sender, and only the notes are to go.
    await _database.clearDevices(<String>[peerId], localPeerId: sender);
    forgetPeerTraits(peerId);
    _policy.suppressDeletedPeerDiscovery(peerId);
    // 删除抑制只保护删除事务本身。数据库清理完成后，新拨入应作为
    // 新设备重新配对；解除时推进策略版本，同时淘汰删除期间抢入的会话。
    _policy.removeSuppression(peerId, PeerAuthSuppressionReason.deviceDeleted);
  }

  bool shouldSuppressDiscoveredPeer(String peerId) =>
      _policy.shouldSuppressDiscoveredPeer(peerId);

  void releaseDeletedPeerDiscoverySuppression(String peerId) =>
      _policy.releaseDeletedPeerDiscoverySuppression(peerId);

  Future<ConnectionAttemptResult> connectToServer(
    ConnectionAttemptRequest request, {
    Future<void>? whenCancelled,
  }) => _dialer.connectToServer(request, whenCancelled: whenCancelled);

  bool hasPendingConnectionAttempt(String requestId) =>
      _dialer.hasPendingConnectionAttempt(requestId);

  bool hasPendingConnectionAttemptForPeer(String peerId) =>
      _dialer.hasPendingConnectionAttemptForPeer(peerId);

  @visibleForTesting
  bool debugBindPendingConnectionPeer(String requestId, String peerId) =>
      _dialer.debugBindPendingConnectionPeer(requestId, peerId);

  Future<void> cancelConnectionAttempt(String requestId) =>
      _dialer.cancelConnectionAttempt(requestId);

  @visibleForTesting
  ConnectionAttemptResult debugClassifyConnectionException(
    ConnectionAttemptRequest request,
    Object error,
  ) => connectionExceptionResult(request, error);

  Future<void> closeGracefully({
    bool closeServer = false,
    bool forceServerClose = false,
  }) {
    _acceptingUpgrades = false;
    _acceptingOutgoingConnections = false;
    _policy.bumpGlobalPolicyEpoch();
    _dialer.closeReconnectControllersForShutdown();
    _dialer.cancelPendingOutgoingConnections();
    _closeServerRequested =
        _closeServerRequested || closeServer || forceServerClose;
    _forceServerCloseRequested = _forceServerCloseRequested || forceServerClose;
    final existing = _closeFuture;
    if (existing != null) {
      final closingServer = _serverClosing;
      if (forceServerClose && closingServer != null) {
        _ignoreFuture(
          _closeHttpServer(closingServer, force: true),
          context: 'upgrade graceful server close',
        );
      }
      return existing;
    }
    _closeOperationQueued = true;
    final operation = _enqueueServerLifecycle(() async {
      try {
        while (true) {
          final requestedServerClose = _closeServerRequested;
          final requestedForceClose = _forceServerCloseRequested;
          await _performCloseGracefully(
            closeServer: requestedServerClose,
            forceServerClose: requestedForceClose,
          );
          final needsServerClose =
              _closeServerRequested && !requestedServerClose && _server != null;
          final needsForceClose =
              _forceServerCloseRequested &&
              !requestedForceClose &&
              (_server != null || _serverClosing != null);
          if (!needsServerClose && !needsForceClose) {
            return;
          }
        }
      } finally {
        _closeOperationQueued = false;
      }
    });
    late final Future<void> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_closeFuture, tracked)) {
        _closeFuture = null;
        _closeServerRequested = false;
        _forceServerCloseRequested = false;
      }
    });
    _closeFuture = tracked;
    return tracked;
  }

  Future<void> _performCloseGracefully({
    required bool closeServer,
    required bool forceServerClose,
  }) async {
    _acceptingUpgrades = false;
    _acceptingOutgoingConnections = false;
    _dialer.cancelPendingOutgoingConnections();
    HttpServer? closingServer;
    Future<void>? serverCloseFuture;
    if (closeServer) {
      started = false;
      closingServer = _server;
      _server = null;
      _serverClosing = closingServer;
      serverCloseFuture =
          (closingServer == null
                  ? null
                  : _closeHttpServer(closingServer, force: forceServerClose))
              ?.whenComplete(() {
                if (identical(_serverClosing, closingServer)) {
                  _serverClosing = null;
                }
              });
    }
    final hadActiveConnection = AuthSocketLifecycle.hasConnectionWork(
      hasClientTimer: _pingTracker.hasActiveKeepalives,
      hasPendingSessions:
          _peers.hasAnySessions ||
          _pendingSocketAttachments.isNotEmpty ||
          _mediaUpgrades.hasPending ||
          _dialer.hasPendingOutgoingConnections ||
          _audioManager.hasActiveChannels ||
          _remoteInputManager.hasActiveChannels,
      hasPendingResults: _auth.hasPendingResults,
      hasPeerConnections: _peers.connectedPeerIds.isNotEmpty,
    );
    if (!hadActiveConnection && !closeServer) {
      if (_server != null && !_closeServerRequested) {
        _acceptingUpgrades = true;
      }
      _acceptingOutgoingConnections = true;
      return;
    }

    _pingTracker.clearAll();
    _auth.clearGatesForClose();
    while (_pendingSocketAttachments.isNotEmpty || _mediaUpgrades.hasPending) {
      await Future.wait(_pendingSocketAttachments.toList(growable: false));
      await _mediaUpgrades.drain();
    }
    final sessionLinks = _peers.linksSnapshot
        .where((link) => link.session != null)
        .toList(growable: false);
    final authenticatedLinks = sessionLinks
        .where((link) => link.isAuthenticated)
        .toList(growable: false);
    final hadAuthenticatedConnection =
        authenticatedLinks.isNotEmpty ||
        _peers.connectedPeerIds.isNotEmpty;
    final pendingLinks = sessionLinks
        .where((link) => !link.isAuthenticated)
        .toList(growable: false);
    final pendingSinks = <WebSocketSink>{
      ...pendingLinks.map((link) => link.sink),
      ..._auth.pendingResultSinks,
    };
    _auth.closePendingAuthSessions(pendingLinks.map((link) => link.session!));
    await Future.wait(
      pendingSinks.map((sink) async {
        try {
          await Future.wait(<Future<void>>[
            _closeSocketSink(sink),
            if (_peers.sessionForSink(sink) case final session?)
              session.stopReceivingAndDrain(),
          ]);
        } catch (error, stackTrace) {
          logger.i('关闭待认证 websocket 失败: $error\n$stackTrace');
        }
        await _handlePeerSocketDoneQueued(sink);
      }),
    );
    final activeCleanups = _peers.activeCleanupsSnapshot;
    if (activeCleanups.isNotEmpty) {
      await Future.wait(activeCleanups);
    }
    await _dialer.drainPendingOutgoingConnections();
    final authenticatedSessions = authenticatedLinks
        .map((link) => link.session!)
        .toSet()
        .toList(growable: false);
    for (final session in authenticatedSessions) {
      await session.stopReceivingAndDrain();
    }
    await _transferEngine.closeAll(
      persistRecoverable: hadAuthenticatedConnection,
    );
    if (hadAuthenticatedConnection && _manageSharedCoordinators) {
      await AudioGroupCoordinator.shared.stopLocal();
      await RemoteInputWorkspaceCoordinator.shared.stopControllerWorkspace(
        sendControlTo: sendRemoteInputControlTo,
      );
      await RemoteInputCoordinator.shared.stopLocal();
    }
    final disconnectedPeerIds = <String>{
      ..._peers.connectedPeerIds,
      for (final session in authenticatedSessions)
        if (session.remotePeerId.isNotEmpty) session.remotePeerId,
    };
    await _audioManager.closeChannels();
    await _remoteInputManager.closeChannels();
    await WindowStreamHost.shared.closeAll();
    if (closeServer) {
      await _transferChannels.stopWorker();
    } else {
      for (final peerId in disconnectedPeerIds) {
        _transferChannels.closePeer(peerId);
      }
    }
    for (final peerId in disconnectedPeerIds) {
      await _remoteClipboardTransfer.clearPeer(peerId);
      WindowStreamViewer.shared.peerDisconnected(peerId);
      FileBrowseHost.shared.closePeer(peerId);
      RemoteFilesClient.peerGone(peerId, reason: 'closed');
    }
    _fileBrowseTrustCache.clear();
    for (final session in authenticatedSessions) {
      await session.drainOutbound();
    }
    await _peers.connections.disconnectAll();
    for (final link in authenticatedLinks) {
      await _handlePeerSocketDoneQueued(link.sink);
    }
    for (final session in authenticatedSessions) {
      session.releaseAdmission();
    }
    _peers.clearAllAfterClose();
    _policy.clearSessionRevisions();
    _wireControlSessions.clearAll();
    _sessionUpgradeTokens.clearAll();
    _outgoingTextAcknowledgements.clear();
    if (closeServer) {
      await serverCloseFuture;
    } else if (!_closeServerRequested) {
      if (_server != null) {
        _acceptingUpgrades = true;
      }
      _acceptingOutgoingConnections = true;
    }
    _completeRemoteProfileRefreshWaiters();
    logger.i("服务已关闭");
    _dispatchToAll((event) => event.onClose());
  }

  Future<void> disconnectPeer(String peerId) async {
    if (peerId.isEmpty) {
      return;
    }
    _policy.addSuppression(peerId, PeerAuthSuppressionReason.manualDisconnect);
    _policy.invalidatePeerPolicy(peerId, PeerPolicyDisposition.manualDisconnect);
    _auth.cancelPendingAuthSessionsForPeer(peerId);
    _dialer.onPeerManualDisconnect(peerId);
    await _dialer.cancelPendingAttemptsForPeer(
      peerId,
      ConnectionAttemptReason.manualDisconnect,
    );
    await _auth.waitForPeerAuthentication(peerId);
    await _removePeerConnection(peerId, PeerDisconnectCause.manual);
  }

  /// A sleeping host keeps its sockets open without answering them. A peer
  /// that is driving this device's keyboard and mouse then never gets its
  /// pointer back, so every peer is let go while there is still time to tell
  /// them.
  Future<void> prepareForSystemSleep() => _dialer.prepareForSystemSleep();

  /// Lets peers back in and redials the ones [prepareForSystemSleep] dropped.
  void resumeFromSystemSleep() => _dialer.resumeFromSystemSleep();

  Future<void> _removePeerConnection(
    String peerId,
    PeerDisconnectCause cause,
  ) => _peers.removePeerConnection(
    peerId,
    cause,
    afterRemove: (removed, closingSession, cause) => _afterPeerRemoved(
      removed,
      closingSession: closingSession,
      cause: cause,
    ),
  );

  Future<bool> _removeUnresponsivePeerIfCurrent(
    TransferConnectionBinding binding,
  ) => _peers.removeUnresponsivePeerIfCurrent(
    binding,
    afterRemove: (removed, closingSession, cause) => _afterPeerRemoved(
      removed,
      closingSession: closingSession,
      cause: cause,
    ),
  );

  /// Explicit ordered teardown steps when a peer's current connection ends.
  /// Keep this sequence explicit so tokens, acks, and media channels close
  /// before transfer recovery and shared coordinators run.
  late final List<PeerDisconnectCleanupStep> _disconnectCleanupSteps =
      <PeerDisconnectCleanupStep>[
        (peerId, _) => _pingTracker.clearPeer(peerId),
        (peerId, _) {
          _outgoingTextAcknowledgements.disconnectPeer(peerId);
          _forgetPeerMedia(peerId);
          _transferChannels.closePeer(peerId);
        },
        (peerId, _) => _wireControlSessions.clearPeer(
          peerId,
          preservedSessions: _manageSharedCoordinators
              ? _preservedControlSessionsForPeer(peerId)
              : const <String, Set<String>>{},
        ),
        (peerId, cause) async {
          await Future.wait(<Future<void>>[
            _audioManager.closePeerChannels(peerId),
            _remoteInputManager.closePeerChannels(peerId),
            _remoteClipboardTransfer.clearPeer(peerId),
            WindowStreamHost.shared.closePeer(peerId),
          ]);
          WindowStreamViewer.shared.peerDisconnected(peerId);
          _fileBrowseTrustCache.invalidate(peerId);
          final transientDisconnect =
              cause == PeerDisconnectCause.network ||
              cause == PeerDisconnectCause.watchdog ||
              cause == PeerDisconnectCause.systemSleep;
          if (transientDisconnect) {
            FileBrowseHost.shared.closePeer(peerId);
            RemoteFilesClient.peerGone(peerId, reason: 'offline');
          } else {
            await _revokeRemoteFilesForPeer(peerId);
          }
        },
        (peerId, cause) => _transferEngine.handlePeerDisconnected(
          peerId,
          handoverInProgress:
              cause == PeerDisconnectCause.network &&
              _dialer.hasReadyPendingOutgoingForPeer(peerId),
        ),
        (peerId, _) async {
          if (!_manageSharedCoordinators) return;
          AudioGroupCoordinator.shared.peerDisconnected(peerId);
          await RemoteInputWorkspaceCoordinator.shared.handlePeerDisconnected(
            peerId,
          );
        },
        (peerId, _) async {
          if (!_manageSharedCoordinators) return;
          if (RemoteInputCoordinator.shared.state.isForPeer(peerId)) {
            await RemoteInputCoordinator.shared.stopLocal();
          }
        },
      ];

  Future<void> _afterPeerRemoved(
    TransferConnectionBinding binding, {
    PeerSocketSession? closingSession,
    required PeerDisconnectCause cause,
  }) async {
    final peerId = binding.peerId;
    final stillOwns = await _peers.releaseActivePeerAndRunCleanup(
      binding,
      closingSession: closingSession,
      cause: cause,
      cleanupSteps: _disconnectCleanupSteps,
    );
    if (!stillOwns) {
      return;
    }
    _completeRemoteProfileRefreshWaiters(peerId: peerId);
    if (_peers.removedBindingOwnsPeerState(binding)) {
      // 会话生命周期终点:不论断因都结算稳定性复位,
      // 稳定连接挣得的退避复位不因手动断开等断因而丢失。
      _dialer.onPeerSessionClosed(peerId);
      _dispatchToAll((event) => event.onClose());
    }
    if (_peers.removedBindingOwnsPeerState(binding) &&
        (cause == PeerDisconnectCause.network ||
            cause == PeerDisconnectCause.watchdog)) {
      _dialer.scheduleReconnectAfterNetworkDrop(peerId);
    }
  }

  Map<String, Set<String>> _preservedControlSessionsForPeer(String peerId) {
    final preserved = <String, Set<String>>{};
    final group = AudioGroupCoordinator.shared.session;
    final groupSessionIds = <String>{};
    if (group != null) {
      if (group.sourcePeerId == peerId) {
        groupSessionIds.addAll(
          group.sinks.values
              .where((sink) => sink.sessionId.isNotEmpty)
              .map((sink) => sink.sessionId),
        );
      } else {
        final sink = group.sinks[peerId];
        if (sink != null && sink.sessionId.isNotEmpty) {
          groupSessionIds.add(sink.sessionId);
        }
      }
    }
    final rejoinSessionId = AudioGroupCoordinator.shared.rejoinSessionId;
    if (AudioGroupCoordinator.shared.rejoinSourcePeerId == peerId &&
        rejoinSessionId.isNotEmpty) {
      groupSessionIds.add(rejoinSessionId);
    }
    if (groupSessionIds.isNotEmpty) {
      preserved['audio-group'] = groupSessionIds;
    }
    return preserved;
  }

  String? remoteIdentityPublicKeyFor(String peerId) =>
      _peers.remoteIdentityPublicKeyFor(peerId);

  Future<void> _revokeRemoteFilesForPeer(String peerId) async {
    FileBrowseHost.shared.closePeer(peerId);
    RemoteFilesClient.peerGone(peerId, reason: 'revoked');
    if (_manageSharedCoordinators) await RemoteMounts.shared.peerRevoked(peerId);
  }

  Future<void> close({bool closeServer = false}) =>
      closeGracefully(closeServer: closeServer);

  Future<bool> _sendBytesOnSink(
    WebSocketSink sink,
    Object message, {
    bool rawAuth = false,
  }) => _peers.sendBytesOnSink(sink, message, rawAuth: rawAuth);

  Future<bool> _sendMessageData(
    MessageData message, {
    String? peerId,
    WebSocketSink? sink,
    bool rawAuth = false,
  }) async {
    final payload = encodeMessageFrame(
      Uint8List.fromList(utf8.encode(encodeWireMessage(message))),
    );
    if (sink != null) {
      return _sendBytesOnSink(sink, payload, rawAuth: rawAuth);
    }
    if (peerId == null || peerId.isEmpty) {
      return false;
    }
    return _peers.sendToAwaited(peerId, payload);
  }

  void _dispatchOutgoingMessage(MessageData message) {
    _dispatchToAll((event) => event.onMessage(message));
  }

  /// [asServer] 是本条 socket 的角色(服务端接入=true/本机拨出=false),
  /// 随消息逐层透传;设备可同时对不同 peer 兼具两种角色,不存在全局角色。
  Future<void> _handleIncomingMessage(
    dynamic message, {
    required WebSocketSink sink,
    required bool asServer,
  }) async {
    final session = _peers.sessionForSink(sink);
    if (session == null ||
        (asServer && session.role != PeerSocketRole.server) ||
        (!asServer && session.role != PeerSocketRole.client)) {
      await _closeSocketSink(sink);
      return;
    }
    final byteLength = _incomingByteLength(message);
    final maxBytes = session.isAuthenticated
        ? _maxAuthenticatedMessageBytes + _authenticatedFrameOverhead
        : _maxPreAuthMessageBytes;
    if (byteLength < 0 || byteLength > maxBytes) {
      await _failSocketSession(session, sink, 'message_too_large');
      return;
    }
    final accepted = await session.enqueueIncoming(byteLength, () async {
      try {
        var bytes = _incomingBytes(message);
        if (session.isAuthenticated) {
          bytes = await session.decodeIncoming(bytes);
          if (bytes.length > _maxAuthenticatedMessageBytes) {
            throw const AuthHandshakeException('message_too_large');
          }
          _auth.requireCurrentBusinessSession(
            session,
            sink,
            session.connectionGeneration,
          );
        }
        await _channelRouter.handlePayload(
          bytes,
          sink: sink,
          asServer: asServer,
          session: session,
        );
      } catch (error) {
        logger.i(
          '处理 websocket 消息失败: ${error.runtimeType}'
          '${error is WireInputRejected ? ' ${error.reason}' : ''}',
        );
        final failedSession = _peers.sessionForSink(sink);
        if (failedSession != null) {
          final message = switch (error) {
            AuthHandshakeException() => error.code,
            WireInputRejected() => error.reason,
            FormatException() => WireInputReason.malformedFrame,
            _ => 'authentication_failed',
          };
          final cause = switch (error) {
            AuthHandshakeException() ||
            WireInputRejected() ||
            FormatException() => PeerDisconnectCause.protocolFailure,
            _ => PeerDisconnectCause.localFailure,
          };
          await _failSocketSession(failedSession, sink, message, cause: cause);
        } else {
          await _closeSocketSink(sink);
        }
      }
    });
    if (!accepted && identical(_peers.sessionForSink(sink), session)) {
      await _failSocketSession(session, sink, 'queue_overflow');
    }
  }

  int _incomingByteLength(dynamic message) {
    if (message is String) {
      return utf8.encode(message).length;
    }
    if (message is List<int>) {
      return message.length;
    }
    return -1;
  }

  Uint8List _incomingBytes(dynamic message) {
    if (message is Uint8List) {
      return message;
    }
    if (message is List<int>) {
      return Uint8List.fromList(message);
    }
    if (message is String) {
      return Uint8List.fromList(utf8.encode(message));
    }
    throw FormatException('unsupported websocket message: $message');
  }

  MessageData _buildMessage(
    MessageEnum type,
    String content,
    msg,
    fileName,
    int size,
    bool clipboard, {
    String md5 = "",
    path = "",
    uid,
    fileTimestamp = 0,
    String? senderOverride,
    String? receiverOverride,
  }) {
    final resolvedReceiver = receiverOverride ?? '';
    final resolvedSender =
        senderOverride ??
        _peers.sessionForPeer(resolvedReceiver)?.localProfile.uid ??
        sender;
    return MessageData(
      id: 0,
      sender: resolvedSender,
      receiver: resolvedReceiver,
      name: fileName,
      clipboard: clipboard,
      size: size,
      type: type,
      content: content,
      message: msg,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      acked: false,
      uuid: uid ?? uuid.v4(),
      path: path,
      md5: md5,
      fileTimestamp: fileTimestamp,
    );
  }

  Future<bool> sendFileTo(String peerId, String path, {String? messageId}) =>
      _transferEngine.sendFileTo(peerId, path, messageId: messageId);

  Future<FolderSendOutcome> sendFolderTo(
    String peerId,
    String path, {
    String? messageId,
    FsSharePolicy? sharePolicy,
  }) => _transferEngine.sendFolderTo(
    peerId,
    path,
    messageId: messageId,
    sharePolicy: sharePolicy,
  );

  Future<bool> sendQuickFileToDurably(
    String peerId,
    String path, {
    required String source,
    required String intentId,
    required String expectedPublicKeyHash,
  }) async {
    try {
      return await _transferEngine.sendFileTo(
        peerId,
        path,
        messageId: stableQuickSendMessageId(
          source: source,
          intentId: jsonEncode(<String>[intentId, expectedPublicKeyHash]),
          peerId: peerId,
        ),
        expectedPublicKeyHash: expectedPublicKeyHash,
      );
    } on ArgumentError {
      return false;
    }
  }

  Future<bool> sendPickedFileTo(
    String peerId,
    PickedTransferFile item, {
    String? messageId,
  }) => _transferEngine.sendPickedFileTo(peerId, item, messageId: messageId);

  Future<bool> sendQuickPickedFileToDurably(
    String peerId,
    PickedTransferFile item, {
    required String source,
    required String intentId,
    required String expectedPublicKeyHash,
  }) async {
    try {
      return await _transferEngine.sendPickedFileTo(
        peerId,
        item,
        messageId: stableQuickSendMessageId(
          source: source,
          intentId: jsonEncode(<String>[intentId, expectedPublicKeyHash]),
          peerId: peerId,
        ),
        expectedPublicKeyHash: expectedPublicKeyHash,
      );
    } on ArgumentError {
      return false;
    }
  }

  Future<void> retryTransfer(String transferId) =>
      _transferEngine.retryTransfer(transferId);

  Future<void> cancelTransfer(String transferId) =>
      _transferEngine.cancelTransfer(transferId);
}
