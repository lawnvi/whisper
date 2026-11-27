import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/backpressure_web_socket.dart';
import 'package:whisper/debug/automation_hooks.dart' show DebugPairingRequests;
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/audio/audio_group_messages.dart';
import 'package:whisper/audio/audio_fanout_transport.dart';
import 'package:whisper/audio/audio_group_media.dart';
import 'package:whisper/clipboard/clipboard_sync_coordinator.dart';
import 'package:whisper/helper/clipboard_sync.dart';
import 'package:whisper/helper/connection_request_notifications.dart';
import 'package:whisper/helper/folder_transfer_store.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/auth_request_gate.dart';
import 'package:whisper/socket/auth_handshake_lifecycle.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/auth_failure_result.dart';
import 'package:whisper/socket/authenticated_frame.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/dial_tiebreaker.dart';
import 'package:whisper/socket/direct_peer_http_client.dart';
import 'package:whisper/socket/file_browse_trust_cache.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/media_dial_back.dart';
import 'package:whisper/socket/media_upgrade_server.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/outgoing_text_retry.dart';
import 'package:whisper/socket/pairing_attempt_limiter.dart';
import 'package:whisper/socket/outbound_frame_class.dart';
import 'package:whisper/socket/pre_auth_byte_cap.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_directory.dart';
import 'package:whisper/socket/peer_ping_tracker.dart';
import 'package:whisper/socket/peer_profile_refresh.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/pending_outgoing_connection.dart';
import 'package:whisper/socket/quick_send_identity_gate.dart';
import 'package:whisper/socket/transfer_ack_watchdog.dart';
import 'package:whisper/socket/socket_admission.dart';
import 'package:whisper/socket/socket_events.dart';
export 'package:whisper/socket/socket_events.dart';
import 'package:whisper/socket/staggered_dialer.dart';
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
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/state/peer_traits.dart';

import '../helper/notification.dart';

part 'svrmanager_media.dart';

final class _SocketAuthResult {
  const _SocketAuthResult(this.allow, this.message);

  final bool allow;
  final String message;
}

typedef _IdentityPinPlan = ({PairingReason? reason, String expectedPublicKey});

enum _PeerPolicyDisposition { manualDisconnect, trustRevoked, deviceDeleted }

