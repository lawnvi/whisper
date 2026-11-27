import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/socket/auth_failure_result.dart';
import 'package:whisper/socket/backpressure_web_socket.dart';
import 'package:whisper/socket/direct_peer_http_client.dart';
import 'package:whisper/socket/peer_auth_coordinator.dart';
import 'package:whisper/socket/peer_directory.dart';
import 'package:whisper/socket/peer_policy_store.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/pending_outgoing_connection.dart';
import 'package:whisper/socket/socket_events.dart';
import 'package:whisper/socket/staggered_dialer.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';

abstract interface class PeerDialerHost {
  PeerDirectory get peers;
  PeerPolicyStore get policy;
  PeerAuthCoordinator get auth;
  LocalDatabase get database;
  Uuid get uuid;
  Duration get socketCloseTimeout;
  Duration get outgoingConnectionTimeout;
  Duration get serverPingInterval;
  Duration get manualPreemptWaitTimeout;
  bool get manageSharedCoordinators;
  bool get acceptingOutgoingConnections;
  Future<bool> Function() get autoConnectEnabled;
  Future<void> Function(bool enabled) get setAutoConnectEnabled;
  PeerReconnectControllerFactory get reconnectControllerFactory;

  Future<PeerSocketSession> createSocketSession({
    required WebSocketSink sink,
    required PeerSocketRole role,
    String intendedPeerId = '',
    String intendedPublicKeyHash = '',
    int protocolVersion = PeerSocketSession.protocolVersion,
  });
  void attachSocketTransport(
    WebSocketChannel webSocket,
    PeerSocketSession session, {
    required bool asServer,
  });
  Future<void> handlePeerSocketDoneQueued(WebSocketSink sink);
  Future<void> removePeerConnection(String peerId, PeerDisconnectCause cause);
  void setRemoteProfile(PeerProfile? profile, {String? peerId});
  void ignoreFuture(Future<void> future, {required String context});
}

/// Manages outbound `/chat` connection attempts (including staggered multi-
/// candidate dialing and manual preemption), per-peer reconnect controllers,
/// auto-connect policy, and system-sleep teardown/resume.
class PeerDialer {
  PeerDialer(this._host);

  final PeerDialerHost _host;

  final Map<String, PeerReconnectController> _reconnectControllers =
      <String, PeerReconnectController>{};
  final Set<String> _quietReconnects = <String>{};
  final Set<PendingOutgoingConnection> _pendingOutgoingConnections =
      <PendingOutgoingConnection>{};
  final Map<String, PendingOutgoingConnection> _pendingOutgoingByRequestId =
      <String, PendingOutgoingConnection>{};
  final Map<String, Set<PendingOutgoingConnection>> _pendingOutgoingByPeerId =
      <String, Set<PendingOutgoingConnection>>{};
  final Map<WebSocketSink, PendingOutgoingConnection> _pendingOutgoingBySink =
      <WebSocketSink, PendingOutgoingConnection>{};

  bool _reconnectManagerClosed = false;
  bool? _autoConnectPolicyOverride;
  bool _systemSleeping = false;
  final Set<String> _systemSleepReconnectPeerIds = <String>{};

  bool get systemSleeping => _systemSleeping;

  bool? get autoConnectPolicyOverride => _autoConnectPolicyOverride;

  bool get hasPendingOutgoingConnections =>
      _pendingOutgoingConnections.isNotEmpty;

  PendingOutgoingConnection? pendingForSink(WebSocketSink sink) =>
      _pendingOutgoingBySink[sink];

  bool hasPendingConnectionAttempt(String requestId) =>
      _pendingOutgoingByRequestId.containsKey(requestId);

  bool hasPendingConnectionAttemptForPeer(String peerId) =>
      _pendingOutgoingByPeerId[peerId]?.isNotEmpty == true;

  bool hasUncancelledPendingAttemptForPeer(String peerId) =>
      _pendingOutgoingByPeerId[peerId]?.any(
        (attempt) => !attempt.isCancelled,
      ) ==
      true;

