import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/auth_handshake_lifecycle.dart';
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
  int negotiatedProtocolVersion = PeerSocketSession.protocolVersion,
}) async {
  final identitySeed = Uint8List.fromList(
    List<int>.generate(32, (i) => seedStart + i),
  );
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
      protocolVersion: PeerSocketSession.protocolVersion,
      capabilities: const PeerCapabilities(
        fileTransferV3: true,
        remoteInputWorkspaceGraphV1: true,
      ),
    ),
    localEphemeralKeyPair: await X25519().newKeyPairFromSeed(ephemeralSeed),
    localNonce: Uint8List.fromList(
      List<int>.generate(32, (i) => seedStart + 128 + i),
    ),
    intendedPeerId: intendedPeerId,
    intendedPublicKeyHash: intendedPkh,
    handshakeTimeout: timeout,
    onTimeout: onTimeout,
    negotiatedProtocolVersion: negotiatedProtocolVersion,
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

Future<({PeerSocketSession client, PeerSocketSession server})>
_authenticatedPair() async {
  final pair = await _reachClientApproval();
  pair.client.resolveLocalApproval(
    generation: pair.client.connectionGeneration,
    allow: true,
  );
  pair.server.resolveLocalApproval(
    generation: pair.server.connectionGeneration,
    allow: true,
  );
  await pair.server.receiveProof(await pair.client.createProof());
  await pair.server.receiveApproval(
    await pair.client.createApproval(allow: true, reason: 'approved'),
  );
  final result = await pair.server.createResult(
    allow: true,
    reason: 'approved',
  );
  await pair.client.receiveResult(result);
  await pair.server.commitAuthentication(
    generation: pair.server.connectionGeneration,
    persistIdentity: () async {},
    registerPeer: () async {},
  );
  await pair.client.commitAuthentication(
    generation: pair.client.connectionGeneration,
    persistIdentity: () async {},
    registerPeer: () async {},
  );
  return pair;
}