enum _PeerAuthSuppressionReason {
  manualDisconnect,
  trustRevoked,
  deviceDeleted,
}

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
  static final Set<String> _audioGroupControlActions = AudioGroupControlAction
      .values
      .map((action) => action.name)
      .toSet();
  static final Set<String> _remoteInputControlActions = RemoteInputControlAction
      .values
      .map((action) => action.name)
      .toSet();
  static final Set<String> _windowStreamControlActions =
      WindowStreamControlAction.values.map((action) => action.name).toSet();
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
       _transferRetryDelays = transferRetryDelays;

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
       );

  // 工厂构造函数，返回单例实例
  factory WsSvrManager() {
    return _singleton;
  }

  Uuid uuid = LocalUuid;

  HttpServer? _server;

  /// What [_server] listens on, for routes that tune their connection.
  NoDelayServerSocket? _acceptedSockets;
  final _listeningSockets = Expando<ServerSocket>('listening socket');

  Future<void> _closeHttpServer(
    HttpServer server, {
    required bool force,
  }) async {
    final listening = _listeningSockets[server];
    _listeningSockets[server] = null;
    await listening?.close();
    await server.close(force: force);
  }

  late final PeerDirectory _peers = PeerDirectory(
    socketCloseTimeout: _socketCloseTimeout,
    maxPreAuthMessageBytes: _maxPreAuthMessageBytes,
    maxAuthenticatedMessageBytes: _maxAuthenticatedMessageBytes,
    authenticatedFrameOverhead: _authenticatedFrameOverhead,
    ignoreFuture: _ignoreFuture,
    logInfo: logger.i,
  );
  final PeerPingTracker _pingTracker = PeerPingTracker();
  final Set<String> _deletedPeerDiscoverySuppressions = <String>{};
  final Map<WebSocketSink, Completer<_SocketAuthResult>> _authResultsBySink =
      <WebSocketSink, Completer<_SocketAuthResult>>{};
  final DeviceIdentityStore _identityStore;
  final AuthEnvelopeObserver? _authEnvelopeObserver;
  int _nextConnectionGeneration = 0;
  final AuthRequestGate _authRequestGate = AuthRequestGate();
  final PairingAttemptLimiter _pairingAttempts = PairingAttemptLimiter();
  final Map<WebSocketSink, String> _outgoingAuthKeysBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, String> _incomingAuthPeerIdsBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, _IdentityPinPlan> _identityPinPlansBySink =
      <WebSocketSink, _IdentityPinPlan>{};
  final Set<Future<void>> _pendingSocketAttachments = <Future<void>>{};
  final Set<PendingOutgoingConnection> _pendingOutgoingConnections =
      <PendingOutgoingConnection>{};
  final Map<String, PendingOutgoingConnection> _pendingOutgoingByRequestId =
      <String, PendingOutgoingConnection>{};
  final Map<String, Set<PendingOutgoingConnection>> _pendingOutgoingByPeerId =
      <String, Set<PendingOutgoingConnection>>{};
  final Map<WebSocketSink, PendingOutgoingConnection> _pendingOutgoingBySink =
      <WebSocketSink, PendingOutgoingConnection>{};
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
  final Map<String, PeerReconnectController> _reconnectControllers =
      <String, PeerReconnectController>{};
  final Map<String, int> _peerPolicyEpochs = <String, int>{};
  final Map<String, int> _peerInvalidationRevisions = <String, int>{};
  final Map<String, _PeerPolicyDisposition> _peerPolicyDispositions =
      <String, _PeerPolicyDisposition>{};
  final Map<String, Set<_PeerAuthSuppressionReason>> _peerAuthSuppressions =
      <String, Set<_PeerAuthSuppressionReason>>{};
  final Map<PeerSocketSession, int> _sessionStartedPolicyRevisions =
      <PeerSocketSession, int>{};
  final Map<String, Future<void>> _peerAuthenticationTails =
      <String, Future<void>>{};
  int _globalPolicyEpoch = 0;
  int _policyRevision = 0;
  bool _reconnectManagerClosed = false;
  bool? _autoConnectPolicyOverride;
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
  // Set from the system's sleep notice until it is awake again. Nothing may
  // connect in between, or the peer ends up talking to a host that has
  // stopped answering.
  bool _systemSleeping = false;
  final Set<String> _systemSleepReconnectPeerIds = <String>{};
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
          !_isPeerAuthenticationAllowed(binding.peerId)) {
        return null;
      }
      try {
        return identityPublicKeyHash(session.remoteIdentityPublicKey);
      } on Object {
        return null;
      }
    },
    sendBytesToConnection: _peers.sendToAwaitedIfCurrent,
    enqueueBytesToConnection: _peers.sendToAwaitedIfCurrent,
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

  String _authRequestKey({
    String? peerId,
    required String host,
    required int port,
  }) {
    final normalizedPeerId = peerId?.trim() ?? '';
    if (normalizedPeerId.isNotEmpty) {
      return 'peer:$normalizedPeerId';
    }
    return 'endpoint:${host.trim()}:$port';
  }

  void _releaseOutgoingAuthForSink(WebSocketSink? sink) {
    if (sink == null) {
      return;
    }
    final requestKey = _outgoingAuthKeysBySink.remove(sink);
    if (requestKey != null) {
      _authRequestGate.releaseOutgoing(requestKey);
    }
  }

  void _releaseIncomingAuthForSink(WebSocketSink? sink) {
    if (sink == null) {
      return;
    }
    final peerId = _incomingAuthPeerIdsBySink.remove(sink);
    if (peerId != null && peerId.isNotEmpty) {
      _authRequestGate.releaseIncoming(peerId);
      _ignoreFuture(
        ConnectionRequestNotifier().dismissForPeer(peerId, graceMillis: 3000),
        context: 'dismiss pairing notification',
      );
    }
  }

  void _ignoreFuture(Future<void> future, {required String context}) {
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        logger.i('$context failed: $error\n$stackTrace');
      }),
    );
  }

  Future<void> _closeSocketSink(WebSocketSink sink) => _peers.closeSink(sink);

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
        !_peerAuthenticationTails.containsKey(session.remotePeerId)) {
      _sessionStartedPolicyRevisions.remove(session);
    }
    session?.close();
    await session?.drainOutbound();
    session?.releaseAdmission();
    _identityPinPlansBySink.remove(sink);
    _completeSocketAuth(sink, false, 'connection_closed');
    _releaseOutgoingAuthForSink(sink);
    _releaseIncomingAuthForSink(sink);
    _pingTracker.stopKeepalive(sink);
    final peerId = link?.registeredPeerId;
    link?.registeredPeerId = null;
    if (peerId == null) {
      return;
    }
    // Wait for any already-verified replacement session for this peer to
    // finish committing before firing offline disconnect cleanup.
    final pendingAuthTail = wasAuthenticated
        ? _peerAuthenticationTails[peerId]
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
        _completeSocketAuth(sink, false, 'pairing_expired');
        _ignoreFuture(
          _closeSocketSink(sink),
          context: 'close expired pairing socket',
        );
      },
    );
    _sessionStartedPolicyRevisions[session] = _policyRevision;
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
        final peerId =
            _peers.peerIdForSink(sink) ??
            session?.remotePeerId ??
            _pendingOutgoingBySink[sink]?.verifiedPeerId ??
            _pendingOutgoingBySink[sink]?.request.expectedPeerId ??
            '';
        final failingPeerId = peerId.isEmpty ? null : peerId;
        AuthSocketLifecycle.closeBeforeQueuedCleanup(session, () {
          logger.i('${asServer ? '连接服务' : '客户端服务'}异常: ${error.runtimeType}');
          _dispatchToPrimary(
            (event) => event.onError(error.toString(), peerId: failingPeerId),
          );
          _completeSocketAuth(sink, false, 'socket_error');
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
        _completeSocketAuth(sink, false, 'queue_overflow');
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
      _completeSocketAuth(sink, false, 'session_setup_failed');
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

  void _completeSocketAuth(WebSocketSink sink, bool allow, String message) {
    final completer = _authResultsBySink.remove(sink);
    if (completer != null && !completer.isCompleted) {
      completer.complete(_SocketAuthResult(allow, message));
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
    _identityPinPlansBySink.remove(sink);
    _completeSocketAuth(sink, false, message);
    _releaseOutgoingAuthForSink(sink);
    _releaseIncomingAuthForSink(sink);
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
      _reconnectManagerClosed = false;
      _acceptingUpgrades = !_closeOperationQueued;
      _acceptingOutgoingConnections = !_closeOperationQueued;
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

  PeerReconnectController _reconnectControllerFor(String peerId) {
    return _reconnectControllers.putIfAbsent(
      peerId,
      () => _reconnectControllerFactory(
        attempt: _runReconnectAttempt,
        eligibility: _reconnectEligibility,
      ),
    );
  }

  void updateReconnectEndpoint(
    String peerId,
    String host,
    int port, {
    bool accelerate = true,
  }) {
    if (peerId.isEmpty || _reconnectManagerClosed) {
      return;
    }
    final target = ReconnectTarget(peerId: peerId, host: host, port: port);
    _reconnectControllerFor(
      peerId,
    ).updateTarget(target, accelerate: accelerate);
    final currentProfile = remoteProfileFor(peerId);
    if (currentProfile != null &&
        (currentProfile.device.host != target.host ||
            currentProfile.device.port != target.port)) {
      _setRemoteProfile(
        currentProfile.withDevice(
          currentProfile.device.copyWith(host: target.host, port: target.port),
        ),
        peerId: peerId,
      );
    }
  }

  void scheduleReconnect(String peerId, String host, int port) {
    if (peerId.isEmpty || _reconnectManagerClosed) {
      return;
    }
    final target = ReconnectTarget(peerId: peerId, host: host, port: port);
    scheduleReconnectTarget(target);
  }

  @visibleForTesting
  void scheduleReconnectTarget(ReconnectTarget target) {
    if (_reconnectManagerClosed) {
      return;
    }
    final controller = _reconnectControllerFor(target.peerId);
    if (controller.target != target) {
      controller.updateTarget(target);
    }
    controller.scheduleReconnect(target);
  }

  ReconnectTarget? reconnectTargetFor(String peerId) =>
      _reconnectControllers[peerId]?.target;

  Set<ReconnectSuppressionReason> reconnectSuppressionsFor(String peerId) =>
      _reconnectControllers[peerId]?.suppressionReasons ??
      const <ReconnectSuppressionReason>{};

  FutureOr<ReconnectEligibilityResult> _reconnectEligibility(
    ReconnectTarget target,
  ) async {
    if (_reconnectManagerClosed ||
        _autoConnectPolicyOverride == false ||
        !await _autoConnectEnabled()) {
      return ReconnectEligibilityResult.autoConnectDisabled;
    }
    final stored = await _database.fetchDevice(target.peerId);
    if (stored == null || !stored.auth) {
      return ReconnectEligibilityResult.trustRevoked;
    }
    if (stored.identityPublicKey.isEmpty) {
      return ReconnectEligibilityResult.identityUnpinned;
    }
    try {
      identityPublicKeyHash(stored.identityPublicKey);
    } on Object {
      return ReconnectEligibilityResult.identityUnpinned;
    }
    return ReconnectEligibilityResult.eligible;
  }

  /// A device can be around and not answer for hours: a phone's system has frozen
  /// Whisper there, say. The retries go on without saying so. Its row says 正在连接
  /// for the first of them and then what it is, or it would say that for good.
  FutureOr<ConnectionAttemptStatus> _runReconnectAttempt(
    ReconnectAttemptContext context,
  ) async {
    final peerId = context.target.peerId;
    final shared = _manageSharedCoordinators;
    if (shared && !_quietReconnects.contains(peerId)) {
      ConnectionCoordinator().markConnecting(peerId, reconnecting: true);
    }
    var status = ConnectionAttemptStatus.cancelled;
    try {
      status = await _attemptReconnect(context);
      return status;
    } finally {
      if (status == ConnectionAttemptStatus.authenticated) {
        _quietReconnects.remove(peerId);
      } else {
        _quietReconnects.add(peerId);
        if (shared && !isConnectedTo(peerId)) {
          ConnectionCoordinator().markDisconnected(peerId: peerId);
        }
      }
    }
  }

  final Set<String> _quietReconnects = <String>{};

  Future<ConnectionAttemptStatus> _attemptReconnect(
    ReconnectAttemptContext context,
  ) async {
    final target = context.target;
    final eligibility = await _reconnectEligibility(target);
    if (!context.isCurrent ||
        eligibility != ReconnectEligibilityResult.eligible) {
      return ConnectionAttemptStatus.cancelled;
    }
    final stored = await _database.fetchDevice(target.peerId);
    if (!context.isCurrent ||
        stored == null ||
        !stored.auth ||
        stored.identityPublicKey.isEmpty) {
      return ConnectionAttemptStatus.cancelled;
    }
    late final String publicKeyHash;
    try {
      publicKeyHash = identityPublicKeyHash(stored.identityPublicKey);
    } on Object {
      return ConnectionAttemptStatus.rejected;
    }
    final allCandidates = _manageSharedCoordinators
        ? ConnectionCoordinator().candidateEndpointsFor(
            target.peerId, primary: target.endpoint,
          )
        : <PeerEndpoint>[target.endpoint];
    final result = await connectToServer(
      ConnectionAttemptRequest(
        requestId: 'reconnect:${target.peerId}:${context.generation}:${uuid.v4()}',
        endpoint: target.endpoint,
        fallbackEndpoints: allCandidates.length > 1
            ? allCandidates.sublist(1)
            : const <PeerEndpoint>[],
        expectedPeerId: target.peerId,
        expectedPublicKeyHash: publicKeyHash,
        mode: ConnectionAttemptMode.automatic,
      ),
      whenCancelled: context.whenCancelled,
    );
    context.reportResultReason(result.reason);
    if (context.isCurrent && result.isAuthenticated) {
      final storedDevice = await _database.fetchDevice(result.peerId);
      if (context.isCurrent &&
          storedDevice != null &&
          _peers.isCurrent(result.peerId, result.generation)) {
        if (_manageSharedCoordinators) {
          final activePeerId = ConnectionCoordinator().snapshot.activePeerId;
          final shouldSelect =
              activePeerId == null || activePeerId == result.peerId;
          ConnectionCoordinator().markConnected(
            storedDevice,
            select: shouldSelect,
          );
        }
      }
    }
    return result.status;
  }

  void _recordAuthenticatedReconnect(
    PeerSocketSession session,
    WebSocketSink sink,
    DeviceData device,
  ) {
    if (_reconnectManagerClosed || device.uid.isEmpty) {
      return;
    }
    if (session.role == PeerSocketRole.server) {
      final controller = _reconnectControllers[device.uid];
      controller?.identityPinned();
      controller?.trustRestored();
      controller?.eligibilityRestored();
      controller?.authenticated();
      return;
    }
    final pending = _pendingOutgoingBySink[sink];
    final endpoint = pending?.connectedEndpoint ?? pending?.request.endpoint;
    if (pending == null || endpoint == null) {
      return;
    }
    if (_manageSharedCoordinators) {
      ConnectionCoordinator().rememberWorkingEndpoint(device.uid, endpoint);
    }
    final target = ReconnectTarget.endpoint(
      peerId: device.uid,
      endpoint: endpoint,
    );
    final controller = _reconnectControllerFor(device.uid);
    if (controller.target != target) {
      controller.updateTarget(target, accelerate: false);
    }
    controller.identityPinned();
    controller.trustRestored();
    controller.eligibilityRestored();
    if (!pending.request.isAutomatic) {
      controller.authenticated();
    }
  }

  void _invalidatePeerPolicy(
    String peerId,
    _PeerPolicyDisposition disposition,
  ) {
    _fileBrowseTrustCache.invalidate(peerId);
    _policyRevision += 1;
    _peerInvalidationRevisions[peerId] = _policyRevision;
    _peerPolicyDispositions[peerId] = disposition;
    _peerPolicyEpochs[peerId] = (_peerPolicyEpochs[peerId] ?? 0) + 1;
  }

  Set<_PeerAuthSuppressionReason> _authSuppressionsFor(String peerId) =>
      _peerAuthSuppressions.putIfAbsent(
        peerId,
        () => <_PeerAuthSuppressionReason>{},
      );

  PairingReason? _incomingPolicyRepairReason(String peerId) {
    final suppressions = _peerAuthSuppressions[peerId];
    if (suppressions == null || suppressions.isEmpty) {
      return null;
    }
    if (suppressions.contains(_PeerAuthSuppressionReason.deviceDeleted)) {
      return null;
    }
    return suppressions.every(
          (reason) =>
              reason == _PeerAuthSuppressionReason.trustRevoked ||
              reason == _PeerAuthSuppressionReason.manualDisconnect,
        )
        ? PairingReason.newDevice
        : null;
  }

  void _requirePairingForPolicyRepair(
    String peerId,
    PairingReason? pairingReason,
  ) {
    final suppressions = _peerAuthSuppressions[peerId];
    final requiresConfirmation =
        suppressions?.any(
          (reason) =>
              reason == _PeerAuthSuppressionReason.trustRevoked ||
              reason == _PeerAuthSuppressionReason.manualDisconnect,
        ) ==
        true;
    if (requiresConfirmation && pairingReason == null) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  void _addPeerAuthSuppression(
    String peerId,
    _PeerAuthSuppressionReason reason,
  ) {
    _authSuppressionsFor(peerId).add(reason);
  }

  void _replacePeerAuthSuppressionForDelete(String peerId) {
    _authSuppressionsFor(peerId)
      ..clear()
      ..add(_PeerAuthSuppressionReason.deviceDeleted);
  }

  bool _removePeerAuthSuppression(
    String peerId,
    _PeerAuthSuppressionReason reason,
  ) {
    final suppressions = _peerAuthSuppressions[peerId];
    if (suppressions == null || !suppressions.remove(reason)) {
      return false;
    }
    if (suppressions.isEmpty) {
      _peerAuthSuppressions.remove(peerId);
    }
    _policyRevision += 1;
    _peerInvalidationRevisions[peerId] = _policyRevision;
    _peerPolicyEpochs[peerId] = (_peerPolicyEpochs[peerId] ?? 0) + 1;
    return true;
  }

  bool _isPeerAuthenticationAllowed(
    String peerId, {
    PendingOutgoingConnection? attempt,
    bool allowTrustRepair = false,
  }) {
    final suppressions = _peerAuthSuppressions[peerId];
    if (suppressions == null || suppressions.isEmpty) {
      return true;
    }
    if (suppressions.contains(_PeerAuthSuppressionReason.deviceDeleted)) {
      return suppressions.length == 1 && attempt?.allowsDeviceRepair == true;
    }
    final repairAllowed =
        allowTrustRepair || attempt?.allowsTrustRepair == true;
    return repairAllowed &&
        suppressions.every(
          (reason) =>
              reason == _PeerAuthSuppressionReason.trustRevoked ||
              reason == _PeerAuthSuppressionReason.manualDisconnect,
        );
  }

  void _authorizeInteractiveAttemptForPeer(
    PendingOutgoingConnection attempt,
    String peerId,
  ) {
    if (!attempt.request.isAutomatic) {
      _removePeerAuthSuppression(
        peerId,
        _PeerAuthSuppressionReason.manualDisconnect,
      );
      final suppressions = _peerAuthSuppressions[peerId];
      final repairableSuppression =
          suppressions != null && suppressions.length == 1
          ? suppressions.single
          : null;
      attempt.allowsDeviceRepair =
          repairableSuppression == _PeerAuthSuppressionReason.deviceDeleted;
      attempt.allowsTrustRepair =
          repairableSuppression == _PeerAuthSuppressionReason.trustRevoked;
    }
    attempt.peerPolicyEpoch = _peerPolicyEpochs[peerId] ?? 0;
    attempt.startedPolicyRevision = _policyRevision;
  }

  void _completeDeviceRepairIfNeeded(
    PendingOutgoingConnection? attempt,
    String peerId,
  ) {
    if (attempt?.allowsDeviceRepair != true) {
      return;
    }
    _removePeerAuthSuppression(
      peerId,
      _PeerAuthSuppressionReason.deviceDeleted,
    );
    attempt!.allowsDeviceRepair = false;
  }

  void _cancelPendingAuthSessionsForPeer(String peerId) {
    for (final link in _peers.linksSnapshot) {
      final session = link.session;
      if (session == null ||
          session.remotePeerId != peerId ||
          session.isAuthenticated) {
        continue;
      }
      session.close();
      _ignoreFuture(
        link.sink.close(),
        context: 'cancel invalidated peer authentication',
      );
    }
  }

  Future<void> _cancelPendingAttemptsForPeer(
    String peerId,
    ConnectionAttemptReason reason, {
    bool Function(PendingOutgoingConnection attempt)? where,
  }) async {
    final attempts =
        _pendingOutgoingByPeerId[peerId]
            ?.where((attempt) => where?.call(attempt) ?? true)
            .toList(growable: false) ??
        const <PendingOutgoingConnection>[];
    final cancellations = attempts
        .map((attempt) => attempt.cancel(reason: reason))
        .toList(growable: false);
    await Future.wait(cancellations);
    await Future.wait(
      attempts.map(
        (attempt) =>
            attempt.completion ??
            Future<ConnectionAttemptResult>.value(
              ConnectionAttemptResult.cancelled(
                requestId: attempt.request.requestId,
              ),
            ),
      ),
    );
  }

  Future<T> _serializePeerAuthentication<T>(
    String peerId,
    Future<T> Function() operation,
  ) {
    final previous = _peerAuthenticationTails[peerId];
    final result = previous == null
        ? Future<T>.sync(operation)
        : previous.then<T>((_) => operation());
    final tail = result.then<void>((_) {}, onError: (_, __) {});
    _peerAuthenticationTails[peerId] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_peerAuthenticationTails[peerId], tail)) {
          _peerAuthenticationTails.remove(peerId);
        }
      }),
    );
    return result;
  }

  Future<void> _waitForPeerAuthentication(String peerId) async {
    await (_peerAuthenticationTails[peerId] ?? Future<void>.value());
  }

  Future<void> _waitForAuthCommitBarrier(
    ConnectionAuthCommitStage stage,
    String peerId,
  ) async {
    await _authCommitBarrier?.call(stage, peerId);
  }

  bool _isPendingPolicyCurrent(PendingOutgoingConnection attempt) {
    if (attempt.isCancelled ||
        (attempt.request.isAutomatic &&
            attempt.globalPolicyEpoch != _globalPolicyEpoch)) {
      return false;
    }
    final peerId = attempt.verifiedPeerId.isNotEmpty
        ? attempt.verifiedPeerId
        : attempt.request.expectedPeerId;
    return peerId.isEmpty ||
        (attempt.peerPolicyEpoch == (_peerPolicyEpochs[peerId] ?? 0) &&
            (_peerInvalidationRevisions[peerId] ?? 0) <=
                attempt.startedPolicyRevision &&
            _isPeerAuthenticationAllowed(peerId, attempt: attempt));
  }

  Future<void> setAutoConnectPolicy(bool enabled) async {
    if (!enabled) {
      _autoConnectPolicyOverride = false;
      _globalPolicyEpoch += 1;
      for (final controller in _reconnectControllers.values) {
        controller.autoConnectDisabled();
      }
      final automaticAttempts = _pendingOutgoingConnections
          .where((attempt) => attempt.request.isAutomatic)
          .toList(growable: false);
      final cancellations = automaticAttempts
          .map(
            (attempt) => attempt.cancel(
              reason: ConnectionAttemptReason.autoConnectDisabled,
            ),
          )
          .toList(growable: false);
      await Future.wait(cancellations);
      await Future.wait(
        automaticAttempts.map(
          (attempt) =>
              attempt.completion ??
              Future<ConnectionAttemptResult>.value(
                ConnectionAttemptResult.cancelled(
                  requestId: attempt.request.requestId,
                ),
              ),
        ),
      );
      await _setAutoConnectEnabled(false);
      return;
    }
    await _setAutoConnectEnabled(true);
    _autoConnectPolicyOverride = true;
    for (final controller in _reconnectControllers.values) {
      controller.autoConnectEnabled();
      final target = controller.target;
      if (target != null && !controller.isSuppressed) {
        controller.scheduleReconnect(target);
      }
    }
  }

  Future<bool> setPeerTrust(String peerId, bool trusted) async {
    if (peerId.isEmpty) {
      return false;
    }
    if (!trusted) {
      _addPeerAuthSuppression(peerId, _PeerAuthSuppressionReason.trustRevoked);
      _invalidatePeerPolicy(peerId, _PeerPolicyDisposition.trustRevoked);
      _cancelPendingAuthSessionsForPeer(peerId);
      _reconnectControllers[peerId]?.trustRevoked();
      _outgoingTextRetries.clearPeer(peerId);
      final invalidation = _transferEngine.invalidateOutgoingTransfersForPeer(
        peerId,
        reason: 'trust_revoked',
        revokeDeviceTrust: true,
      );
      final pendingCancellation = _cancelPendingAttemptsForPeer(
        peerId,
        ConnectionAttemptReason.trustRevoked,
      );
      final removal = _removePeerConnection(
        peerId,
        PeerDisconnectCause.trustRevoked,
      );
      await invalidation;
      await pendingCancellation;
      await _waitForPeerAuthentication(peerId);
      await removal;
      await _revokeRemoteFilesForPeer(peerId);
      return true;
    }
    final stored = await _database.fetchDevice(peerId);
    if (stored == null || stored.identityPublicKey.isEmpty) {
      _reconnectControllers[peerId]?.identityUnpinned();
      return false;
    }
    final updated = await _database.authDeviceIfPinned(
      peerId,
      stored.identityPublicKey,
    );
    if (updated) {
      _fileBrowseTrustCache.invalidate(peerId);
      _removePeerAuthSuppression(
        peerId,
        _PeerAuthSuppressionReason.trustRevoked,
      );
      final controller = _reconnectControllers[peerId];
      controller?.identityPinned();
      controller?.trustRestored();
      final target = controller?.target;
      if (controller != null && target != null && !controller.isSuppressed) {
        controller.scheduleReconnect(target);
      }
    }
    return updated;
  }

  Future<void> deletePeer(String peerId) async {
    if (peerId.isEmpty) {
      return;
    }
    _replacePeerAuthSuppressionForDelete(peerId);
    _invalidatePeerPolicy(peerId, _PeerPolicyDisposition.deviceDeleted);
    _cancelPendingAuthSessionsForPeer(peerId);
    _reconnectControllers[peerId]?.trustRevoked();
    _outgoingTextRetries.clearPeer(peerId);
    final invalidation = _transferEngine.invalidateOutgoingTransfersForPeer(
      peerId,
      reason: 'device_deleted',
      revokeDeviceTrust: true,
    );
    final pendingCancellation = _cancelPendingAttemptsForPeer(
      peerId,
      ConnectionAttemptReason.deviceDeleted,
    );
    final removal = _removePeerConnection(
      peerId,
      PeerDisconnectCause.deviceDeleted,
    );
    await invalidation;
    await pendingCancellation;
    await _waitForPeerAuthentication(peerId);
    await removal;
    await _revokeRemoteFilesForPeer(peerId);
    // With this device's own id, 本机: everything it ever sent also has that
    // id as its sender, and only the notes are to go.
    await _database.clearDevices(<String>[peerId], localPeerId: sender);
    forgetPeerTraits(peerId);
    _deletedPeerDiscoverySuppressions.add(peerId);
    // 删除抑制只保护删除事务本身。数据库清理完成后，新拨入应作为
    // 新设备重新配对；解除时推进策略版本，同时淘汰删除期间抢入的会话。
    _removePeerAuthSuppression(
      peerId,
      _PeerAuthSuppressionReason.deviceDeleted,
    );
  }

  bool shouldSuppressDiscoveredPeer(String peerId) =>
      _deletedPeerDiscoverySuppressions.contains(peerId);

  void releaseDeletedPeerDiscoverySuppression(String peerId) {
    _deletedPeerDiscoverySuppressions.remove(peerId);
  }

  Future<ConnectionAttemptResult> connectToServer(
    ConnectionAttemptRequest request, {
    Future<void>? whenCancelled,
  }) {
    if (request.mode == ConnectionAttemptMode.interactive &&
        _reconnectManagerClosed &&
        _acceptingOutgoingConnections) {
      _reconnectManagerClosed = false;
    }
    if (request.mode == ConnectionAttemptMode.interactive &&
        request.expectedPeerId.isNotEmpty &&
        !_reconnectManagerClosed) {
      final target = ReconnectTarget.endpoint(
        peerId: request.expectedPeerId,
        endpoint: request.endpoint,
      );
      _reconnectControllerFor(
        request.expectedPeerId,
      ).unsuppressForManualConnect(target);
    }
    if (_pendingOutgoingByRequestId.containsKey(request.requestId)) {
      return Future<ConnectionAttemptResult>.value(
        ConnectionAttemptResult.rejected(
          requestId: request.requestId,
          reason: ConnectionAttemptReason.duplicateRequest,
        ),
      );
    }
    // 同 peer 已有在途尝试(手动或自动)时直接跳过新的自动拨号:
    // 不建 attempt、不建 socket,也避免自动尝试在手动抢占期间
    // 重新占用出站鉴权门。只统计未被取消的尝试:被 cancel/invalidate
    // 但异步清理尚未 untrack 的垂死 attempt 不得挡下加速重拨。
    if (request.isAutomatic &&
        _hasUncancelledPendingAttemptForPeer(request.expectedPeerId)) {
      return Future<ConnectionAttemptResult>.value(
        ConnectionAttemptResult.rejected(
          requestId: request.requestId,
          reason: ConnectionAttemptReason.duplicateRequest,
        ),
      );
    }
    final attempt = PendingOutgoingConnection(
      request,
      globalPolicyEpoch: _globalPolicyEpoch,
      peerPolicyEpoch: _peerPolicyEpochs[request.expectedPeerId] ?? 0,
      startedPolicyRevision: _policyRevision,
      socketCloseTimeout: _socketCloseTimeout,
    );
    if (request.mode == ConnectionAttemptMode.interactive &&
        request.expectedPeerId.isNotEmpty) {
      _authorizeInteractiveAttemptForPeer(attempt, request.expectedPeerId);
    }
    final completer = Completer<ConnectionAttemptResult>();
    attempt.completion = completer.future;
    _trackPendingOutgoing(attempt);
    if (whenCancelled != null) {
      unawaited(
        whenCancelled.then<void>((_) {
          if (_pendingOutgoingByRequestId[request.requestId] == attempt) {
            unawaited(attempt.cancel());
          }
        }),
      );
    }
    final operation =
        request.mode == ConnectionAttemptMode.interactive &&
            request.expectedPeerId.isNotEmpty
        ? _preemptAutomaticAttemptsThenConnect(attempt)
        : _connectToServer(attempt);
    unawaited(
      operation.then<void>(
        (result) {
          _untrackPendingOutgoing(attempt);
          attempt.httpClient.close();
          if (!completer.isCompleted) {
            completer.complete(result);
          }
        },
        onError: (Object _, StackTrace __) {
          _untrackPendingOutgoing(attempt);
          attempt.httpClient.close(force: true);
          if (!completer.isCompleted) {
            completer.complete(
              ConnectionAttemptResult.networkFailure(
                requestId: request.requestId,
              ),
            );
          }
        },
      ),
    );
    return completer.future;
  }

  bool hasPendingConnectionAttempt(String requestId) =>
      _pendingOutgoingByRequestId.containsKey(requestId);

  bool hasPendingConnectionAttemptForPeer(String peerId) =>
      _pendingOutgoingByPeerId[peerId]?.isNotEmpty == true;

  bool _hasUncancelledPendingAttemptForPeer(String peerId) =>
      _pendingOutgoingByPeerId[peerId]?.any(
        (attempt) => !attempt.isCancelled,
      ) ==
      true;

  @visibleForTesting
  bool debugBindPendingConnectionPeer(String requestId, String peerId) {
    final attempt = _pendingOutgoingByRequestId[requestId];
    if (attempt == null) {
      return false;
    }
    _bindPendingOutgoingPeer(attempt, peerId);
    return _isPendingPolicyCurrent(attempt);
  }

  Future<void> cancelConnectionAttempt(String requestId) async {
    final attempt = _pendingOutgoingByRequestId[requestId];
    if (attempt != null) {
      await attempt.cancel();
      await attempt.completion;
    }
  }

  void _trackPendingOutgoing(PendingOutgoingConnection attempt) {
    _pendingOutgoingConnections.add(attempt);
    _pendingOutgoingByRequestId[attempt.request.requestId] = attempt;
    _indexPendingOutgoingPeer(attempt, attempt.request.expectedPeerId);
  }

  void _indexPendingOutgoingPeer(
    PendingOutgoingConnection attempt,
    String peerId,
  ) {
    if (peerId.isEmpty) {
      return;
    }
    _pendingOutgoingByPeerId
        .putIfAbsent(peerId, () => <PendingOutgoingConnection>{})
        .add(attempt);
  }

  void _bindPendingOutgoingPeer(
    PendingOutgoingConnection attempt,
    String peerId,
  ) {
    if (attempt.verifiedPeerId == peerId) {
      return;
    }
    if (attempt.verifiedPeerId.isNotEmpty) {
      _pendingOutgoingByPeerId[attempt.verifiedPeerId]?.remove(attempt);
    }
    attempt.verifiedPeerId = peerId;
    if (attempt.request.expectedPeerId.isEmpty) {
      attempt.peerPolicyEpoch = _peerPolicyEpochs[peerId] ?? 0;
      final invalidationRevision = _peerInvalidationRevisions[peerId] ?? 0;
      if (attempt.request.mode == ConnectionAttemptMode.interactive &&
          invalidationRevision <= attempt.startedPolicyRevision) {
        _authorizeInteractiveAttemptForPeer(attempt, peerId);
      }
    }
    _indexPendingOutgoingPeer(attempt, peerId);
  }

  void _untrackPendingOutgoing(PendingOutgoingConnection attempt) {
    _pendingOutgoingConnections.remove(attempt);
    if (identical(
      _pendingOutgoingByRequestId[attempt.request.requestId],
      attempt,
    )) {
      _pendingOutgoingByRequestId.remove(attempt.request.requestId);
    }
    for (final peerId in <String>{
      attempt.request.expectedPeerId,
      attempt.verifiedPeerId,
    }) {
      final attempts = _pendingOutgoingByPeerId[peerId];
      attempts?.remove(attempt);
      if (attempts?.isEmpty == true) {
        _pendingOutgoingByPeerId.remove(peerId);
      }
    }
    final sink = attempt.channel?.sink;
    if (sink != null && identical(_pendingOutgoingBySink[sink], attempt)) {
      _pendingOutgoingBySink.remove(sink);
    }
  }

  static bool _isAutomaticAttempt(PendingOutgoingConnection attempt) =>
      attempt.request.isAutomatic;

  /// 手动连接优先:先取消同 peer 的在途自动尝试,并有界等待其清理完成
  /// (含释放出站鉴权门),再真正拨号;否则手动尝试会同步撞门,
  /// 直接得到 duplicateRequest 而无任何网络活动。
  Future<ConnectionAttemptResult> _preemptAutomaticAttemptsThenConnect(
    PendingOutgoingConnection attempt,
  ) async {
    final peerId = attempt.request.expectedPeerId;
    final hasAutomaticInFlight =
        _pendingOutgoingByPeerId[peerId]?.any(_isAutomaticAttempt) == true;
    if (hasAutomaticInFlight) {
      try {
        await _cancelPendingAttemptsForPeer(
          peerId,
          ConnectionAttemptReason.superseded,
          where: _isAutomaticAttempt,
        ).timeout(_manualPreemptWaitTimeout);
      } catch (_) {
        // 有界等待:超时或清理异常都不阻断手动拨号;若鉴权门尚未
        // 释放,后续 claim 会自然返回 duplicateRequest,绝不死等。
      }
    }
    if (attempt.isCancelled) {
      return ConnectionAttemptResult.cancelled(
        requestId: attempt.request.requestId,
        reason: attempt.cancellationReason,
      );
    }
    return _connectToServer(attempt);
  }

  Future<ConnectionAttemptResult> _connectToServer(
    PendingOutgoingConnection attempt,
  ) => _connectToServerVersion(attempt, PeerSocketSession.protocolVersion);

  Future<ConnectionAttemptResult> _connectToServerVersion(
    PendingOutgoingConnection attempt,
    int protocolVersion,
  ) async {
    final request = attempt.request;
    if (!_acceptingOutgoingConnections || _systemSleeping) {
      return ConnectionAttemptResult.cancelled(
        requestId: request.requestId,
        reason: ConnectionAttemptReason.managerClosed,
      );
    }
    final primaryEndpoint = request.endpoint;
    final authRequestKey = _authRequestKey(
      peerId: request.expectedPeerId,
      host: primaryEndpoint.host,
      port: primaryEndpoint.port,
    );
    if (!_authRequestGate.tryClaimOutgoing(authRequestKey)) {
      return ConnectionAttemptResult.rejected(
        requestId: request.requestId,
        reason: ConnectionAttemptReason.duplicateRequest,
      );
    }
    var authClaimOwnedLocally = true;
    WebSocketChannel? activeChannel;
    bool isRetryableCandidateFailure(ConnectionAttemptReason reason) =>
        (reason == ConnectionAttemptReason.identityMismatch ||
            reason == ConnectionAttemptReason.transportClosed) &&
        !attempt.isCancelled;
    try {
      return await dialAndAuthenticateCandidates<
        ({WebSocket webSocket, Socket socket}),
        ConnectionAttemptResult
      >(
        endpoints: request.candidateEndpoints,
        dial: (endpoint) => connectOutgoingWebSocket(
          endpoint.chatUri, attempt,
          timeout: _outgoingConnectionTimeout, pingInterval: _serverPingInterval,
        ),
        close: (upgraded) async {
          upgraded.socket.destroy();
          unawaited(upgraded.webSocket.close().catchError((Object _) {}));
        },
        isCancelled: () => attempt.isCancelled,
        onSettled: attempt.abortPendingDialClients,
        shouldRetryNextCandidate: (result) =>
            isRetryableCandidateFailure(result.reason),
        authenticate: (endpoint, upgraded) async {
          attempt.resetTransportForCandidateRetry();
          final channel = BackpressureWebSocketChannel(
            upgraded.webSocket, socket: upgraded.socket,
          );
          activeChannel = channel;
          attempt.channel = channel;
          attempt.connectedEndpoint = endpoint;
          attempt.isReady = true;
          if (attempt.isCancelled) throw const OutgoingConnectionCancelled();
          final channelSink = channel.sink;
          _pendingOutgoingBySink[channelSink] = attempt;
          if (authClaimOwnedLocally) {
            _outgoingAuthKeysBySink[channelSink] = authRequestKey;
            authClaimOwnedLocally = false;
          }
          _peers.setEndpoint(channelSink, (
            host: endpoint.host,
            port: endpoint.port,
          ));
          final authCompleter = Completer<_SocketAuthResult>();
          _authResultsBySink[channelSink] = authCompleter;
          final session = await _createSocketSession(
            sink: channelSink,
            role: PeerSocketRole.client,
            intendedPeerId: request.expectedPeerId,
            intendedPublicKeyHash: request.expectedPublicKeyHash,
            protocolVersion: protocolVersion,
          );
          attempt.session = session;
          if (attempt.isCancelled) throw const OutgoingConnectionCancelled();
          _attachSocketTransport(channel, session, asServer: false);
          await _sendAuthEnvelope(channelSink, await session.createHello());
          final authResult = await authCompleter.future;
          if (attempt.isCancelled) throw const OutgoingConnectionCancelled();
          if (!authResult.allow) {
            final failure = authFailureResult(request, authResult.message);
            if (isRetryableCandidateFailure(failure.reason) &&
                _outgoingAuthKeysBySink.remove(channelSink) == authRequestKey) {
              authClaimOwnedLocally = true;
            } else {
              _releaseOutgoingAuthForSink(channelSink);
            }
            activeChannel = null;
            await _closeSocketSink(channelSink);
            await _handlePeerSocketDoneQueued(channelSink);
            return failure;
          }
          _releaseOutgoingAuthForSink(channelSink);
          activeChannel = null;
          final peerId = session.remotePeerId;
          final generation = session.connectionGeneration;
          if (!_peers.isCurrent(peerId, generation) ||
              !identical(_peers.sessionForPeer(peerId), session)) {
            return ConnectionAttemptResult.cancelled(
              requestId: request.requestId, reason: ConnectionAttemptReason.superseded,
            );
          }
          return ConnectionAttemptResult.authenticated(
            requestId: request.requestId, peerId: peerId, generation: generation,
          );
        },
      );
    } catch (error) {
      final wasCancelled =
          attempt.isCancelled ||
          error is OutgoingConnectionCancelled ||
          error is StaggeredDialCancelled ||
          (error is WebSocketChannelException &&
              error.inner is OutgoingConnectionCancelled);
      try {
        await attempt.cancel();
      } catch (_) {}
      final channel = activeChannel;
      if (channel != null) {
        _completeSocketAuth(channel.sink, false, 'connection_failed');
        _releaseOutgoingAuthForSink(channel.sink);
        await _handlePeerSocketDoneQueued(channel.sink);
      }
      if (authClaimOwnedLocally) {
        _authRequestGate.releaseOutgoing(authRequestKey);
        authClaimOwnedLocally = false;
      }
      if (wasCancelled) {
        return ConnectionAttemptResult.cancelled(
          requestId: request.requestId, reason: attempt.cancellationReason,
        );
      }
      return connectionExceptionResult(request, error);
    } finally {
      attempt.abortPendingDialClients();
      if (authClaimOwnedLocally) {
        _authRequestGate.releaseOutgoing(authRequestKey);
      }
    }
  }

  @visibleForTesting
  ConnectionAttemptResult debugClassifyConnectionException(
    ConnectionAttemptRequest request,
    Object error,
  ) => connectionExceptionResult(request, error);

  void _cancelPendingOutgoingConnections() {
    for (final attempt in _pendingOutgoingConnections.toList(growable: false)) {
      _ignoreFuture(
        attempt.cancel(reason: ConnectionAttemptReason.managerClosed),
        context: 'cancel pending outgoing websocket',
      );
    }
  }

  Future<void> closeGracefully({
    bool closeServer = false,
    bool forceServerClose = false,
  }) {
    _acceptingUpgrades = false;
    _acceptingOutgoingConnections = false;
    _reconnectManagerClosed = true;
    _globalPolicyEpoch += 1;
    for (final controller in _reconnectControllers.values) {
      controller.close();
    }
    _reconnectControllers.clear();
    _cancelPendingOutgoingConnections();
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
    _cancelPendingOutgoingConnections();
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
          _pendingOutgoingConnections.isNotEmpty ||
          _audioManager.hasActiveChannels ||
          _remoteInputManager.hasActiveChannels,
      hasPendingResults: _authResultsBySink.isNotEmpty,
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
    _outgoingAuthKeysBySink.clear();
    _incomingAuthPeerIdsBySink.clear();
    _identityPinPlansBySink.clear();
    _authRequestGate.clear();
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
      ..._authResultsBySink.keys,
    };
    AuthSocketLifecycle.closePendingAuth(
      sessions: pendingLinks.map((link) => link.session!),
      completeFailures: _authResultsBySink.values.map((completer) {
        return () {
          if (!completer.isCompleted) {
            completer.complete(
              const _SocketAuthResult(false, 'connection_closed'),
            );
          }
        };
      }),
    );
    _authResultsBySink.clear();
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
    while (_pendingOutgoingConnections.isNotEmpty) {
      final attempts = _pendingOutgoingConnections.toList(growable: false);
      await Future.wait(
        attempts.map((attempt) async {
          try {
            await attempt.cancel();
          } catch (_) {
            // The tracked connection operation performs authoritative cleanup.
          }
          try {
            await attempt.completion;
          } catch (error, stackTrace) {
            logger.i('等待出站 websocket 清理失败: ${error.runtimeType}\n$stackTrace');
          }
        }),
      );
    }
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
    _sessionStartedPolicyRevisions.clear();
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
    _addPeerAuthSuppression(
      peerId,
      _PeerAuthSuppressionReason.manualDisconnect,
    );
    _invalidatePeerPolicy(peerId, _PeerPolicyDisposition.manualDisconnect);
    _cancelPendingAuthSessionsForPeer(peerId);
    _reconnectControllers[peerId]?.manualDisconnect();
    await _cancelPendingAttemptsForPeer(
      peerId,
      ConnectionAttemptReason.manualDisconnect,
    );
    await _waitForPeerAuthentication(peerId);
    await _removePeerConnection(peerId, PeerDisconnectCause.manual);
  }

  /// A sleeping host keeps its sockets open without answering them. A peer
  /// that is driving this device's keyboard and mouse then never gets its
  /// pointer back, so every peer is let go while there is still time to tell
  /// them.
  Future<void> prepareForSystemSleep() async {
    if (_systemSleeping) {
      return;
    }
    _systemSleeping = true;
    for (final entry in _reconnectControllers.entries) {
      if (entry.value.hasPendingAttempt || entry.value.isAttemptInFlight) {
        _systemSleepReconnectPeerIds.add(entry.key);
      }
    }
    _cancelPendingOutgoingConnections();
    // A handshake that was already under way can finish while the first
    // peers are closing, hence the second pass.
    for (var pass = 0; pass < 2 && _systemSleeping; pass += 1) {
      final peerIds = connectedPeerIds.toList(growable: false);
      if (peerIds.isEmpty) {
        break;
      }
      _systemSleepReconnectPeerIds.addAll(peerIds);
      await Future.wait(
        peerIds.map(
          (peerId) =>
              _removePeerConnection(peerId, PeerDisconnectCause.systemSleep),
        ),
      );
    }
  }

  /// Lets peers back in and redials the ones [prepareForSystemSleep] dropped.
  void resumeFromSystemSleep() {
    if (!_systemSleeping) {
      return;
    }
    _systemSleeping = false;
    final peerIds = _systemSleepReconnectPeerIds.toList(growable: false);
    _systemSleepReconnectPeerIds.clear();
    if (_reconnectManagerClosed) {
      return;
    }
    for (final peerId in peerIds) {
      final controller = _reconnectControllers[peerId];
      final target = controller?.target;
      if (controller != null && target != null) {
        controller.scheduleReconnect(target);
      }
    }
  }

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

  @visibleForTesting
  Future<bool> debugRemovePeerForWatchdog(String peerId) {
    final binding = _peers.currentBinding(peerId);
    if (binding == null) {
      return Future<bool>.value(false);
    }
    return _removeUnresponsivePeerIfCurrent(binding);
  }

  /// Explicit ordered teardown steps when a peer's current connection ends.
  /// Keep this sequence explicit so tokens, acks, and media channels close
  /// before transfer recovery and shared coordinators run.
  late final List<PeerDisconnectCleanupStep> _disconnectCleanupSteps =
      <PeerDisconnectCleanupStep>[
        (peerId, _) => _pingTracker.clearPeer(peerId),
        (peerId, _) {
          _outgoingTextAcknowledgements.disconnectPeer(peerId);
          _forgetPeerMedia(peerId);
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
              _hasReadyPendingOutgoingForPeer(peerId),
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
      _reconnectControllers[peerId]?.sessionClosed();
      _dispatchToAll((event) => event.onClose());
    }
    if (_peers.removedBindingOwnsPeerState(binding) &&
        (cause == PeerDisconnectCause.network ||
            cause == PeerDisconnectCause.watchdog) &&
        !_hasUncancelledPendingAttemptForPeer(peerId)) {
      final target = _reconnectControllers[peerId]?.target;
      if (target != null) {
        _reconnectControllers[peerId]?.scheduleReconnect(target);
      }
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
          _requireCurrentBusinessSession(
            session,
            sink,
            session.connectionGeneration,
          );
        }
        await _listen(bytes, sink: sink, asServer: asServer, session: session);
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

  Future<void> _sendAuthEnvelope(
    WebSocketSink sink,
    AuthEnvelope envelope,
  ) async {
    final message = _buildMessage(
      MessageEnum.Auth,
      envelope.toJsonString(),
      '',
      '',
      0,
      false,
      senderOverride: _peers.sessionForSink(sink)?.localProfile.uid,
      receiverOverride: envelope.action == AuthAction.hello
          ? envelope.intendedPeerId ?? ''
          : _peers.sessionForSink(sink)?.remotePeerId,
    );
    if (!await _sendMessageData(message, sink: sink, rawAuth: true)) {
      throw const AuthHandshakeException('send_failed');
    }
  }

  Future<void> _handleAuthMessage(
    MessageData message, {
    required WebSocketSink sink,
    required PeerSocketSession session,
  }) async {
    try {
      final content = message.content;
      if (content == null || content.isEmpty) {
        throw const FormatException('Missing auth envelope');
      }
      final envelope = AuthEnvelope.fromJsonString(content);
      if (message.sender.isNotEmpty && message.sender != envelope.peerId) {
        throw const AuthHandshakeException('sender_mismatch');
      }
      _authEnvelopeObserver?.call(session.role, envelope);
      switch ((session.role, envelope.action)) {
        case (PeerSocketRole.server, AuthAction.hello):
          await _handleServerHello(session, sink, envelope);
        case (PeerSocketRole.server, AuthAction.proof):
          await _handleServerProof(session, sink, envelope);
        case (PeerSocketRole.server, AuthAction.approval):
          await _handleServerApproval(session, sink, envelope);
        case (PeerSocketRole.client, AuthAction.challenge):
          await _handleClientChallenge(session, sink, envelope);
        case (PeerSocketRole.client, AuthAction.result):
          await _handleClientResult(session, sink, envelope);
        default:
          throw const AuthHandshakeException('unexpected_action');
      }
    } on FormatException {
      if (session.role == PeerSocketRole.server) {
        await _sendUpgradeRequired(sink, session);
      }
      final code = rawAuthFailureCode(message.content);
      await _failSocketSession(session, sink, code);
    } on AuthHandshakeException catch (error) {
      if ((error.code == 'upgrade_required' ||
              error.code == 'peer_upgrade_required' ||
              error.code == 'local_upgrade_required' ||
              error.code == pairingBusyAction) &&
          session.role == PeerSocketRole.server) {
        final action =
            error.code == pairingBusyAction
                ? pairingBusyAction
                : 'upgrade_required';
        await _sendUpgradeRequired(sink, session, action: action);
      }
      await _failSocketSession(session, sink, error.code);
    }
  }

  Future<void> _handleServerHello(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope hello,
  ) async {
    final presentedDevice = await _database.fetchDevice(hello.peerId);
    final pinPlan = (
      reason:
          pairingReasonForIdentity(presentedDevice, hello.identityPublicKey!) ??
          _incomingPolicyRepairReason(hello.peerId),
      expectedPublicKey: presentedDevice?.identityPublicKey ?? '',
    );
    final challenge = await session.receiveHello(
      hello,
      pairingRequired: pinPlan.reason != null,
    );
    final from = _peers.endpointForSink(sink)?.host ?? '';
    final codeOnly = _pairingAttempts.admit(hello, pinPlan, from: from);
    if (!_isSessionPeerPolicyCurrent(session)) {
      throw const AuthHandshakeException('session_expired');
    }
    _requirePairingForPolicyRepair(session.remotePeerId, pinPlan.reason);
    _identityPinPlansBySink[sink] = pinPlan;
    final generation = session.connectionGeneration;
    await _sendAuthEnvelope(sink, challenge);
    if (codeOnly) _pairingAttempts.watch(session);
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }
  }

  Future<void> _handleClientChallenge(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope challenge,
  ) async {
    await session.receiveChallenge(challenge);
    final attempt = _pendingOutgoingBySink[sink];
    if (attempt == null || attempt.isCancelled) {
      throw const AuthHandshakeException('session_expired');
    }
    _bindPendingOutgoingPeer(attempt, session.remotePeerId);
    final incomingSink = _activeIncomingAuthSinkForPeer(session.remotePeerId);
    if (incomingSink != null) {
      final decision = resolveSimultaneousDial(
        localUid: session.localProfile.uid,
        remoteUid: session.remotePeerId,
      );
      if (decision == SimultaneousDialDecision.acceptIncoming) {
        _completeSocketAuth(sink, false, 'superseded');
        await attempt.cancel(reason: ConnectionAttemptReason.superseded);
        await _closeSocketSink(sink);
        return;
      }
      _peers.sessionForSink(incomingSink)?.close();
      await _closeSocketSink(incomingSink);
    }
    if (!_isPendingPolicyCurrent(attempt)) {
      throw const AuthHandshakeException('session_expired');
    }
    if (attempt.request.isAutomatic &&
        !await _automaticAttemptStillEligible(attempt, session)) {
      throw const AuthHandshakeException('identity_pin_conflict');
    }
    final pinPlan = await _pairingReason(session);
    final pairingReason =
        pinPlan.reason ??
        (session.serverPairingRequired ? PairingReason.newDevice : null);
    _requirePairingForPolicyRepair(session.remotePeerId, pairingReason);
    if (pairingReason != null && attempt.request.isAutomatic) {
      _completeSocketAuth(sink, false, 'automatic_pairing_required');
      session.close();
      await _closeSocketSink(sink);
      return;
    }
    final generation = session.connectionGeneration;
    _identityPinPlansBySink[sink] = pinPlan;

    Future<void> approveAndSend() async {
      final approved = session.resolveLocalApproval(
        generation: generation,
        allow: true,
      );
      if (!approved || !_isSameSession(session, sink, generation)) {
        return;
      }
      final approval = await session.createApproval(
        allow: true,
        reason: approvalReasonForPairing(pairingReason),
      );
      if (!_isSameSession(session, sink, generation)) {
        return;
      }
      await _sendAuthEnvelope(sink, approval);
    }

    Future<void> resolve(bool keepConnecting) async {
      if (!_isSameSession(session, sink, generation)) {
        return;
      }
      if (keepConnecting) {
        await approveAndSend();
        return;
      }
      _identityPinPlansBySink.remove(sink);
      _completeSocketAuth(sink, false, 'request_cancelled');
      await attempt.cancel(reason: ConnectionAttemptReason.requestCancelled);
      await _closeSocketSink(sink);
    }

    final proof = await session.createProof(
      reason: approvalReasonForPairing(pairingReason),
    );
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }
    await _sendAuthEnvelope(sink, proof);
    if (!_isSameSession(session, sink, generation)) {
      return;
    }

    if (pairingReason == null) {
      await approveAndSend();
    } else {
      await _requestPairingDecision(
        session,
        sink,
        pairingReason,
        PairingPromptMode.initiator,
        resolve,
      );
    }
  }

  Future<bool> _automaticAttemptStillEligible(
    PendingOutgoingConnection attempt,
    PeerSocketSession session,
  ) async {
    if (!_isPendingPolicyCurrent(attempt) ||
        _autoConnectPolicyOverride == false ||
        !await _autoConnectEnabled()) {
      return false;
    }
    final stored = await _database.fetchDevice(session.remotePeerId);
    if (!_isPendingPolicyCurrent(attempt) ||
        stored == null ||
        !stored.auth ||
        stored.identityPublicKey.isEmpty) {
      return false;
    }
    try {
      final storedHash = identityPublicKeyHash(stored.identityPublicKey);
      final remoteHash = identityPublicKeyHash(session.remoteIdentityPublicKey);
      return storedHash == attempt.request.expectedPublicKeyHash &&
          remoteHash == storedHash;
    } on Object {
      return false;
    }
  }

  Future<void> _handleServerProof(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope proof,
  ) async {
    await session.receiveProof(proof);
    if (!_isSessionPeerPolicyCurrent(session)) {
      throw const AuthHandshakeException('session_expired');
    }
    // Claimed only now: a hello alone, which anyone can send under a known
    // id, must not keep the real device out.
    final gateKey = _authRequestGate.tryClaimProven(
      session.remotePeerId,
      pinnedPublicKey: _identityPinPlansBySink[sink]?.expectedPublicKey ?? '',
      presentedPublicKey: session.remoteIdentityPublicKey,
    );
    if (gateKey == null) {
      session.close();
      await _closeSocketSink(sink);
      return;
    }
    _incomingAuthPeerIdsBySink[sink] = gateKey;
    if (_hasReadyPendingOutgoingForPeer(session.remotePeerId)) {
      final decision = resolveSimultaneousDial(
        localUid: session.localProfile.uid,
        remoteUid: session.remotePeerId,
      );
      if (decision == SimultaneousDialDecision.keepOutgoing) {
        session.close();
        await _closeSocketSink(sink);
        return;
      }
      _cancelLosingOutgoingForPeer(session.remotePeerId);
    } else if (_hasPendingOutgoingForPeer(session.remotePeerId)) {
      // Only a WebSocket-ready outgoing dial counts as simultaneous dial;
      // an attempt still stuck in TCP/HTTP connect must not kill a working
      // incoming connection.
      _cancelLosingOutgoingForPeer(session.remotePeerId);
    }
    await _ensureServerPairingDecision(session, sink);
    await _tryCompleteServerPairing(session, sink);
  }

  bool _hasReadyPendingOutgoingForPeer(String peerId) {
    if (peerId.isEmpty) return false;
    final attempts = _pendingOutgoingByPeerId[peerId];
    return attempts != null &&
        attempts.any((attempt) => !attempt.isCancelled && attempt.isReady);
  }

  bool _hasPendingOutgoingForPeer(String peerId) {
    if (peerId.isEmpty) return false;
    final attempts = _pendingOutgoingByPeerId[peerId];
    return attempts != null && attempts.any((attempt) => !attempt.isCancelled);
  }

  WebSocketSink? _activeIncomingAuthSinkForPeer(String peerId) {
    if (peerId.isEmpty) return null;
    for (final entry in _incomingAuthPeerIdsBySink.entries) {
      final session = _peers.sessionForSink(entry.key);
      if (session != null &&
          !session.isClosed &&
          session.remotePeerId == peerId) {
        return entry.key;
      }
    }
    return null;
  }

  void _cancelLosingOutgoingForPeer(String peerId) {
    final attempts =
        _pendingOutgoingByPeerId[peerId]?.toList(growable: false) ??
        const <PendingOutgoingConnection>[];
    for (final attempt in attempts) {
      final outgoingSink = attempt.channel?.sink;
      if (outgoingSink != null) {
        _completeSocketAuth(outgoingSink, false, 'superseded');
      }
      _ignoreFuture(
        attempt.cancel(reason: ConnectionAttemptReason.superseded),
        context: 'cancel losing simultaneous outgoing dial',
      );
    }
  }

  Future<void> _handleServerApproval(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope approval,
  ) async {
    await session.receiveApproval(approval);
    await _ensureServerPairingDecision(session, sink);
    await _tryCompleteServerPairing(session, sink);
  }

  Future<void> _ensureServerPairingDecision(
    PeerSocketSession session,
    WebSocketSink sink,
  ) async {
    final generation = session.connectionGeneration;
    if (!_isCurrentSession(session, sink, generation) ||
        session.isLocalApprovalResolved) {
      return;
    }
    final pinPlan = _identityPinPlansBySink[sink];
    if (pinPlan == null) {
      throw const AuthHandshakeException('identity_pin_state_missing');
    }
    final pairingReason =
        pinPlan.reason ??
        pairingReasonFromApproval(session.remotePairingReason);

    Future<void> resolve(bool allow) async {
      final accepted = session.resolveLocalApproval(
        generation: generation,
        allow: allow,
      );
      if (!accepted || !_isCurrentSession(session, sink, generation)) {
        return;
      }
      _pairingAttempts.noteDecision(allow, _peers.endpointForSink(sink)?.host);
      await _tryCompleteServerPairing(session, sink);
    }

    if (pairingReason == null) {
      await resolve(true);
      return;
    }
    if (!session.tryClaimLocalApprovalPrompt()) {
      return;
    }
    await _requestPairingDecision(
      session,
      sink,
      pairingReason,
      PairingPromptMode.responder,
      resolve,
    );
  }

  Future<void> _tryCompleteServerPairing(
    PeerSocketSession session,
    WebSocketSink sink,
  ) async {
    final generation = session.connectionGeneration;
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }
    if (!session.tryClaimPairingCompletion()) {
      return;
    }
    if (session.hasPairingRejection) {
      _identityPinPlansBySink.remove(sink);
      final result = await session.createResult(
        allow: false,
        reason: 'pairing_rejected',
      );
      if (!_isSameSession(session, sink, generation)) {
        return;
      }
      await _sendAuthEnvelope(sink, result);
      // 由 client 消费签名拒绝后关连接，避免 onDone 抢先关闭其待处理会话。
      _releaseIncomingAuthForSink(sink);
      _dispatchToAll((event) => event.afterAuth(false, null));
      return;
    }
    final pinPlan = _identityPinPlansBySink.remove(sink);
    if (pinPlan == null) {
      throw const AuthHandshakeException('identity_pin_state_missing');
    }
    final result = await session.createResult(allow: true, reason: 'approved');
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }
    await AuthHandshakeLifecycle.completeServerAllow<DeviceData>(
      commit: () =>
          _completeAuthenticatedSession(session, sink, pinPlan: pinPlan),
      sendAllow: (storedDevice) async {
        _requireCurrentAuthenticatedSession(session, sink, generation);
        await _sendAuthEnvelope(sink, result);
      },
      onAuthenticated: (storedDevice) {
        _announceAuthenticatedSession(session, sink, storedDevice);
      },
      onFailure: (error, stackTrace) async {
        logger.i('完成服务端配对失败: $error\n$stackTrace');
        if (_isSameSession(session, sink, generation)) {
          await _failSocketSession(
            session,
            sink,
            error is AuthHandshakeException
                ? error.code
                : 'authentication_failed',
            cause: error is AuthHandshakeException
                ? PeerDisconnectCause.protocolFailure
                : PeerDisconnectCause.localFailure,
          );
        }
      },
    );
  }

  Future<void> _handleClientResult(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope result,
  ) async {
    if (!await session.receiveResult(result)) {
      _identityPinPlansBySink.remove(sink);
      _completeSocketAuth(sink, false, result.reason ?? 'rejected');
      await _closeSocketSink(sink);
      return;
    }
    final pinPlan = _identityPinPlansBySink.remove(sink);
    if (pinPlan == null) {
      throw const AuthHandshakeException('identity_pin_state_missing');
    }
    final storedDevice = await _completeAuthenticatedSession(
      session,
      sink,
      pinPlan: pinPlan,
    );
    _announceAuthenticatedSession(session, sink, storedDevice);
  }

  Future<_IdentityPinPlan> _pairingReason(PeerSocketSession session) async {
    final stored = await _database.fetchDevice(session.remotePeerId);
    return (
      reason: pairingReasonForIdentity(stored, session.remoteIdentityPublicKey),
      expectedPublicKey: stored?.identityPublicKey ?? '',
    );
  }

  Future<void> _requestPairingDecision(
    PeerSocketSession session,
    WebSocketSink sink,
    PairingReason reason,
    PairingPromptMode mode,
    Future<void> Function(bool) resolve,
  ) async {
    final listener = _primaryEvent;
    if (listener == null) {
      await resolve(false);
      return;
    }
    final generation = session.connectionGeneration;
    final device = await _deviceForSession(session, sink);
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }
    final sessionGuarded = session.guardApprovalCallback((allow) {
      _runGuardedApproval(
        session: session,
        sink: sink,
        generation: generation,
        resolve: () => resolve(allow),
      );
    });
    final presentation = PairingPresentationBinding(
      sessionCancellation: session.pairingResolved,
      onResolve: sessionGuarded,
    );
    final request = PairingRequest(
      device: device,
      pairingCode: session.pairingCode,
      reason: reason,
      mode: mode,
      cancellation: presentation.cancellation,
      presentation: presentation,
    );
    if (kDebugMode) {
      // Test machines are paired by the automation hooks, not by a click.
      DebugPairingRequests.add(request);
    }
    _ignoreFuture(
      ConnectionRequestNotifier().maybeShowForPairing(
        request: request,
        resolve: presentation.resolve,
      ),
      context: 'show pairing notification',
    );
    _dispatchGuarded(
      listener,
      (event) => event.onPairing(request, presentation.resolve),
    );
  }

  void _runGuardedApproval({
    required PeerSocketSession session,
    required WebSocketSink sink,
    required int generation,
    required Future<void> Function() resolve,
  }) {
    final handling = AuthHandshakeLifecycle.resolveGuarded(
      resolve: resolve,
      onFailure: (error, stackTrace) async {
        logger.i('处理配对决定失败: $error\n$stackTrace');
        if (_isSameSession(session, sink, generation)) {
          await _failSocketSession(
            session,
            sink,
            error is AuthHandshakeException
                ? error.code
                : 'authentication_failed',
            cause: error is AuthHandshakeException
                ? PeerDisconnectCause.protocolFailure
                : PeerDisconnectCause.localFailure,
          );
        }
      },
    );
    _ignoreFuture(
      handling.then<void>((_) {}),
      context: 'handle guarded pairing decision',
    );
  }

  Future<DeviceData> _deviceForSession(
    PeerSocketSession session,
    WebSocketSink sink,
  ) async {
    final stored = await _database.fetchDevice(session.remotePeerId);
    final endpoint = _peers.endpointForSink(sink);
    final host = endpoint?.host.isNotEmpty == true
        ? endpoint!.host
        : stored?.host ?? '';
    final port = endpoint?.port != null && endpoint!.port > 0
        ? endpoint.port
        : stored?.port ?? 0;
    return session.remoteProfile!.toDeviceData(host: host, port: port);
  }

  Future<DeviceData> _completeAuthenticatedSession(
    PeerSocketSession session,
    WebSocketSink sink, {
    required _IdentityPinPlan pinPlan,
  }) {
    return _serializePeerAuthentication(
      session.remotePeerId,
      () =>
          _completeAuthenticatedSessionSerialized(
            session,
            sink,
            pinPlan: pinPlan,
          ).whenComplete(() {
            _sessionStartedPolicyRevisions.remove(session);
          }),
    );
  }

  Future<DeviceData> _completeAuthenticatedSessionSerialized(
    PeerSocketSession session,
    WebSocketSink sink, {
    required _IdentityPinPlan pinPlan,
  }) async {
    final generation = session.connectionGeneration;
    _requireCurrentSession(session, sink, generation);
    final previousDevice = await _database.fetchDevice(session.remotePeerId);
    final identityChanged =
        previousDevice != null &&
        previousDevice.identityPublicKey != session.remoteIdentityPublicKey;
    if (identityChanged) {
      _outgoingTextRetries.clearPeer(session.remotePeerId);
    }
    _requireCurrentAuthenticationCommit(session, sink, generation);
    final existingLink = _peers.linkForPeer(session.remotePeerId);
    final existing = existingLink?.session;
    if (existing != null &&
        !existing.isClosed &&
        existing.isAuthenticated &&
        existing.role != session.role &&
        (existingLink?.authCommitWatermark ?? -1) >=
            session.connectionGeneration &&
        existingSessionWinsOverlap(
          localUid: session.localProfile.uid,
          remoteUid: session.remotePeerId,
          existingIsClient: existing.role == PeerSocketRole.client,
        )) {
      throw const AuthHandshakeException('superseded');
    }
    DeviceData? storedDevice;
    PeerProfile? runtimeProfile;
    var published = false;
    var superseded = false;
    try {
      final committed = await session.commitAuthentication(
        generation: generation,
        persistIdentity: () async {
          await _waitForAuthCommitBarrier(
            ConnectionAuthCommitStage.beforePersistence,
            session.remotePeerId,
          );
          _requireCurrentAuthenticationCommit(session, sink, generation);
          final candidate = await _deviceForSession(session, sink);
          _requireCurrentAuthenticationCommit(session, sink, generation);
          final device = await _database.commitAuthenticatedDevice(
            candidate: candidate,
            publicKey: session.remoteIdentityPublicKey,
            replaceIdentity: pinPlan.reason == PairingReason.identityChanged,
            expectedPublicKey: pinPlan.expectedPublicKey,
            requireCurrent: () =>
                _requireCurrentAuthenticationCommit(session, sink, generation),
          );
          if (identityChanged) {
            await _transferEngine.invalidateOutgoingTransfersForPeer(
              session.remotePeerId,
              reason: 'identity_replaced',
            );
            _requireCurrentAuthenticationCommit(session, sink, generation);
          }
          storedDevice = device;
          // As received: trusting nothing, asking for nothing.
          runtimeProfile = PeerProfile.fromWire(
            session.remoteProfile!,
          ).withDevice(device);
          await _waitForAuthCommitBarrier(
            ConnectionAuthCommitStage.afterPersistence,
            session.remotePeerId,
          );
          _requireCurrentAuthenticationCommit(session, sink, generation);
        },
        registerPeer: () async {
          await _waitForAuthCommitBarrier(
            ConnectionAuthCommitStage.beforeRegistration,
            session.remotePeerId,
          );
          _requireCurrentRegisterableSession(session, sink, generation);
          _requireCurrentAuthenticationCommit(session, sink, generation);
          final peerId = session.remotePeerId;
          superseded = await _registerPeerConnection(
            peerId: peerId,
            sink: sink,
            session: session,
            profile: runtimeProfile,
          );
          await _waitForAuthCommitBarrier(
            ConnectionAuthCommitStage.afterRegistration,
            session.remotePeerId,
          );
          _requireCurrentRegisterableSession(session, sink, generation);
          _requireCurrentAuthenticationCommit(session, sink, generation);
        },
      );
      if (!committed) {
        throw const AuthHandshakeException('session_expired');
      }
      _requireCurrentAuthenticatedSession(session, sink, generation);
      _requireCurrentAuthenticationCommit(session, sink, generation);
      await _closeSupersededMediaChannels(session);
      _requireCurrentAuthenticatedSession(session, sink, generation);
      _requireCurrentAuthenticationCommit(session, sink, generation);
      final device = storedDevice;
      if (device == null) {
        throw const AuthHandshakeException('identity_pin_state_missing');
      }
      session.markTransportAuthenticated();
      final link = _peers.linkForSink(sink);
      if (link != null) {
        link.authCommitWatermark = _nextConnectionGeneration;
        if (superseded) {
          link.supersededOnAuth = true;
        }
      }
      _transferEngine.allowOutgoingTransfersForPeer(session.remotePeerId);
      _removePeerAuthSuppression(
        session.remotePeerId,
        _PeerAuthSuppressionReason.trustRevoked,
      );
      _removePeerAuthSuppression(
        session.remotePeerId,
        _PeerAuthSuppressionReason.manualDisconnect,
      );
      published = true;
      return device;
    } catch (error, stackTrace) {
      final attempted = storedDevice;
      if (!published && attempted != null) {
        await _database.rollbackAuthenticatedDevice(
          peerId: session.remotePeerId,
          attemptedPublicKey: session.remoteIdentityPublicKey,
          previous: _rollbackPreviousDevice(session, previousDevice),
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _announceAuthenticatedSession(
    PeerSocketSession session,
    WebSocketSink sink,
    DeviceData storedDevice,
  ) {
    _requireCurrentAuthenticatedSession(
      session,
      sink,
      session.connectionGeneration,
    );
    _releaseOutgoingAuthForSink(sink);
    _releaseIncomingAuthForSink(sink);
    _completeDeviceRepairIfNeeded(
      _pendingOutgoingBySink[sink],
      storedDevice.uid,
    );
    _recordAuthenticatedReconnect(session, sink, storedDevice);
    _completeSocketAuth(sink, true, '');
    _deletedPeerDiscoverySuppressions.remove(storedDevice.uid);
    _startKeepaliveTimer(storedDevice.uid, sink);
    _dispatchToAll((event) => event.onConnect());
    if (_manageSharedCoordinators) {
      _ignoreFuture(
        RemoteInputWorkspaceCoordinator.shared.handlePeerReconnected(
          peerId: storedDevice.uid,
          host: storedDevice.host,
          port: storedDevice.port,
          isMutuallyTrusted:
              storedDevice.auth &&
              storedDevice.identityPublicKey.isNotEmpty &&
              storedDevice.identityPublicKey == session.remoteIdentityPublicKey,
          remoteCanInject: supportsRemoteInputWorkspaceGraphFor(
            storedDevice.uid,
          ),
          sendControlTo: sendRemoteInputControlTo,
        ),
        context: 'restore remote input workspace peer',
      );
    }
    if (session.role == PeerSocketRole.server) {
      _dispatchToAll((event) => event.afterAuth(true, storedDevice));
    }
    _peers.closeDeferredSupersededSink(session);
    if (_peers.linkForSink(sink)?.takeSupersededOnAuth() == true ||
        _transferEngine.hasSupersededOutgoingForPeer(session.remotePeerId)) {
      _ignoreFuture(
        _transferEngine.resumeSupersededOutgoingForPeer(
          session.remotePeerId,
          newGeneration: session.connectionGeneration,
        ),
        context: 'resume superseded peer transfers',
      );
    }
    _ignoreFuture(
      _transferEngine.markRecoverableTransfersPausedForPeer(
        session.remotePeerId,
      ),
      context: 'pause recoverable peer transfers',
    );
  }

  bool _isSameSession(
    PeerSocketSession session, WebSocketSink sink, int generation,
  ) => identical(_peers.sessionForSink(sink), session) &&
      session.connectionGeneration == generation;

  bool _isCurrentSession(
    PeerSocketSession session, WebSocketSink sink, int generation,
  ) => _isSameSession(session, sink, generation) && !session.isClosed;

  void _requireCurrentSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    if (!_isCurrentSession(session, sink, generation)) {
      throw const AuthHandshakeException('session_expired');
    }
    if (session.role == PeerSocketRole.client && !session.isAuthenticated) {
      final attempt = _pendingOutgoingBySink[sink];
      if (attempt == null || !_isPendingPolicyCurrent(attempt)) {
        throw const AuthHandshakeException('session_expired');
      }
    }
  }

  void _requireCurrentAuthenticationCommit(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    _requireCurrentSession(session, sink, generation);
    if (session.role == PeerSocketRole.server) {
      if (!_isSessionPeerPolicyCurrent(session)) {
        throw const AuthHandshakeException('session_expired');
      }
      return;
    }
    final attempt = _pendingOutgoingBySink[sink];
    if (attempt == null || !_isPendingPolicyCurrent(attempt)) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  bool _isSessionPeerPolicyCurrent(PeerSocketSession session) {
    final startedRevision = _sessionStartedPolicyRevisions[session];
    if (startedRevision == null || session.remotePeerId.isEmpty) {
      return false;
    }
    return (_peerInvalidationRevisions[session.remotePeerId] ?? 0) <=
            startedRevision &&
        _isPeerAuthenticationAllowed(
          session.remotePeerId,
          allowTrustRepair: true,
        );
  }

  DeviceData? _rollbackPreviousDevice(
    PeerSocketSession session,
    DeviceData? previous,
  ) {
    final startedRevision = _sessionStartedPolicyRevisions[session];
    final invalidationRevision =
        _peerInvalidationRevisions[session.remotePeerId] ?? 0;
    if (startedRevision == null || invalidationRevision <= startedRevision) {
      return previous;
    }
    return switch (_peerPolicyDispositions[session.remotePeerId]) {
      _PeerPolicyDisposition.deviceDeleted => null,
      _PeerPolicyDisposition.trustRevoked => previous?.copyWith(auth: false),
      _PeerPolicyDisposition.manualDisconnect || null => previous,
    };
  }

  void _requireCurrentAuthenticatedSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    _requireCurrentSession(session, sink, generation);
    if (!session.isAuthenticated) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  void _requireCurrentBusinessSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    _requireCurrentAuthenticatedSession(session, sink, generation);
    _peers.validateBusinessSession(session, sink, generation);
  }

  PeerProfile _requireRemoteProfileForSession(PeerSocketSession session) =>
      _peers.requireRemoteProfileForSession(session);

  void _requireCurrentRegisterableSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    _requireCurrentSession(session, sink, generation);
    if (!session.isAuthenticationReady) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  Future<void> _sendUpgradeRequired(
    WebSocketSink sink,
    PeerSocketSession session, {
    String action = 'upgrade_required',
  }) async {
    final payload = jsonEncode(<String, Object?>{
      'action': action,
      'version': PeerSocketSession.protocolVersion,
      'minVersion': PeerSocketSession.minimumProtocolVersion,
      'maxVersion': PeerSocketSession.protocolVersion,
    });
    final message = _buildMessage(
      MessageEnum.Auth,
      payload,
      action,
      '',
      0,
      false,
      senderOverride: session.localProfile.uid,
      receiverOverride: session.remotePeerId,
    );
    await _sendMessageData(message, sink: sink, rawAuth: true);
  }

  Future<void> _handleWhisperFrameV3(
    WhisperFrameV3 frame, {
    WebSocketSink? sink,
    required bool asServer,
    required PeerSocketSession session,
  }) async {
    if (session.isAuthenticated) {
      if (sink == null) {
        throw const WireInputRejected(WireInputReason.sessionNotCurrent);
      }
      _requireCurrentBusinessSession(
        session,
        sink,
        session.connectionGeneration,
      );
      _pingTracker.noteInboundActivity(session.remotePeerId);
    }
    if (!session.isAuthenticated && frame.type != WhisperFrameType.message) {
      throw const WireInputRejected(WireInputReason.sessionNotAuthenticated);
    }
    if ((frame.type == WhisperFrameType.fileData ||
            frame.type == WhisperFrameType.browseData ||
            frame.type == WhisperFrameType.browseWrite) &&
        frame.payload.length > _maxFileDataPayloadBytes) {
      throw const WireInputRejected(WireInputReason.transferPayloadInvalid);
    }
    switch (frame.type) {
      case WhisperFrameType.message:
        WireInputPolicy.validateMessageFrame(frame).requireAccepted();
        await _listen(
          frame.payload,
          sink: sink,
          allowFrame: false,
          asServer: asServer,
          session: session,
        );
        break;
      case WhisperFrameType.fileOffer:
      case WhisperFrameType.fileData:
      case WhisperFrameType.fileReady:
      case WhisperFrameType.fileAck:
      case WhisperFrameType.fileComplete:
      case WhisperFrameType.fileCancel:
      case WhisperFrameType.fileError:
        await _transferEngine.handleFrame(
          TransferConnectionBinding(
            peerId: session.remotePeerId,
            generation: session.connectionGeneration,
          ),
          frame,
          requireCurrent: () => _requireCurrentBusinessSession(
            session,
            sink!,
            session.connectionGeneration,
          ),
        );
        break;
      case WhisperFrameType.clipboardOffer:
      case WhisperFrameType.clipboardRequest:
      case WhisperFrameType.clipboardClear:
      case WhisperFrameType.clipboardError:
        if (!(await LocalSetting().instance()).clipboard) {
          return;
        }
        final clipboardSessionId = _remoteClipboardFrameSessionId(frame);
        try {
          await _remoteClipboardTransfer.handleFrame(
            TransferConnectionBinding(
              peerId: session.remotePeerId,
              generation: session.connectionGeneration,
            ),
            frame,
            prepareImages:
                frame.type == WhisperFrameType.clipboardOffer &&
                await LocalSetting().clipboardAutoSync(),
          );
        } on Exception catch (error) {
          // An offer that crossed the end of a sharing session, a temporary
          // file that could not be written: only this clipboard is lost.
          // Thrown on, it ended the whole connection, and the side that threw
          // never reconnects after a protocol failure.
          logClipboardSync(
            ClipboardSyncStep.frameDropped,
            kind: frame.type,
            error: error,
          );
          return;
        }
        if (frame.type == WhisperFrameType.clipboardOffer &&
            clipboardSessionId != null) {
          await _handleWorkspaceClipboardOffer(
            peerId: session.remotePeerId,
            sessionId: clipboardSessionId,
          );
        } else if (frame.type == WhisperFrameType.clipboardClear &&
            clipboardSessionId != null) {
          await _handleWorkspaceClipboardClear(
            peerId: session.remotePeerId,
            sessionId: clipboardSessionId,
          );
        }
        break;
      case WhisperFrameType.browseData:
        RemoteFilesClient.handleData(
          remotePeerId: session.remotePeerId,
          sessionId: frame.transferId,
          requestId: frame.sequence,
          data: Uint8List.fromList(frame.payload),
        );
        break;
      case WhisperFrameType.browseWrite:
        // A disk write: never hold this peer's other frames for it.
        unawaited(
          FileBrowseHost.shared
              .handleWrite(
                remotePeerId: session.remotePeerId,
                transferId: frame.transferId,
                requestId: frame.sequence,
                offset: frame.offset,
                data: Uint8List.fromList(frame.payload),
              )
              .catchError((Object error) {
                logger.i('挂载写入失败: ${error.runtimeType}');
              }),
        );
        break;
    }
  }

  Future<void> _listen(
    Uint8List data, {
    WebSocketSink? sink,
    bool allowFrame = true,
    required bool asServer,
    required PeerSocketSession session,
  }) async {
    if (allowFrame && WhisperFrameV3.looksLikeFrame(data)) {
      await _handleWhisperFrameV3(
        WhisperFrameV3.decode(data),
        sink: sink,
        asServer: asServer,
        session: session,
      );
      return;
    }
    final streamPeerId = _peerIdForSink(sink);

    String str = "";
    MessageData message = MessageData(
      id: 0,
      sender: sender,
      receiver: '',
      name: "",
      clipboard: false,
      size: 0,
      type: MessageEnum.UNKONWN,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      uuid: '',
      acked: false,
      path: '',
      md5: '',
    );
    try {
      str = utf8.decode(data);
      Map<String, dynamic> json = jsonDecode(str);
      message = decodeWireMessage(json);
    } catch (_) {
      // 需同时容忍 Error:type 以枚举序号上线,新版对端发来的越界序号
      // 会抛 RangeError(不是 Exception),此处降级为 UNKONWN 消息继续。
    }
    final incomingPeerId = session.isAuthenticated
        ? session.remotePeerId
        : (message.sender.isNotEmpty ? message.sender : streamPeerId);
    void requireCurrentBusiness() {
      if (!session.isAuthenticated || sink == null) {
        throw const WireInputRejected(WireInputReason.sessionNotCurrent);
      }
      _requireCurrentBusinessSession(
        session,
        sink,
        session.connectionGeneration,
      );
    }

    if (!session.isAuthenticated && message.type != MessageEnum.Auth) {
      throw const WireInputRejected(WireInputReason.sessionNotAuthenticated);
    }
    if (session.isAuthenticated) {
      requireCurrentBusiness();
      WireInputPolicy.validateMessage(
        message,
        authenticatedPeerId: session.remotePeerId,
        localPeerId: session.localProfile.uid,
      ).requireAccepted();
    }
    if (message.type == MessageEnum.Text && !message.clipboard) {
      final replay = await _claimIncomingTextMessage(
        message,
        requireCurrent: requireCurrentBusiness,
      );
      requireCurrentBusiness();
      switch (replay.decision) {
        case WireMessageReplayDecision.accept:
          message = replay.message!;
          break;
        case WireMessageReplayDecision.duplicate:
          message = replay.message!;
          _dispatchToAll((event) => event.onMessage(message));
          await _ackMessage(message);
          return;
        case WireMessageReplayDecision.conflict:
          throw const AuthHandshakeException('message_uuid_conflict');
      }
    }

    switch (message.type) {
      case MessageEnum.Auth:
        {
          if (sink == null) {
            session.close();
            return;
          }
          await _handleAuthMessage(message, sink: sink, session: session);
          break;
        }
      case MessageEnum.Ack:
        {
          if (sink == null) {
            throw const WireInputRejected(WireInputReason.sessionNotCurrent);
          }
          final database = _database;
          final acknowledged = await WireInputPolicy.acknowledgeOutgoing(
            database: database,
            acknowledgement: message,
            authenticatedPeerId: session.remotePeerId,
            localPeerId: session.localProfile.uid,
            requireCurrent: () => _requireCurrentBusinessSession(
              session,
              sink,
              session.connectionGeneration,
            ),
          );
          if (acknowledged != null) {
            _outgoingTextAcknowledgements.acknowledge(
              session.remotePeerId,
              acknowledged.uuid,
            );
            _dispatchToAll((event) => event.onMessage(acknowledged));
          }
          break;
        }
      case MessageEnum.Text:
        {
          logger.i(
            "收到文本消息, uuid: ${message.uuid}, clipboard: ${message.clipboard}",
          );
          if (message.clipboard) {
            if ((await LocalSetting().instance()).clipboard) {
              logClipboardSync(ClipboardSyncStep.received);
              requireCurrentBusiness();
              await _relayWorkspaceClipboardText(
                message,
                sourcePeerId: session.remotePeerId,
              );
              requireCurrentBusiness();
              await ClipboardSyncCoordinator.shared.applyRemoteText(
                message.content ?? "",
              );
            }
            requireCurrentBusiness();
            await _ackMessage(message);
            return;
          }
          requireCurrentBusiness();
          _dispatchToAll((event) => event.onMessage(message));
          await _ackMessage(message);
          break;
        }
      case MessageEnum.Notification:
        {
          final decoded = jsonDecode(message.content ?? "{}");
          final data = decoded is Map ? decoded : const <String, Object?>{};
          final ignoreNotification = await LocalSetting()
              .ignoreAndroidNotification();
          requireCurrentBusiness();
          if (!ignoreNotification) {
            if (supportNotification() && data['text'] != null) {
              unawaited(
                NotificationHelper().showNotification(
                  title: "【${data['app']}】 ${data['title']}",
                  body: data['text'] ?? "",
                ),
              );
              if (isVerificationCodeNotificationPackage(data['package'])) {
                var code = verifyCode(
                  '${data["title"] ?? ""}\n${data["text"] ?? ""}',
                );
                if (code.isNotEmpty && await LocalSetting().copyVerify()) {
                  requireCurrentBusiness();
                  await copyToClipboard(code);
                }
              }
            }
          }
          requireCurrentBusiness();
          _dispatchToAll((event) => event.onMessage(message));
          await _ackMessage(message);
          break;
        }
      case MessageEnum.Heartbeat:
        {
          if (message.sender == sender) {
            return;
          }
          final heartbeatPeerId = incomingPeerId ?? message.sender;
          if (message.message == heartbeatPingTag) {
            final pong = _pingTracker.buildPongPayload(message.content);
            if (pong != null && heartbeatPeerId.isNotEmpty) {
              unawaited(_sendHeartbeatControl(heartbeatPongTag, pong, heartbeatPeerId, sink: sink));
            }
            break;
          }
          if (message.message == heartbeatPongTag) {
            if (heartbeatPeerId.isNotEmpty) {
              _pingTracker.completePong(heartbeatPeerId, message.content);
            }
            break;
          }
          await _refreshRemoteProfileFromHeartbeat(
            message,
            peerId: incomingPeerId,
            requireCurrent: requireCurrentBusiness,
          );
          requireCurrentBusiness();
          if (message.message == heartbeatProfileRequestTag) {
            unawaited(_heartBeat(peerId: incomingPeerId, sink: sink));
          }
          break;
        }
      case MessageEnum.File:
        // WSP2 可续传接收协议已删除,新版对端只通过 WhisperFrameV3
        // (fileOffer/fileData/...) 传输文件,纯 JSON 的 File 消息不再处理。
        break;
      case MessageEnum.TransferControl:
        // WSP2 可续传控制协议已删除,枚举值保留以兼容历史存储数据。
        break;
      case MessageEnum.AudioControl:
        // The one-to-one sound of protocol 15 and earlier; the enum value
        // stays for stored rows. Sound is AudioGroupControl only.
        break;
      case MessageEnum.WindowStreamControl:
        {
          final json =
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>;
          WireInputPolicy.validateControlEnvelope(
            json,
            allowedActions: _windowStreamControlActions,
          ).requireAccepted();
          final control = WindowStreamControlMessage.fromJson(json);
          WireInputPolicy.validateControlSessionId(
            messageId: message.uuid,
            sessionId: control.sessionId,
          ).requireAccepted();
          WireInputPolicy.validatePeerPair(
            sourcePeerId: control.viewerPeerId,
            sinkPeerId: control.hostPeerId,
            authenticatedPeerId: session.remotePeerId,
            localPeerId: session.localProfile.uid,
          ).requireAccepted();
          final weAreHost = control.hostPeerId == session.localProfile.uid;
          // Both ends may end a stream at once (the host's window went away
          // while the viewer saw its picture stop): a stop or error for a
          // session this side already ended is expected, not a protocol
          // violation that drops the whole connection.
          if (control.isTerminal &&
              !control.isInitial &&
              !_wireControlSessions.knows(
                namespace: WindowStreamHost.namespace,
                sessionId: control.sessionId,
              )) {
            await _ackMessage(message);
            break;
          }
          _wireControlSessions
              .validateAndRemember(
                namespace: WindowStreamHost.namespace,
                sessionId: control.sessionId,
                sourcePeerId: control.viewerPeerId,
                sinkPeerId: control.hostPeerId,
                authenticatedPeerId: session.remotePeerId,
                localPeerId: session.localProfile.uid,
                isInitialOffer: control.isInitial,
                isIncoming: weAreHost,
                // Viewer-first sessions arrive at a viewer reversed; a host's
                // offer arrives there in its natural direction.
                reverseInitialDirection: !weAreHost && !control.isHostInitiated,
              )
              .requireAccepted();
          requireCurrentBusiness();
          final remoteDevice = _requireRemoteProfileForSession(session).device;
          var releaseLater = false;
          try {
            if (weAreHost) {
              // Only mutually trusted peers may see or drive this desktop.
              final storedRemote = await _database.fetchDevice(
                remoteDevice.uid,
              );
              requireCurrentBusiness();
              final trusted =
                  storedRemote?.auth == true &&
                  storedRemote?.identityPublicKey.isNotEmpty == true &&
                  storedRemote?.identityPublicKey ==
                      session.remoteIdentityPublicKey &&
                  session.isAuthenticated;
              final remotePeerId = session.remotePeerId;
              Future<bool> reply(WindowStreamControlMessage outgoing) =>
                  sendWindowStreamControlTo(remotePeerId, outgoing);
              if (!trusted || !supportsWindowStreamSource()) {
                if (control.isInitial) {
                  await reply(
                    control.reply(
                      WindowStreamControlAction.reject,
                      payload: {
                        'reason': trusted ? 'unsupported' : 'untrusted',
                      },
                    ),
                  );
                }
              } else {
                // Catalogs, icons and thumbnails take the capture framework
                // seconds. Answering them here would hold every later
                // message of this peer (heartbeats included) until the
                // phone gave up and reconnected; replies go to whichever
                // session is current when they are ready.
                releaseLater = control.isTerminal;
                unawaited(
                  WindowStreamHost.shared
                      .handleControl(
                        control,
                        remotePeerId: remotePeerId,
                        send: reply,
                      )
                      .catchError((Object error) {
                        logger.i('窗口流转请求失败: ${error.runtimeType}');
                      })
                      .whenComplete(() async {
                        if (releaseLater) {
                          await _releaseTerminalControl(
                            namespace: WindowStreamHost.namespace,
                            route: WindowStreamHost.route,
                            peerId: remotePeerId,
                            sessionId: control.sessionId,
                          );
                        }
                      }),
                );
              }
            } else {
              session.withMediaSendKey(
                (sendKey) => session.withMediaReceiveKey(
                  (receiveKey) => WindowStreamViewer.shared.handleControl(
                    control,
                    remotePeerId: session.remotePeerId,
                    remoteHost: remoteDevice.host,
                    sendKey: sendKey,
                    receiveKey: receiveKey,
                  ),
                ),
              );
            }
          } finally {
            if (control.isTerminal && !releaseLater) {
              await _releaseTerminalControl(
                namespace: WindowStreamHost.namespace,
                route: WindowStreamHost.route,
                peerId: session.remotePeerId,
                sessionId: control.sessionId,
              );
            }
          }
          requireCurrentBusiness();
          await _ackMessage(message);
          break;
        }
      case MessageEnum.FileBrowseControl:
        {
          final json =
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>;
          WireInputPolicy.validateControlEnvelope(
            json,
            allowedActions: FileBrowseMessage.allActions,
          ).requireAccepted();
          final control = FileBrowseMessage.fromJson(json);
          WireInputPolicy.validateControlSessionId(
            messageId: message.uuid,
            sessionId: control.sessionId,
          ).requireAccepted();
          WireInputPolicy.validatePeerPair(
            sourcePeerId: control.clientPeerId,
            sinkPeerId: control.hostPeerId,
            authenticatedPeerId: session.remotePeerId,
            localPeerId: session.localProfile.uid,
          ).requireAccepted();
          final weAreHost = control.hostPeerId == session.localProfile.uid;
          _wireControlSessions
              .validateAndRemember(
                namespace: _fileBrowseNamespace,
                sessionId: control.sessionId,
                sourcePeerId: control.clientPeerId,
                sinkPeerId: control.hostPeerId,
                authenticatedPeerId: session.remotePeerId,
                localPeerId: session.localProfile.uid,
                isInitialOffer: control.isInitial,
                isIncoming: weAreHost,
                reverseInitialDirection: !weAreHost,
              )
              .requireAccepted();
          requireCurrentBusiness();
          final remoteDevice = _requireRemoteProfileForSession(session).device;
          final remotePeerId = session.remotePeerId;
          if (weAreHost) {
            final trusted = await _fileBrowseTrustCache.isTrusted(
              session,
              _database.fetchDevice,
            );
            requireCurrentBusiness();
            if (!trusted) {
              if (control.isInitial) {
                await sendFileBrowseControlTo(
                  remotePeerId,
                  control.reply(FileBrowseAction.denied),
                );
              }
            } else {
              // Asking the user takes up to a minute: never hold this
              // peer's other messages for it.
              unawaited(
                FileBrowseHost.shared
                    .handle(
                      control,
                      remotePeerId: remotePeerId,
                      deviceName: remoteDevice.label,
                    )
                    .catchError((Object error) {
                      logger.i('文件浏览请求失败: ${error.runtimeType}');
                    }),
              );
            }
          } else {
            RemoteFilesClient.handle(control, remotePeerId: remotePeerId);
          }
          if (control.isTerminal) {
            _wireControlSessions.forget(
              namespace: _fileBrowseNamespace,
              sessionId: control.sessionId,
            );
          }
          requireCurrentBusiness();
          await _ackMessage(message);
          break;
        }
      case MessageEnum.AudioGroupControl:
        {
          final json =
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>;
          WireInputPolicy.validateControlEnvelope(
            json,
            allowedActions: _audioGroupControlActions,
          ).requireAccepted();
          final control = AudioGroupControlMessage.fromJson(json);
          WireInputPolicy.validateControlSessionId(
            messageId: message.uuid,
            sessionId: control.sessionId,
          ).requireAccepted();
          WireInputPolicy.validatePeerPair(
            sourcePeerId: control.sourcePeerId,
            sinkPeerId: control.sinkPeerId,
            authenticatedPeerId: session.remotePeerId,
            localPeerId: session.localProfile.uid,
          ).requireAccepted();
          // A stop or report for a session this device doesn't know (it
          // restarted since, or the session ended here first) is no reason
          // to drop the connection, and the transfers and offers on it.
          if (control.action.mayOutliveSession &&
              !_wireControlSessions.knows(
                namespace: 'audio-group',
                sessionId: control.sessionId,
              )) {
            requireCurrentBusiness();
            await _ackMessage(message);
            break;
          }
          _wireControlSessions
              .validateAndRemember(
                namespace: 'audio-group',
                sessionId: control.sessionId,
                sourcePeerId: control.sourcePeerId,
                sinkPeerId: control.sinkPeerId,
                authenticatedPeerId: session.remotePeerId,
                localPeerId: session.localProfile.uid,
                isInitialOffer:
                    control.action == AudioGroupControlAction.groupOffer ||
                    control.action == AudioGroupControlAction.sinkJoinRequest,
                isIncoming: true,
                reverseInitialDirection:
                    control.action == AudioGroupControlAction.sinkJoinRequest,
                context: '${control.groupId}\u0000${control.streamId}',
              )
              .requireAccepted();
          if (control.action == AudioGroupControlAction.groupDialBack) {
            _answerAudioDialBack(session, control);
            await _ackMessage(message);
            break;
          }
          final self = await LocalSetting().instance();
          requireCurrentBusiness();
          final remoteDevice = _requireRemoteProfileForSession(session).device;
          final isTerminal =
              control.action == AudioGroupControlAction.groupReject ||
              control.action == AudioGroupControlAction.groupStop ||
              control.action == AudioGroupControlAction.error;
          try {
            await session.withMediaSendKeyAsync(
              (mediaSendKey) =>
                  AudioGroupCoordinator.shared.handleControlMessage(
                    control,
                    localPeerId: self.uid,
                    remoteHost: remoteDevice.host,
                    remotePort: remoteDevice.port,
                    mediaSendKey: mediaSendKey,
                    sendControl: (_, control) =>
                        sendAudioGroupControlTo(session.remotePeerId, control),
                  ),
            );
          } finally {
            if (isTerminal) {
              await _releaseTerminalControl(
                namespace: 'audio-group',
                route: '/audio',
                peerId: session.remotePeerId,
                sessionId: control.sessionId,
              );
            }
          }
          requireCurrentBusiness();
          await _ackMessage(message);
          break;
        }
      case MessageEnum.RemoteInputControl:
        {
          final json =
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>;
          WireInputPolicy.validateControlEnvelope(
            json,
            allowedActions: _remoteInputControlActions,
          ).requireAccepted();
          final control = RemoteInputControlMessage.fromJson(json);
          WireInputPolicy.validateControlSessionId(
            messageId: message.uuid,
            sessionId: control.sessionId,
          ).requireAccepted();
          WireInputPolicy.validatePeerPair(
            sourcePeerId: control.sourcePeerId,
            sinkPeerId: control.sinkPeerId,
            authenticatedPeerId: session.remotePeerId,
            localPeerId: session.localProfile.uid,
          ).requireAccepted();
          _wireControlSessions
              .validateAndRemember(
                namespace: 'remote-input',
                sessionId: control.sessionId,
                sourcePeerId: control.sourcePeerId,
                sinkPeerId: control.sinkPeerId,
                authenticatedPeerId: session.remotePeerId,
                localPeerId: session.localProfile.uid,
                isInitialOffer:
                    control.action == RemoteInputControlAction.offer,
                isIncoming: true,
              )
              .requireAccepted();
          if (control.action == RemoteInputControlAction.dialBack) {
            _answerInputDialBack(session, control);
            await _ackMessage(message);
            break;
          }
          final self = await LocalSetting().instance();
          requireCurrentBusiness();
          final remoteDevice = _requireRemoteProfileForSession(session).device;
          final storedRemote = await _database.fetchDevice(remoteDevice.uid);
          requireCurrentBusiness();
          final authenticatedSession = _peers.sessionForPeer(remoteDevice.uid);
          final isMutuallyTrusted =
              storedRemote?.auth == true &&
              storedRemote?.identityPublicKey.isNotEmpty == true &&
              storedRemote?.identityPublicKey ==
                  authenticatedSession?.remoteIdentityPublicKey &&
              authenticatedSession?.isAuthenticated == true;
          final remoteProfile = _requireRemoteProfileForSession(session);
          final manual = control.mode == RemoteInputMode.manual;
          final manualAllowed =
              supportsManualRemoteInputSink() &&
              remoteProfile.capabilities.remoteInputManualSourceV1;
          final localCanInject = manual
              ? manualAllowed
              : supportsNativeRemoteInput();
          _remoteInputTrace(
            'remote input recv control ${_remoteInputControlSummary(control)} '
            'local=${self.uid} '
            'remote=${remoteDevice.uid} '
            'remoteAddress=${remoteDevice.host}:${remoteDevice.port} '
            'storedAuth=${storedRemote?.auth == true} '
            'signedSession=${authenticatedSession?.isAuthenticated == true} '
            'mutualTrust=$isMutuallyTrusted '
            'localCanInject=$localCanInject '
            'remoteSupports=${supportsRemoteInputFor(remoteDevice.uid)}',
          );
          final isTerminal =
              control.action == RemoteInputControlAction.reject ||
              control.action == RemoteInputControlAction.stop ||
              control.action == RemoteInputControlAction.error;
          try {
            final handledByWorkspace = await session.withMediaSendKeyAsync(
              (mediaSendKey) =>
                  RemoteInputWorkspaceCoordinator.shared.handleControlMessage(
                    control,
                    localPeerId: self.uid,
                    remoteHost: remoteDevice.host,
                    remotePort: remoteDevice.port,
                    mediaSendKey: mediaSendKey,
                    sendControlTo: (peerId, control) =>
                        sendRemoteInputControlTo(peerId, control),
                  ),
            );
            requireCurrentBusiness();
            if (handledByWorkspace) {
              await _ackMessage(message);
              break;
            }
            await session.withMediaSendKeyAsync(
              (mediaSendKey) =>
                  RemoteInputCoordinator.shared.handleControlMessage(
                    control,
                    localPeerId: self.uid,
                    remoteHost: remoteDevice.host,
                    remotePort: remoteDevice.port,
                    isMutuallyTrusted: isMutuallyTrusted,
                    localCanInject: localCanInject,
                    mediaSendKey: mediaSendKey,
                    sendControl: (control) =>
                        sendRemoteInputControlTo(session.remotePeerId, control),
                    remotePlatform: remoteDevice.platform,
                  ),
            );
            requireCurrentBusiness();
            final inputState = RemoteInputCoordinator.shared.state;
            _remoteInputTrace(
              'remote input handled control ${_remoteInputControlSummary(control)} '
              'state=${inputState.role.name}/${inputState.status.name} '
              'stateSession=${_shortSessionId(inputState.sessionId)} '
              'statePeer=${inputState.peerId} '
              'stateError=${inputState.errorMessage}',
            );
            await _ackMessage(message);
          } finally {
            if (isTerminal) {
              await _releaseTerminalControl(
                namespace: 'remote-input',
                route: '/input',
                peerId: session.remotePeerId,
                sessionId: control.sessionId,
              );
            }
          }
          break;
        }
      default:
        {
          logger.i("未知消息：$str");
        }
    }
  }

  Future<WireMessageReplayClaim> _claimIncomingTextMessage(
    MessageData incoming, {
    void Function()? requireCurrent,
  }) async {
    final database = _database;
    return _wireMessageReplayGuard.claim(
      incoming,
      fetchExisting: database.fetchMessagesByUuid,
      hasExternalClaim: (uuid) async =>
          await database.fetchFileTransfer(uuid) != null,
      persist: (message) {
        requireCurrent?.call();
        return database.insertMessageReturning(message, acked: false);
      },
    );
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

  Future<PeerProfile> _localPeerProfile() async {
    final injected = _localPeerProfileLoader;
    if (injected != null) {
      return injected();
    }
    var device = await LocalSetting().instance(online: true);
    RemoteInputTopology? topology;
    if (supportsNativeRemoteInput()) {
      try {
        topology = await RemoteInputCoordinator.shared.displayTopology();
      } catch (error) {
        _remoteInputTrace('display topology unavailable: $error');
      }
    }
    final hasTopology = topology?.isNotEmpty == true;
    final profile = PeerProfile(
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
      ),
      displayTopology: topology,
      formFactor: await localFormFactor(),
      wake: await localWakeTargetsForProfile(),
      appVersion: await localAppVersion(),
    );
    return profile;
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
      sendRequest: () => _heartBeat(
        profileRefreshRequest: true,
        peerId: peerId,
      ),
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
                    peerId, profile.device.label,
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

  Future<void> _refreshRemoteProfileFromHeartbeat(
    MessageData message, {
    String? peerId,
    void Function()? requireCurrent,
  }) async {
    try {
      final resolvedPeerId = peerId ?? message.sender;
      final previousProfile = resolvedPeerId.isEmpty
          ? null
          : _peers.remoteProfileFor(resolvedPeerId);
      final profile = PeerProfileRefreshTracker.decodeHeartbeatProfile(
        message.content,
        resolvedPeerId: resolvedPeerId,
        previousProfile: previousProfile,
      );
      if (profile == null) return;
      requireCurrent?.call();
      final profileDeviceChanged = PeerProfileRefreshTracker.deviceChanged(
        previousProfile?.device,
        profile.device,
      );
      _setRemoteProfile(profile, peerId: resolvedPeerId);
      if (profile.device.uid.isNotEmpty) {
        requireCurrent?.call();
        await _database.upsertDevice(profile.device);
        requireCurrent?.call();
        if (_manageSharedCoordinators &&
            _peers.isConnectedTo(profile.device.uid)) {
          ConnectionCoordinator().markConnected(
            profile.device,
            select: ConnectionCoordinator().snapshot.activePeerId ==
                resolvedPeerId,
          );
        }
        if (profileDeviceChanged) {
          _dispatchToAll((event) => event.onConnect());
        }
      }
    } on WireInputRejected {
      rethrow;
    } catch (error) {
      _remoteInputTrace('heartbeat profile parse failed: $error');
    }
  }

  Future<void> _ackMessage(MessageData data) async {
    if (data.type != MessageEnum.Text && data.type != MessageEnum.File) {
      return;
    }
    var json = data.toJson();
    json["type"] = MessageEnum.Ack.index;
    json["acked"] = true;
    json["sender"] = data.receiver;
    json["receiver"] = data.sender;
    // logger.i("ack消息, ${data.type.name} uuid: ${data.uuid}");
    await sendAcknowledgementBestEffort(
      send: () =>
          _sendMessageData(decodeWireMessage(json), peerId: data.sender),
      onError: (error, stackTrace) {
        logger.i('send acknowledgement failed: ${error.runtimeType}');
      },
    );
  }

  void _startKeepaliveTimer(String peerId, WebSocketSink sink) {
    _pingTracker.startKeepalive(
      token: sink,
      peerId: peerId,
      interval: _clientHeartbeatInterval,
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
      MessageEnum.Heartbeat, content, tag, '', 0, false,
      senderOverride: localUid, receiverOverride: peerId,
    );
    return _sendMessageData(
      message, peerId: sink == null ? peerId : null, sink: sink,
    );
  }

  bool _isCurrentSinkForPeer(WebSocketSink sink, String peerId) {
    final session = _peers.sessionForSink(sink);
    if (session == null || session.remotePeerId != peerId) return false;
    try {
      _requireCurrentBusinessSession(session, sink, session.connectionGeneration);
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
      '', 0, false,
      senderOverride: profile.device.uid, receiverOverride: targetPeerId,
    );
    await _sendMessageData(
      message, peerId: sink == null ? targetPeerId : null, sink: sink,
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
          namespace: _fileBrowseNamespace,
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
      "",
      "",
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
        namespace: _fileBrowseNamespace,
        sessionId: control.sessionId,
      ),
    );
  }

  /// The bytes a mounted folder on [peerId] asked for, on the same
  /// connection as the session's other replies.
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
    return _peers.sendToAwaitedIfCurrent(binding, frame.encode());
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
    return _peers.sendToAwaitedIfCurrent(binding, frame.encode());
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
      "",
      "",
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
      "",
      "",
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
      "",
      "",
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

  Future<bool> sendMessageTo(
    String peerId,
    String content, {
    bool clipboard = false,
  }) {
    return _outgoingTextSendLocks.synchronized(
      peerId,
      () => _sendMessageToSerialized(peerId, content, clipboard: clipboard),
    );
  }

  /// Sends a quick-send text with a persistent idempotency key and returns
  /// only after the authenticated peer acknowledges the exact message.
  Future<bool> sendQuickTextToAcknowledged(
    String peerId,
    String content, {
    required String source,
    required String intentId,
    required String expectedPublicKeyHash,
    Duration acknowledgementTimeout = const Duration(seconds: 10),
  }) {
    final messageId = stableQuickSendMessageId(
      source: source,
      intentId: jsonEncode(<String>[intentId, expectedPublicKeyHash]),
      peerId: peerId,
    );
    return _outgoingTextSendLocks.synchronized(
      peerId,
      () => _sendQuickTextToAcknowledgedSerialized(
        peerId,
        content,
        messageId: messageId,
        expectedPublicKeyHash: expectedPublicKeyHash,
        acknowledgementTimeout: acknowledgementTimeout,
      ),
    );
  }

  Future<bool> _sendQuickTextToAcknowledgedSerialized(
    String peerId,
    String content, {
    required String messageId,
    required String expectedPublicKeyHash,
    required Duration acknowledgementTimeout,
  }) async {
    if (peerId.isEmpty ||
        acknowledgementTimeout <= Duration.zero ||
        !isConnectedTo(peerId) ||
        content.trim().isEmpty ||
        !isCanonicalTransferId(messageId)) {
      return false;
    }

    var expectedBinding = await _trustedQuickSendBinding(
      peerId,
      expectedPublicKeyHash,
    );
    if (expectedBinding == null) {
      return false;
    }

    final draft = _buildMessage(
      MessageEnum.Text,
      content,
      '',
      '',
      0,
      false,
      uid: messageId,
      receiverOverride: peerId,
    );
    final database = _database;
    final candidates = await database.fetchMessagesByUuid(messageId);
    if (!await _quickSendBindingRemainsTrusted(
      expectedBinding,
      expectedPublicKeyHash,
    )) {
      return false;
    }
    if (await database.fetchFileTransfer(messageId) != null ||
        candidates.any((candidate) => !_isSameQuickText(candidate, draft))) {
      return false;
    }
    if (!await _quickSendBindingRemainsTrusted(
      expectedBinding,
      expectedPublicKeyHash,
    )) {
      return false;
    }

    MessageData selectedMessage;
    var isNew = false;
    if (candidates.isEmpty) {
      selectedMessage = await database.insertMessageReturning(draft);
      isNew = true;
    } else {
      selectedMessage = candidates.firstWhere(
        (candidate) => candidate.acked,
        orElse: () => candidates.first,
      );
      if (selectedMessage.acked) {
        return true;
      }
    }
    if (isNew) {
      _dispatchOutgoingMessage(selectedMessage);
    }

    expectedBinding = await _trustedQuickSendBinding(
      peerId,
      expectedPublicKeyHash,
      expectedBinding: expectedBinding,
    );
    if (expectedBinding == null) {
      return false;
    }

    final acknowledgement = _outgoingTextAcknowledgements.waitFor(
      peerId: peerId,
      messageId: selectedMessage.uuid,
      timeout: acknowledgementTimeout,
    );
    try {
      if (!_quickSendSessionMatches(expectedBinding, expectedPublicKeyHash)) {
        acknowledgement.cancel();
        return false;
      }
      final accepted = await _sendMessageData(selectedMessage, peerId: peerId);
      if (!accepted) {
        acknowledgement.cancel();
        return false;
      }
      return await acknowledgement.future;
    } catch (_) {
      acknowledgement.cancel();
      rethrow;
    }
  }

  Future<TransferConnectionBinding?> _trustedQuickSendBinding(
    String peerId,
    String expectedPublicKeyHash, {
    TransferConnectionBinding? expectedBinding,
  }) async {
    final binding = _peers.currentBinding(peerId);
    if (binding == null ||
        (expectedBinding != null && binding != expectedBinding) ||
        !_quickSendSessionMatches(binding, expectedPublicKeyHash)) {
      return null;
    }
    final stored = await _database.fetchDevice(peerId);
    if (stored == null ||
        !matchesExpectedQuickSendIdentity(
          expectedPublicKeyHash: expectedPublicKeyHash,
          authenticatedIdentityPublicKey:
              _peers.sessionForPeer(peerId)?.remoteIdentityPublicKey ?? '',
          storedTrusted: stored.auth,
          storedIdentityPublicKey: stored.identityPublicKey,
        ) ||
        !_quickSendSessionMatches(binding, expectedPublicKeyHash)) {
      return null;
    }
    return binding;
  }

  Future<bool> _quickSendBindingRemainsTrusted(
    TransferConnectionBinding binding,
    String expectedPublicKeyHash,
  ) async {
    return await _trustedQuickSendBinding(
          binding.peerId,
          expectedPublicKeyHash,
          expectedBinding: binding,
        ) !=
        null;
  }

  bool _quickSendSessionMatches(
    TransferConnectionBinding binding,
    String expectedPublicKeyHash,
  ) {
    final session = _peers.sessionForPeer(binding.peerId);
    return session != null &&
        session.isAuthenticated &&
        session.connectionGeneration == binding.generation &&
        _peers.currentBinding(binding.peerId) == binding &&
        _isPeerAuthenticationAllowed(binding.peerId) &&
        matchesExpectedQuickSendIdentity(
          expectedPublicKeyHash: expectedPublicKeyHash,
          authenticatedIdentityPublicKey: session.remoteIdentityPublicKey,
          storedTrusted: true,
          storedIdentityPublicKey: session.remoteIdentityPublicKey,
        );
  }

  bool _isSameQuickText(MessageData stored, MessageData draft) {
    return stored.sender == draft.sender &&
        stored.receiver == draft.receiver &&
        stored.name == draft.name &&
        stored.clipboard == draft.clipboard &&
        stored.size == draft.size &&
        stored.type == MessageEnum.Text &&
        stored.content == draft.content &&
        stored.message == draft.message &&
        stored.uuid == draft.uuid &&
        stored.path == draft.path &&
        stored.md5 == draft.md5 &&
        stored.fileTimestamp == draft.fileTimestamp;
  }

  Future<bool> _sendMessageToSerialized(
    String peerId,
    String content, {
    required bool clipboard,
  }) async {
    if (peerId.isEmpty || !isConnectedTo(peerId)) {
      return false;
    }
    if (clipboard && content.isEmpty) {
      var str = await readClipboardTextForSync() ?? "";
      content = str.trimRight();
    }
    if (content.trim().isEmpty) {
      return false;
    }
    final draft = _buildMessage(
      MessageEnum.Text,
      content,
      "",
      "",
      0,
      clipboard,
      receiverOverride: peerId,
    );
    if (clipboard) {
      logger.i("发送剪贴板文本, uuid: ${draft.uuid}");
      return _sendMessageData(draft, peerId: peerId);
    }
    final database = _database;
    final retry = await _outgoingTextRetries.resolve(
      draft,
      fetchByUuid: database.fetchMessagesByUuid,
    );
    if (retry.alreadyAcknowledged) {
      _dispatchOutgoingMessage(retry.message!);
      return true;
    }

    final prepared = await prepareOutgoingTextWithRetryIdentity(
      draft: draft,
      retry: retry.message,
      persist: database.insertMessageReturning,
    );
    final selectedMessage = prepared.message;
    if (prepared.isNew) {
      _dispatchOutgoingMessage(selectedMessage);
    }
    try {
      logger.i("发送消息, uuid: ${selectedMessage.uuid}");
      final accepted = await _sendMessageData(selectedMessage, peerId: peerId);
      if (accepted) {
        _outgoingTextRetries.clearAccepted(selectedMessage);
      } else {
        _outgoingTextRetries.rememberFailure(selectedMessage);
      }
      return accepted;
    } catch (_) {
      _outgoingTextRetries.rememberFailure(selectedMessage);
      rethrow;
    }
  }

  Future<void> sendNotification(
    String? package,
    String? title,
    String? text,
  ) async {
    final targets = connectedPeerIds.toList(growable: false);
    if (targets.isEmpty || (package == null && title == null && text == null)) {
      return;
    }
    var content = {
      "app": await appName(package),
      "package": package,
      "title": title,
      "text": text,
    };
    final encodedContent = jsonEncode(content);
    for (final peerId in targets) {
      final message = _buildMessage(
        MessageEnum.Notification,
        encodedContent,
        "",
        "",
        0,
        false,
        receiverOverride: peerId,
      );
      await _sendMessageData(message, peerId: peerId);
    }
  }

  Future<bool> publishRemoteClipboard({
    required String peerId,
    required String sessionId,
    required List<RemoteClipboardLocalItem> items,
  }) async {
    if (!(await LocalSetting().instance()).clipboard ||
        !await LocalSetting().clipboardAutoSync()) {
      await _remoteClipboardTransfer.clearSession(
        sessionId,
        notifyPeer: true,
        peerId: peerId,
      );
      return false;
    }
    return _remoteClipboardTransfer.publish(
      peerId: peerId,
      sessionId: sessionId,
      items: items,
    );
  }

  Future<RemoteClipboardPasteResult> prepareRemoteClipboardPaste({
    required String peerId,
    required String sessionId,
  }) async {
    if (!(await LocalSetting().instance()).clipboard ||
        !await LocalSetting().clipboardAutoSync()) {
      return RemoteClipboardPasteResult.notAvailable;
    }
    return _remoteClipboardTransfer.preparePaste(
      peerId: peerId,
      sessionId: sessionId,
    );
  }

  void markLocalWorkspaceClipboard() {
    _workspaceClipboardRevision++;
    _workspaceClipboardOrigin = null;
  }

  Future<RemoteClipboardPasteResult> prepareLatestWorkspaceClipboardPaste() {
    final origin = _workspaceClipboardOrigin;
    if (origin == null) {
      return Future<RemoteClipboardPasteResult>.value(
        RemoteClipboardPasteResult.notAvailable,
      );
    }
    final offer = _remoteClipboardTransfer.remoteOffer(
      peerId: origin.peerId,
      sessionId: origin.sessionId,
    );
    if (offer == null || offer.offerId != origin.offerId) {
      _workspaceClipboardOrigin = null;
      return Future<RemoteClipboardPasteResult>.value(
        RemoteClipboardPasteResult.notAvailable,
      );
    }
    return prepareRemoteClipboardPaste(
      peerId: origin.peerId,
      sessionId: origin.sessionId,
    );
  }

  /// The paste shortcut pressed on this device for files copied on the one
  /// it controls. True: press it again now. Files still on their way are
  /// waited for on screen, without holding up the shortcut's caller.
  Future<bool> pasteLatestWorkspaceClipboard() async {
    final origin = _workspaceClipboardOrigin;
    final front = foregroundWindowToken();
    final folder = foregroundFolder();
    final pending = prepareLatestWorkspaceClipboardPaste();
    final early = await pending
        .then<RemoteClipboardPasteResult?>((result) => result)
        .timeout(remoteClipboardPasteHoldLimit, onTimeout: () => null);
    if (early != null) {
      return early != RemoteClipboardPasteResult.failed;
    }
    if (origin == null) {
      return false;
    }
    return remoteClipboardPasteWatch.follow(
      sessionId: origin.sessionId,
      pending: pending,
      front: front,
      folder: folder,
    );
  }

  Future<void> clearRemoteClipboardSession({
    required String peerId,
    required String sessionId,
    bool notifyPeer = false,
    bool endsPaste = false,
  }) {
    return _remoteClipboardTransfer.clearSession(
      sessionId,
      notifyPeer: notifyPeer,
      peerId: peerId,
      endsPaste: endsPaste,
    );
  }

  /// Whether [transferId] brings files for a paste, which the floating
  /// island shows instead of the window's.
  bool carriesRemoteClipboardTransfer(String transferId) =>
      _remoteClipboardTransfer.carriesTransfer(transferId);

  bool remoteClipboardOwnsPaths({
    required String sessionId,
    required List<String> paths,
  }) {
    return _remoteClipboardTransfer.ownsClipboardPaths(sessionId, paths);
  }

  bool _validateRemoteClipboardSession({
    required String peerId,
    required String sessionId,
    required bool sourceIsLocal,
  }) {
    final inputSession = _remoteInputManager.session(sessionId);
    final socketSession = _peers.sessionForPeer(peerId);
    if (inputSession?.state != RemoteInputSessionState.connected ||
        inputSession?.remoteClipboardV1 != true ||
        socketSession == null ||
        !socketSession.isAuthenticated ||
        _peers.currentBinding(peerId)?.generation !=
            socketSession.connectionGeneration) {
      return false;
    }
    final localPeerId = socketSession.localProfile.uid;
    final participantsMatch =
        (inputSession!.sourcePeerId == localPeerId &&
            inputSession.sinkPeerId == peerId) ||
        (inputSession.sourcePeerId == peerId &&
            inputSession.sinkPeerId == localPeerId);
    return participantsMatch;
  }

  String? _remoteClipboardFrameSessionId(WhisperFrameV3 frame) {
    if (frame.payload.length > 64 * 1024) {
      return null;
    }
    try {
      final value = jsonDecode(utf8.decode(frame.payload));
      if (value is Map && value['sessionId'] is String) {
        return value['sessionId'] as String;
      }
    } on Object {
      return null;
    }
    return null;
  }

  Future<void> _handleWorkspaceClipboardOffer({
    required String peerId,
    required String sessionId,
  }) {
    return _serializeWorkspaceClipboard(() async {
      final offer = _remoteClipboardTransfer.remoteOffer(
        peerId: peerId,
        sessionId: sessionId,
      );
      if (offer == null) {
        return;
      }
      final workspace = RemoteInputWorkspaceCoordinator.shared.snapshot;
      final originTarget = workspace.targets[peerId];
      final legacy = RemoteInputCoordinator.shared.state;
      final isWorkspaceOrigin =
          workspace.isControllerLive &&
          originTarget?.isConnected == true &&
          originTarget?.sessionId == sessionId;
      final isLegacyOrigin =
          legacy.role == RemoteInputRuntimeRole.source &&
          legacy.peerId == peerId &&
          legacy.sessionId == sessionId;
      if (!isWorkspaceOrigin && !isLegacyOrigin) {
        return;
      }
      final revision = ++_workspaceClipboardRevision;
      _workspaceClipboardOrigin = _WorkspaceClipboardOrigin(
        revision: revision,
        peerId: peerId,
        sessionId: sessionId,
        offerId: offer.offerId,
      );
      if (!isWorkspaceOrigin) {
        return;
      }
      for (final target in workspace.targets.values) {
        if (!target.isConnected || target.peerId == peerId) {
          continue;
        }
        if (_workspaceClipboardOrigin?.revision != revision) {
          return;
        }
        await _remoteClipboardTransfer.relayRemoteOffer(
          originPeerId: peerId,
          originSessionId: sessionId,
          targetPeerId: target.peerId,
          targetSessionId: target.sessionId,
        );
      }
    });
  }

  Future<void> _handleWorkspaceClipboardClear({
    required String peerId,
    required String sessionId,
  }) {
    return _serializeWorkspaceClipboard(() async {
      final origin = _workspaceClipboardOrigin;
      if (origin == null ||
          origin.peerId != peerId ||
          origin.sessionId != sessionId) {
        return;
      }
      _workspaceClipboardRevision++;
      _workspaceClipboardOrigin = null;
      final workspace = RemoteInputWorkspaceCoordinator.shared.snapshot;
      if (!workspace.isControllerLive) {
        return;
      }
      for (final target in workspace.targets.values) {
        if (!target.isConnected || target.peerId == peerId) {
          continue;
        }
        await _remoteClipboardTransfer.clearSession(
          target.sessionId,
          notifyPeer: true,
          peerId: target.peerId,
        );
      }
    });
  }

  Future<void> _relayWorkspaceClipboardText(
    MessageData message, {
    required String sourcePeerId,
  }) async {
    final workspace = RemoteInputWorkspaceCoordinator.shared.snapshot;
    final source = workspace.targets[sourcePeerId];
    if (!workspace.isControllerLive || source?.isConnected != true) {
      return;
    }
    markLocalWorkspaceClipboard();
    for (final target in workspace.targets.values) {
      if (!target.isConnected || target.peerId == sourcePeerId) {
        continue;
      }
      await _remoteClipboardTransfer.clearSession(
        target.sessionId,
        notifyPeer: true,
        peerId: target.peerId,
      );
      await sendMessageTo(
        target.peerId,
        message.content ?? '',
        clipboard: true,
      );
    }
  }

  Future<void> _serializeWorkspaceClipboard(Future<void> Function() action) {
    final next = _workspaceClipboardSerial.then((_) => action());
    _workspaceClipboardSerial = next.catchError((_) {});
    return next;
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
