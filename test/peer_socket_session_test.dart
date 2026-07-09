import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/state/peer_profile.dart';

Future<PeerSocketSession> _session({
  required PeerSocketRole role,
  required int generation,
  required int seedStart,
  String intendedPeerId = '',
  String intendedPkh = '',
  Duration timeout = const Duration(seconds: 30),
  void Function()? onTimeout,
}) async {
  final identitySeed =
      Uint8List.fromList(List<int>.generate(32, (i) => seedStart + i));
  final ephemeralSeed = Uint8List.fromList(
    List<int>.generate(32, (i) => seedStart + 64 + i),
  );
  return PeerSocketSession.create(
    role: role,
    connectionGeneration: generation,
    localIdentity: await DeviceIdentity.fromSeed(identitySeed),
    localProfile: WirePeerProfile(
      uid: role == PeerSocketRole.client ? 'client-a' : 'server-b',
      name: role == PeerSocketRole.client ? 'Client A' : 'Server B',
      platform: role == PeerSocketRole.client ? 'macos' : 'windows',
      protocolVersion: 5,
      capabilities: const PeerCapabilities(fileTransferV3: true),
    ),
    localEphemeralKeyPair: await X25519().newKeyPairFromSeed(ephemeralSeed),
    localNonce: Uint8List.fromList(
      List<int>.generate(32, (i) => seedStart + 128 + i),
    ),
    intendedPeerId: intendedPeerId,
    intendedPublicKeyHash: intendedPkh,
    handshakeTimeout: timeout,
    onTimeout: onTimeout,
  );
}

Future<({PeerSocketSession client, PeerSocketSession server})>
    _reachClientApproval({
  String intendedPeerId = 'server-b',
  String intendedPkh = '',
}) async {
  final server = await _session(
    role: PeerSocketRole.server,
    generation: 1,
    seedStart: 32,
  );
  final pkh = intendedPkh.isEmpty
      ? identityPublicKeyHash(server.localIdentity.publicKeyBase64Url)
      : intendedPkh;
  final client = await _session(
    role: PeerSocketRole.client,
    generation: 2,
    seedStart: 0,
    intendedPeerId: intendedPeerId,
    intendedPkh: pkh,
  );
  final hello = await client.createHello();
  final challenge = await server.receiveHello(hello);
  await client.receiveChallenge(challenge);
  return (client: client, server: server);
}

void main() {
  test('roles begin in distinct pre-auth phases', () async {
    final client = await _session(
      role: PeerSocketRole.client,
      generation: 1,
      seedStart: 0,
    );
    final server = await _session(
      role: PeerSocketRole.server,
      generation: 2,
      seedStart: 32,
    );
    addTearDown(client.close);
    addTearDown(server.close);

    expect(client.phase, PeerSocketPhase.awaitingChallenge);
    expect(server.phase, PeerSocketPhase.awaitingHello);
  });

  test('full handshake enables inverse directional MAC codecs', () async {
    final pair = await _reachClientApproval();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);

    expect(pair.client.phase, PeerSocketPhase.awaitingLocalApproval);
    expect(pair.server.phase, PeerSocketPhase.awaitingProof);
    expect(pair.client.pairingCode, pair.server.pairingCode);
    expect(pair.client.pairingCode, matches(RegExp(r'^\d{6}$')));

    expect(
      pair.client.resolveLocalApproval(
        generation: pair.client.connectionGeneration,
        allow: true,
      ),
      isTrue,
    );
    final proof = await pair.client.createProof();
    await pair.server.receiveProof(proof);
    expect(pair.server.phase, PeerSocketPhase.awaitingLocalApproval);
    expect(
      pair.server.resolveLocalApproval(
        generation: pair.server.connectionGeneration,
        allow: true,
      ),
      isTrue,
    );
    final result = await pair.server.createResult(
      allow: true,
      reason: 'approved',
    );
    expect(await pair.client.receiveResult(result), isTrue);

    expect(pair.client.phase, PeerSocketPhase.authenticated);
    expect(pair.server.phase, PeerSocketPhase.authenticated);
    expect(pair.client.remotePeerId, 'server-b');
    expect(pair.server.remotePeerId, 'client-a');

    final encoded = await pair.client.codec!.encode(
      Uint8List.fromList(<int>[1, 2, 3]),
    );
    expect(
      await pair.server.codec!.decode(encoded),
      orderedEquals(<int>[1, 2, 3]),
    );
  });

  test('unknown target can omit peer id but must match discovered pkh',
      () async {
    final accepted = await _reachClientApproval(intendedPeerId: '');
    addTearDown(accepted.client.close);
    addTearDown(accepted.server.close);
    expect(accepted.client.remotePeerId, 'server-b');

    final server = await _session(
      role: PeerSocketRole.server,
      generation: 3,
      seedStart: 32,
    );
    final client = await _session(
      role: PeerSocketRole.client,
      generation: 4,
      seedStart: 0,
      intendedPkh: 'wrong-pkh',
    );
    addTearDown(client.close);
    addTearDown(server.close);
    await expectLater(
      server.receiveHello(await client.createHello()),
      throwsA(isA<AuthHandshakeException>()),
    );
    expect(server.phase, PeerSocketPhase.closing);
  });

  test('wrong order and replay close only the affected session', () async {
    final server = await _session(
      role: PeerSocketRole.server,
      generation: 1,
      seedStart: 32,
    );
    final unaffected = await _session(
      role: PeerSocketRole.client,
      generation: 2,
      seedStart: 0,
    );
    addTearDown(server.close);
    addTearDown(unaffected.close);

    await expectLater(
      server.receiveProof(await unaffected.createHello()),
      throwsA(isA<AuthHandshakeException>()),
    );
    expect(server.phase, PeerSocketPhase.closing);
    expect(unaffected.phase, PeerSocketPhase.awaitingChallenge);
  });

  test('late, duplicate, and wrong-generation approvals are ignored', () async {
    final pair = await _reachClientApproval();
    addTearDown(pair.server.close);
    var decisions = 0;
    final callback = pair.client.guardApprovalCallback((allow) {
      decisions += 1;
    });

    expect(
      pair.client.resolveLocalApproval(
        generation: pair.client.connectionGeneration + 1,
        allow: true,
      ),
      isFalse,
    );
    pair.client.close();
    callback(true);
    callback(false);

    expect(decisions, 0);
    expect(pair.client.phase, PeerSocketPhase.closing);
  });

  test('timeout invalidates pending approval callback', () async {
    var timedOut = false;
    final server = await _session(
      role: PeerSocketRole.server,
      generation: 1,
      seedStart: 32,
    );
    final client = await _session(
      role: PeerSocketRole.client,
      generation: 2,
      seedStart: 0,
      intendedPeerId: 'server-b',
      intendedPkh: identityPublicKeyHash(
        server.localIdentity.publicKeyBase64Url,
      ),
      timeout: const Duration(milliseconds: 30),
      onTimeout: () => timedOut = true,
    );
    addTearDown(server.close);
    addTearDown(client.close);
    await client.receiveChallenge(
      await server.receiveHello(await client.createHello()),
    );
    var decisions = 0;
    final callback = client.guardApprovalCallback((_) => decisions += 1);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    callback(true);

    expect(timedOut, isTrue);
    expect(client.phase, PeerSocketPhase.closing);
    expect(decisions, 0);
  });
}
