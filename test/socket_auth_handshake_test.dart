import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_profile.dart';

Future<PeerSocketSession> _makeSession(
  PeerSocketRole role,
  int seed, {
  String intendedPeerId = '',
  String intendedPkh = '',
}) async {
  return PeerSocketSession.create(
    role: role,
    connectionGeneration: seed,
    localIdentity: await DeviceIdentity.fromSeed(
      Uint8List.fromList(List<int>.generate(32, (i) => seed + i)),
    ),
    localProfile: WirePeerProfile(
      uid: role == PeerSocketRole.client ? 'client' : 'server',
      name: role == PeerSocketRole.client ? 'Client' : 'Server',
      platform: 'test',
      protocolVersion: 5,
      capabilities: const PeerCapabilities(
        fileTransferV3: true,
        remoteInputSourceV1: true,
      ),
    ),
    localEphemeralKeyPair: await X25519().newKeyPairFromSeed(
      List<int>.generate(32, (i) => seed + 64 + i),
    ),
    localNonce:
        Uint8List.fromList(List<int>.generate(32, (i) => seed + 128 + i)),
    intendedPeerId: intendedPeerId,
    intendedPublicKeyHash: intendedPkh,
  );
}

Future<
    ({
      PeerSocketSession client,
      PeerSocketSession server,
      AuthEnvelope result
    })> _completedServerHandshake() async {
  final server = await _makeSession(PeerSocketRole.server, 32);
  final client = await _makeSession(
    PeerSocketRole.client,
    1,
    intendedPeerId: 'server',
    intendedPkh: identityPublicKeyHash(
      server.localIdentity.publicKeyBase64Url,
    ),
  );
  final challenge = await server.receiveHello(await client.createHello());
  await client.receiveChallenge(challenge);
  client.resolveLocalApproval(
    generation: client.connectionGeneration,
    allow: true,
  );
  await server.receiveProof(await client.createProof());
  server.resolveLocalApproval(
    generation: server.connectionGeneration,
    allow: true,
  );
  final result = await server.createResult(allow: true, reason: 'approved');
  return (client: client, server: server, result: result);
}

Future<({PeerSocketSession client, PeerSocketSession server})>
    _serverAwaitingApproval() async {
  final server = await _makeSession(PeerSocketRole.server, 32);
  final client = await _makeSession(PeerSocketRole.client, 1);
  await client.receiveChallenge(
    await server.receiveHello(await client.createHello()),
  );
  client.resolveLocalApproval(
    generation: client.connectionGeneration,
    allow: true,
  );
  await server.receiveProof(await client.createProof());
  return (client: client, server: server);
}

