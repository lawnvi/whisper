import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/helper/connection_request_notifications.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/socket/auth_handshake_lifecycle.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/auth_request_gate.dart';
import 'package:whisper/socket/dial_tiebreaker.dart';
import 'package:whisper/socket/pairing_attempt_limiter.dart';
import 'package:whisper/socket/peer_auth_host.dart';
export 'package:whisper/socket/peer_auth_host.dart';
import 'package:whisper/socket/peer_policy_store.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/pending_outgoing_connection.dart';
import 'package:whisper/socket/socket_events.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_profile.dart';

/// Coordinates `/chat` authentication handshakes, pairing prompts, identity
/// pinning/rollback, simultaneous dial tie-breaks, and per-peer auth commit
/// serialization.
class PeerAuthCoordinator {
  PeerAuthCoordinator(this._host);

  final PeerAuthHost _host;

  final AuthRequestGate _authRequestGate = AuthRequestGate();
  final PairingAttemptLimiter _pairingAttempts = PairingAttemptLimiter();
  final Map<WebSocketSink, Completer<SocketAuthResult>> _authResultsBySink =
      <WebSocketSink, Completer<SocketAuthResult>>{};
  final Map<WebSocketSink, String> _outgoingAuthKeysBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, String> _incomingAuthPeerIdsBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, IdentityPinPlan> _identityPinPlansBySink =
      <WebSocketSink, IdentityPinPlan>{};
  final Map<String, Future<void>> _peerAuthenticationTails =
      <String, Future<void>>{};

  bool get hasPendingResults => _authResultsBySink.isNotEmpty;

  Set<WebSocketSink> get pendingResultSinks => _authResultsBySink.keys.toSet();

  bool hasAuthenticationTailForPeer(String peerId) =>
      _peerAuthenticationTails.containsKey(peerId);

  Future<void>? authenticationTailForPeer(String peerId) =>
      _peerAuthenticationTails[peerId];

  Future<void> waitForPeerAuthentication(String peerId) async {
    await (_peerAuthenticationTails[peerId] ?? Future<void>.value());
  }

