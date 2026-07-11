import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/auth_handshake_lifecycle.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/state/peer_profile.dart';

final class _FakeAuthSink {
  final List<String> sent = <String>[];
  bool closed = false;

  void send(String message) => sent.add(message);

  Future<void> close() async {
    closed = true;
  }
}

Future<PeerSocketSession> _session({
  required PeerSocketRole role,
  required int generation,
  required int seed,
}) async {
  return PeerSocketSession.create(
    role: role,
    connectionGeneration: generation,
    localIdentity: await DeviceIdentity.fromSeed(
      Uint8List.fromList(List<int>.generate(32, (index) => seed + index)),
    ),
    localProfile: WirePeerProfile(
      uid: role == PeerSocketRole.client ? 'client-a' : 'server-b',
      name: role == PeerSocketRole.client ? 'Client A' : 'Server B',
      platform: 'test',
    ),
    localEphemeralKeyPair: await X25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => seed + 64 + index),
    ),
    localNonce: Uint8List.fromList(
      List<int>.generate(32, (index) => seed + 128 + index),
    ),
  );
}

Future<({PeerSocketSession client, PeerSocketSession server})>
    _approvedServer() async {
  final client = await _session(
    role: PeerSocketRole.client,
    generation: 1,
    seed: 1,
  );
  final server = await _session(
    role: PeerSocketRole.server,
    generation: 2,
    seed: 33,
  );
  await client.receiveChallenge(
    await server.receiveHello(await client.createHello()),
  );
  await server.receiveProof(await client.createProof());
  client.resolveLocalApproval(
    generation: client.connectionGeneration,
    allow: true,
  );
  await server.receiveApproval(
    await client.createApproval(allow: true, reason: 'approved'),
  );
  server.resolveLocalApproval(
    generation: server.connectionGeneration,
    allow: true,
  );
  await server.createResult(allow: true, reason: 'approved');
  return (client: client, server: server);
}

