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
    expect(register, contains('!session.isAuthenticated'));
    expect(register, contains('_sink = sink'));
  });

  test('rejecting pairing closes only that socket', () {
    final proof = section(
      'Future<void> _handleServerProof(',
      'Future<void> _handleClientResult(',
    );
    expect(proof, contains('await sink.close()'));
    expect(proof, isNot(contains('closeGracefully(')));
    expect(proof, isNot(contains('close(closeServer')));
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
    expect(create, contains('sink.close()'));
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
      'Future<PairingReason?> _pairingReason(',
    );
    expect(result, contains('session.receiveResult(result)'));
    expect(result, contains('_completeAuthenticatedSession(session, sink)'));
    expect(
      result.indexOf('session.receiveResult(result)'),
      lessThan(result.indexOf('_completeAuthenticatedSession(session, sink)')),
    );
  });
}
