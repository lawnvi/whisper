import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/helper/clipboard_sync.dart';
import 'package:whisper/helper/connection_request_notifications.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/auth_request_gate.dart';
import 'package:whisper/socket/auth_handshake_lifecycle.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/dial_tiebreaker.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/outgoing_text_retry.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/peer_transfer_runtime.dart';
import 'package:whisper/socket/socket_admission.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/transport_close_guard.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/socket/wire_message_replay.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:path/path.dart' as p;

import '../helper/file.dart';
import '../helper/notification.dart';

abstract class ISocketEvent {
  void onError(String message);

  void onNotice(String message);

  void onMessage(MessageData messageData);

  void onTransferUpdated(TransferSnapshot snapshot);

  void onClose();

  void onConnect();

  void onPairing(PairingRequest request, void Function(bool) resolve);

  void afterAuth(bool allow, DeviceData? device);
}

final class _SocketAuthResult {
  const _SocketAuthResult(this.allow, this.message);

  final bool allow;
  final String message;
}

typedef _IdentityPinPlan = ({
  PairingReason? reason,
  String expectedPublicKey,
});

typedef PeerReconnectControllerFactory = PeerReconnectController Function({
  required ReconnectAttempt attempt,
  required ReconnectEligibility eligibility,
});

Uint8List _secureMediaProofRandomBytes(int length) {
  final random = math.Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

typedef LocalPeerProfileLoader = Future<PeerProfile> Function();

enum ConnectionAuthCommitStage {
  beforePersistence,
  afterPersistence,
  beforeRegistration,
  afterRegistration,
}

typedef ConnectionAuthCommitBarrier = Future<void> Function(
  ConnectionAuthCommitStage stage,
  String peerId,
);

typedef AuthEnvelopeObserver = void Function(
  PeerSocketRole role,
  AuthEnvelope envelope,
);

enum PeerDisconnectCause {
  network,
  watchdog,
  manual,
  trustRevoked,
  deviceDeleted,
  superseded,
  protocolFailure,
  localFailure,
  managerClose,
}

enum _PeerPolicyDisposition { manualDisconnect, trustRevoked, deviceDeleted }

enum _PeerAuthSuppressionReason {
  manualDisconnect,
  trustRevoked,
  deviceDeleted,
}

final class ServerStartResult {
  const ServerStartResult.success(this.port)
      : isSuccess = true,
        error = null;

  const ServerStartResult.failure(this.error)
      : isSuccess = false,
        port = 0;

  final bool isSuccess;
  final int port;
  final Object? error;
}

final class _PendingOutgoingConnection {
  _PendingOutgoingConnection(
    this.request, {
    required this.globalPolicyEpoch,
    required this.peerPolicyEpoch,
    required this.startedPolicyRevision,
    required this.socketCloseTimeout,
  }) : httpClient = HttpClient();

  final ConnectionAttemptRequest request;
  final int globalPolicyEpoch;
  int peerPolicyEpoch;
  int startedPolicyRevision;
  final Duration socketCloseTimeout;
  final HttpClient httpClient;
  WebSocketChannel? channel;
  HttpClientRequest? transportRequest;
  PeerSocketSession? session;
  String verifiedPeerId = '';
  Future<ConnectionAttemptResult>? completion;
  TransportCloseGuard? _sinkCloseGuard;
  bool isCancelled = false;
  bool isReady = false;
  bool allowsDeviceRepair = false;
  bool allowsTrustRepair = false;
  ConnectionAttemptReason cancellationReason =
      ConnectionAttemptReason.requestCancelled;

  Future<void> cancel({
    ConnectionAttemptReason reason = ConnectionAttemptReason.requestCancelled,
  }) {
    session?.close();
    if (!isCancelled) {
      cancellationReason = reason;
    }
    isCancelled = true;
    transportRequest?.abort(const _OutgoingConnectionCancelled());
    httpClient.close(force: true);
    final sink = channel?.sink;
    if (sink != null) {
      _sinkCloseGuard ??= TransportCloseGuard(
        close: () async {
          await sink.close();
        },
        timeout: socketCloseTimeout,
      );
      unawaited(
        _sinkCloseGuard!.close().catchError((Object _, StackTrace __) {}),
      );
    }
    if (isReady && _sinkCloseGuard != null) {
      return _sinkCloseGuard!.close();
    }
    return Future<void>.value();
  }
}

final class _OutgoingConnectionCancelled implements Exception {
  const _OutgoingConnectionCancelled();
}

class WsSvrManager {
  static const Duration _serverPingInterval = Duration(seconds: 45);
  static const Duration _clientHeartbeatInterval = Duration(seconds: 15);
  static const Duration _manualPreemptWaitTimeout = Duration(seconds: 3);
  static const int _maxPreAuthMessageBytes = 256 * 1024;
  static const int _maxAuthenticatedMessageBytes = 1024 * 1024;
  static const int _authenticatedFrameOverhead = 48;
  static const int _maxFileDataPayloadBytes = 512 * 1024;
  static final Set<String> _audioControlActions =
      AudioControlAction.values.map((action) => action.name).toSet();
  static final Set<String> _audioGroupControlActions =
      AudioGroupControlAction.values.map((action) => action.name).toSet();
  static final Set<String> _remoteInputControlActions =
      RemoteInputControlAction.values.map((action) => action.name).toSet();

  static const String _profileRefreshRequestMessage = 'profile-refresh-request';

  static Duration _validateMediaProofTimeout(Duration value) {
    if (value <= Duration.zero) {
      throw ArgumentError.value(value, 'mediaProofTimeout');
    }
    return value;
  }

  static int _validateMaxProvisionalMediaSockets(int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, 'maxProvisionalMediaSockets');
    }
    return value;
  }

  static PeerReconnectController _defaultReconnectControllerFactory({
    required ReconnectAttempt attempt,
    required ReconnectEligibility eligibility,
  }) =>
      PeerReconnectController(attempt: attempt, eligibility: eligibility);
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
  })  : _admission = admission ?? SocketAdmissionController(),
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
        _mediaProofTimeout = _validateMediaProofTimeout(mediaProofTimeout),
        _maxProvisionalMediaSockets =
            _validateMaxProvisionalMediaSockets(maxProvisionalMediaSockets),
        _mediaProofRandomBytes =
            mediaProofRandomBytes ?? _secureMediaProofRandomBytes;

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
  }) : this._internal(
          admission: admission,
          audioManager: audioManager,
          remoteInputManager: remoteInputManager,
          sessionUpgradeTokens: sessionUpgradeTokens,
          audioGroupClaimValidator: audioGroupClaimValidator,
          audioGroupPacketValidator: audioGroupPacketValidator,
          mediaPeerClaimValidator: mediaPeerClaimValidator,
          database: database,
          autoConnectEnabled: autoConnectEnabled,
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
        );

  // 工厂构造函数，返回单例实例
  factory WsSvrManager() {
    return _singleton;
  }

  Uuid uuid = LocalUuid;

  HttpServer? _server;
  WebSocketSink? _sink;
  final PeerConnectionRegistry _peerConnections = PeerConnectionRegistry();
  final Map<WebSocketSink, String> _peerIdsBySink = <WebSocketSink, String>{};
  final Map<WebSocketSink, PeerSocketSession> _sessionsBySink =
      <WebSocketSink, PeerSocketSession>{};
  final Map<String, PeerSocketSession> _sessionsByPeerId =
      <String, PeerSocketSession>{};
  final Map<WebSocketSink, Completer<_SocketAuthResult>> _authResultsBySink =
      <WebSocketSink, Completer<_SocketAuthResult>>{};
  final Map<WebSocketSink, ({String host, int port})> _endpointsBySink =
      <WebSocketSink, ({String host, int port})>{};
  final DeviceIdentityStore _identityStore;
  final AuthEnvelopeObserver? _authEnvelopeObserver;
  int _nextConnectionGeneration = 0;
  final AuthRequestGate _authRequestGate = AuthRequestGate();
  final Map<WebSocketSink, String> _outgoingAuthKeysBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, String> _incomingAuthPeerIdsBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, _IdentityPinPlan> _identityPinPlansBySink =
      <WebSocketSink, _IdentityPinPlan>{};
  final Map<String, PeerProfile> _remoteProfilesByPeerId =
      <String, PeerProfile>{};
  final Map<WebSocketSink, Timer> _clientTimersBySink =
      <WebSocketSink, Timer>{};
  final Map<WebSocketSink, Future<void>> _socketCleanups =
      <WebSocketSink, Future<void>>{};
  final Map<WebSocketSink, TransportCloseGuard> _socketCloseGuards =
      <WebSocketSink, TransportCloseGuard>{};
  final Map<WebSocketSink, PeerDisconnectCause> _terminalDisconnectCauses =
      <WebSocketSink, PeerDisconnectCause>{};
  final Set<Future<void>> _pendingSocketAttachments = <Future<void>>{};
  final Set<_PendingOutgoingConnection> _pendingOutgoingConnections =
      <_PendingOutgoingConnection>{};
  final Map<String, _PendingOutgoingConnection> _pendingOutgoingByRequestId =
      <String, _PendingOutgoingConnection>{};
  final Map<String, Set<_PendingOutgoingConnection>> _pendingOutgoingByPeerId =
      <String, Set<_PendingOutgoingConnection>>{};
  final Map<WebSocketSink, _PendingOutgoingConnection> _pendingOutgoingBySink =
      <WebSocketSink, _PendingOutgoingConnection>{};
  final OutgoingTextRetryRegistry _outgoingTextRetries =
      OutgoingTextRetryRegistry();
  final OutgoingTextSendLocks _outgoingTextSendLocks = OutgoingTextSendLocks();
  final WireMessageReplayGuard _wireMessageReplayGuard =
      WireMessageReplayGuard();
  final WireControlSessionRegistry _wireControlSessions =
      WireControlSessionRegistry();
  final SocketAdmissionController _admission;
  final AudioShareManager _audioManager;
  final RemoteInputManager _remoteInputManager;
  final SessionUpgradeTokenRegistry _sessionUpgradeTokens;
  final bool Function(SessionUpgradeClaim claim)? _audioGroupClaimValidator;
  final AudioGroupPacketClaimValidator? _audioGroupPacketValidator;
  final bool Function(SessionUpgradeClaim claim)? _mediaPeerClaimValidator;
  final LocalDatabase _database;
  final Future<bool> Function() _autoConnectEnabled;
  final Future<void> Function(bool enabled) _setAutoConnectEnabled;
  final PeerReconnectControllerFactory _reconnectControllerFactory;
  final LocalPeerProfileLoader? _localPeerProfileLoader;
  final bool _manageSharedCoordinators;
  final ConnectionAuthCommitBarrier? _authCommitBarrier;
  final Duration _socketCloseTimeout;
  final Duration _mediaProofTimeout;
  final int _maxProvisionalMediaSockets;
  final SecureRandomBytes _mediaProofRandomBytes;
  int _provisionalMediaSocketCount = 0;
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
  String receiver = "";
  String sender = "";
  Future<void>? _closeFuture;
  bool _closeServerRequested = false;
  bool _forceServerCloseRequested = false;
  bool _closeOperationQueued = false;
  bool _acceptingUpgrades = false;
  bool _acceptingOutgoingConnections = true;
  HttpServer? _serverClosing;
  Timer? _clientTimer;
  PeerProfile? _remoteProfile;
  int _remoteProfileRevision = 0;
  final List<Completer<PeerProfile?>> _remoteProfileRefreshWaiters =
      <Completer<PeerProfile?>>[];
  late final FileTransferEngine _transferEngine = FileTransferEngine(
    currentConnectionBinding: _peerConnections.currentBinding,
    sendBytesToConnection: _peerConnections.sendToAwaitedIfCurrent,
    markPeerUnresponsive: _removeUnresponsivePeerIfCurrent,
    emitTransferUpdated: (snapshot) =>
        _dispatchToAll((event) => event.onTransferUpdated(snapshot)),
    notify: (message) => _dispatchToAll((event) => event.onNotice(message)),
    remoteProfileFor: (peerId) =>
        _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null),
    isConnectedTo: isConnectedTo,
    connectedPeerIds: () => _peerConnections.connectedPeerIds,
    defaultPeerId: () => receiver,
    hasLegacySinkFor: (peerId) => peerId == receiver && _sink != null,
    localPeerIdFor: (peerId) =>
        _sessionsByPeerId[peerId]?.localProfile.uid ?? '',
    buildMessage: _buildMessage,
    dispatchOutgoingMessage: _dispatchOutgoingMessage,
    ackMessage: _ackMessage,
    wireMessageReplayGuard: _wireMessageReplayGuard,
    database: () => _database,
  );

  PeerProfile? get _selectedRemoteProfile =>
      _remoteProfilesByPeerId[receiver] ?? _remoteProfile;

  Set<String> get connectedPeerIds => _peerConnections.connectedPeerIds;
  bool get isConnected =>
      _sink != null || _peerConnections.connectedPeerIds.isNotEmpty;
  bool get supportsFileTransferV3 =>
      _selectedRemoteProfile?.capabilities.fileTransferV3 == true;
  bool get supportsRemoteInput =>
      _selectedRemoteProfile?.capabilities.remoteInputSourceV1 == true &&
      _selectedRemoteProfile?.capabilities.remoteInputSinkV1 == true;
  bool get supportsRemoteInputTopology =>
      supportsRemoteInput &&
      _selectedRemoteProfile?.capabilities.remoteInputTopologyV1 == true &&
      _selectedRemoteProfile?.displayTopology?.isNotEmpty == true;
  RemoteInputTopology? get remoteDisplayTopology =>
      _selectedRemoteProfile?.displayTopology;

  bool supportsRemoteInputFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.capabilities.remoteInputSourceV1 == true &&
        profile?.capabilities.remoteInputSinkV1 == true;
  }

  PeerProfile? remoteProfileFor(String peerId) {
    return _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
  }

  bool supportsAudioGroupSourceFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.capabilities.audioGroupSourceV1 == true;
  }

  bool supportsAudioGroupSinkFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.capabilities.audioGroupSinkV1 == true;
  }

  List<DeviceData> connectedAudioGroupSinkDevices({
    String preferredPeerId = '',
  }) {
    final devices = <DeviceData>[];
    for (final peerId in connectedPeerIds) {
      if (!supportsAudioGroupSinkFor(peerId)) {
        continue;
      }
      final profile = _remoteProfilesByPeerId[peerId] ??
          (peerId == receiver ? _remoteProfile : null);
      final device = profile?.device;
      if (device != null) {
        devices.add(device);
      }
    }
    devices.sort((left, right) {
      if (left.uid == preferredPeerId) {
        return -1;
      }
      if (right.uid == preferredPeerId) {
        return 1;
      }
      return left.name.compareTo(right.name);
    });
    return devices;
  }

  List<DeviceData> connectedRemoteInputDevices({
    String preferredPeerId = '',
  }) {
    final devices = <DeviceData>[];
    for (final peerId in connectedPeerIds) {
      if (!supportsRemoteInputFor(peerId)) {
        continue;
      }
      final profile = _remoteProfilesByPeerId[peerId] ??
          (peerId == receiver ? _remoteProfile : null);
      final device = profile?.device;
      if (device != null) {
        devices.add(device);
      }
    }
    devices.sort((left, right) {
      if (left.uid == preferredPeerId) {
        return -1;
      }
      if (right.uid == preferredPeerId) {
        return 1;
      }
      return left.name.compareTo(right.name);
    });
    return devices;
  }

  bool supportsRemoteInputTopologyFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return supportsRemoteInputFor(peerId) &&
        profile?.capabilities.remoteInputTopologyV1 == true &&
        profile?.displayTopology?.isNotEmpty == true;
  }

  RemoteInputTopology? remoteDisplayTopologyFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.displayTopology;
  }

  bool remoteTrustsPeer(String peerId) {
    final selectedPeerId = _selectedRemoteProfile?.device.uid ?? receiver;
    return peerId == sender &&
        _sessionsByPeerId[selectedPeerId]?.isAuthenticated == true;
  }

  bool remotePeerTrustsPeer(String remotePeerId, String trustedPeerId) {
    return trustedPeerId == sender &&
        _sessionsByPeerId[remotePeerId]?.isAuthenticated == true;
  }

  bool isConnectedTo(String peerId) {
    return _peerConnections.isConnectedTo(peerId);
  }

  bool isCurrentConnectionGeneration(String peerId, int generation) =>
      _peerConnections.isCurrent(peerId, generation);

  void selectPeer(String peerId) {
    if (!_peerConnections.isConnectedTo(peerId)) {
      return;
    }
    receiver = peerId;
    for (final entry in _peerIdsBySink.entries) {
      if (entry.value == peerId) {
        _sink = entry.key;
        break;
      }
    }
    _setSelectedRemoteProfile(_remoteProfilesByPeerId[peerId]);
  }

  @visibleForTesting
  Future<PeerProfile?> debugWaitForSelectedProfileUpdate() {
    final completer = Completer<PeerProfile?>();
    _remoteProfileRefreshWaiters.add(completer);
    return completer.future;
  }

  @visibleForTesting
  Future<void> debugSendProfileHeartbeatTo(String peerId) =>
      _heartBeat(peerId: peerId);

  @visibleForTesting
  int get debugProvisionalMediaSocketCount => _provisionalMediaSocketCount;

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

  String? _peerIdForSink(WebSocketSink? sink) {
    return sink == null ? null : _peerIdsBySink[sink];
  }

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

  void debugDispatchMessage(MessageData messageData) {
    _dispatchToAll((event) => event.onMessage(messageData));
  }

  void debugDispatchTransfer(TransferSnapshot snapshot) {
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
        ConnectionRequestNotifier().dismissForPeer(
          peerId,
          graceMillis: 3000,
        ),
        context: 'dismiss pairing notification',
      );
    }
  }

  void _ignoreFuture(Future<void> future, {required String context}) {
    unawaited(future.catchError((Object error, StackTrace stackTrace) {
      logger.i('$context failed: $error\n$stackTrace');
    }));
  }

  Future<void> _closeSocketSink(WebSocketSink sink) {
    final guard = _socketCloseGuards.putIfAbsent(
      sink,
      () => TransportCloseGuard(
        close: () async {
          await sink.close();
        },
        timeout: _socketCloseTimeout,
      ),
    );
    return guard.close();
  }

  Future<void> debugRegisterPeerConnection(
    String peerId,
    PeerConnection connection,
  ) async {
    await _peerConnections.register(
      connection,
      afterRegister: (_) {
        if (receiver.isEmpty) {
          receiver = peerId;
        }
      },
    );
  }

  @visibleForTesting
  bool debugSendMalformedTransportFrame(String peerId) {
    for (final entry in _peerIdsBySink.entries) {
      if (entry.value == peerId) {
        entry.key.add(Uint8List.fromList(const <int>[0]));
        return true;
      }
    }
    return false;
  }

  @visibleForTesting
  Future<bool> debugDropPeerTransport(String peerId) async {
    for (final entry in _peerIdsBySink.entries) {
      if (entry.value == peerId) {
        await entry.key.close();
        return true;
      }
    }
    return false;
  }

  Future<void> _registerPeerConnection({
    required String peerId,
    required WebSocketSink sink,
    required PeerSocketSession session,
    PeerProfile? profile,
  }) async {
    if (peerId.isEmpty || !session.isAuthenticationReady) {
      return;
    }
    await _peerConnections.register(
      PeerConnection(
        peerId: peerId,
        connectionId: session.connectionGeneration,
        send: (message) {
          if (session.isAuthenticated) {
            _ignoreFuture(
              _sendBytesOnSink(sink, message).then<void>((_) {}),
              context: 'send peer message',
            );
          }
        },
        sendAsync: (message) {
          if (!session.isAuthenticated) {
            return Future<bool>.value(false);
          }
          return _sendBytesOnSink(sink, message);
        },
        close: () async {
          _peerIdsBySink.remove(sink);
          session.close();
          await _closeSocketSink(sink);
        },
      ),
      afterRemove: (binding) => _afterPeerRemoved(
        binding,
        closingSession: _sessionsByPeerId[peerId],
        cause: PeerDisconnectCause.superseded,
      ),
      afterRegister: (binding) {
        if (binding.generation != session.connectionGeneration ||
            !session.isAuthenticationReady) {
          throw StateError('stale peer registration');
        }
        _sessionsByPeerId[peerId] = session;
        _peerIdsBySink[sink] = peerId;
        if (session.role == PeerSocketRole.server &&
            (receiver.isEmpty || receiver == peerId)) {
          receiver = peerId;
          _sink = sink;
        }
        _setRemoteProfile(profile, peerId: peerId);
      },
    );
  }

  Future<void> _handlePeerSocketDoneQueued(WebSocketSink sink) {
    final existing = _socketCleanups[sink];
    if (existing != null) {
      return existing;
    }
    late final Future<void> cleanup;
    cleanup = () async {
      try {
        await _sessionsBySink[sink]?.stopReceivingAndDrain();
      } catch (error, stackTrace) {
        logger.i('停止 websocket 接收失败: $error\n$stackTrace');
      }
      try {
        await _handlePeerSocketDone(sink);
      } catch (error, stackTrace) {
        logger.i('处理 websocket 关闭失败: $error\n$stackTrace');
      } finally {
        if (identical(_socketCleanups[sink], cleanup)) {
          _socketCleanups.remove(sink);
        }
        _socketCloseGuards.remove(sink);
      }
    }();
    _socketCleanups[sink] = cleanup;
    return cleanup;
  }

  Future<void> _handlePeerSocketDone(WebSocketSink sink) async {
    final disconnectCause =
        _terminalDisconnectCauses.remove(sink) ?? PeerDisconnectCause.network;
    final session = _sessionsBySink.remove(sink);
    if (session != null &&
        !_peerAuthenticationTails.containsKey(session.remotePeerId)) {
      _sessionStartedPolicyRevisions.remove(session);
    }
    session?.close();
    await session?.drainOutbound();
    session?.releaseAdmission();
    _endpointsBySink.remove(sink);
    _identityPinPlansBySink.remove(sink);
    _completeSocketAuth(sink, false, 'connection_closed');
    _releaseOutgoingAuthForSink(sink);
    _releaseIncomingAuthForSink(sink);
    _clientTimersBySink.remove(sink)?.cancel();
    final peerId = _peerIdsBySink.remove(sink);
    final currentSession = peerId == null ? null : _sessionsByPeerId[peerId];
    if (peerId == null) {
      if (identical(_sink, sink)) {
        _sink = null;
      }
      return;
    }
    if (!await AuthSocketLifecycle.removeConnectionIfCurrent(
      connections: _peerConnections,
      peerId: peerId,
      closingSession: session,
      currentSession: currentSession,
      afterRemove: (binding) => _afterPeerRemoved(
        binding,
        closingSession: session,
        cause: disconnectCause,
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
  }) async {
    late PeerSocketSession session;
    session = await PeerSocketSession.create(
      role: role,
      connectionGeneration: ++_nextConnectionGeneration,
      localIdentity: await _identityStore.loadOrCreate(),
      localProfile: (await _localPeerProfile()).toWireProfile(),
      intendedPeerId: intendedPeerId,
      intendedPublicKeyHash: intendedPublicKeyHash,
      onTimeout: () {
        if (!identical(_sessionsBySink[sink], session)) {
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
    _sessionsBySink[sink] = session;
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
    subscription = webSocket.stream.listen((message) {
      final handling = _handleIncomingMessage(
        message,
        sink: sink,
        asServer: asServer,
      );
      _ignoreFuture(
        handling.then<void>((_) {}),
        context: 'process websocket message',
      );
    }, onError: (Object error, StackTrace stackTrace) {
      AuthSocketLifecycle.closeBeforeQueuedCleanup(
        _sessionsBySink[sink],
        () {
          logger.i('${asServer ? '连接服务' : '客户端服务'}异常: ${error.runtimeType}');
          _dispatchToPrimary((event) => event.onError(error.toString()));
          _completeSocketAuth(sink, false, 'socket_error');
          _ignoreFuture(
            _handlePeerSocketDoneQueued(sink),
            context: 'cleanup failed websocket',
          );
        },
      );
    }, onDone: () {
      AuthSocketLifecycle.closeBeforeQueuedCleanup(
        _sessionsBySink[sink],
        () => _ignoreFuture(
          _handlePeerSocketDoneQueued(sink),
          context: 'cleanup closed websocket',
        ),
      );
    });
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
        if (!identical(_sessionsBySink[sink], session)) {
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
  ) async {
    final sink = webSocket.sink;
    try {
      final session = await _createSocketSession(
        sink: sink,
        role: PeerSocketRole.server,
      );
      _attachSocketTransport(
        webSocket,
        session,
        admissionLease: admissionLease,
        asServer: true,
      );
    } catch (_) {
      admissionLease.close();
      _completeSocketAuth(sink, false, 'session_setup_failed');
      await _closeSocketSink(sink);
    }
  }

  void _trackIncomingSocketAttachment(
    WebSocketChannel webSocket,
    AdmissionLease admissionLease,
    Completer<void> pendingUpgrade,
  ) {
    final attachment = _attachIncomingSocket(webSocket, admissionLease)
        .whenComplete(() => _completePendingSocketAttachment(pendingUpgrade));
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
    _terminalDisconnectCauses[sink] = cause;
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
      await _performCloseGracefully(
        closeServer: true,
        forceServerClose: false,
      );
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

    Future<shelf.Response> handleMediaUpgrade({
      required shelf.Request request,
      required String route,
      required String sessionId,
      required String token,
      required SessionUpgradeClaim provisionalClaim,
      required bool Function(SessionUpgradeClaim claim) canAttach,
      required bool Function(
        WebSocketChannel channel,
        SessionUpgradeClaim claim,
      ) attach,
    }) async {
      if (_provisionalMediaSocketCount >= _maxProvisionalMediaSockets) {
        return shelf.Response(429, body: 'Too Many Requests');
      }
      _provisionalMediaSocketCount += 1;
      var provisionalReleased = false;
      final pendingUpgrade = Completer<void>();
      _pendingSocketAttachments.add(pendingUpgrade.future);
      void releaseProvisional() {
        if (provisionalReleased) {
          return;
        }
        provisionalReleased = true;
        _provisionalMediaSocketCount -= 1;
        _completePendingSocketAttachment(pendingUpgrade);
      }

      late final shelf.Handler mediaHandler;
      try {
        final nonceBytes = _mediaProofRandomBytes(32);
        if (nonceBytes.length != 32) {
          releaseProvisional();
          return shelf.Response.internalServerError();
        }
        final challenge = MediaUpgradeChallenge(
          route: provisionalClaim.route,
          namespace: provisionalClaim.namespace,
          sessionId: provisionalClaim.sessionId,
          tokenHash: mediaUpgradeTokenHash(token),
          nonce: base64Url.encode(nonceBytes).replaceAll('=', ''),
          peerId: provisionalClaim.peerId,
          connectionGeneration: provisionalClaim.connectionGeneration,
        );
        mediaHandler = webSocketHandler(
          (WebSocketChannel channel) {
            try {
              MediaUpgradeServerSession(
                channel: channel,
                challenge: challenge,
                mediaMacKey: provisionalClaim.mediaMacKey,
                timeout: _mediaProofTimeout,
                onAuthenticated: (authenticatedChannel) {
                  if (!canAttach(provisionalClaim)) {
                    return false;
                  }
                  final consumed = _sessionUpgradeTokens.consume(
                    route: route,
                    sessionId: sessionId,
                    token: token,
                    now: DateTime.now(),
                    expected: provisionalClaim,
                  );
                  return consumed != null &&
                      attach(authenticatedChannel, consumed);
                },
                onProvisionalFinished: releaseProvisional,
              );
            } catch (_) {
              releaseProvisional();
              _ignoreFuture(
                channel.sink.close(4001, 'media_auth_failed'),
                context: 'close failed media proof session initialization',
              );
            }
          },
          pingInterval: _serverPingInterval,
        );
      } catch (_) {
        releaseProvisional();
        return shelf.Response.internalServerError();
      }
      late final shelf.Response response;
      try {
        response = await mediaHandler(request);
      } on shelf.HijackException {
        rethrow;
      } catch (_) {
        releaseProvisional();
        rethrow;
      }
      if (response.statusCode != HttpStatus.switchingProtocols) {
        releaseProvisional();
      }
      return response;
    }

    FutureOr<shelf.Response> handler(shelf.Request request) async {
      final path = request.url.path;
      if (path != 'chat' && path != 'audio' && path != 'input') {
        return shelf.Response.notFound('Not Found');
      }
      if (request.method != 'GET' || !_isValidWebSocketUpgrade(request)) {
        return shelf.Response.badRequest(body: 'Bad Request');
      }
      final origin = request.headers['origin'];
      if (origin?.trim().isNotEmpty == true) {
        return shelf.Response.forbidden('Forbidden');
      }
      if (!_acceptingUpgrades) {
        return shelf.Response(
          HttpStatus.serviceUnavailable,
          body: 'Service Unavailable',
        );
      }
      final connectionInfo =
          request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
      final remoteAddress =
          connectionInfo?.remoteAddress ?? request.requestedUri.host;
      final rateRejection = _admission.tryUpgrade(
        remoteAddress,
        DateTime.now(),
      );
      if (rateRejection != null) {
        return shelf.Response(429, body: 'Too Many Requests');
      }
      if (path == 'audio') {
        final credentials = _mediaUpgradeCredentials(request);
        final claim = credentials == null
            ? null
            : _sessionUpgradeTokens.lookup(
                route: '/audio',
                sessionId: credentials.sessionId,
                token: credentials.token,
                now: DateTime.now(),
              );
        if (claim == null ||
            !_isExpectedMediaPeerClaim(claim) ||
            !_isExpectedAudioUpgradeClaim(claim)) {
          return shelf.Response.unauthorized('Unauthorized');
        }
        return handleMediaUpgrade(
          request: request,
          route: '/audio',
          sessionId: credentials!.sessionId,
          token: credentials.token,
          provisionalClaim: claim,
          canAttach: (candidate) =>
              _isExpectedMediaPeerClaim(candidate) &&
              _isExpectedAudioUpgradeClaim(candidate),
          attach: (channel, consumed) => _audioManager.attachChannel(
            channel,
            claim: consumed,
            additionalValidator: _isExpectedAudioGroupUpgradeClaim,
            groupPacketValidator: _isExpectedAudioGroupPacket,
            claimValidator: _isExpectedMediaPeerClaim,
          ),
        );
      }
      if (path == 'input') {
        final credentials = _mediaUpgradeCredentials(request);
        final claim = credentials == null
            ? null
            : _sessionUpgradeTokens.lookup(
                route: '/input',
                sessionId: credentials.sessionId,
                token: credentials.token,
                now: DateTime.now(),
              );
        if (claim == null ||
            !_isExpectedMediaPeerClaim(claim) ||
            !_remoteInputManager.canAttachClaim(claim)) {
          return shelf.Response.unauthorized('Unauthorized');
        }
        return handleMediaUpgrade(
          request: request,
          route: '/input',
          sessionId: credentials!.sessionId,
          token: credentials.token,
          provisionalClaim: claim,
          canAttach: (candidate) =>
              _isExpectedMediaPeerClaim(candidate) &&
              _remoteInputManager.canAttachClaim(candidate),
          attach: (channel, consumed) => _remoteInputManager.attachChannel(
            channel,
            claim: consumed,
            claimValidator: _isExpectedMediaPeerClaim,
          ),
        );
      }

      final admission = _admission.tryOpenChat(remoteAddress);
      final lease = admission.lease;
      if (lease == null) {
        return shelf.Response(429, body: 'Too Many Requests');
      }
      final pendingUpgrade = Completer<void>();
      _pendingSocketAttachments.add(pendingUpgrade.future);
      final chatHandler = webSocketHandler(
        (WebSocketChannel webSocket) {
          _trackIncomingSocketAttachment(
            webSocket,
            lease,
            pendingUpgrade,
          );
        },
        allowedOrigins: const <String>[],
        pingInterval: _serverPingInterval,
      );
      late final shelf.Response response;
      try {
        response = await chatHandler(request);
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
      final server = await shelf_io.serve(
        handler,
        '0.0.0.0',
        port,
        shared: true,
      );
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

  ({String sessionId, String token})? _mediaUpgradeCredentials(
    shelf.Request request,
  ) {
    final sessions = request.url.queryParametersAll['session'];
    final tokens = request.url.queryParametersAll['token'];
    if (sessions == null ||
        sessions.length != 1 ||
        sessions.single.isEmpty ||
        tokens == null ||
        tokens.length != 1 ||
        tokens.single.isEmpty) {
      return null;
    }
    return (sessionId: sessions.single, token: tokens.single);
  }

  bool _isExpectedMediaPeerClaim(SessionUpgradeClaim claim) {
    final injected = _mediaPeerClaimValidator;
    if (injected != null) {
      return injected(claim);
    }
    final session = _sessionsByPeerId[claim.peerId];
    final mediaReceiveKey = session?.mediaReceiveKey;
    return session?.isAuthenticated == true &&
        session?.connectionGeneration == claim.connectionGeneration &&
        mediaReceiveKey != null &&
        constantTimeBytesEqual(mediaReceiveKey, claim.mediaMacKey);
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

  bool _isValidWebSocketUpgrade(shelf.Request request) {
    final connection = request.headers[HttpHeaders.connectionHeader];
    final upgrade = request.headers[HttpHeaders.upgradeHeader];
    final version = request.headers['sec-websocket-version'];
    final key = request.headers['sec-websocket-key'];
    if (connection == null ||
        !connection
            .split(',')
            .map((token) => token.trim().toLowerCase())
            .contains('upgrade') ||
        upgrade?.trim().toLowerCase() != 'websocket' ||
        version?.trim() != '13' ||
        key == null) {
      return false;
    }
    try {
      return base64.decode(key.trim()).length == 16;
    } on FormatException {
      return false;
    }
  }

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
    _reconnectControllerFor(peerId).updateTarget(
      target,
      accelerate: accelerate,
    );
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

  FutureOr<ConnectionAttemptStatus> _runReconnectAttempt(
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
    final result = await connectToServer(
      ConnectionAttemptRequest(
        requestId:
            'reconnect:${target.peerId}:${context.generation}:${uuid.v4()}',
        endpoint: target.endpoint,
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
          _peerConnections.isCurrent(result.peerId, result.generation)) {
        final shouldSelect = receiver.isEmpty || receiver == result.peerId;
        if (shouldSelect) {
          selectPeer(result.peerId);
        }
        if (_manageSharedCoordinators) {
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
    final endpoint = pending?.request.endpoint;
    if (pending == null || endpoint == null) {
      return;
    }
    final target =
        ReconnectTarget.endpoint(peerId: device.uid, endpoint: endpoint);
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

  bool _isPeerSuppressedOnlyFor(
    String peerId,
    _PeerAuthSuppressionReason reason,
  ) {
    final suppressions = _peerAuthSuppressions[peerId];
    return suppressions != null &&
        suppressions.length == 1 &&
        suppressions.contains(reason);
  }

  void _requirePairingForTrustRepair(
    String peerId,
    PairingReason? pairingReason,
  ) {
    if (_isPeerSuppressedOnlyFor(
          peerId,
          _PeerAuthSuppressionReason.trustRevoked,
        ) &&
        pairingReason == null) {
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
    _PendingOutgoingConnection? attempt,
    bool allowTrustRepair = false,
  }) {
    final suppressions = _peerAuthSuppressions[peerId];
    if (suppressions == null || suppressions.isEmpty) {
      return true;
    }
    if (suppressions.length != 1) {
      return false;
    }
    return switch (suppressions.single) {
      _PeerAuthSuppressionReason.deviceDeleted =>
        attempt?.allowsDeviceRepair == true,
      _PeerAuthSuppressionReason.trustRevoked =>
        allowTrustRepair || attempt?.allowsTrustRepair == true,
      _PeerAuthSuppressionReason.manualDisconnect => false,
    };
  }

  void _authorizeInteractiveAttemptForPeer(
    _PendingOutgoingConnection attempt,
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
    _PendingOutgoingConnection? attempt,
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
    for (final entry in _sessionsBySink.entries.toList(growable: false)) {
      final session = entry.value;
      if (session.remotePeerId != peerId || session.isAuthenticated) {
        continue;
      }
      session.close();
      _ignoreFuture(
        entry.key.close(),
        context: 'cancel invalidated peer authentication',
      );
    }
  }

  Future<void> _cancelPendingAttemptsForPeer(
    String peerId,
    ConnectionAttemptReason reason, {
    bool Function(_PendingOutgoingConnection attempt)? where,
  }) async {
    final attempts = _pendingOutgoingByPeerId[peerId]
            ?.where((attempt) => where?.call(attempt) ?? true)
            .toList(growable: false) ??
        const <_PendingOutgoingConnection>[];
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
    unawaited(tail.whenComplete(() {
      if (identical(_peerAuthenticationTails[peerId], tail)) {
        _peerAuthenticationTails.remove(peerId);
      }
    }));
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

  bool _isPendingPolicyCurrent(_PendingOutgoingConnection attempt) {
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
      _addPeerAuthSuppression(
        peerId,
        _PeerAuthSuppressionReason.trustRevoked,
      );
      _invalidatePeerPolicy(peerId, _PeerPolicyDisposition.trustRevoked);
      _cancelPendingAuthSessionsForPeer(peerId);
      _reconnectControllers[peerId]?.trustRevoked();
      await _cancelPendingAttemptsForPeer(
        peerId,
        ConnectionAttemptReason.trustRevoked,
      );
      await _waitForPeerAuthentication(peerId);
      await _removePeerConnection(peerId, PeerDisconnectCause.trustRevoked);
      await _database.authDevice(peerId, false);
      return true;
    }
    final stored = await _database.fetchDevice(peerId);
    if (stored == null || stored.identityPublicKey.isEmpty) {
      _reconnectControllers[peerId]?.identityUnpinned();
      return false;
    }
    final updated =
        await _database.authDeviceIfPinned(peerId, stored.identityPublicKey);
    if (updated) {
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
    await _cancelPendingAttemptsForPeer(
      peerId,
      ConnectionAttemptReason.deviceDeleted,
    );
    await _waitForPeerAuthentication(peerId);
    await _removePeerConnection(peerId, PeerDisconnectCause.deviceDeleted);
    await _database.clearDevices(<String>[peerId], localPeerId: '');
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
      _reconnectControllerFor(request.expectedPeerId)
          .unsuppressForManualConnect(target);
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
    final attempt = _PendingOutgoingConnection(
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
      unawaited(whenCancelled.then<void>((_) {
        if (_pendingOutgoingByRequestId[request.requestId] == attempt) {
          unawaited(attempt.cancel());
        }
      }));
    }
    final operation = request.mode == ConnectionAttemptMode.interactive &&
            request.expectedPeerId.isNotEmpty
        ? _preemptAutomaticAttemptsThenConnect(attempt)
        : _connectToServer(attempt);
    unawaited(operation.then<void>((result) {
      _untrackPendingOutgoing(attempt);
      attempt.httpClient.close();
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }, onError: (Object _, StackTrace __) {
      _untrackPendingOutgoing(attempt);
      attempt.httpClient.close(force: true);
      if (!completer.isCompleted) {
        completer.complete(
          ConnectionAttemptResult.networkFailure(
            requestId: request.requestId,
          ),
        );
      }
    }));
    return completer.future;
  }

  bool hasPendingConnectionAttempt(String requestId) =>
      _pendingOutgoingByRequestId.containsKey(requestId);

  bool hasPendingConnectionAttemptForPeer(String peerId) =>
      _pendingOutgoingByPeerId[peerId]?.isNotEmpty == true;

  bool _hasUncancelledPendingAttemptForPeer(String peerId) =>
      _pendingOutgoingByPeerId[peerId]
              ?.any((attempt) => !attempt.isCancelled) ==
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

  void _trackPendingOutgoing(_PendingOutgoingConnection attempt) {
    _pendingOutgoingConnections.add(attempt);
    _pendingOutgoingByRequestId[attempt.request.requestId] = attempt;
    _indexPendingOutgoingPeer(attempt, attempt.request.expectedPeerId);
  }

  void _indexPendingOutgoingPeer(
    _PendingOutgoingConnection attempt,
    String peerId,
  ) {
    if (peerId.isEmpty) {
      return;
    }
    _pendingOutgoingByPeerId
        .putIfAbsent(peerId, () => <_PendingOutgoingConnection>{})
        .add(attempt);
  }

  void _bindPendingOutgoingPeer(
    _PendingOutgoingConnection attempt,
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

  void _untrackPendingOutgoing(_PendingOutgoingConnection attempt) {
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

  static bool _isAutomaticAttempt(_PendingOutgoingConnection attempt) =>
      attempt.request.isAutomatic;

  /// 手动连接优先:先取消同 peer 的在途自动尝试,并有界等待其清理完成
  /// (含释放出站鉴权门),再真正拨号;否则手动尝试会同步撞门,
  /// 直接得到 duplicateRequest 而无任何网络活动。
  Future<ConnectionAttemptResult> _preemptAutomaticAttemptsThenConnect(
    _PendingOutgoingConnection attempt,
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
    _PendingOutgoingConnection attempt,
  ) async {
    final request = attempt.request;
    if (!_acceptingOutgoingConnections) {
      return ConnectionAttemptResult.cancelled(
        requestId: request.requestId,
        reason: ConnectionAttemptReason.managerClosed,
      );
    }
    final endpoint = request.endpoint;
    final authRequestKey = _authRequestKey(
      peerId: request.expectedPeerId,
      host: endpoint.host,
      port: endpoint.port,
    );
    if (!_authRequestGate.tryClaimOutgoing(authRequestKey)) {
      return ConnectionAttemptResult.rejected(
        requestId: request.requestId,
        reason: ConnectionAttemptReason.duplicateRequest,
      );
    }
    WebSocketChannel? channel;
    // claim 的所有权在写入 _outgoingAuthKeysBySink 时移交给 sink 映射;
    // 在此之前失败必须直接释放,否则该 key 会永久占用鉴权门。
    var authKeyBoundToSink = false;
    try {
      channel = IOWebSocketChannel(
        _connectOutgoingWebSocket(endpoint.chatUri, attempt),
      );
      attempt.channel = channel;
      final connectedChannel = channel;
      await connectedChannel.ready;
      attempt.isReady = true;
      if (attempt.isCancelled) {
        throw const _OutgoingConnectionCancelled();
      }
      final channelSink = connectedChannel.sink;
      _pendingOutgoingBySink[channelSink] = attempt;
      _outgoingAuthKeysBySink[channelSink] = authRequestKey;
      authKeyBoundToSink = true;
      _endpointsBySink[channelSink] = (
        host: endpoint.host,
        port: endpoint.port,
      );
      final authCompleter = Completer<_SocketAuthResult>();
      _authResultsBySink[channelSink] = authCompleter;
      final session = await _createSocketSession(
        sink: channelSink,
        role: PeerSocketRole.client,
        intendedPeerId: request.expectedPeerId,
        intendedPublicKeyHash: request.expectedPublicKeyHash,
      );
      attempt.session = session;
      if (attempt.isCancelled) {
        throw const _OutgoingConnectionCancelled();
      }
      _attachSocketTransport(
        connectedChannel,
        session,
        asServer: false,
      );
      await _sendAuthEnvelope(channelSink, await session.createHello());
      final authResult = await authCompleter.future;
      _releaseOutgoingAuthForSink(channelSink);
      if (attempt.isCancelled) {
        throw const _OutgoingConnectionCancelled();
      }
      if (!authResult.allow) {
        await _closeSocketSink(channelSink);
        return _connectionFailureResult(request, authResult.message);
      }
      final peerId = session.remotePeerId;
      final generation = session.connectionGeneration;
      if (!_peerConnections.isCurrent(peerId, generation) ||
          !identical(_sessionsByPeerId[peerId], session)) {
        return ConnectionAttemptResult.cancelled(
          requestId: request.requestId,
          reason: ConnectionAttemptReason.superseded,
        );
      }
      final timer = Timer.periodic(_clientHeartbeatInterval, (timer) {
        unawaited(_heartBeat(peerId: peerId, sink: channelSink));
      });
      _clientTimersBySink[channelSink] = timer;
      if (receiver == peerId) {
        _clientTimer = timer;
      }
      return ConnectionAttemptResult.authenticated(
        requestId: request.requestId,
        peerId: peerId,
        generation: generation,
      );
    } catch (error) {
      final wasCancelled = attempt.isCancelled ||
          error is _OutgoingConnectionCancelled ||
          (error is WebSocketChannelException &&
              error.inner is _OutgoingConnectionCancelled);
      try {
        await attempt.cancel();
      } catch (_) {
        // The typed result below remains authoritative.
      }
      if (channel != null) {
        _completeSocketAuth(channel.sink, false, 'connection_failed');
        _releaseOutgoingAuthForSink(channel.sink);
        await _handlePeerSocketDoneQueued(channel.sink);
      }
      if (!authKeyBoundToSink) {
        // pre-ready 失败(或 channel 构造失败)时映射尚未写入,
        // 按 sink 查找释放不到,需直接释放本次 claim;
        // 绑定之后统一走幂等的 _releaseOutgoingAuthForSink,
        // 避免误释放新一轮 attempt 重新 claim 的同名 key。
        _authRequestGate.releaseOutgoing(authRequestKey);
      }
      if (wasCancelled) {
        return ConnectionAttemptResult.cancelled(
          requestId: request.requestId,
          reason: attempt.cancellationReason,
        );
      }
      return _connectionExceptionResult(request, error);
    }
  }

  ConnectionAttemptResult _connectionExceptionResult(
    ConnectionAttemptRequest request,
    Object error,
  ) {
    final isNetworkFailure = error is SocketException ||
        error is HttpException ||
        error is TimeoutException ||
        (error is WebSocketChannelException && error.inner is SocketException);
    if (isNetworkFailure) {
      return ConnectionAttemptResult.networkFailure(
        requestId: request.requestId,
      );
    }
    return ConnectionAttemptResult.rejected(
      requestId: request.requestId,
      reason: error is AuthHandshakeException
          ? ConnectionAttemptReason.authenticationFailed
          : error is WebSocketException || error is WebSocketChannelException
              ? ConnectionAttemptReason.protocolMismatch
              : ConnectionAttemptReason.localStateFailure,
    );
  }

  @visibleForTesting
  ConnectionAttemptResult debugClassifyConnectionException(
    ConnectionAttemptRequest request,
    Object error,
  ) =>
      _connectionExceptionResult(request, error);

  ConnectionAttemptResult _connectionFailureResult(
    ConnectionAttemptRequest request,
    String message,
  ) {
    final reason = switch (message) {
      'pairing_expired' => ConnectionAttemptReason.pairingExpired,
      'upgrade_required' => ConnectionAttemptReason.protocolMismatch,
      'wrong_intended_peer' ||
      'wrong_intended_pkh' ||
      'identity_pin_conflict' =>
        ConnectionAttemptReason.identityMismatch,
      'automatic_pairing_required' =>
        ConnectionAttemptReason.automaticPairingRequired,
      'rejected' || 'pairing_rejected' => ConnectionAttemptReason.peerRejected,
      'socket_error' => ConnectionAttemptReason.socketError,
      'connection_closed' ||
      'connection_failed' =>
        ConnectionAttemptReason.transportClosed,
      _ => ConnectionAttemptReason.authenticationFailed,
    };
    if (reason == ConnectionAttemptReason.socketError ||
        reason == ConnectionAttemptReason.transportClosed) {
      return ConnectionAttemptResult.networkFailure(
        requestId: request.requestId,
        reason: reason,
      );
    }
    return ConnectionAttemptResult.rejected(
      requestId: request.requestId,
      reason: reason,
    );
  }

  Future<WebSocket> _connectOutgoingWebSocket(
    Uri webSocketUri,
    _PendingOutgoingConnection attempt,
  ) async {
    final requestUri = webSocketUri.replace(
      scheme: webSocketUri.scheme == 'wss' ? 'https' : 'http',
    );
    final random = math.Random.secure();
    final nonce = base64.encode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final request = await attempt.httpClient.openUrl('GET', requestUri);
    attempt.transportRequest = request;
    request.followRedirects = false;
    if (attempt.isCancelled) {
      request.abort(const _OutgoingConnectionCancelled());
      throw const _OutgoingConnectionCancelled();
    }
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Key', nonce)
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set('Sec-WebSocket-Version', '13');
    final response = await request.close();
    attempt.transportRequest = null;
    if (attempt.isCancelled) {
      final socket = await response.detachSocket();
      socket.destroy();
      throw const _OutgoingConnectionCancelled();
    }
    final connectionTokens =
        (response.headers[HttpHeaders.connectionHeader] ?? const <String>[])
            .expand((value) => value.split(','))
            .map((value) => value.trim().toLowerCase());
    final upgrade = response.headers.value(HttpHeaders.upgradeHeader);
    final accept = response.headers.value('Sec-WebSocket-Accept');
    Future<Never> rejectResponse(String reason) async {
      final socket = await response.detachSocket();
      socket.destroy();
      throw WebSocketException(reason, response.statusCode);
    }

    if (response.statusCode != HttpStatus.switchingProtocols ||
        !connectionTokens.contains('upgrade') ||
        upgrade?.trim().toLowerCase() != 'websocket' ||
        accept?.trim() != WebSocketChannel.signKey(nonce)) {
      return rejectResponse(
        "Connection to '$webSocketUri' was not upgraded to websocket",
      );
    }
    if (response.headers.value('Sec-WebSocket-Protocol') != null ||
        response.headers.value('Sec-WebSocket-Extensions') != null) {
      return rejectResponse('unexpected_websocket_negotiation');
    }
    final socket = await response.detachSocket();
    if (attempt.isCancelled) {
      socket.destroy();
      throw const _OutgoingConnectionCancelled();
    }
    return WebSocket.fromUpgradedSocket(
      socket,
      serverSide: false,
    );
  }

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
          closingServer.close(force: true).then<void>((_) {}),
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
          final needsForceClose = _forceServerCloseRequested &&
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
      serverCloseFuture = closingServer
          ?.close(force: forceServerClose)
          .then<void>((_) {})
          .whenComplete(() {
        if (identical(_serverClosing, closingServer)) {
          _serverClosing = null;
        }
      });
    }
    final hadActiveConnection = AuthSocketLifecycle.hasConnectionWork(
      hasSelectedSink: _sink != null,
      hasClientTimer: _clientTimer != null,
      hasPendingSessions: _sessionsBySink.isNotEmpty ||
          _pendingSocketAttachments.isNotEmpty ||
          _pendingOutgoingConnections.isNotEmpty ||
          _audioManager.hasActiveChannels ||
          _remoteInputManager.hasActiveChannels,
      hasPendingResults: _authResultsBySink.isNotEmpty,
      hasPeerConnections: _peerConnections.connectedPeerIds.isNotEmpty,
      hasReceiver: receiver.isNotEmpty,
    );
    if (!hadActiveConnection && !closeServer) {
      if (_server != null && !_closeServerRequested) {
        _acceptingUpgrades = true;
      }
      _acceptingOutgoingConnections = true;
      return;
    }

    _clientTimer?.cancel();
    _clientTimer = null;
    for (final timer in _clientTimersBySink.values) {
      timer.cancel();
    }
    _clientTimersBySink.clear();
    _outgoingAuthKeysBySink.clear();
    _incomingAuthPeerIdsBySink.clear();
    _identityPinPlansBySink.clear();
    _authRequestGate.clear();
    while (_pendingSocketAttachments.isNotEmpty) {
      await Future.wait(
        _pendingSocketAttachments.toList(growable: false),
      );
    }
    final sessionEntries = _sessionsBySink.entries.toList(growable: false);
    final authenticatedEntries = sessionEntries
        .where((entry) => entry.value.isAuthenticated)
        .toList(growable: false);
    final hadAuthenticatedConnection = authenticatedEntries.isNotEmpty ||
        _peerConnections.connectedPeerIds.isNotEmpty;
    final pendingEntries = sessionEntries
        .where((entry) => !entry.value.isAuthenticated)
        .toList(growable: false);
    final pendingSinks = <WebSocketSink>{
      ...pendingEntries.map((entry) => entry.key),
      ..._authResultsBySink.keys,
    };
    AuthSocketLifecycle.closePendingAuth(
      sessions: pendingEntries.map((entry) => entry.value),
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
    await Future.wait(pendingSinks.map((sink) async {
      try {
        await Future.wait(<Future<void>>[
          _closeSocketSink(sink),
          if (_sessionsBySink[sink] case final session?)
            session.stopReceivingAndDrain(),
        ]);
      } catch (error, stackTrace) {
        logger.i('关闭待认证 websocket 失败: $error\n$stackTrace');
      }
      await _handlePeerSocketDoneQueued(sink);
    }));
    final activeCleanups = _socketCleanups.values.toList(growable: false);
    if (activeCleanups.isNotEmpty) {
      await Future.wait(activeCleanups);
    }
    while (_pendingOutgoingConnections.isNotEmpty) {
      final attempts = _pendingOutgoingConnections.toList(growable: false);
      await Future.wait(attempts.map((attempt) async {
        try {
          await attempt.cancel();
        } catch (_) {
          // The tracked connection operation performs authoritative cleanup.
        }
        try {
          await attempt.completion;
        } catch (error, stackTrace) {
          logger.i(
            '等待出站 websocket 清理失败: ${error.runtimeType}\n$stackTrace',
          );
        }
      }));
    }
    final authenticatedSessions = authenticatedEntries
        .map((entry) => entry.value)
        .toSet()
        .toList(growable: false);
    for (final session in authenticatedSessions) {
      await session.stopReceivingAndDrain();
    }
    await _transferEngine.closeAll(
      persistRecoverable: hadAuthenticatedConnection,
    );
    if (hadAuthenticatedConnection && _manageSharedCoordinators) {
      await AudioShareCoordinator.shared.stopLocal();
      await AudioGroupCoordinator.shared.stopLocal();
      await RemoteInputWorkspaceCoordinator.shared.stopControllerWorkspace(
        sendControlTo: sendRemoteInputControlTo,
      );
      await RemoteInputCoordinator.shared.stopLocal();
    }
    await _audioManager.closeChannels();
    await _remoteInputManager.closeChannels();
    for (final session in authenticatedSessions) {
      await session.drainOutbound();
    }
    _sink = null;
    await _peerConnections.disconnectAll();
    for (final entry in authenticatedEntries) {
      await _handlePeerSocketDoneQueued(entry.key);
    }
    for (final session in authenticatedSessions) {
      session.releaseAdmission();
    }
    _sessionsBySink.clear();
    _sessionsByPeerId.clear();
    _terminalDisconnectCauses.clear();
    _sessionStartedPolicyRevisions.clear();
    _wireControlSessions.clearAll();
    _sessionUpgradeTokens.clearAll();
    _endpointsBySink.clear();
    _peerIdsBySink.clear();
    _remoteProfilesByPeerId.clear();
    if (closeServer) {
      await serverCloseFuture;
    } else if (!_closeServerRequested) {
      if (_server != null) {
        _acceptingUpgrades = true;
      }
      _acceptingOutgoingConnections = true;
    }
    _remoteProfile = null;
    _completeRemoteProfileRefreshWaiters();
    receiver = "";
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

  Future<void> _removePeerConnection(
    String peerId,
    PeerDisconnectCause cause,
  ) async {
    final binding = _peerConnections.currentBinding(peerId);
    if (binding == null) {
      return;
    }
    await _peerConnections.removeIfCurrent(
      binding,
      afterRemove: (removed) => _afterPeerRemoved(
        removed,
        closingSession: _sessionsByPeerId[peerId],
        cause: cause,
      ),
    );
  }

  Future<bool> _removeUnresponsivePeerIfCurrent(
    TransferConnectionBinding binding,
  ) {
    return _peerConnections.removeIfCurrent(
      binding,
      afterRemove: (removed) => _afterPeerRemoved(
        removed,
        closingSession: _sessionsByPeerId[removed.peerId],
        cause: PeerDisconnectCause.watchdog,
      ),
    );
  }

  @visibleForTesting
  Future<bool> debugRemovePeerForWatchdog(String peerId) {
    final binding = _peerConnections.currentBinding(peerId);
    if (binding == null) {
      return Future<bool>.value(false);
    }
    return _removeUnresponsivePeerIfCurrent(binding);
  }

  bool _removedBindingOwnsPeerState(
    TransferConnectionBinding binding,
  ) {
    if (_peerConnections.currentBinding(binding.peerId) != null) {
      return false;
    }
    final session = _sessionsByPeerId[binding.peerId];
    return session == null ||
        session.connectionGeneration == binding.generation;
  }

  Future<void> _afterPeerRemoved(
    TransferConnectionBinding binding, {
    PeerSocketSession? closingSession,
    required PeerDisconnectCause cause,
  }) async {
    final peerId = binding.peerId;
    final currentSession = _sessionsByPeerId[peerId];
    if (currentSession != null &&
        currentSession.connectionGeneration == binding.generation &&
        (closingSession == null || identical(currentSession, closingSession))) {
      _sessionsByPeerId.remove(peerId);
    }
    if (!_removedBindingOwnsPeerState(binding)) {
      return;
    }
    await _handlePeerDisconnected(
      peerId,
      stillOwnsCleanup: () => _removedBindingOwnsPeerState(binding),
    );
    if (!_removedBindingOwnsPeerState(binding)) {
      return;
    }
    _remoteProfilesByPeerId.remove(peerId);
    if (!_removedBindingOwnsPeerState(binding)) {
      return;
    }
    if (receiver == peerId) {
      receiver = _peerConnections.connectedPeerIds.isEmpty
          ? ''
          : _peerConnections.connectedPeerIds.first;
      if (receiver.isEmpty) {
        _sink = null;
        _setRemoteProfile(null);
      } else {
        selectPeer(receiver);
      }
    }
    if (_removedBindingOwnsPeerState(binding)) {
      // 会话生命周期终点:不论断因都结算稳定性复位,
      // 稳定连接挣得的退避复位不因手动断开等断因而丢失。
      _reconnectControllers[peerId]?.sessionClosed();
      _dispatchToAll((event) => event.onClose());
    }
    if (_removedBindingOwnsPeerState(binding) &&
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
    final audioState = AudioShareCoordinator.shared.state;
    if (audioState.isForPeer(peerId) && audioState.sessionId.isNotEmpty) {
      preserved['audio'] = <String>{audioState.sessionId};
    }

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

  Future<void> _handlePeerDisconnected(
    String peerId, {
    bool Function()? stillOwnsCleanup,
  }) async {
    bool ownsCleanup() => stillOwnsCleanup?.call() ?? true;

    if (!ownsCleanup()) {
      return;
    }
    _sessionUpgradeTokens.clearPeer(peerId);
    if (!ownsCleanup()) {
      return;
    }
    _wireControlSessions.clearPeer(
      peerId,
      preservedSessions: _manageSharedCoordinators
          ? _preservedControlSessionsForPeer(peerId)
          : const <String, Set<String>>{},
    );
    if (!ownsCleanup()) {
      return;
    }
    await Future.wait(<Future<void>>[
      _audioManager.closePeerChannels(peerId),
      _remoteInputManager.closePeerChannels(peerId),
    ]);
    if (!ownsCleanup()) {
      return;
    }
    await _transferEngine.handlePeerDisconnected(peerId);
    if (!ownsCleanup()) {
      return;
    }
    if (!_manageSharedCoordinators) {
      return;
    }
    await RemoteInputWorkspaceCoordinator.shared.handlePeerDisconnected(peerId);
    if (!ownsCleanup()) {
      return;
    }
    if (RemoteInputCoordinator.shared.state.isForPeer(peerId)) {
      await RemoteInputCoordinator.shared.stopLocal();
    }
  }

  Future<void> close({bool closeServer = false}) {
    return closeGracefully(closeServer: closeServer);
  }

  Future<bool> _sendBytesOnSink(
    WebSocketSink sink,
    Object message, {
    bool rawAuth = false,
  }) async {
    final session = _sessionsBySink[sink];
    final bytes = _outgoingBytes(message);
    if (session == null || bytes == null) {
      await _closeSocketSink(sink);
      return false;
    }
    final maxBytes =
        rawAuth ? _maxPreAuthMessageBytes : _maxAuthenticatedMessageBytes;
    if (bytes.length > maxBytes) {
      session.close();
      await _closeSocketSink(sink);
      return false;
    }
    if (rawAuth) {
      return session.enqueueOutgoing(bytes, byteLength: bytes.length);
    }
    if (!session.isAuthenticated) {
      await _closeSocketSink(sink);
      return false;
    }
    return session.enqueueAuthenticatedOutgoing(
      bytes,
      byteLength: bytes.length + _authenticatedFrameOverhead,
    );
  }

  Uint8List? _outgoingBytes(Object message) {
    if (message is Uint8List) {
      return message;
    }
    if (message is List<int>) {
      return Uint8List.fromList(message);
    }
    if (message is String) {
      return Uint8List.fromList(utf8.encode(message));
    }
    return null;
  }

  Uint8List _messageFrame(Uint8List payload) {
    return WhisperFrameV3(
      type: WhisperFrameType.message,
      transferId: '',
      offset: 0,
      sequence: 0,
      payload: payload,
    ).encode();
  }

  Future<bool> _sendMessageData(
    MessageData message, {
    String? peerId,
    WebSocketSink? sink,
    bool rawAuth = false,
  }) async {
    final payload = WhisperFrameV3(
      type: WhisperFrameType.message,
      transferId: '',
      offset: 0,
      sequence: 0,
      payload: Uint8List.fromList(utf8.encode(encodeWireMessage(message))),
    ).encode();
    if (sink != null) {
      return _sendBytesOnSink(sink, payload, rawAuth: rawAuth);
    }
    return _peerConnections.sendTargetedOrDefault(
      peerId: peerId,
      message: payload,
      sendDefault: () => _send(encodeWireMessage(message)),
    );
  }

  void _dispatchOutgoingMessage(MessageData message) {
    _dispatchToAll((event) => event.onMessage(message));
  }

  Future<bool> _sendBytesToPeer(String peerId, Object bytes) async {
    if (peerId.isNotEmpty) {
      return _peerConnections.sendToAwaited(peerId, bytes);
    }
    if (peerId.isEmpty) {
      final sink = _sink;
      if (sink != null) {
        return _sendBytesOnSink(sink, bytes);
      }
      return false;
    }
    return false;
  }

  Future<bool> _send(String message) async {
    final payload = _messageFrame(Uint8List.fromList(utf8.encode(message)));
    if (_peerConnections.isConnectedTo(receiver)) {
      return _peerConnections.sendToAwaited(receiver, payload);
    }
    final sink = _sink;
    if (sink != null) {
      return _sendBytesOnSink(sink, payload);
    }
    return false;
  }

  /// [asServer] 是本条 socket 的角色(服务端接入=true/本机拨出=false),
  /// 随消息逐层透传;设备可同时对不同 peer 兼具两种角色,不存在全局角色。
  Future<void> _handleIncomingMessage(
    dynamic message, {
    required WebSocketSink sink,
    required bool asServer,
  }) async {
    final session = _sessionsBySink[sink];
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
        await _listen(
          bytes,
          sink: sink,
          asServer: asServer,
          session: session,
        );
      } catch (error) {
        logger.i('处理 websocket 消息失败: ${error.runtimeType}');
        final failedSession = _sessionsBySink[sink];
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
            FormatException() =>
              PeerDisconnectCause.protocolFailure,
            _ => PeerDisconnectCause.localFailure,
          };
          await _failSocketSession(
            failedSession,
            sink,
            message,
            cause: cause,
          );
        } else {
          await _closeSocketSink(sink);
        }
      }
    });
    if (!accepted && identical(_sessionsBySink[sink], session)) {
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
      senderOverride: _sessionsBySink[sink]?.localProfile.uid,
      receiverOverride: envelope.action == AuthAction.hello
          ? envelope.intendedPeerId ?? ''
          : _sessionsBySink[sink]?.remotePeerId,
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
      await _failSocketSession(session, sink, 'upgrade_required');
    } on AuthHandshakeException catch (error) {
      if (error.code == 'upgrade_required' &&
          session.role == PeerSocketRole.server) {
        await _sendUpgradeRequired(sink, session);
      }
      await _failSocketSession(session, sink, error.code);
    }
  }

  Future<void> _handleServerHello(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope hello,
  ) async {
    final challenge = await session.receiveHello(hello);
    final peerId = session.remotePeerId;
    if (!_isSessionPeerPolicyCurrent(session)) {
      throw const AuthHandshakeException('session_expired');
    }
    if (!_authRequestGate.tryClaimIncoming(peerId)) {
      session.close();
      await _closeSocketSink(sink);
      return;
    }
    _incomingAuthPeerIdsBySink[sink] = peerId;

    final pinPlan = await _pairingReason(session);
    _requirePairingForTrustRepair(session.remotePeerId, pinPlan.reason);
    _identityPinPlansBySink[sink] = pinPlan;
    final generation = session.connectionGeneration;
    await _sendAuthEnvelope(sink, challenge);
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }

    Future<void> resolve(bool allow) async {
      final accepted = session.resolveLocalApproval(
        generation: generation,
        allow: allow,
      );
      if (!accepted || !_isCurrentSession(session, sink, generation)) {
        return;
      }
      await _tryCompleteServerPairing(session, sink);
    }

    if (pinPlan.reason == null) {
      await resolve(true);
    } else {
      await _requestPairingDecision(
        session,
        sink,
        pinPlan.reason!,
        PairingPromptMode.responder,
        resolve,
      );
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
    if (!_isPendingPolicyCurrent(attempt)) {
      throw const AuthHandshakeException('session_expired');
    }
    if (attempt.request.isAutomatic &&
        !await _automaticAttemptStillEligible(attempt, session)) {
      throw const AuthHandshakeException('identity_pin_conflict');
    }
    final pinPlan = await _pairingReason(session);
    _requirePairingForTrustRepair(session.remotePeerId, pinPlan.reason);
    if (pinPlan.reason != null && attempt.request.isAutomatic) {
      _completeSocketAuth(sink, false, 'automatic_pairing_required');
      session.close();
      await _closeSocketSink(sink);
      return;
    }
    final generation = session.connectionGeneration;
    _identityPinPlansBySink[sink] = pinPlan;
    final approved = session.resolveLocalApproval(
      generation: generation,
      allow: true,
    );
    if (!approved || !_isSameSession(session, sink, generation)) {
      return;
    }

    Future<void> resolve(bool keepConnecting) async {
      if (keepConnecting || !_isSameSession(session, sink, generation)) {
        return;
      }
      _identityPinPlansBySink.remove(sink);
      _completeSocketAuth(sink, false, 'request_cancelled');
      await attempt.cancel(reason: ConnectionAttemptReason.requestCancelled);
      await _closeSocketSink(sink);
    }

    final proof = await session.createProof();
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }
    final approval = await session.createApproval(
      allow: true,
      reason: 'approved',
    );
    if (!_isSameSession(session, sink, generation)) {
      return;
    }
    final credentialSend = () async {
      await _sendAuthEnvelope(sink, proof);
      if (!_isSameSession(session, sink, generation)) {
        return;
      }
      await _sendAuthEnvelope(sink, approval);
    }();

    if (pinPlan.reason == null) {
      await credentialSend;
    } else {
      await Future.wait(<Future<void>>[
        credentialSend,
        _requestPairingDecision(
          session,
          sink,
          pinPlan.reason!,
          PairingPromptMode.initiator,
          resolve,
        ),
      ]);
    }
  }

  Future<bool> _automaticAttemptStillEligible(
    _PendingOutgoingConnection attempt,
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
    final outgoingKey = _authRequestKey(
      peerId: session.remotePeerId,
      host: '',
      port: 0,
    );
    if (_authRequestGate.hasOutgoing(outgoingKey)) {
      final decision = resolveSimultaneousDial(
        localUid: session.localProfile.uid,
        remoteUid: session.remotePeerId,
      );
      if (decision == SimultaneousDialDecision.keepOutgoing) {
        session.close();
        await _closeSocketSink(sink);
        return;
      }
    }
    await _tryCompleteServerPairing(session, sink);
  }

  Future<void> _handleServerApproval(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope approval,
  ) async {
    await session.receiveApproval(approval);
    await _tryCompleteServerPairing(session, sink);
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
    final result = await session.createResult(
      allow: true,
      reason: 'approved',
    );
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }
    await AuthHandshakeLifecycle.completeServerAllow<DeviceData>(
      commit: () => _completeAuthenticatedSession(
        session,
        sink,
        pinPlan: pinPlan,
      ),
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
    _ignoreFuture(
      ConnectionRequestNotifier().maybeShowForPairing(
        peerId: session.remotePeerId,
      ),
      context: 'show pairing notification',
    );
    final guarded = session.guardApprovalCallback((allow) {
      _runGuardedApproval(
        session: session,
        sink: sink,
        generation: generation,
        resolve: () => resolve(allow),
      );
    });
    _dispatchGuarded(
      listener,
      (event) => event.onPairing(
        PairingRequest(
          device: device,
          pairingCode: session.pairingCode,
          reason: reason,
          mode: mode,
          cancellation: session.pairingResolved,
        ),
        guarded,
      ),
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
    final endpoint = _endpointsBySink[sink];
    final host =
        endpoint?.host.isNotEmpty == true ? endpoint!.host : stored?.host ?? '';
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
      () => _completeAuthenticatedSessionSerialized(
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
    _requireCurrentAuthenticationCommit(session, sink, generation);
    DeviceData? storedDevice;
    PeerProfile? runtimeProfile;
    var published = false;
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
          storedDevice = device;
          runtimeProfile = PeerProfile(
            device: device,
            trustedPeerIds: const <String>[],
            autoApproveNewDevices: false,
            autoConnectEnabled: true,
            protocolVersion: session.remoteProfile!.protocolVersion,
            capabilities: session.remoteProfile!.capabilities,
            displayTopology: session.remoteProfile!.displayTopology,
          );
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
          await _registerPeerConnection(
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
      _removePeerAuthSuppression(
        session.remotePeerId,
        _PeerAuthSuppressionReason.trustRevoked,
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

  Future<void> _closeSupersededMediaChannels(PeerSocketSession session) async {
    final mediaReceiveKey = session.mediaReceiveKey;
    if (mediaReceiveKey == null) {
      throw const AuthHandshakeException('media_key_missing');
    }
    await Future.wait(<Future<void>>[
      _audioManager.closeSupersededPeerChannels(
        session.remotePeerId,
        mediaMacKey: mediaReceiveKey,
      ),
      _remoteInputManager.closeSupersededPeerChannels(
        session.remotePeerId,
        mediaMacKey: mediaReceiveKey,
      ),
    ]);
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
    _dispatchToAll((event) => event.onConnect());
    if (session.role == PeerSocketRole.server) {
      _dispatchToAll((event) => event.afterAuth(true, storedDevice));
    }
    _ignoreFuture(
      _transferEngine.resumeRecoverableOutgoing(),
      context: 'resume outgoing transfers',
    );
  }

  bool _isSameSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    return identical(_sessionsBySink[sink], session) &&
        session.connectionGeneration == generation;
  }

  bool _isCurrentSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    return _isSameSession(session, sink, generation) && !session.isClosed;
  }

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
    final peerId = session.remotePeerId;
    WireInputPolicy.validateSessionBinding(
      isAuthenticated: session.isAuthenticated,
      sessionPeerId: peerId,
      sinkPeerId: _peerIdsBySink[sink] ?? '',
      sessionGeneration: generation,
      isCurrentSession: identical(_sessionsByPeerId[peerId], session),
      isCurrentConnection: _peerConnections.isCurrent(peerId, generation),
    ).requireAccepted();
  }

  PeerProfile _requireRemoteProfileForSession(PeerSocketSession session) {
    final peerId = session.remotePeerId;
    final profile = _remoteProfilesByPeerId[peerId];
    if (profile == null || profile.device.uid != peerId) {
      throw const WireInputRejected(WireInputReason.sessionNotCurrent);
    }
    return profile;
  }

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
    PeerSocketSession session,
  ) async {
    final payload = jsonEncode(<String, Object?>{
      'action': 'upgrade_required',
      'version': PeerSocketSession.protocolVersion,
    });
    final message = _buildMessage(
      MessageEnum.Auth,
      payload,
      'upgrade_required',
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
    }
    if (!session.isAuthenticated && frame.type != WhisperFrameType.message) {
      throw const WireInputRejected(
        WireInputReason.sessionNotAuthenticated,
      );
    }
    if (frame.type == WhisperFrameType.fileData &&
        frame.payload.length > _maxFileDataPayloadBytes) {
      throw const WireInputRejected(
        WireInputReason.transferPayloadInvalid,
      );
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
        receiver: receiver,
        name: "",
        clipboard: false,
        size: 0,
        type: MessageEnum.UNKONWN,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        uuid: '',
        acked: false,
        path: '',
        md5: '');
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
      throw const WireInputRejected(
        WireInputReason.sessionNotAuthenticated,
      );
    }
    if (session.isAuthenticated) {
      requireCurrentBusiness();
      WireInputPolicy.validateMessage(
        message,
        authenticatedPeerId: session.remotePeerId,
        localPeerId: session.localProfile.uid,
      ).requireAccepted();
    }
    if (message.type == MessageEnum.Text) {
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
            _dispatchToAll((event) => event.onMessage(acknowledged));
          }
          break;
        }
      case MessageEnum.Text:
        {
          logger.i(
              "收到消息：${message.content} sender: ${message.sender} receiver: ${message.receiver}");
          if (message.clipboard) {
            if ((await LocalSetting().instance()).clipboard) {
              requireCurrentBusiness();
              copyToClipboard(
                message.content ?? "",
                suppressWatcher: true,
              );
            }
          }
          requireCurrentBusiness();
          _dispatchToAll((event) => event.onMessage(message));
          await _ackMessage(message);
          logger.i("文本消息：$str");
          break;
        }
      case MessageEnum.Notification:
        {
          var data = jsonDecode(message.content ?? "{}");
          final ignoreNotification =
              await LocalSetting().ignoreAndroidNotification();
          requireCurrentBusiness();
          if (!ignoreNotification) {
            if (supportNotification() && data['text'] != null) {
              NotificationHelper().showNotification(
                  title: "【${data['app']}】 ${data['title']}",
                  body: data['text'] ?? "");
              if (isVerificationCodeNotificationPackage(data['package'])) {
                var code =
                    verifyCode('${data["title"] ?? ""}\n${data["text"] ?? ""}');
                if (code.isNotEmpty && await LocalSetting().copyVerify()) {
                  requireCurrentBusiness();
                  copyToClipboard(code);
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
          await _refreshRemoteProfileFromHeartbeat(
            message,
            peerId: incomingPeerId,
            requireCurrent: requireCurrentBusiness,
          );
          requireCurrentBusiness();
          if (message.message == _profileRefreshRequestMessage) {
            unawaited(_heartBeat(peerId: incomingPeerId, sink: sink));
          }
          await _ackMessage(message);
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
        {
          final json =
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>;
          WireInputPolicy.validateControlEnvelope(
            json,
            allowedActions: _audioControlActions,
          ).requireAccepted();
          final control = AudioControlMessage.fromJson(json);
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
                namespace: 'audio',
                sessionId: control.sessionId,
                sourcePeerId: control.sourcePeerId,
                sinkPeerId: control.sinkPeerId,
                authenticatedPeerId: session.remotePeerId,
                localPeerId: session.localProfile.uid,
                isInitialOffer: control.action == AudioControlAction.offer,
                isIncoming: true,
              )
              .requireAccepted();
          final self = await LocalSetting().instance();
          requireCurrentBusiness();
          final remoteDevice = _requireRemoteProfileForSession(session).device;
          final isTerminal = control.action == AudioControlAction.reject ||
              control.action == AudioControlAction.stop ||
              control.action == AudioControlAction.error;
          try {
            await AudioShareCoordinator.shared.handleControlMessage(
              control,
              localPeerId: self.uid,
              remoteHost: remoteDevice.host,
              remotePort: remoteDevice.port,
              mediaSendKey: session.mediaSendKey,
              sendControl: (control) =>
                  sendAudioControlTo(session.remotePeerId, control),
            );
          } finally {
            if (isTerminal) {
              await _releaseTerminalControl(
                namespace: 'audio',
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
          _wireControlSessions
              .validateAndRemember(
                namespace: 'audio-group',
                sessionId: control.sessionId,
                sourcePeerId: control.sourcePeerId,
                sinkPeerId: control.sinkPeerId,
                authenticatedPeerId: session.remotePeerId,
                localPeerId: session.localProfile.uid,
                isInitialOffer: control.action ==
                        AudioGroupControlAction.groupOffer ||
                    control.action == AudioGroupControlAction.sinkJoinRequest,
                isIncoming: true,
                reverseInitialDirection:
                    control.action == AudioGroupControlAction.sinkJoinRequest,
                context: '${control.groupId}\u0000${control.streamId}',
              )
              .requireAccepted();
          final self = await LocalSetting().instance();
          requireCurrentBusiness();
          final remoteDevice = _requireRemoteProfileForSession(session).device;
          final isTerminal =
              control.action == AudioGroupControlAction.groupReject ||
                  control.action == AudioGroupControlAction.groupStop ||
                  control.action == AudioGroupControlAction.error;
          try {
            await AudioGroupCoordinator.shared.handleControlMessage(
              control,
              localPeerId: self.uid,
              remoteHost: remoteDevice.host,
              remotePort: remoteDevice.port,
              mediaSendKey: session.mediaSendKey,
              sendControl: (_, control) =>
                  sendAudioGroupControlTo(session.remotePeerId, control),
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
          final self = await LocalSetting().instance();
          requireCurrentBusiness();
          final remoteDevice = _requireRemoteProfileForSession(session).device;
          final storedRemote = await _database.fetchDevice(remoteDevice.uid);
          requireCurrentBusiness();
          final authenticatedSession = _sessionsByPeerId[remoteDevice.uid];
          final isMutuallyTrusted = storedRemote?.auth == true &&
              storedRemote?.identityPublicKey.isNotEmpty == true &&
              storedRemote?.identityPublicKey ==
                  authenticatedSession?.remoteIdentityPublicKey &&
              authenticatedSession?.isAuthenticated == true;
          final localCanInject = supportsNativeRemoteInput();
          _remoteInputTrace(
            'remote input recv control ${_remoteInputControlSummary(control)} '
            'local=${self.uid} '
            'remote=${remoteDevice.uid} '
            'remoteAddress=${remoteDevice.host}:${remoteDevice.port} '
            'storedAuth=${storedRemote?.auth == true} '
            'signedSession=${authenticatedSession?.isAuthenticated == true} '
            'mutualTrust=$isMutuallyTrusted '
            'localCanInject=$localCanInject '
            'remoteSupports=$supportsRemoteInput',
          );
          final isTerminal =
              control.action == RemoteInputControlAction.reject ||
                  control.action == RemoteInputControlAction.stop ||
                  control.action == RemoteInputControlAction.error;
          final handledByWorkspaceBusy = await RemoteInputWorkspaceCoordinator
              .shared
              .handleIncomingOfferIfBusy(
            control,
            localPeerId: self.uid,
            sendControlTo: (_, control) =>
                sendRemoteInputControlTo(session.remotePeerId, control),
          );
          requireCurrentBusiness();
          if (handledByWorkspaceBusy) {
            await _ackMessage(message);
            break;
          }
          try {
            final handledByWorkspace = await RemoteInputWorkspaceCoordinator
                .shared
                .handleControlMessage(
              control,
              localPeerId: self.uid,
              remoteHost: remoteDevice.host,
              remotePort: remoteDevice.port,
              mediaSendKey: session.mediaSendKey,
              sendControlTo: (peerId, control) =>
                  sendRemoteInputControlTo(peerId, control),
            );
            requireCurrentBusiness();
            if (handledByWorkspace) {
              await _ackMessage(message);
              break;
            }
            await RemoteInputCoordinator.shared.handleControlMessage(
              control,
              localPeerId: self.uid,
              remoteHost: remoteDevice.host,
              remotePort: remoteDevice.port,
              isMutuallyTrusted: isMutuallyTrusted,
              localCanInject: localCanInject,
              mediaSendKey: session.mediaSendKey,
              sendControl: (control) =>
                  sendRemoteInputControlTo(session.remotePeerId, control),
              remotePlatform: remoteDevice.platform,
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
      MessageEnum type, String content, msg, fileName, int size, bool clipboard,
      {String md5 = "",
      path = "",
      uid,
      fileTimestamp = 0,
      String? senderOverride,
      String? receiverOverride}) {
    final resolvedReceiver = receiverOverride ?? receiver;
    final resolvedSender = senderOverride ??
        _sessionsByPeerId[resolvedReceiver]?.localProfile.uid ??
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
        fileTimestamp: fileTimestamp);
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
        systemAudioSourceV1: supportsNativeSystemAudio(),
        speakerSinkV1: true,
        remoteInputSourceV1: supportsNativeRemoteInput(),
        remoteInputSinkV1: supportsNativeRemoteInput(),
        remoteInputTopologyV1: hasTopology,
        audioGroupSourceV1: supportsNativeSystemAudio(),
        audioGroupSinkV1: true,
        audioGroupRejoinV1: true,
        audioSyncClockV1: true,
        audioChannelRoleV1: true,
      ),
      displayTopology: topology,
    );
    return profile;
  }

  Future<PeerProfile?> requestRemoteProfileRefresh({
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    if (_sink == null) {
      return _remoteProfile;
    }

    final startRevision = _remoteProfileRevision;
    final completer = Completer<PeerProfile?>();
    _remoteProfileRefreshWaiters.add(completer);
    final timer = Timer(timeout, () {
      _remoteProfileRefreshWaiters.remove(completer);
      if (!completer.isCompleted) {
        completer.complete(_remoteProfile);
      }
    });

    try {
      await _heartBeat(profileRefreshRequest: true);
      if (_remoteProfileRevision != startRevision && !completer.isCompleted) {
        _remoteProfileRefreshWaiters.remove(completer);
        completer.complete(_remoteProfile);
      }
    } catch (_) {
      _remoteProfileRefreshWaiters.remove(completer);
      timer.cancel();
      if (!completer.isCompleted) {
        completer.complete(_remoteProfile);
      }
    }

    return completer.future.whenComplete(timer.cancel);
  }

  void _setRemoteProfile(PeerProfile? profile, {String? peerId}) {
    final hasPeerId = peerId != null && peerId.isNotEmpty;
    if (hasPeerId) {
      if (profile == null) {
        _remoteProfilesByPeerId.remove(peerId);
      } else {
        _remoteProfilesByPeerId[peerId] = profile;
      }
    } else if (profile == null) {
      _remoteProfilesByPeerId.clear();
    }

    if (hasPeerId && peerId != receiver) {
      return;
    }
    _setSelectedRemoteProfile(profile);
  }

  void _setSelectedRemoteProfile(PeerProfile? profile) {
    _remoteProfile = profile;
    _remoteProfileRevision++;
    _completeRemoteProfileRefreshWaiters();
  }

  void _completeRemoteProfileRefreshWaiters() {
    final waiters = _remoteProfileRefreshWaiters.toList(growable: false);
    _remoteProfileRefreshWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(_remoteProfile);
      }
    }
  }

  bool _profileDeviceChanged(DeviceData? previous, DeviceData next) {
    if (previous == null) {
      return true;
    }
    return previous.name != next.name ||
        previous.host != next.host ||
        previous.port != next.port ||
        previous.platform != next.platform;
  }

  Future<void> _refreshRemoteProfileFromHeartbeat(
    MessageData message, {
    String? peerId,
    void Function()? requireCurrent,
  }) async {
    final content = message.content;
    if (content == null || content.isEmpty) {
      return;
    }
    try {
      final resolvedPeerId = peerId ?? message.sender;
      final previousProfile = resolvedPeerId.isEmpty
          ? _remoteProfile
          : _remoteProfilesByPeerId[resolvedPeerId];
      final wireJson = Map<String, Object?>.from(
        jsonDecode(content) as Map,
      );
      final wireProfile = WirePeerProfile.fromJson(wireJson);
      final profile = PeerProfile.fromWire(
        wireProfile,
        host: previousProfile?.device.host ?? '',
        port: previousProfile?.device.port ?? 0,
      );
      WireInputPolicy.validateClaimedPeerId(
        claimedPeerId: profile.device.uid,
        authenticatedPeerId: resolvedPeerId,
      ).requireAccepted();
      requireCurrent?.call();
      final profileDeviceChanged =
          _profileDeviceChanged(previousProfile?.device, profile.device);
      _setRemoteProfile(profile, peerId: resolvedPeerId);
      if (profile.device.uid.isNotEmpty) {
        requireCurrent?.call();
        await _database.upsertDevice(profile.device);
        requireCurrent?.call();
        if (_manageSharedCoordinators &&
            _peerConnections.isConnectedTo(profile.device.uid)) {
          ConnectionCoordinator().markConnected(
            profile.device,
            select: resolvedPeerId == receiver,
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
      send: () => _sendMessageData(
        decodeWireMessage(json),
        peerId: data.sender,
      ),
      onError: (error, stackTrace) {
        logger.i('send acknowledgement failed: ${error.runtimeType}');
      },
    );
  }

  Future<void> _heartBeat({
    bool profileRefreshRequest = false,
    WebSocketSink? sink,
    String? peerId,
  }) async {
    final targetPeerId = peerId?.isNotEmpty == true
        ? peerId!
        : sink == null
            ? receiver
            : _peerIdForSink(sink) ?? '';
    if (targetPeerId.isEmpty) {
      return;
    }
    if (sink != null) {
      final session = _sessionsBySink[sink];
      if (session == null || session.remotePeerId != targetPeerId) {
        return;
      }
      try {
        _requireCurrentBusinessSession(
          session,
          sink,
          session.connectionGeneration,
        );
      } on WireInputRejected {
        return;
      } on AuthHandshakeException {
        return;
      }
    }
    final profile = await _localPeerProfile();
    var message = _buildMessage(
        MessageEnum.Heartbeat,
        profile.toJsonString(),
        profileRefreshRequest ? _profileRefreshRequestMessage : "",
        "",
        0,
        false,
        senderOverride: profile.device.uid,
        receiverOverride: targetPeerId);
    await _sendMessageData(
      message,
      peerId: sink == null ? targetPeerId : null,
      sink: sink,
    );
  }

  Future<void> refreshConnectionLiveness() async {
    await _heartBeat();
  }

  Future<void> broadcastLocalProfileUpdate() async {
    if (connectedPeerIds.isEmpty) {
      await _heartBeat();
      return;
    }
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
    final session = _sessionsByPeerId[peerId];
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

  String? _issueSessionUpgradeToken({
    required String route,
    required String namespace,
    required String peerId,
    required String sessionId,
    required String sourcePeerId,
    required String sinkPeerId,
  }) {
    final session = _sessionsByPeerId[peerId];
    final mediaReceiveKey = session?.mediaReceiveKey;
    if (session == null ||
        !session.isAuthenticated ||
        mediaReceiveKey == null ||
        sourcePeerId != peerId ||
        sinkPeerId != session.localProfile.uid) {
      return null;
    }
    return _sessionUpgradeTokens.issue(
      route: route,
      namespace: namespace,
      sessionId: sessionId,
      peerId: peerId,
      mediaMacKey: mediaReceiveKey,
      connectionGeneration: session.connectionGeneration,
      now: DateTime.now(),
    );
  }

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
    } else if (route == '/input') {
      await _remoteInputManager.closeSessionChannels(
        sessionId,
        peerId: peerId,
        namespace: namespace,
      );
    }
    _wireControlSessions.forget(
      namespace: namespace,
      sessionId: sessionId,
    );
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

  Future<bool> sendAudioControl(AudioControlMessage control) {
    return sendAudioControlTo(receiver, control);
  }

  Future<bool> sendAudioControlTo(
    String peerId,
    AudioControlMessage control,
  ) {
    if (!_validateOutgoingControlSession(
      namespace: 'audio',
      peerId: peerId,
      sessionId: control.sessionId,
      sourcePeerId: control.sourcePeerId,
      sinkPeerId: control.sinkPeerId,
      isInitialOffer: control.action == AudioControlAction.offer,
    )) {
      return Future<bool>.value(false);
    }
    var outgoing = control.withTransportToken('');
    if (control.action == AudioControlAction.accept) {
      final acceptedSession = _audioManager.session(control.sessionId);
      if (acceptedSession?.state != AudioShareSessionState.connected ||
          acceptedSession?.sourcePeerId != control.sourcePeerId ||
          acceptedSession?.sinkPeerId != control.sinkPeerId) {
        return Future<bool>.value(false);
      }
      final token = _issueSessionUpgradeToken(
        route: '/audio',
        namespace: 'audio',
        peerId: peerId,
        sessionId: control.sessionId,
        sourcePeerId: control.sourcePeerId,
        sinkPeerId: control.sinkPeerId,
      );
      if (token == null) {
        return Future<bool>.value(false);
      }
      outgoing = control.withTransportToken(token);
    }
    final message = _buildMessage(
      MessageEnum.AudioControl,
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
      isTerminal: control.action == AudioControlAction.reject ||
          control.action == AudioControlAction.stop ||
          control.action == AudioControlAction.error,
      namespace: 'audio',
      route: '/audio',
      peerId: peerId,
      sessionId: control.sessionId,
    );
  }

  Future<bool> sendAudioGroupControl(AudioGroupControlMessage control) {
    return sendAudioGroupControlTo(receiver, control);
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
      isInitialOffer: control.action == AudioGroupControlAction.groupOffer ||
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
      isTerminal: control.action == AudioGroupControlAction.groupReject ||
          control.action == AudioGroupControlAction.groupStop ||
          control.action == AudioGroupControlAction.error,
      namespace: 'audio-group',
      route: '/audio',
      peerId: peerId,
      sessionId: control.sessionId,
    );
  }

  Future<bool> sendRemoteInputControl(RemoteInputControlMessage control) {
    return sendRemoteInputControlTo(receiver, control);
  }

  Future<bool> sendRemoteInputControlTo(
    String peerId,
    RemoteInputControlMessage control,
  ) {
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
      outgoing = control.withTransportToken(token);
    }
    _remoteInputTrace(
      'remote input send control ${_remoteInputControlSummary(control)} '
      'sender=$sender receiver=$peerId connected=$isConnected '
      'remoteSupports=$supportsRemoteInput',
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
      isTerminal: control.action == RemoteInputControlAction.reject ||
          control.action == RemoteInputControlAction.stop ||
          control.action == RemoteInputControlAction.error,
      namespace: 'remote-input',
      route: '/input',
      peerId: peerId,
      sessionId: control.sessionId,
    );
  }

  Future<bool> sendMessage(String content, {clipboard = false}) {
    return sendMessageTo(receiver, content, clipboard: clipboard);
  }

  Future<bool> sendMessageTo(
    String peerId,
    String content, {
    bool clipboard = false,
  }) {
    return _outgoingTextSendLocks.synchronized(
      peerId,
      () => _sendMessageToSerialized(
        peerId,
        content,
        clipboard: clipboard,
      ),
    );
  }

  Future<bool> _sendMessageToSerialized(
    String peerId,
    String content, {
    required bool clipboard,
  }) async {
    final canUseLegacySink = peerId == receiver && _sink != null;
    if (peerId.isEmpty || (!isConnectedTo(peerId) && !canUseLegacySink)) {
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
      String? package, String? title, String? text) async {
    if (_sink == null || package == null && title == null && text == null) {
      return;
    }
    var content = {
      "app": await appName(package),
      "package": package,
      "title": title,
      "text": text,
    };

    var message = _buildMessage(
        MessageEnum.Notification, jsonEncode(content), "", "", 0, false);
    await _send(encodeWireMessage(message));
  }

  Future<bool> sendFile(String path) async {
    return sendFileTo(receiver, path);
  }

  Future<bool> sendFileTo(String peerId, String path) =>
      _transferEngine.sendFileTo(peerId, path);

  Future<bool> sendPickedFileTo(String peerId, PickedTransferFile item) =>
      _transferEngine.sendPickedFileTo(peerId, item);

  Future<void> retryTransfer(String transferId) =>
      _transferEngine.retryTransfer(transferId);

  Future<void> cancelTransfer(String transferId) =>
      _transferEngine.cancelTransfer(transferId);
}