void main() {
  test('server claims only one visible local approval prompt', () async {
    final pair = await _reachClientApproval();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);
    await pair.server.receiveProof(await pair.client.createProof());

    expect(pair.server.tryClaimLocalApprovalPrompt(), isTrue);
    expect(pair.server.tryClaimLocalApprovalPrompt(), isFalse);
  });

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

  test('previous auth protocol versions fail before pairing starts', () async {
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
    final hello = await client.createHello();
    final oldHello = AuthEnvelope.hello(
      protocolVersion: 5,
      peerId: hello.peerId,
      identityPublicKey: hello.identityPublicKey!,
      ephemeralPublicKey: hello.ephemeralPublicKey!,
      nonce: hello.nonce,
      profileDigest: hello.profileDigest,
      intendedPeerId: hello.intendedPeerId,
      intendedPublicKeyHash: hello.intendedPublicKeyHash,
      profile: hello.profile,
    );

    await expectLater(
      server.receiveHello(oldHello),
      throwsA(
        isA<AuthHandshakeException>().having(
          (error) => error.code,
          'code',
          'upgrade_required',
        ),
      ),
    );
    expect(server.isClosed, isTrue);
  });

  test('protocol 10 server negotiates a legacy protocol 9 handshake', () async {
    final server = await _session(
      role: PeerSocketRole.server,
      generation: 1,
      seedStart: 32,
    );
    final client = await _session(
      role: PeerSocketRole.client,
      generation: 2,
      seedStart: 0,
      negotiatedProtocolVersion: PeerSocketSession.minimumProtocolVersion,
    );
    addTearDown(client.close);
    addTearDown(server.close);

    final hello = await client.createHello();
    final helloCapabilities = hello.profile!['capabilities']! as Map;
    expect(hello.protocolVersion, 9);
    expect(helloCapabilities, isNot(contains('remoteInputWorkspaceGraphV1')));

    final challenge = await server.receiveHello(hello);
    final challengeCapabilities = challenge.profile!['capabilities']! as Map;
    expect(challenge.protocolVersion, 9);
    expect(
      challengeCapabilities,
      isNot(contains('remoteInputWorkspaceGraphV1')),
    );

    await client.receiveChallenge(challenge);
    expect(client.remoteProfile!.protocolVersion, 9);
    expect(server.remoteProfile!.protocolVersion, 9);
    expect(client.remoteProfile!.capabilities.fileTransferV3, isTrue);
    expect(
      client.remoteProfile!.capabilities.remoteInputWorkspaceGraphV1,
      isFalse,
    );
  });

  test('full handshake enables inverse directional AEAD codecs', () async {
    final pair = await _reachClientApproval();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);

    expect(pair.client.phase, PeerSocketPhase.awaitingLocalApproval);
    expect(pair.server.phase, PeerSocketPhase.awaitingProof);
    expect(pair.client.pairingCode, pair.server.pairingCode);
    expect(pair.client.pairingCode, matches(RegExp(r'^\d{6}$')));

    expect(
      pair.server.resolveLocalApproval(
        generation: pair.server.connectionGeneration,
        allow: true,
      ),
      isTrue,
    );
    expect(
      pair.client.resolveLocalApproval(
        generation: pair.client.connectionGeneration,
        allow: true,
      ),
      isTrue,
    );
    final proof = await pair.client.createProof();
    await pair.server.receiveProof(proof);
    expect(pair.client.phase, PeerSocketPhase.awaitingResult);
    expect(pair.server.phase, PeerSocketPhase.awaitingLocalApproval);
    expect(
      await pair.server.receiveApproval(
        await pair.client.createApproval(allow: true, reason: 'approved'),
      ),
      isTrue,
    );
    final result = await pair.server.createResult(
      allow: true,
      reason: 'approved',
    );
    expect(await pair.client.receiveResult(result), isTrue);

    expect(pair.client.phase, PeerSocketPhase.awaitingResult);
    expect(pair.server.phase, PeerSocketPhase.awaitingLocalApproval);
    expect(pair.client.codec, isNull);
    expect(pair.server.codec, isNull);

    final serverOrder = <String>[];
    expect(
      await pair.server.commitAuthentication(
        generation: pair.server.connectionGeneration,
        persistIdentity: () async => serverOrder.add('persist'),
        registerPeer: () async {
          expect(pair.server.isAuthenticated, isFalse);
          expect(pair.server.isAuthenticationReady, isTrue);
          expect(pair.server.codec, isNotNull);
          serverOrder.add('register');
        },
      ),
      isTrue,
    );
    final clientOrder = <String>[];
    expect(
      await pair.client.commitAuthentication(
        generation: pair.client.connectionGeneration,
        persistIdentity: () async => clientOrder.add('persist'),
        registerPeer: () async {
          expect(pair.client.isAuthenticated, isFalse);
          expect(pair.client.isAuthenticationReady, isTrue);
          expect(pair.client.codec, isNotNull);
          clientOrder.add('register');
        },
      ),
      isTrue,
    );

    expect(serverOrder, <String>['persist', 'register']);
    expect(clientOrder, <String>['persist', 'register']);
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

  test('client proof does not grant local approval', () async {
    final pair = await _reachClientApproval();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);

    final proof = await pair.client.createProof();
    await pair.server.receiveProof(proof);

    expect(pair.client.phase, PeerSocketPhase.awaitingLocalApproval);
    expect(pair.client.isLocalApprovalResolved, isFalse);
    expect(pair.server.phase, PeerSocketPhase.awaitingLocalApproval);
    expect(pair.server.isMutuallyApproved, isFalse);
  });

  test('server cannot commit after only its local pairing approval', () async {
    final pair = await _reachClientApproval();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);
    expect(
      pair.server.resolveLocalApproval(
        generation: pair.server.connectionGeneration,
        allow: true,
      ),
      isTrue,
    );
    var persisted = false;

    expect(pair.server.isMutuallyApproved, isFalse);
    expect(
      await pair.server.commitAuthentication(
        generation: pair.server.connectionGeneration,
        persistIdentity: () async => persisted = true,
        registerPeer: () async {},
      ),
      isFalse,
    );
    expect(persisted, isFalse);
  });

  test(
    'server rejection completes without waiting for remote approval',
    () async {
      final pair = await _reachClientApproval();
      addTearDown(pair.client.close);
      addTearDown(pair.server.close);
      expect(
        pair.server.resolveLocalApproval(
          generation: pair.server.connectionGeneration,
          allow: false,
        ),
        isTrue,
      );
      await pair.server.receiveProof(await pair.client.createProof());
      expect(pair.server.tryClaimPairingCompletion(), isTrue);
    },
  );

  test(
    'server result completes external pairing presentation cancellation',
    () async {
      final pair = await _reachClientApproval();
      addTearDown(pair.client.close);
      addTearDown(pair.server.close);
      pair.client.resolveLocalApproval(
        generation: pair.client.connectionGeneration,
        allow: true,
      );
      pair.server.resolveLocalApproval(
        generation: pair.server.connectionGeneration,
        allow: true,
      );
      await pair.server.receiveProof(await pair.client.createProof());
      await pair.server.receiveApproval(
        await pair.client.createApproval(allow: true, reason: 'approved'),
      );

      await pair.server.createResult(allow: true, reason: 'approved');

      await expectLater(pair.server.pairingResolved, completes);
    },
  );

  test('authenticated sessions scope and wipe inverse media keys', () async {
    final pair = await _authenticatedPair();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);

    late Uint8List scopedSendKey;
    late int originalFirstByte;
    pair.client.withMediaSendKey((clientSendKey) {
      scopedSendKey = clientSendKey;
      originalFirstByte = clientSendKey.first;
      pair.server.withMediaReceiveKey((serverReceiveKey) {
        expect(clientSendKey, orderedEquals(serverReceiveKey));
      });
      clientSendKey[0] ^= 0xff;
    });
    expect(scopedSendKey, everyElement(0));
    pair.client.withMediaSendKey((clientSendKey) {
      expect(clientSendKey.first, originalFirstByte);
    });

    late Uint8List scopedReceiveKey;
    await pair.client.withMediaReceiveKeyAsync((clientReceiveKey) async {
      scopedReceiveKey = clientReceiveKey;
      pair.server.withMediaSendKey((serverSendKey) {
        expect(clientReceiveKey, orderedEquals(serverSendKey));
      });
      await Future<void>.delayed(Duration.zero);
      expect(clientReceiveKey, isNot(everyElement(0)));
    });
    expect(scopedReceiveKey, everyElement(0));

    pair.client.close();
    expect(
      () => pair.client.withMediaSendKey<void>((_) {}),
      throwsA(isA<AuthHandshakeException>()),
    );
    expect(
      () => pair.client.withMediaReceiveKey<void>((_) {}),
      throwsA(isA<AuthHandshakeException>()),
    );
  });

  test('shutdown drains queued authenticated frames before closing', () async {
    final pair = await _authenticatedPair();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);
    final incoming = StreamController<Object>();
    addTearDown(incoming.close);
    final subscription = incoming.stream.listen((_) {});
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final writes = <Object>[];

    pair.client.attachTransport(
      subscription: subscription,
      addStream: (stream) async {
        final value = await stream.single;
        writes.add(value);
        if (writes.length == 1) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
      },
      onOverflow: () => fail('outbound queue overflowed'),
    );
    final first = pair.client.enqueueOutgoing(
      Uint8List.fromList(<int>[9]),
      byteLength: 1,
    );
    await firstWriteStarted.future;
    final payload = Uint8List.fromList(<int>[1, 2, 3]);
    final queued = pair.client.enqueueAuthenticatedOutgoing(
      payload,
      byteLength: payload.length,
    );

    AuthSocketLifecycle.closePendingAuth(
      sessions: <PeerSocketSession>[pair.client],
      completeFailures: const <void Function()>[],
    );
    expect(pair.client.isAuthenticated, isTrue);

    final shutdown = () async {
      await pair.client.stopReceivingAndDrain();
      await pair.client.drainOutbound();
      pair.client.close();
    }();
    releaseFirstWrite.complete();

    expect(await first, isTrue);
    expect(await queued, isTrue);
    await shutdown;
    expect(pair.client.phase, PeerSocketPhase.closing);
    expect(writes, hasLength(2));
    expect(
      await pair.server.decodeIncoming(writes.last as Uint8List),
      orderedEquals(payload),
    );
  });

  test('closing a session aborts active and queued outbound writes', () async {
    final pair = await _authenticatedPair();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);
    final incoming = StreamController<Object>();
    addTearDown(incoming.close);
    final subscription = incoming.stream.listen((_) {});
    final firstWriteStarted = Completer<void>();
    final releaseWriter = Completer<void>();
    var writes = 0;
    pair.client.attachTransport(
      subscription: subscription,
      addStream: (stream) async {
        writes += 1;
        await stream.single;
        firstWriteStarted.complete();
        await releaseWriter.future;
      },
      onOverflow: () => fail('outbound queue overflowed'),
    );

    final active = pair.client.enqueueOutgoing(
      Uint8List.fromList(<int>[1]),
      byteLength: 1,
    );
    await firstWriteStarted.future;
    final waiting = pair.client.enqueueOutgoing(
      Uint8List.fromList(<int>[2]),
      byteLength: 1,
    );

    pair.client.close();

    expect(await active.timeout(const Duration(milliseconds: 100)), isFalse);
    expect(await waiting, isFalse);
    await pair.client.drainOutbound().timeout(
      const Duration(milliseconds: 100),
    );
    expect(pair.client.pendingOutboundItems, 0);
    expect(writes, 1);

    releaseWriter.complete();
    await Future<void>.delayed(Duration.zero);
    expect(writes, 1);
    expect(pair.client.pendingOutboundItems, 0);
  });

  test(
    'concurrent receive stops share and await subscription cancellation',
    () async {
      final session = await _session(
        role: PeerSocketRole.server,
        generation: 1,
        seedStart: 32,
      );
      addTearDown(session.close);
      final cancelStarted = Completer<void>();
      final releaseCancel = Completer<void>();
      var cancelCount = 0;
      final incoming = StreamController<Object>(
        onCancel: () async {
          cancelCount += 1;
          cancelStarted.complete();
          await releaseCancel.future;
        },
      );
      addTearDown(incoming.close);
      final subscription = incoming.stream.listen((_) {});
      session.attachTransport(
        subscription: subscription,
        addStream: (_) async {},
        onOverflow: () => fail('queue overflowed'),
      );

      final firstStop = session.stopReceivingAndDrain();
      await cancelStarted.future;
      var secondCompleted = false;
      final secondStop = session.stopReceivingAndDrain().whenComplete(() {
        secondCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);

      expect(cancelCount, 1);
      expect(secondCompleted, isFalse);

      releaseCancel.complete();
      await Future.wait(<Future<void>>[firstStop, secondStop]);
      expect(cancelCount, 1);
    },
  );

  test('real websocket shutdown drains an action and outbound frame', () async {
    final pair = await _authenticatedPair();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => httpServer.close(force: true));
    final accepted = Completer<WebSocket>();
    httpServer.listen((request) async {
      accepted.complete(await WebSocketTransformer.upgrade(request));
    });
    final client = await WebSocket.connect(
      'ws://127.0.0.1:${httpServer.port}/chat',
    );
    final server = await accepted.future;
    addTearDown(client.close);
    addTearDown(server.close);
    final actionStarted = Completer<void>();
    final releaseAction = Completer<void>();
    final outboundReceived = Completer<List<int>>();
    server.listen((message) {
      if (!outboundReceived.isCompleted && message is List<int>) {
        outboundReceived.complete(message);
      }
    });
    late final StreamSubscription<dynamic> subscription;
    subscription = client.listen((message) {
      final bytes = message as List<int>;
      unawaited(
        pair.client.enqueueIncoming(bytes.length, () async {
          actionStarted.complete();
          await releaseAction.future;
        }),
      );
    });
    pair.client.attachTransport(
      subscription: subscription,
      addStream: client.addStream,
      onOverflow: () => fail('queue overflowed'),
    );

    server.add(Uint8List.fromList(<int>[1]));
    await actionStarted.future;
    final outgoing = pair.client.enqueueOutgoing(
      Uint8List.fromList(<int>[9, 8, 7]),
      byteLength: 3,
    );
    var shutdownCompleted = false;
    final shutdown = () async {
      await pair.client.stopReceivingAndDrain();
      await pair.client.drainOutbound();
      shutdownCompleted = true;
    }();

    expect(await outgoing, isTrue);
    expect(
      await outboundReceived.future.timeout(const Duration(seconds: 2)),
      orderedEquals(<int>[9, 8, 7]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(shutdownCompleted, isFalse);

    releaseAction.complete();
    await shutdown;
    expect(shutdownCompleted, isTrue);
  });

  test(
    'persistence failure closes an approved session before registration',
    () async {
      final pair = await _reachClientApproval();
      addTearDown(pair.client.close);
      addTearDown(pair.server.close);
      pair.client.resolveLocalApproval(
        generation: pair.client.connectionGeneration,
        allow: true,
      );
      pair.server.resolveLocalApproval(
        generation: pair.server.connectionGeneration,
        allow: true,
      );
      await pair.server.receiveProof(await pair.client.createProof());
      await pair.server.receiveApproval(
        await pair.client.createApproval(allow: true, reason: 'approved'),
      );
      await pair.server.createResult(allow: true, reason: 'approved');
      var registered = false;

      await expectLater(
        pair.server.commitAuthentication(
          generation: pair.server.connectionGeneration,
          persistIdentity: () async => throw StateError('database failed'),
          registerPeer: () async => registered = true,
        ),
        throwsStateError,
      );

      expect(registered, isFalse);
      expect(pair.server.phase, PeerSocketPhase.closing);
      expect(pair.server.isAuthenticated, isFalse);
    },
  );

  test('registration failure closes an AEAD-activated session', () async {
    final pair = await _reachClientApproval();
    addTearDown(pair.client.close);
    addTearDown(pair.server.close);
    pair.client.resolveLocalApproval(
      generation: pair.client.connectionGeneration,
      allow: true,
    );
    pair.server.resolveLocalApproval(
      generation: pair.server.connectionGeneration,
      allow: true,
    );
    await pair.server.receiveProof(await pair.client.createProof());
    await pair.server.receiveApproval(
      await pair.client.createApproval(allow: true, reason: 'approved'),
    );
    await pair.server.createResult(allow: true, reason: 'approved');

    await expectLater(
      pair.server.commitAuthentication(
        generation: pair.server.connectionGeneration,
        persistIdentity: () async {},
        registerPeer: () async {
          expect(pair.server.isAuthenticated, isFalse);
          expect(pair.server.isAuthenticationReady, isTrue);
          throw StateError('registry failed');
        },
      ),
      throwsStateError,
    );

    expect(pair.server.phase, PeerSocketPhase.closing);
    expect(pair.server.isAuthenticated, isFalse);
  });

  test(
    'closing during persistence is terminal and cannot resume auth',
    () async {
      final pair = await _reachClientApproval();
      addTearDown(pair.client.close);
      addTearDown(pair.server.close);
      pair.client.resolveLocalApproval(
        generation: pair.client.connectionGeneration,
        allow: true,
      );
      pair.server.resolveLocalApproval(
        generation: pair.server.connectionGeneration,
        allow: true,
      );
      await pair.server.receiveProof(await pair.client.createProof());
      await pair.server.receiveApproval(
        await pair.client.createApproval(allow: true, reason: 'approved'),
      );
      await pair.server.createResult(allow: true, reason: 'approved');
      final persistence = Completer<void>();
      var registered = false;
      final commit = pair.server.commitAuthentication(
        generation: pair.server.connectionGeneration,
        persistIdentity: () => persistence.future,
        registerPeer: () async => registered = true,
      );

      pair.server.close();
      persistence.complete();

      await expectLater(commit, throwsA(isA<AuthHandshakeException>()));
      expect(pair.server.phase, PeerSocketPhase.closing);
      expect(registered, isFalse);
    },
  );

  test(
    'unknown target can omit peer id but must match discovered pkh',
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
        intendedPkh: encodeAuthBase64Url(List<int>.filled(32, 0)),
      );
      addTearDown(client.close);
      addTearDown(server.close);
      await expectLater(
        server.receiveHello(await client.createHello()),
        throwsA(isA<AuthHandshakeException>()),
      );
      expect(server.phase, PeerSocketPhase.closing);
    },
  );

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