  bool hasReadyPendingOutgoingForPeer(String peerId) {
    if (peerId.isEmpty) return false;
    final attempts = _pendingOutgoingByPeerId[peerId];
    return attempts != null &&
        attempts.any((attempt) => !attempt.isCancelled && attempt.isReady);
  }

  bool hasPendingOutgoingForPeer(String peerId) {
    if (peerId.isEmpty) return false;
    final attempts = _pendingOutgoingByPeerId[peerId];
    return attempts != null && attempts.any((attempt) => !attempt.isCancelled);
  }

  void markServerStarted() {
    _reconnectManagerClosed = false;
  }

  void closeReconnectControllersForShutdown() {
    _reconnectManagerClosed = true;
    for (final controller in _reconnectControllers.values) {
      controller.close();
    }
    _reconnectControllers.clear();
  }

  PeerReconnectController _reconnectControllerFor(String peerId) {
    return _reconnectControllers.putIfAbsent(
      peerId,
      () => _host.reconnectControllerFactory(
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
    final currentProfile = _host.peers.remoteProfileFor(peerId);
    if (currentProfile != null &&
        (currentProfile.device.host != target.host ||
            currentProfile.device.port != target.port)) {
      _host.setRemoteProfile(
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
    scheduleReconnectTarget(
      ReconnectTarget(peerId: peerId, host: host, port: port),
    );
  }

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

  void onPeerSessionClosed(String peerId) {
    _reconnectControllers[peerId]?.sessionClosed();
  }

  void scheduleReconnectAfterNetworkDrop(String peerId) {
    if (hasUncancelledPendingAttemptForPeer(peerId)) {
      return;
    }
    final target = _reconnectControllers[peerId]?.target;
    if (target != null) {
      _reconnectControllers[peerId]?.scheduleReconnect(target);
    }
  }

  void onPeerManualDisconnect(String peerId) {
    _reconnectControllers[peerId]?.manualDisconnect();
  }

  void onPeerTrustRevoked(String peerId) {
    _reconnectControllers[peerId]?.trustRevoked();
  }

  void onPeerIdentityUnpinned(String peerId) {
    _reconnectControllers[peerId]?.identityUnpinned();
  }

  void onPeerTrustRestored(String peerId) {
    final controller = _reconnectControllers[peerId];
    controller?.identityPinned();
    controller?.trustRestored();
    final target = controller?.target;
    if (controller != null && target != null && !controller.isSuppressed) {
      controller.scheduleReconnect(target);
    }
  }

  FutureOr<ReconnectEligibilityResult> _reconnectEligibility(
    ReconnectTarget target,
  ) async {
    if (_reconnectManagerClosed ||
        _autoConnectPolicyOverride == false ||
        !await _host.autoConnectEnabled()) {
      return ReconnectEligibilityResult.autoConnectDisabled;
    }
    final stored = await _host.database.fetchDevice(target.peerId);
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
    final peerId = context.target.peerId;
    final shared = _host.manageSharedCoordinators;
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
        if (shared && !_host.peers.isConnectedTo(peerId)) {
          ConnectionCoordinator().markDisconnected(peerId: peerId);
        }
      }
    }
  }

  Future<ConnectionAttemptStatus> _attemptReconnect(
    ReconnectAttemptContext context,
  ) async {
    final target = context.target;
    final eligibility = await _reconnectEligibility(target);
    if (!context.isCurrent ||
        eligibility != ReconnectEligibilityResult.eligible) {
      return ConnectionAttemptStatus.cancelled;
    }
    final stored = await _host.database.fetchDevice(target.peerId);
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
    final allCandidates = _host.manageSharedCoordinators
        ? ConnectionCoordinator().candidateEndpointsFor(
            target.peerId,
            primary: target.endpoint,
          )
        : <PeerEndpoint>[target.endpoint];
    final result = await connectToServer(
      ConnectionAttemptRequest(
        requestId:
            'reconnect:${target.peerId}:${context.generation}:${_host.uuid.v4()}',
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
      final storedDevice = await _host.database.fetchDevice(result.peerId);
      if (context.isCurrent &&
          storedDevice != null &&
          _host.peers.isCurrent(result.peerId, result.generation) &&
          _host.manageSharedCoordinators) {
        final activePeerId = ConnectionCoordinator().snapshot.activePeerId;
        final shouldSelect =
            activePeerId == null || activePeerId == result.peerId;
        ConnectionCoordinator().markConnected(
          storedDevice,
          select: shouldSelect,
        );
      }
    }
    return result.status;
  }

  void recordAuthenticatedReconnect(
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
    if (_host.manageSharedCoordinators) {
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

  Future<void> setAutoConnectPolicy(bool enabled) async {
    if (!enabled) {
      _autoConnectPolicyOverride = false;
      _host.policy.bumpGlobalPolicyEpoch();
      for (final controller in _reconnectControllers.values) {
        controller.autoConnectDisabled();
      }
      final automaticAttempts = _pendingOutgoingConnections
          .where((attempt) => attempt.request.isAutomatic)
          .toList(growable: false);
      await Future.wait(
        automaticAttempts.map(
          (attempt) => attempt.cancel(
            reason: ConnectionAttemptReason.autoConnectDisabled,
          ),
        ),
      );
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
      await _host.setAutoConnectEnabled(false);
      return;
    }
    await _host.setAutoConnectEnabled(true);
    _autoConnectPolicyOverride = true;
    for (final controller in _reconnectControllers.values) {
      controller.autoConnectEnabled();
      final target = controller.target;
      if (target != null && !controller.isSuppressed) {
        controller.scheduleReconnect(target);
      }
    }
  }

  Future<void> prepareForSystemSleep() async {
    if (_systemSleeping) return;
    _systemSleeping = true;
    for (final entry in _reconnectControllers.entries) {
      if (entry.value.hasPendingAttempt || entry.value.isAttemptInFlight) {
        _systemSleepReconnectPeerIds.add(entry.key);
      }
    }
    cancelPendingOutgoingConnections();
    // A handshake that was already under way can finish while the first peers
    // are closing, hence the second pass.
    for (var pass = 0; pass < 2 && _systemSleeping; pass += 1) {
      final peerIds = _host.peers.connectedPeerIds.toList(growable: false);
      if (peerIds.isEmpty) break;
      _systemSleepReconnectPeerIds.addAll(peerIds);
      await Future.wait(
        peerIds.map(
          (peerId) => _host.removePeerConnection(
            peerId,
            PeerDisconnectCause.systemSleep,
          ),
        ),
      );
    }
  }

  void resumeFromSystemSleep() {
    if (!_systemSleeping) return;
    _systemSleeping = false;
    final peerIds = _systemSleepReconnectPeerIds.toList(growable: false);
    _systemSleepReconnectPeerIds.clear();
    if (_reconnectManagerClosed) return;
    for (final peerId in peerIds) {
      final controller = _reconnectControllers[peerId];
      final target = controller?.target;
      if (controller != null && target != null) {
        controller.scheduleReconnect(target);
      }
    }
  }

  Future<ConnectionAttemptResult> connectToServer(
    ConnectionAttemptRequest request, {
    Future<void>? whenCancelled,
  }) {
    if (request.mode == ConnectionAttemptMode.interactive &&
        _reconnectManagerClosed &&
        _host.acceptingOutgoingConnections) {
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
    if (request.isAutomatic &&
        hasUncancelledPendingAttemptForPeer(request.expectedPeerId)) {
      return Future<ConnectionAttemptResult>.value(
        ConnectionAttemptResult.rejected(
          requestId: request.requestId,
          reason: ConnectionAttemptReason.duplicateRequest,
        ),
      );
    }
    final attempt = PendingOutgoingConnection(
      request,
      globalPolicyEpoch: _host.policy.globalPolicyEpoch,
      peerPolicyEpoch: _host.policy.peerPolicyEpoch(request.expectedPeerId),
      startedPolicyRevision: _host.policy.policyRevision,
      socketCloseTimeout: _host.socketCloseTimeout,
    );
    if (request.mode == ConnectionAttemptMode.interactive &&
        request.expectedPeerId.isNotEmpty) {
      _host.policy.authorizeInteractiveAttempt(attempt, request.expectedPeerId);
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
        : _connectToServerVersion(attempt, PeerSocketSession.protocolVersion);
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

  bool debugBindPendingConnectionPeer(String requestId, String peerId) {
    final attempt = _pendingOutgoingByRequestId[requestId];
    if (attempt == null) return false;
    bindPendingOutgoingPeer(attempt, peerId);
    return _host.policy.isPendingPolicyCurrent(attempt);
  }

  Future<void> cancelConnectionAttempt(String requestId) async {
    final attempt = _pendingOutgoingByRequestId[requestId];
    if (attempt != null) {
      await attempt.cancel();
      await attempt.completion;
    }
  }

  Future<void> cancelPendingAttemptsForPeer(
    String peerId,
    ConnectionAttemptReason reason, {
    bool Function(PendingOutgoingConnection attempt)? where,
  }) async {
    final attempts =
        _pendingOutgoingByPeerId[peerId]
            ?.where((attempt) => where?.call(attempt) ?? true)
            .toList(growable: false) ??
        const <PendingOutgoingConnection>[];
    await Future.wait(
      attempts.map((attempt) => attempt.cancel(reason: reason)),
    );
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

  void cancelLosingOutgoingForPeer(String peerId) {
    final attempts =
        _pendingOutgoingByPeerId[peerId]?.toList(growable: false) ??
        const <PendingOutgoingConnection>[];
    for (final attempt in attempts) {
      final outgoingSink = attempt.channel?.sink;
      if (outgoingSink != null) {
        _host.auth.completeSocketAuth(outgoingSink, false, 'superseded');
      }
      _host.ignoreFuture(
        attempt.cancel(reason: ConnectionAttemptReason.superseded),
        context: 'cancel losing simultaneous outgoing dial',
      );
    }
  }

  void cancelPendingOutgoingConnections() {
    for (final attempt in _pendingOutgoingConnections.toList(growable: false)) {
      _host.ignoreFuture(
        attempt.cancel(reason: ConnectionAttemptReason.managerClosed),
        context: 'cancel pending outgoing websocket',
      );
    }
  }

  Future<void> drainPendingOutgoingConnections() async {
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
  }

  void bindPendingOutgoingPeer(
    PendingOutgoingConnection attempt,
    String peerId,
  ) {
    if (attempt.verifiedPeerId == peerId) return;
    if (attempt.verifiedPeerId.isNotEmpty) {
      _pendingOutgoingByPeerId[attempt.verifiedPeerId]?.remove(attempt);
    }
    attempt.verifiedPeerId = peerId;
    _host.policy.bindAttemptPolicyForDiscoveredPeer(attempt, peerId);
    _indexPendingOutgoingPeer(attempt, peerId);
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
    if (peerId.isEmpty) return;
    _pendingOutgoingByPeerId
        .putIfAbsent(peerId, () => <PendingOutgoingConnection>{})
        .add(attempt);
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

  Future<ConnectionAttemptResult> _preemptAutomaticAttemptsThenConnect(
    PendingOutgoingConnection attempt,
  ) async {
    final peerId = attempt.request.expectedPeerId;
    final hasAutomaticInFlight =
        _pendingOutgoingByPeerId[peerId]?.any(_isAutomaticAttempt) == true;
    if (hasAutomaticInFlight) {
      try {
        await cancelPendingAttemptsForPeer(
          peerId,
          ConnectionAttemptReason.superseded,
          where: _isAutomaticAttempt,
        ).timeout(_host.manualPreemptWaitTimeout);
      } catch (_) {
        // Bounded wait: timeout or cleanup errors never block manual connect.
      }
    }
    if (attempt.isCancelled) {
      return ConnectionAttemptResult.cancelled(
        requestId: attempt.request.requestId,
        reason: attempt.cancellationReason,
      );
    }
    return _connectToServerVersion(attempt, PeerSocketSession.protocolVersion);
  }

  Future<ConnectionAttemptResult> _connectToServerVersion(
    PendingOutgoingConnection attempt,
    int protocolVersion,
  ) async {
    final request = attempt.request;
    if (!_host.acceptingOutgoingConnections || _systemSleeping) {
      return ConnectionAttemptResult.cancelled(
        requestId: request.requestId,
        reason: ConnectionAttemptReason.managerClosed,
      );
    }
    final primaryEndpoint = request.endpoint;
    final authRequestKey = _host.auth.authRequestKey(
      peerId: request.expectedPeerId,
      host: primaryEndpoint.host,
      port: primaryEndpoint.port,
    );
    if (!_host.auth.tryClaimOutgoingAuth(authRequestKey)) {
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
          endpoint.chatUri,
          attempt,
          timeout: _host.outgoingConnectionTimeout,
          pingInterval: _host.serverPingInterval,
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
            upgraded.webSocket,
            socket: upgraded.socket,
          );
          activeChannel = channel;
          attempt.channel = channel;
          attempt.connectedEndpoint = endpoint;
          attempt.isReady = true;
          if (attempt.isCancelled) throw const OutgoingConnectionCancelled();
          final channelSink = channel.sink;
          _pendingOutgoingBySink[channelSink] = attempt;
          if (authClaimOwnedLocally) {
            _host.auth.trackOutgoingAuthKey(channelSink, authRequestKey);
            authClaimOwnedLocally = false;
          }
          _host.peers.setEndpoint(channelSink, (
            host: endpoint.host,
            port: endpoint.port,
          ));
          final authCompleter = _host.auth.registerAuthResultCompleter(
            channelSink,
          );
          final session = await _host.createSocketSession(
            sink: channelSink,
            role: PeerSocketRole.client,
            intendedPeerId: request.expectedPeerId,
            intendedPublicKeyHash: request.expectedPublicKeyHash,
            protocolVersion: protocolVersion,
          );
          attempt.session = session;
          if (attempt.isCancelled) throw const OutgoingConnectionCancelled();
          _host.attachSocketTransport(channel, session, asServer: false);
          await _host.auth.sendAuthEnvelope(
            channelSink,
            await session.createHello(),
          );
          final authResult = await authCompleter.future;
          if (attempt.isCancelled) throw const OutgoingConnectionCancelled();
          if (!authResult.allow) {
            final failure = authFailureResult(request, authResult.message);
            if (isRetryableCandidateFailure(failure.reason) &&
                _host.auth.takeOutgoingAuthKey(channelSink) == authRequestKey) {
              authClaimOwnedLocally = true;
            } else {
              _host.auth.releaseOutgoingAuthForSink(channelSink);
            }
            activeChannel = null;
            await _host.peers.closeSink(channelSink);
            await _host.handlePeerSocketDoneQueued(channelSink);
            return failure;
          }
          _host.auth.releaseOutgoingAuthForSink(channelSink);
          activeChannel = null;
          final peerId = session.remotePeerId;
          final generation = session.connectionGeneration;
          if (!_host.peers.isCurrent(peerId, generation) ||
              !identical(_host.peers.sessionForPeer(peerId), session)) {
            return ConnectionAttemptResult.cancelled(
              requestId: request.requestId,
              reason: ConnectionAttemptReason.superseded,
            );
          }
          return ConnectionAttemptResult.authenticated(
            requestId: request.requestId,
            peerId: peerId,
            generation: generation,
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
        _host.auth.completeSocketAuth(channel.sink, false, 'connection_failed');
        _host.auth.releaseOutgoingAuthForSink(channel.sink);
        await _host.handlePeerSocketDoneQueued(channel.sink);
      }
      if (authClaimOwnedLocally) {
        _host.auth.releaseOutgoingAuthKey(authRequestKey);
        authClaimOwnedLocally = false;
      }
      if (wasCancelled) {
        return ConnectionAttemptResult.cancelled(
          requestId: request.requestId,
          reason: attempt.cancellationReason,
        );
      }
      return connectionExceptionResult(request, error);
    } finally {
      attempt.abortPendingDialClients();
      if (authClaimOwnedLocally) {
        _host.auth.releaseOutgoingAuthKey(authRequestKey);
      }
    }
  }
}