void main() {
  group('AuthHandshakeLifecycle', () {
    test('server sends allow only after persistence and registration complete',
        () async {
      final pair = await _approvedServer();
      addTearDown(pair.client.close);
      addTearDown(pair.server.close);
      final sink = _FakeAuthSink();
      final persistenceStarted = Completer<void>();
      final releasePersistence = Completer<void>();
      final registrationStarted = Completer<void>();
      final releaseRegistration = Completer<void>();
      final order = <String>[];

      final completion = AuthHandshakeLifecycle.completeServerAllow<void>(
        commit: () async {
          final committed = await pair.server.commitAuthentication(
            generation: pair.server.connectionGeneration,
            persistIdentity: () async {
              order.add('persist');
              persistenceStarted.complete();
              await releasePersistence.future;
            },
            registerPeer: () async {
              expect(pair.server.codec, isNotNull);
              expect(pair.server.isAuthenticationReady, isTrue);
              order.add('mac-ready');
              registrationStarted.complete();
              await releaseRegistration.future;
              order.add('register');
            },
          );
          expect(committed, isTrue);
          expect(pair.server.isAuthenticated, isTrue);
          order.add('authenticated');
        },
        sendAllow: (_) async {
          expect(pair.server.isAuthenticated, isTrue);
          order.add('send-allow');
          sink.send('allow');
        },
        onAuthenticated: (_) => order.add('announce'),
        onFailure: (_, __) async {
          pair.server.close();
          await sink.close();
        },
      );

      await persistenceStarted.future;
      expect(sink.sent, isEmpty);
      releasePersistence.complete();
      await registrationStarted.future;
      expect(sink.sent, isEmpty);
      releaseRegistration.complete();

      expect(await completion, isTrue);
      expect(sink.sent, <String>['allow']);
      expect(
        order,
        <String>[
          'persist',
          'mac-ready',
          'register',
          'authenticated',
          'send-allow',
          'announce',
        ],
      );
    });

    for (final failureStage in <String>['database', 'registry']) {
      test('$failureStage failure is consumed and never sends allow', () async {
        final pair = await _approvedServer();
        addTearDown(pair.client.close);
        addTearDown(pair.server.close);
        final sink = _FakeAuthSink();
        var failureHandled = false;

        final completed =
            await AuthHandshakeLifecycle.completeServerAllow<void>(
          commit: () async {
            await pair.server.commitAuthentication(
              generation: pair.server.connectionGeneration,
              persistIdentity: () async {
                if (failureStage == 'database') {
                  throw StateError('database failed');
                }
              },
              registerPeer: () async {
                if (failureStage == 'registry') {
                  throw StateError('registry failed');
                }
              },
            );
          },
          sendAllow: (_) async => sink.send('allow'),
          onAuthenticated: (_) {},
          onFailure: (error, _) async {
            expect(error, isA<StateError>());
            failureHandled = true;
            pair.server.close();
            await sink.close();
          },
        );

        expect(completed, isFalse);
        expect(failureHandled, isTrue);
        expect(sink.sent, isEmpty);
        expect(sink.closed, isTrue);
        expect(pair.server.phase, PeerSocketPhase.closing);
      });
    }

    for (final failureStage in <String>['database', 'registry']) {
      test('guarded UI $failureStage error is consumed and closes resources',
          () async {
        final session = await _session(
          role: PeerSocketRole.client,
          generation: 5,
          seed: 5,
        );
        addTearDown(session.close);
        final sink = _FakeAuthSink();
        final authResult = Completer<bool>();

        final completed = await AuthHandshakeLifecycle.resolveGuarded(
          resolve: () async => throw StateError('$failureStage failed'),
          onFailure: (_, __) async {
            session.close();
            await sink.close();
            authResult.complete(false);
          },
        );

        expect(completed, isFalse);
        expect(await authResult.future, isFalse);
        expect(session.phase, PeerSocketPhase.closing);
        expect(sink.closed, isTrue);
      });
    }
  });

  group('AuthSocketLifecycle', () {
    for (final terminal in <String>['onDone', 'onError']) {
      test('$terminal closes the session before queued cleanup', () async {
        final session = await _session(
          role: PeerSocketRole.client,
          generation: 7,
          seed: 7,
        );
        var cleanupQueued = false;

        AuthSocketLifecycle.closeBeforeQueuedCleanup(session, () {
          expect(session.phase, PeerSocketPhase.closing);
          cleanupQueued = true;
        });

        expect(cleanupQueued, isTrue);
      });
    }

    test('shutdown closes only pending auth sessions', () async {
      final pendingSession = await _session(
        role: PeerSocketRole.client,
        generation: 8,
        seed: 8,
      );
      final authenticatedPair = await _approvedServer();
      addTearDown(pendingSession.close);
      addTearDown(authenticatedPair.client.close);
      addTearDown(authenticatedPair.server.close);
      expect(
        await authenticatedPair.server.commitAuthentication(
          generation: authenticatedPair.server.connectionGeneration,
          persistIdentity: () async {},
          registerPeer: () async {},
        ),
        isTrue,
      );

      expect(
        AuthSocketLifecycle.hasConnectionWork(
          hasSelectedSink: false,
          hasClientTimer: false,
          hasPendingSessions: true,
          hasPendingResults: true,
          hasPeerConnections: false,
          hasReceiver: false,
        ),
        isTrue,
      );
      final authResult = Completer<bool>();
      AuthSocketLifecycle.closePendingAuth(
        sessions: <PeerSocketSession>[
          pendingSession,
          authenticatedPair.server,
        ],
        completeFailures: <void Function()>[
          () => authResult.complete(false),
        ],
      );

      expect(pendingSession.phase, PeerSocketPhase.closing);
      expect(authenticatedPair.server.isAuthenticated, isTrue);
      expect(await authResult.future, isFalse);
    });

    test('old onDone cannot remove or close its replacement', () async {
      final registry = PeerConnectionRegistry();
      final oldSession = await _session(
        role: PeerSocketRole.client,
        generation: 1,
        seed: 10,
      );
      final replacementSession = await _session(
        role: PeerSocketRole.client,
        generation: 2,
        seed: 20,
      );
      addTearDown(oldSession.close);
      addTearDown(replacementSession.close);
      var replacementClosed = false;
      await registry.register(PeerConnection(
        peerId: 'peer-a',
        connectionId: 1,
        send: (_) {},
        close: () async {},
      ));
      final replacement = PeerConnection(
        peerId: 'peer-a',
        connectionId: 2,
        send: (_) {},
        close: () async => replacementClosed = true,
      );
      await registry.register(replacement);

      final removed = await AuthSocketLifecycle.removeConnectionIfCurrent(
        connections: registry,
        peerId: 'peer-a',
        closingSession: oldSession,
        currentSession: replacementSession,
      );

      expect(removed, isFalse);
      expect(replacementClosed, isFalse);
      expect(registry.connection('peer-a'), same(replacement));
    });

    test('current onDone removes only its matching connection', () async {
      final registry = PeerConnectionRegistry();
      final session = await _session(
        role: PeerSocketRole.client,
        generation: 3,
        seed: 30,
      );
      addTearDown(session.close);
      var connectionClosed = false;
      await registry.register(PeerConnection(
        peerId: 'peer-a',
        connectionId: 3,
        send: (_) {},
        close: () async => connectionClosed = true,
      ));

      final removed = await AuthSocketLifecycle.removeConnectionIfCurrent(
        connections: registry,
        peerId: 'peer-a',
        closingSession: session,
        currentSession: session,
      );

      expect(removed, isTrue);
      expect(connectionClosed, isTrue);
      expect(registry.connection('peer-a'), isNull);
    });
  });
}
