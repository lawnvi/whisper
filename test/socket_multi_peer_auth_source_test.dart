import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/socket/svrmanager.dart').readAsStringSync();

  String section(String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    expect(start, greaterThanOrEqualTo(0), reason: 'Missing $startMarker');
    final end = source.indexOf(endMarker, start);
    expect(end, greaterThan(start), reason: 'Missing $endMarker');
    return source.substring(start, end);
  }

  test('pre-auth sockets cannot register or take the default sink', () {
    expect(source, isNot(contains('_sink = webSocket.sink')));
    expect(source, isNot(contains('_sink = channelSink')));
    final register = section(
      'Future<void> _registerPeerConnection(',
      'Future<void> _handlePeerSocketDoneQueued(',
    );
    expect(register, contains('!session.isAuthenticationReady'));
    expect(register, contains('_sink = sink'));
  });

  test('authenticated direct replacement cleans the old generation first', () {
    final register = section(
      'Future<void> _registerPeerConnection(',
      'Future<void> _handlePeerSocketDoneQueued(',
    );

    expect(register, contains('afterRemove:'));
    expect(register, contains('_afterPeerRemoved('));
    expect(
      register.indexOf('afterRemove:'),
      lessThan(register.indexOf('afterRegister:')),
    );
  });

  test('rejecting pairing closes only that socket', () {
    final completion = section(
      'Future<void> _tryCompleteServerPairing(',
      'Future<void> _handleClientResult(',
    );
    expect(completion, contains('await _closeSocketSink(sink)'));
    final denial = completion.substring(
      completion.indexOf('if (session.hasPairingRejection)'),
    );
    expect(
      denial.indexOf('await _sendAuthEnvelope(sink, result)'),
      lessThan(denial.indexOf('session.close()')),
    );
    expect(
      denial.indexOf('session.close()'),
      lessThan(denial.indexOf('await _closeSocketSink(sink)')),
    );
    expect(completion, isNot(contains('closeGracefully(')));
    expect(completion, isNot(contains('close(closeServer')));
  });

  test('session timeout invalidates its generation and closes only its sink',
      () {
    final create = section(
      'Future<PeerSocketSession> _createSocketSession(',
      'Future<void> _attachIncomingSocket(',
    );
    expect(create, contains('onTimeout:'));
    expect(create, contains('identical(_sessionsBySink[sink], session)'));
    expect(create,
        contains("_completeSocketAuth(sink, false, 'pairing_expired')"));
    expect(create, contains('_closeSocketSink(sink)'));
  });

  test('authenticated frames are verified before business parsing', () {
    final incoming = section(
      'Future<void> _handleIncomingMessage(',
      'Uint8List _incomingBytes(',
    );
    expect(incoming, contains('session.decodeIncoming(bytes)'));
    expect(
      incoming.indexOf('session.decodeIncoming(bytes)'),
      lessThan(incoming.indexOf('await _listen(')),
    );
    final listen =
        section('Future<void> _listen(', 'MessageData _buildMessage(');
    expect(listen, contains('message.type != MessageEnum.Auth'));
    expect(listen, contains('session.close()'));
  });

  test('socket role is immutable per PeerSocketSession', () {
    expect(source, isNot(contains('bool asServer = true;')));
    expect(source, contains('role: PeerSocketRole.server'));
    expect(source, contains('role: PeerSocketRole.client'));
    expect(source, contains('session.role != PeerSocketRole.server'));
    expect(source, contains('session.role != PeerSocketRole.client'));
  });

  test('simultaneous dials are resolved only after proof verification', () {
    final proof = section(
      'Future<void> _handleServerProof(',
      'Future<void> _handleClientResult(',
    );
    expect(proof, contains('await session.receiveProof(proof)'));
    expect(proof, contains('hasOutgoing'));
    expect(proof, contains('resolveSimultaneousDial'));
    expect(
      proof.indexOf('await session.receiveProof(proof)'),
      lessThan(proof.indexOf('resolveSimultaneousDial')),
    );
  });

  test('legacy auth booleans cannot bypass signed pairing', () {
    final pairingPolicy =
        File('lib/state/pairing_request.dart').readAsStringSync();
    expect(source, isNot(contains('self.auth ||')));
    expect(source, isNot(contains('localTemp.auth')));
    expect(source, contains('pairingReasonForIdentity'));
    expect(pairingPolicy, contains('PairingReason.legacyTrustWithoutPin'));
    expect(pairingPolicy, contains('stored?.identityPublicKey'));
  });

  test('signed result verification precedes client registration', () {
    final result = section(
      'Future<void> _handleClientResult(',
      'Future<_IdentityPinPlan> _pairingReason(',
    );
    expect(result, contains('session.receiveResult(result)'));
    expect(result, contains('_completeAuthenticatedSession('));
    expect(
      result.indexOf('session.receiveResult(result)'),
      lessThan(result.indexOf('_completeAuthenticatedSession(')),
    );
  });

  test('identity pin commits use captured compare-and-set state', () {
    final completion = section(
      'Future<DeviceData> _completeAuthenticatedSession(',
      'Future<void> _sendUpgradeRequired(',
    );
    expect(completion, contains('_database.commitAuthenticatedDevice('));
    expect(completion, contains('pinPlan.expectedPublicKey'));
    expect(completion, contains('PairingReason.identityChanged'));
    expect(completion, contains('_requireCurrentSession('));
    expect(
      completion.indexOf('_requireCurrentSession('),
      lessThan(completion.indexOf('database.commitAuthenticatedDevice(')),
    );

    final challenge = section(
      'Future<void> _handleClientChallenge(',
      'Future<void> _handleServerProof(',
    );
    expect(challenge, contains('_identityPinPlansBySink[sink] = pinPlan'));
  });

  test('server persists and registers before sending an allow result', () {
    final proof = section(
      'Future<void> _handleServerProof(',
      'Future<void> _handleClientResult(',
    );
    expect(
      proof,
      contains('AuthHandshakeLifecycle.completeServerAllow<DeviceData>('),
    );
    expect(proof, contains('_completeAuthenticatedSession('));
    expect(proof, contains('_sendAuthEnvelope(sink, result)'));
    expect(proof, contains('session.tryClaimPairingCompletion()'));
    expect(proof, isNot(contains('session.isMutuallyApproved')));
    final sessionSource =
        File('lib/socket/peer_socket_session.dart').readAsStringSync();
    expect(
      sessionSource,
      contains('(!isMutuallyApproved && !hasPairingRejection)'),
    );
    expect(
      proof.indexOf('_completeAuthenticatedSession('),
      lessThan(proof.lastIndexOf('_sendAuthEnvelope(sink, result)')),
    );
  });

  test('guarded UI resolution uses the tested failure boundary', () {
    final guarded = section(
      'void _runGuardedApproval({',
      'Future<DeviceData> _deviceForSession(',
    );
    expect(guarded, contains('AuthHandshakeLifecycle.resolveGuarded('));
    expect(guarded, contains('_failSocketSession('));
  });

  test('pending sessions participate in graceful shutdown', () {
    final close = section(
      'Future<void> closeGracefully(',
      'Future<void> disconnectPeer(',
    );
    expect(close, contains('_sessionsBySink.isNotEmpty'));
    expect(close, contains('_authResultsBySink.isNotEmpty'));
  });

  test('stream terminal callbacks close sessions before queued cleanup', () {
    final attach = section(
      'void _attachSocketTransport(',
      'Future<void> _attachIncomingSocket(',
    );
    expect(attach, contains('AuthSocketLifecycle.closeBeforeQueuedCleanup('));
    expect(attach, contains('_handlePeerSocketDoneQueued(sink)'));
    final connect = section(
      'Future<ConnectionAttemptResult> connectToServer(',
      'Future<void> closeGracefully(',
    );
    expect(connect, contains('_attachSocketTransport('));
  });

  test('outbound failure closes and cleans only the captured socket', () {
    final attach = section(
      'void _attachSocketTransport(',
      'Future<void> _attachIncomingSocket(',
    );
    final register = section(
      'Future<void> _registerPeerConnection(',
      'Future<void> _handlePeerSocketDoneQueued(',
    );

    expect(attach, contains('_closeSocketSink(sink)'));
    expect(attach, contains('identical(_sessionsBySink[sink], session)'));
    expect(attach, contains('_handlePeerSocketDoneQueued(sink)'));
    expect(register, contains('await _closeSocketSink(sink)'));
    expect(register, isNot(contains('await sink.close()')));
  });

  test('cancelling a ready outgoing attempt bounds its socket close', () {
    final pendingAttempt = section(
      'final class _PendingOutgoingConnection',
      'class WsSvrManager',
    );

    expect(pendingAttempt, contains('TransportCloseGuard'));
    expect(pendingAttempt, contains('return _sinkCloseGuard!.close()'));
    expect(pendingAttempt, isNot(contains('return _sinkCloseFuture!')));
  });

  test('outbound auth outcomes are returned only to the awaiting caller', () {
    final challenge = section(
      'Future<void> _handleClientChallenge(',
      'Future<bool> _automaticAttemptStillEligible(',
    );
    final result = section(
      'Future<void> _handleClientResult(',
      'Future<_IdentityPinPlan> _pairingReason(',
    );
    final announce = section(
      'void _announceAuthenticatedSession(',
      'bool _isSameSession(',
    );

    expect(challenge, isNot(contains('afterAuth(')));
    expect(result, isNot(contains('afterAuth(')));
    expect(announce, contains('session.role == PeerSocketRole.server'));
  });

  test('old socket cleanup removes only its own connection generation', () {
    final cleanup = section(
      'Future<void> _handlePeerSocketDone(',
      'Future<PeerSocketSession> _createSocketSession(',
    );
    expect(
      cleanup,
      contains('AuthSocketLifecycle.removeConnectionIfCurrent('),
    );
    expect(cleanup, contains('closingSession: session'));
    expect(cleanup, contains('currentSession: currentSession'));
    expect(cleanup, isNot(contains('_peerConnections.disconnect(peerId)')));
  });
}