void main() {
  DeviceData stored({required bool auth, String pin = ''}) => DeviceData(
        id: 1,
        uid: 'peer',
        identityPublicKey: pin,
        name: 'Peer',
        host: '',
        port: 0,
        platform: 'test',
        isServer: false,
        online: false,
        clipboard: false,
        auth: auth,
        lastTime: 0,
      );

  test('pairing policy distinguishes new, legacy, changed, and pinned peers',
      () {
    expect(
      pairingReasonForIdentity(null, 'key'),
      PairingReason.newDevice,
    );
    expect(
      pairingReasonForIdentity(stored(auth: true), 'key'),
      PairingReason.legacyTrustWithoutPin,
    );
    expect(
      pairingReasonForIdentity(stored(auth: true, pin: 'old'), 'new'),
      PairingReason.identityChanged,
    );
    expect(
      pairingReasonForIdentity(stored(auth: true, pin: 'key'), 'key'),
      isNull,
    );
  });

  test('profile digest binds both profiles and rejects profile tampering',
      () async {
    final server = await _makeSession(PeerSocketRole.server, 32);
    final client = await _makeSession(PeerSocketRole.client, 1);
    addTearDown(server.close);
    addTearDown(client.close);
    final hello = await client.createHello();
    final tamperedProfile = <String, Object?>{
      ...hello.profile!,
      'name': 'Mallory',
    };
    final tampered = AuthEnvelope.hello(
      protocolVersion: hello.protocolVersion,
      peerId: hello.peerId,
      identityPublicKey: hello.identityPublicKey!,
      ephemeralPublicKey: hello.ephemeralPublicKey!,
      nonce: hello.nonce,
      profileDigest: hello.profileDigest,
      intendedPeerId: hello.intendedPeerId,
      intendedPublicKeyHash: hello.intendedPublicKeyHash,
      profile: tamperedProfile,
    );

    await expectLater(
      server.receiveHello(tampered),
      throwsA(isA<AuthHandshakeException>()),
    );
    expect(server.phase, PeerSocketPhase.closing);
  });

  test('client rejects a challenge with a tampered server profile', () async {
    final server = await _makeSession(PeerSocketRole.server, 32);
    final client = await _makeSession(PeerSocketRole.client, 1);
    addTearDown(server.close);
    addTearDown(client.close);
    final challenge = await server.receiveHello(await client.createHello());
    final tampered = AuthEnvelope.challenge(
      protocolVersion: challenge.protocolVersion,
      peerId: challenge.peerId,
      identityPublicKey: challenge.identityPublicKey!,
      ephemeralPublicKey: challenge.ephemeralPublicKey!,
      nonce: challenge.nonce,
      peerNonce: challenge.peerNonce!,
      profileDigest: challenge.profileDigest,
      signature: challenge.signature!,
      profile: <String, Object?>{
        ...challenge.profile!,
        'platform': 'tampered',
      },
    );

    await expectLater(
      client.receiveChallenge(tampered),
      throwsA(isA<AuthHandshakeException>()),
    );
    expect(client.phase, PeerSocketPhase.closing);
    expect(client.isClosed, isTrue);
  });

  test('tampered signed result cannot pin or register the peer', () async {
    final flow = await _completedServerHandshake();
    addTearDown(flow.client.close);
    addTearDown(flow.server.close);
    final signatureBytes = decodeAuthBase64Url(
      flow.result.signature!,
      expectedLength: 64,
    )..[0] ^= 1;
    final tampered = AuthEnvelope.result(
      protocolVersion: flow.result.protocolVersion,
      peerId: flow.result.peerId,
      nonce: flow.result.nonce,
      peerNonce: flow.result.peerNonce!,
      profileDigest: flow.result.profileDigest,
      signature: encodeAuthBase64Url(signatureBytes),
      allow: true,
      reason: flow.result.reason!,
    );

    await expectLater(
      flow.client.receiveResult(tampered),
      throwsA(isA<AuthHandshakeException>()),
    );
    var pins = 0;
    var registrations = 0;
    expect(
      await flow.client.commitAuthentication(
        generation: flow.client.connectionGeneration,
        pinIdentity: () async => pins += 1,
        registerPeer: () async => registrations += 1,
      ),
      isFalse,
    );
    expect(pins, 0);
    expect(registrations, 0);
  });

  test('verified result permits one generation-bound pin and registration',
      () async {
    final flow = await _completedServerHandshake();
    addTearDown(flow.client.close);
    addTearDown(flow.server.close);
    expect(await flow.client.receiveResult(flow.result), isTrue);
    var pins = 0;
    var registrations = 0;

    expect(
      await flow.client.commitAuthentication(
        generation: flow.client.connectionGeneration,
        pinIdentity: () async => pins += 1,
        registerPeer: () async => registrations += 1,
      ),
      isTrue,
    );
    expect(
      await flow.client.commitAuthentication(
        generation: flow.client.connectionGeneration,
        pinIdentity: () async => pins += 1,
        registerPeer: () async => registrations += 1,
      ),
      isFalse,
    );
    expect(pins, 1);
    expect(registrations, 1);
  });

  test('closing during result verification cannot revive or commit session',
      () async {
    final flow = await _completedServerHandshake();
    addTearDown(flow.client.close);
    addTearDown(flow.server.close);

    final receiving = flow.client.receiveResult(flow.result);
    flow.client.close();
    await expectLater(receiving, throwsA(isA<AuthHandshakeException>()));
    var pins = 0;
    var registrations = 0;

    expect(flow.client.isClosed, isTrue);
    expect(flow.client.phase, PeerSocketPhase.closing);
    expect(
      await flow.client.commitAuthentication(
        generation: flow.client.connectionGeneration,
        pinIdentity: () async => pins += 1,
        registerPeer: () async => registrations += 1,
      ),
      isFalse,
    );
    expect(pins, 0);
    expect(registrations, 0);
  });

  test('client and server rejection never authenticate', () async {
    final server = await _makeSession(PeerSocketRole.server, 32);
    final client = await _makeSession(PeerSocketRole.client, 1);
    addTearDown(server.close);
    addTearDown(client.close);
    await client.receiveChallenge(
      await server.receiveHello(await client.createHello()),
    );
    expect(
      client.resolveLocalApproval(
        generation: client.connectionGeneration,
        allow: false,
      ),
      isTrue,
    );
    expect(client.phase, PeerSocketPhase.closing);
    expect(client.isClosed, isTrue);

    final flow = await _serverAwaitingApproval();
    addTearDown(flow.client.close);
    addTearDown(flow.server.close);
    flow.server.resolveLocalApproval(
      generation: flow.server.connectionGeneration,
      allow: false,
    );
    final denial = await flow.server.createResult(
      allow: false,
      reason: 'rejected',
    );
    expect(await flow.client.receiveResult(denial), isFalse);
    expect(flow.client.phase, PeerSocketPhase.closing);
    expect(flow.server.phase, PeerSocketPhase.closing);
    expect(flow.client.isClosed, isTrue);
    expect(flow.server.isClosed, isTrue);
  });

  test('wire profile excludes local trust and endpoint fields', () {
    const profile = WirePeerProfile(
      uid: 'peer-a',
      name: 'Peer A',
      platform: 'macos',
      protocolVersion: 5,
      capabilities: PeerCapabilities(fileTransferV3: true),
    );
    final json = profile.toJson();

    expect(
        json.keys,
        containsAll(<String>[
          'uid',
          'name',
          'platform',
          'protocolVersion',
          'capabilities',
        ]));
    for (final forbidden in <String>[
      'id',
      'host',
      'port',
      'password',
      'auth',
      'clipboard',
      'lastTime',
      'around',
      'trustedPeerIds',
      'autoConnectEnabled',
    ]) {
      expect(json, isNot(contains(forbidden)));
    }
    expect(WirePeerProfile.fromJson(json), profile);
  });
}