  String authRequestKey({
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

  bool tryClaimOutgoingAuth(String key) =>
      _authRequestGate.tryClaimOutgoing(key);

  void releaseOutgoingAuthKey(String key) =>
      _authRequestGate.releaseOutgoing(key);

  void trackOutgoingAuthKey(WebSocketSink sink, String key) {
    _outgoingAuthKeysBySink[sink] = key;
  }

  String? takeOutgoingAuthKey(WebSocketSink sink) =>
      _outgoingAuthKeysBySink.remove(sink);

  Completer<SocketAuthResult> registerAuthResultCompleter(WebSocketSink sink) {
    final completer = Completer<SocketAuthResult>();
    _authResultsBySink[sink] = completer;
    return completer;
  }

  void completeSocketAuth(WebSocketSink sink, bool allow, String message) {
    final completer = _authResultsBySink.remove(sink);
    if (completer != null && !completer.isCompleted) {
      completer.complete(SocketAuthResult(allow, message));
    }
  }

  void releaseOutgoingAuthForSink(WebSocketSink? sink) {
    if (sink == null) return;
    final requestKey = _outgoingAuthKeysBySink.remove(sink);
    if (requestKey != null) {
      _authRequestGate.releaseOutgoing(requestKey);
    }
  }

  void releaseIncomingAuthForSink(WebSocketSink? sink) {
    if (sink == null) return;
    final peerId = _incomingAuthPeerIdsBySink.remove(sink);
    if (peerId != null && peerId.isNotEmpty) {
      _authRequestGate.releaseIncoming(peerId);
      _host.ignoreFuture(
        ConnectionRequestNotifier().dismissForPeer(peerId, graceMillis: 3000),
        context: 'dismiss pairing notification',
      );
    }
  }

  void clearSinkAuthState(
    WebSocketSink sink, {
    required String failureMessage,
  }) {
    _identityPinPlansBySink.remove(sink);
    completeSocketAuth(sink, false, failureMessage);
    releaseOutgoingAuthForSink(sink);
    releaseIncomingAuthForSink(sink);
  }

  void clearGatesForClose() {
    _outgoingAuthKeysBySink.clear();
    _incomingAuthPeerIdsBySink.clear();
    _identityPinPlansBySink.clear();
    _authRequestGate.clear();
  }

  void closePendingAuthSessions(Iterable<PeerSocketSession> sessions) {
    AuthSocketLifecycle.closePendingAuth(
      sessions: sessions,
      completeFailures: _authResultsBySink.values.map((completer) {
        return () {
          if (!completer.isCompleted) {
            completer.complete(
              const SocketAuthResult(false, 'connection_closed'),
            );
          }
        };
      }),
    );
    _authResultsBySink.clear();
  }

  void cancelPendingAuthSessionsForPeer(String peerId) {
    for (final link in _host.peers.linksSnapshot) {
      final session = link.session;
      if (session == null ||
          session.remotePeerId != peerId ||
          session.isAuthenticated) {
        continue;
      }
      session.close();
      _host.ignoreFuture(
        link.sink.close(),
        context: 'cancel invalidated peer authentication',
      );
    }
  }

  Future<void> sendAuthEnvelope(
    WebSocketSink sink,
    AuthEnvelope envelope,
  ) async {
    final session = _host.peers.sessionForSink(sink);
    final message = _host.buildAuthMessage(
      content: envelope.toJsonString(),
      msg: '',
      senderOverride: session?.localProfile.uid,
      receiverOverride: envelope.action == AuthAction.hello
          ? envelope.intendedPeerId ?? ''
          : session?.remotePeerId,
    );
    if (!await _host.sendRawAuthMessage(message, sink: sink)) {
      throw const AuthHandshakeException('send_failed');
    }
  }

  Future<void> handleAuthMessage(
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
      _host.authEnvelopeObserver?.call(session.role, envelope);
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
      await _host.failSocketSession(session, sink, code);
    } on AuthHandshakeException catch (error) {
      if ((error.code == 'upgrade_required' ||
              error.code == 'peer_upgrade_required' ||
              error.code == 'local_upgrade_required' ||
              error.code == pairingBusyAction) &&
          session.role == PeerSocketRole.server) {
        final action = error.code == pairingBusyAction
            ? pairingBusyAction
            : 'upgrade_required';
        await _sendUpgradeRequired(sink, session, action: action);
      }
      await _host.failSocketSession(session, sink, error.code);
    }
  }

  Future<void> _handleServerHello(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope hello,
  ) async {
    final presentedDevice = await _host.database.fetchDevice(hello.peerId);
    final pinPlan = (
      reason:
          pairingReasonForIdentity(presentedDevice, hello.identityPublicKey!) ??
          _host.policy.incomingPolicyRepairReason(hello.peerId),
      expectedPublicKey: presentedDevice?.identityPublicKey ?? '',
    );
    final challenge = await session.receiveHello(
      hello,
      pairingRequired: pinPlan.reason != null,
    );
    final from = _host.peers.endpointForSink(sink)?.host ?? '';
    final codeOnly = _pairingAttempts.admit(hello, pinPlan, from: from);
    if (!_host.policy.isSessionPeerPolicyCurrent(session)) {
      throw const AuthHandshakeException('session_expired');
    }
    _host.policy.requirePairingForPolicyRepair(
      session.remotePeerId,
      pinPlan.reason,
    );
    _identityPinPlansBySink[sink] = pinPlan;
    final generation = session.connectionGeneration;
    await sendAuthEnvelope(sink, challenge);
    if (codeOnly) _pairingAttempts.watch(session);
    if (!isCurrentSession(session, sink, generation)) {
      return;
    }
  }

  Future<void> _handleClientChallenge(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope challenge,
  ) async {
    await session.receiveChallenge(challenge);
    final attempt = _host.pendingOutgoingForSink(sink);
    if (attempt == null || attempt.isCancelled) {
      throw const AuthHandshakeException('session_expired');
    }
    _host.bindPendingOutgoingPeer(attempt, session.remotePeerId);
    final incomingSink = _activeIncomingAuthSinkForPeer(session.remotePeerId);
    if (incomingSink != null) {
      final decision = resolveSimultaneousDial(
        localUid: session.localProfile.uid,
        remoteUid: session.remotePeerId,
      );
      if (decision == SimultaneousDialDecision.acceptIncoming) {
        completeSocketAuth(sink, false, 'superseded');
        await attempt.cancel(reason: ConnectionAttemptReason.superseded);
        await _host.peers.closeSink(sink);
        return;
      }
      _host.peers.sessionForSink(incomingSink)?.close();
      await _host.peers.closeSink(incomingSink);
    }
    if (!_host.policy.isPendingPolicyCurrent(attempt)) {
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
    _host.policy.requirePairingForPolicyRepair(
      session.remotePeerId,
      pairingReason,
    );
    if (pairingReason != null && attempt.request.isAutomatic) {
      completeSocketAuth(sink, false, 'automatic_pairing_required');
      session.close();
      await _host.peers.closeSink(sink);
      return;
    }
    final generation = session.connectionGeneration;
    _identityPinPlansBySink[sink] = pinPlan;

    Future<void> approveAndSend() async {
      final approved = session.resolveLocalApproval(
        generation: generation,
        allow: true,
      );
      if (!approved || !isSameSession(session, sink, generation)) {
        return;
      }
      final approval = await session.createApproval(
        allow: true,
        reason: approvalReasonForPairing(pairingReason),
      );
      if (!isSameSession(session, sink, generation)) {
        return;
      }
      await sendAuthEnvelope(sink, approval);
    }

    Future<void> resolve(bool keepConnecting) async {
      if (!isSameSession(session, sink, generation)) {
        return;
      }
      if (keepConnecting) {
        await approveAndSend();
        return;
      }
      _identityPinPlansBySink.remove(sink);
      completeSocketAuth(sink, false, 'request_cancelled');
      await attempt.cancel(reason: ConnectionAttemptReason.requestCancelled);
      await _host.peers.closeSink(sink);
    }

    final proof = await session.createProof(
      reason: approvalReasonForPairing(pairingReason),
    );
    if (!isCurrentSession(session, sink, generation)) {
      return;
    }
    await sendAuthEnvelope(sink, proof);
    if (!isSameSession(session, sink, generation)) {
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
    if (!_host.policy.isPendingPolicyCurrent(attempt) ||
        _host.autoConnectPolicyOverride == false ||
        !await _host.autoConnectEnabled()) {
      return false;
    }
    final stored = await _host.database.fetchDevice(session.remotePeerId);
    if (!_host.policy.isPendingPolicyCurrent(attempt) ||
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
    if (!_host.policy.isSessionPeerPolicyCurrent(session)) {
      throw const AuthHandshakeException('session_expired');
    }
    // Claimed only now: a hello alone, which anyone can send under a known id,
    // must not keep the real device out.
    final gateKey = _authRequestGate.tryClaimProven(
      session.remotePeerId,
      pinnedPublicKey: _identityPinPlansBySink[sink]?.expectedPublicKey ?? '',
      presentedPublicKey: session.remoteIdentityPublicKey,
    );
    if (gateKey == null) {
      session.close();
      await _host.peers.closeSink(sink);
      return;
    }
    _incomingAuthPeerIdsBySink[sink] = gateKey;
    if (_host.hasReadyPendingOutgoingForPeer(session.remotePeerId)) {
      final decision = resolveSimultaneousDial(
        localUid: session.localProfile.uid,
        remoteUid: session.remotePeerId,
      );
      if (decision == SimultaneousDialDecision.keepOutgoing) {
        session.close();
        await _host.peers.closeSink(sink);
        return;
      }
      _host.cancelLosingOutgoingForPeer(session.remotePeerId);
    } else if (_host.hasPendingOutgoingForPeer(session.remotePeerId)) {
      // Only a WebSocket-ready outgoing dial counts as simultaneous dial; an
      // attempt still stuck in TCP/HTTP connect must not kill a working
      // incoming connection.
      _host.cancelLosingOutgoingForPeer(session.remotePeerId);
    }
    await _ensureServerPairingDecision(session, sink);
    await _tryCompleteServerPairing(session, sink);
  }

  WebSocketSink? _activeIncomingAuthSinkForPeer(String peerId) {
    if (peerId.isEmpty) return null;
    for (final entry in _incomingAuthPeerIdsBySink.entries) {
      final session = _host.peers.sessionForSink(entry.key);
      if (session != null &&
          !session.isClosed &&
          session.remotePeerId == peerId) {
        return entry.key;
      }
    }
    return null;
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
    if (!isCurrentSession(session, sink, generation) ||
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
      if (!accepted || !isCurrentSession(session, sink, generation)) {
        return;
      }
      _pairingAttempts.noteDecision(
        allow,
        _host.peers.endpointForSink(sink)?.host,
      );
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
    if (!isCurrentSession(session, sink, generation)) {
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
      if (!isSameSession(session, sink, generation)) {
        return;
      }
      await sendAuthEnvelope(sink, result);
      // 由 client 消费签名拒绝后关连接，避免 onDone 抢先关闭其待处理会话。
      releaseIncomingAuthForSink(sink);
      _host.dispatchAfterAuth(false, null);
      return;
    }
    final pinPlan = _identityPinPlansBySink.remove(sink);
    if (pinPlan == null) {
      throw const AuthHandshakeException('identity_pin_state_missing');
    }
    final result = await session.createResult(allow: true, reason: 'approved');
    if (!isCurrentSession(session, sink, generation)) {
      return;
    }
    await AuthHandshakeLifecycle.completeServerAllow<DeviceData>(
      commit: () =>
          _completeAuthenticatedSession(session, sink, pinPlan: pinPlan),
      sendAllow: (storedDevice) async {
        requireCurrentAuthenticatedSession(session, sink, generation);
        await sendAuthEnvelope(sink, result);
      },
      onAuthenticated: (storedDevice) {
        _announceAuthenticatedSession(session, sink, storedDevice);
      },
      onFailure: (error, stackTrace) async {
        logger.i('完成服务端配对失败: $error\n$stackTrace');
        if (isSameSession(session, sink, generation)) {
          await _host.failSocketSession(
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
      completeSocketAuth(sink, false, result.reason ?? 'rejected');
      await _host.peers.closeSink(sink);
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

  Future<IdentityPinPlan> _pairingReason(PeerSocketSession session) async {
    final stored = await _host.database.fetchDevice(session.remotePeerId);
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
    if (_host.primaryEvent == null) {
      await resolve(false);
      return;
    }
    final generation = session.connectionGeneration;
    final device = await _deviceForSession(session, sink);
    if (!isCurrentSession(session, sink, generation)) {
      return;
    }
    await presentAuthPairingDecision(
      host: _host,
      session: session,
      sink: sink,
      device: device,
      reason: reason,
      mode: mode,
      isSameSession: isSameSession,
      resolve: resolve,
    );
  }

  Future<DeviceData> _deviceForSession(
    PeerSocketSession session,
    WebSocketSink sink,
  ) async {
    final stored = await _host.database.fetchDevice(session.remotePeerId);
    final endpoint = _host.peers.endpointForSink(sink);
    final host = endpoint?.host.isNotEmpty == true
        ? endpoint!.host
        : stored?.host ?? '';
    final port = endpoint?.port != null && endpoint!.port > 0
        ? endpoint.port
        : stored?.port ?? 0;
    return session.remoteProfile!.toDeviceData(host: host, port: port);
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

  Future<void> _waitForAuthCommitBarrier(
    ConnectionAuthCommitStage stage,
    String peerId,
  ) async {
    await _host.authCommitBarrier?.call(stage, peerId);
  }

  Future<DeviceData> _completeAuthenticatedSession(
    PeerSocketSession session,
    WebSocketSink sink, {
    required IdentityPinPlan pinPlan,
  }) {
    return _serializePeerAuthentication(
      session.remotePeerId,
      () =>
          _completeAuthenticatedSessionSerialized(
            session,
            sink,
            pinPlan: pinPlan,
          ).whenComplete(() {
            _host.policy.forgetSession(session);
          }),
    );
  }

  Future<DeviceData> _completeAuthenticatedSessionSerialized(
    PeerSocketSession session,
    WebSocketSink sink, {
    required IdentityPinPlan pinPlan,
  }) async {
    final generation = session.connectionGeneration;
    requireCurrentSession(session, sink, generation);
    final previousDevice = await _host.database.fetchDevice(
      session.remotePeerId,
    );
    final identityChanged =
        previousDevice != null &&
        previousDevice.identityPublicKey != session.remoteIdentityPublicKey;
    if (identityChanged) {
      _host.outgoingTextRetries.clearPeer(session.remotePeerId);
    }
    requireCurrentAuthenticationCommit(session, sink, generation);
    final existingLink = _host.peers.linkForPeer(session.remotePeerId);
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
          requireCurrentAuthenticationCommit(session, sink, generation);
          final candidate = await _deviceForSession(session, sink);
          requireCurrentAuthenticationCommit(session, sink, generation);
          final device = await _host.database.commitAuthenticatedDevice(
            candidate: candidate,
            publicKey: session.remoteIdentityPublicKey,
            replaceIdentity: pinPlan.reason == PairingReason.identityChanged,
            expectedPublicKey: pinPlan.expectedPublicKey,
            requireCurrent: () =>
                requireCurrentAuthenticationCommit(session, sink, generation),
          );
          if (identityChanged) {
            await _host.transferEngine.invalidateOutgoingTransfersForPeer(
              session.remotePeerId,
              reason: 'identity_replaced',
            );
            requireCurrentAuthenticationCommit(session, sink, generation);
          }
          storedDevice = device;
          runtimeProfile = PeerProfile.fromWire(
            session.remoteProfile!,
          ).withDevice(device);
          await _waitForAuthCommitBarrier(
            ConnectionAuthCommitStage.afterPersistence,
            session.remotePeerId,
          );
          requireCurrentAuthenticationCommit(session, sink, generation);
        },
        registerPeer: () async {
          await _waitForAuthCommitBarrier(
            ConnectionAuthCommitStage.beforeRegistration,
            session.remotePeerId,
          );
          requireCurrentRegisterableSession(session, sink, generation);
          requireCurrentAuthenticationCommit(session, sink, generation);
          superseded = await _host.registerPeerConnection(
            peerId: session.remotePeerId,
            sink: sink,
            session: session,
            profile: runtimeProfile,
          );
          await _waitForAuthCommitBarrier(
            ConnectionAuthCommitStage.afterRegistration,
            session.remotePeerId,
          );
          requireCurrentRegisterableSession(session, sink, generation);
          requireCurrentAuthenticationCommit(session, sink, generation);
        },
      );
      if (!committed) {
        throw const AuthHandshakeException('session_expired');
      }
      requireCurrentAuthenticatedSession(session, sink, generation);
      requireCurrentAuthenticationCommit(session, sink, generation);
      await _host.closeSupersededMediaChannels(session);
      requireCurrentAuthenticatedSession(session, sink, generation);
      requireCurrentAuthenticationCommit(session, sink, generation);
      final device = storedDevice;
      if (device == null) {
        throw const AuthHandshakeException('identity_pin_state_missing');
      }
      session.markTransportAuthenticated();
      final link = _host.peers.linkForSink(sink);
      if (link != null) {
        link.authCommitWatermark = _host.nextConnectionGeneration;
        if (superseded) {
          link.supersededOnAuth = true;
        }
      }
      _host.transferEngine.allowOutgoingTransfersForPeer(session.remotePeerId);
      _host.policy.removeSuppression(
        session.remotePeerId,
        PeerAuthSuppressionReason.trustRevoked,
      );
      _host.policy.removeSuppression(
        session.remotePeerId,
        PeerAuthSuppressionReason.manualDisconnect,
      );
      published = true;
      return device;
    } catch (error, stackTrace) {
      final attempted = storedDevice;
      if (!published && attempted != null) {
        await _host.database.rollbackAuthenticatedDevice(
          peerId: session.remotePeerId,
          attemptedPublicKey: session.remoteIdentityPublicKey,
          previous: _host.policy.rollbackPreviousDevice(
            session,
            previousDevice,
          ),
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
    requireCurrentAuthenticatedSession(
      session,
      sink,
      session.connectionGeneration,
    );
    releaseOutgoingAuthForSink(sink);
    releaseIncomingAuthForSink(sink);
    _host.policy.completeDeviceRepairIfNeeded(
      _host.pendingOutgoingForSink(sink),
      storedDevice.uid,
    );
    _host.recordAuthenticatedReconnect(session, sink, storedDevice);
    completeSocketAuth(sink, true, '');
    _host.policy.releaseDeletedPeerDiscoverySuppression(storedDevice.uid);
    _host.startKeepaliveTimer(storedDevice.uid, sink);
    _host.dispatchConnect();
    if (_host.manageSharedCoordinators) {
      _host.ignoreFuture(
        RemoteInputWorkspaceCoordinator.shared.handlePeerReconnected(
          peerId: storedDevice.uid,
          host: storedDevice.host,
          port: storedDevice.port,
          isMutuallyTrusted:
              storedDevice.auth &&
              storedDevice.identityPublicKey.isNotEmpty &&
              storedDevice.identityPublicKey == session.remoteIdentityPublicKey,
          remoteCanInject: _host.peers.supportsRemoteInputWorkspaceGraphFor(
            storedDevice.uid,
          ),
          sendControlTo: _host.sendRemoteInputControlTo,
        ),
        context: 'restore remote input workspace peer',
      );
    }
    if (session.role == PeerSocketRole.server) {
      _host.dispatchAfterAuth(true, storedDevice);
    }
    _host.peers.closeDeferredSupersededSink(session);
    if (_host.peers.linkForSink(sink)?.takeSupersededOnAuth() == true ||
        _host.transferEngine.hasSupersededOutgoingForPeer(
          session.remotePeerId,
        )) {
      _host.ignoreFuture(
        _host.transferEngine.resumeSupersededOutgoingForPeer(
          session.remotePeerId,
          newGeneration: session.connectionGeneration,
        ),
        context: 'resume superseded peer transfers',
      );
    }
    _host.ignoreFuture(
      _host.transferEngine.markRecoverableTransfersPausedForPeer(
        session.remotePeerId,
      ),
      context: 'pause recoverable peer transfers',
    );
  }

  bool isSameSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) =>
      identical(_host.peers.sessionForSink(sink), session) &&
      session.connectionGeneration == generation;

  bool isCurrentSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) => isSameSession(session, sink, generation) && !session.isClosed;

  void requireCurrentSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    if (!isCurrentSession(session, sink, generation)) {
      throw const AuthHandshakeException('session_expired');
    }
    if (session.role == PeerSocketRole.client && !session.isAuthenticated) {
      final attempt = _host.pendingOutgoingForSink(sink);
      if (attempt == null || !_host.policy.isPendingPolicyCurrent(attempt)) {
        throw const AuthHandshakeException('session_expired');
      }
    }
  }

  void requireCurrentAuthenticationCommit(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    requireCurrentSession(session, sink, generation);
    if (session.role == PeerSocketRole.server) {
      if (!_host.policy.isSessionPeerPolicyCurrent(session)) {
        throw const AuthHandshakeException('session_expired');
      }
      return;
    }
    final attempt = _host.pendingOutgoingForSink(sink);
    if (attempt == null || !_host.policy.isPendingPolicyCurrent(attempt)) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  void requireCurrentAuthenticatedSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    requireCurrentSession(session, sink, generation);
    if (!session.isAuthenticated) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  void requireCurrentBusinessSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    requireCurrentAuthenticatedSession(session, sink, generation);
    _host.peers.validateBusinessSession(session, sink, generation);
  }

  void requireCurrentRegisterableSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    requireCurrentSession(session, sink, generation);
    if (!session.isAuthenticationReady) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  Future<void> _sendUpgradeRequired(
    WebSocketSink sink,
    PeerSocketSession session, {
    String action = 'upgrade_required',
  }) => sendAuthUpgradeRequired(_host, sink, session, action: action);
}
