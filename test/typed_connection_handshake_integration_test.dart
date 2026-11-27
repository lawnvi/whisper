import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_files/fs_protocol.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/pre_auth_byte_cap.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';

void main() {
  test(
    'incompatible servers fail in one attempt and indicate which device must update',
    () async {
      final harness = await _HandshakeHarness.start();
      for (final scenario in <({
        int version,
        int? minVersion,
        int? maxVersion,
        ConnectionAttemptReason expected,
      })>[
        (
          version: 15,
          minVersion: null,
          maxVersion: null,
          expected: ConnectionAttemptReason.protocolMismatch,
        ),
        (
          version: 17,
          minVersion: 17,
          maxVersion: 17,
          expected: ConnectionAttemptReason.localUpgradeRequired,
        ),
      ]) {
        final server = await _UpgradeRequiredServer.start(
          version: scenario.version,
          minVersion: scenario.minVersion,
          maxVersion: scenario.maxVersion,
        );
        addTearDown(server.close);

        final result = await harness.connectVia(server.port);
        expect(result.status, ConnectionAttemptStatus.rejected);
        expect(result.reason, scenario.expected);
        expect(server.acceptedConnections, 1);
      }
    },
  );

  test(
    'typed success waits for signed persistence and current registration',
    () async {
      final harness = await _HandshakeHarness.start();
      final result = await harness.connect('signed-success');

      expect(result.status, ConnectionAttemptStatus.authenticated);
      expect(result.peerId, 'server-peer');
      expect(result.generation, greaterThan(0));
      expect(
        harness.client.isCurrentConnectionGeneration(
          result.peerId,
          result.generation,
        ),
        isTrue,
      );
      final storedServer = await harness.database.fetchDevice('server-peer');
      final storedClient = await harness.database.fetchDevice('client-peer');
      expect(storedServer?.auth, isTrue);
      expect(storedServer?.identityPublicKey, isNotEmpty);
      expect(storedClient?.auth, isTrue);
      expect(storedClient?.identityPublicKey, isNotEmpty);
      expect(harness.client.receiver, isEmpty);
      expect(harness.clientEvents.afterAuthCount, 0);
      expect(harness.serverEvents.afterAuthCount, 1);

      harness.client.selectPeer(result.peerId);
      expect(harness.client.receiver, 'server-peer');
    },
  );

  // dart:io's WebSocket gathers a whole message before anything can check
  // its size, so a peer that never authenticates could fill memory with one.
  test(
    'a peer that has not authenticated is cut off past the byte cap',
    () async {
      final harness = await _HandshakeHarness.start();
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        harness.port,
      );
      addTearDown(socket.destroy);
      final closed = Completer<void>();
      final response = StringBuffer();
      socket.listen(
        (data) => response.write(latin1.decode(data)),
        onError: (Object _) {},
        onDone: closed.complete,
      );
      socket.write(
        'GET /chat HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\n'
        'Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: ${base64.encode(List<int>.filled(16, 1))}\r\n\r\n',
      );
      await _waitUntil(() => response.toString().contains('\r\n\r\n'));
      expect(response.toString(), startsWith('HTTP/1.1 101'));

      // One masked binary frame announced as 64 MiB, never finished.
      socket.add(<int>[0x82, 0xff, 0, 0, 0, 0, 4, 0, 0, 0, 1, 2, 3, 4]);
      final chunk = Uint8List(64 * 1024);
      try {
        for (var sent = 0; sent < 2 * preAuthByteCap; sent += chunk.length) {
          if (closed.isCompleted) break;
          socket.add(chunk);
          await socket.flush();
        }
      } on SocketException {
        // The server hung up while we were still writing.
      }
      await closed.future.timeout(const Duration(seconds: 5));
    },
  );

  test('a hello under a trusted id without a proof keeps nobody out', () async {
    final harness = await _HandshakeHarness.start();
    await _trust(harness.database, 'server-peer', await _publicKey(1));
    await _trust(harness.database, 'client-peer', await _publicKey(33));
    final impostor = await PeerSocketSession.create(
      role: PeerSocketRole.client,
      connectionGeneration: 1,
      localIdentity: await _identityStore(99).loadOrCreate(),
      localProfile: _profile('client-peer').toWireProfile(),
    );
    addTearDown(impostor.close);
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${harness.port}/chat',
    );
    addTearDown(socket.close);
    final challenged = Completer<void>();
    socket.listen((_) {
      if (!challenged.isCompleted) challenged.complete();
    });
    final hello = await impostor.createHello();
    socket.add(_authFrame('client-peer', hello.toJsonString()));
    await challenged.future.timeout(const Duration(seconds: 2));

    // The impostor got its challenge and sits on it; the real device, with
    // the pinned key, still connects without a prompt.
    final result = await harness.connect('impostor-holds-a-hello');
    expect(result.status, ConnectionAttemptStatus.authenticated);
    expect(harness.serverEvents.pairingCount, 0);
  });

  test('incoming connection replaces a stale stored peer host', () async {
    final harness = await _HandshakeHarness.start();
    await harness.database.upsertDevice(
      _profile(
        'client-peer',
      ).device.copyWith(host: 'fe80::1c7e:5825:60ff:e377%13'),
    );

    final result = await harness.connect('observed-incoming-host');

    expect(result.isAuthenticated, isTrue);
    expect(
      (await harness.database.fetchDevice('client-peer'))?.host,
      InternetAddress.loopbackIPv4.address,
    );
    expect(
      harness.server.remoteProfileFor('client-peer')?.device.host,
      InternetAddress.loopbackIPv4.address,
    );
  });

  test('new-device pairing completes only after both peers confirm', () async {
    final receivedActions = <AuthAction>[];
    final clientEvents = _BlockingPairingEvents();
    final serverEvents = _BlockingPairingEvents();
    final harness = await _HandshakeHarness.start(
      clientEvents: clientEvents,
      serverEvents: serverEvents,
      serverAuthObserver: (_, envelope) => receivedActions.add(envelope.action),
    );
    var completed = false;
    final connecting = harness.connect('concurrent-pairing').whenComplete(() {
      completed = true;
    });

    await Future.wait(<Future<void>>[
      clientEvents.pairingStarted.future,
      serverEvents.pairingStarted.future,
    ]).timeout(const Duration(seconds: 2));

    expect(clientEvents.hasPendingDecision, isTrue);
    expect(serverEvents.hasPendingDecision, isTrue);
    expect(clientEvents.request?.mode, PairingPromptMode.initiator);
    expect(serverEvents.request?.mode, PairingPromptMode.responder);
    expect(
      clientEvents.request?.pairingCode,
      serverEvents.request?.pairingCode,
    );
    expect(await harness.database.fetchDevice('server-peer'), isNull);
    expect(await harness.database.fetchDevice('client-peer'), isNull);

    serverEvents.resolve(true);
    await pumpEventQueue();
    expect(completed, isFalse);
    expect(receivedActions, isNot(contains(AuthAction.approval)));
    expect(await harness.database.fetchDevice('server-peer'), isNull);

    clientEvents.resolve(true);
    final result = await connecting;
    await clientEvents.pairingDismissed.future.timeout(
      const Duration(seconds: 2),
    );
    expect(completed, isTrue);
    expect(clientEvents.hasPendingDecision, isFalse);
    expect(result.status, ConnectionAttemptStatus.authenticated);
    expect((await harness.database.fetchDevice('server-peer'))?.auth, isTrue);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
  });

  test(
    'initiator sends proof but withholds approval until confirmation',
    () async {
      final receivedActions = <AuthAction>[];
      final clientEvents = _BlockingPairingEvents();
      final serverEvents = _BlockingPairingEvents();
      final harness = await _HandshakeHarness.start(
        clientEvents: clientEvents,
        serverEvents: serverEvents,
        serverAuthObserver: (_, envelope) =>
            receivedActions.add(envelope.action),
      );
      final connecting = harness.connect('prompts-before-proof');

      await Future.wait(<Future<void>>[
        clientEvents.pairingStarted.future,
        serverEvents.pairingStarted.future,
      ]).timeout(const Duration(seconds: 2));

      expect(clientEvents.hasPendingDecision, isTrue);
      expect(serverEvents.hasPendingDecision, isTrue);
      expect(clientEvents.request?.mode, PairingPromptMode.initiator);
      expect(serverEvents.request?.mode, PairingPromptMode.responder);
      await _waitUntil(() => receivedActions.contains(AuthAction.proof));
      await pumpEventQueue();
      expect(receivedActions, isNot(contains(AuthAction.approval)));

      clientEvents.resolve(true);
      await _waitUntil(() => receivedActions.contains(AuthAction.approval));
      serverEvents.resolve(true);
      expect((await connecting).isAuthenticated, isTrue);
    },
  );

  test(
    'same-uid identity replacement waits for initiator confirmation',
    () async {
      final receivedActions = <AuthAction>[];
      final clientEvents = _BlockingPairingEvents();
      final serverEvents = _BlockingPairingEvents();
      final harness = await _HandshakeHarness.start(
        clientEvents: clientEvents,
        serverEvents: serverEvents,
        serverAuthObserver: (_, envelope) =>
            receivedActions.add(envelope.action),
      );
      final oldIdentity = await DeviceIdentity.fromSeed(
        Uint8List.fromList(List<int>.generate(32, (index) => index + 96)),
      );
      final actualIdentity = await DeviceIdentity.fromSeed(
        Uint8List.fromList(List<int>.generate(32, (index) => index + 1)),
      );
      final candidate = _profile('server-peer').device;
      await harness.database.upsertDevice(candidate);
      expect(
        await harness.database.pinDeviceIdentity(
          candidate.uid,
          oldIdentity.publicKeyBase64Url,
        ),
        DeviceIdentityPinResult.pinned,
      );
      await harness.database.authDevice(candidate.uid, true);

      final connecting = harness.connect('same-uid-new-key');
      await Future.wait(<Future<void>>[
        clientEvents.pairingStarted.future,
        serverEvents.pairingStarted.future,
      ]).timeout(const Duration(seconds: 2));
      expect(clientEvents.request?.reason, PairingReason.identityChanged);
      await _waitUntil(() => receivedActions.contains(AuthAction.proof));
      expect(receivedActions, isNot(contains(AuthAction.approval)));

      serverEvents.resolve(true);
      await pumpEventQueue();
      final beforeConfirmation = await harness.database.fetchDevice(
        'server-peer',
      );
      expect(
        beforeConfirmation?.identityPublicKey,
        oldIdentity.publicKeyBase64Url,
      );

      clientEvents.resolve(true);
      expect((await connecting).isAuthenticated, isTrue);
      final replaced = await harness.database.fetchDevice('server-peer');
      expect(replaced?.identityPublicKey, actualIdentity.publicKeyBase64Url);
    },
  );

  test(
    'client cancellation retracts the server prompt and persists no trust',
    () async {
      final receivedActions = <AuthAction>[];
      final clientEvents = _BlockingPairingEvents();
      final serverEvents = _BlockingPairingEvents();
      final harness = await _HandshakeHarness.start(
        clientEvents: clientEvents,
        serverEvents: serverEvents,
        serverAuthObserver: (_, envelope) =>
            receivedActions.add(envelope.action),
      );
      final connecting = harness.connect('reject-before-proof');

      await Future.wait(<Future<void>>[
        clientEvents.pairingStarted.future,
        serverEvents.pairingStarted.future,
      ]).timeout(const Duration(seconds: 2));
      await _waitUntil(() => receivedActions.contains(AuthAction.proof));
      clientEvents.resolve(false);

      final result = await connecting;
      await serverEvents.pairingDismissed.future.timeout(
        const Duration(seconds: 2),
      );
      expect(result.status, ConnectionAttemptStatus.cancelled);
      expect(result.reason, ConnectionAttemptReason.requestCancelled);
      expect(serverEvents.hasPendingDecision, isFalse);
      expect(receivedActions, contains(AuthAction.proof));
      expect(await harness.database.fetchDevice('server-peer'), isNull);
      expect(await harness.database.fetchDevice('client-peer'), isNull);
    },
  );

  test('server rejection returns an explicit peer-rejected reason', () async {
    final clientResults = <AuthEnvelope>[];
    final clientEvents = _BlockingPairingEvents();
    final serverEvents = _BlockingPairingEvents();
    final harness = await _HandshakeHarness.start(
      clientEvents: clientEvents,
      serverEvents: serverEvents,
      clientAuthObserver: (_, envelope) {
        if (envelope.action == AuthAction.result) {
          clientResults.add(envelope);
        }
      },
    );
    final connecting = harness.connect('server-rejects');
    await Future.wait(<Future<void>>[
      clientEvents.pairingStarted.future,
      serverEvents.pairingStarted.future,
    ]).timeout(const Duration(seconds: 2));

    serverEvents.resolve(false);

    final result = await connecting;
    await clientEvents.pairingDismissed.future.timeout(
      const Duration(seconds: 2),
    );
    expect(clientResults, hasLength(1));
    expect(clientResults.single.reason, 'pairing_rejected');
    expect(result.status, ConnectionAttemptStatus.rejected);
    expect(result.reason, ConnectionAttemptReason.peerRejected);
    expect(clientEvents.hasPendingDecision, isFalse);
    expect(await harness.database.fetchDevice('server-peer'), isNull);
    expect(await harness.database.fetchDevice('client-peer'), isNull);
  });

  test(
    'cancellation while pairing cannot persist or register the peer',
    () async {
      final clientEvents = _BlockingPairingEvents();
      final harness = await _HandshakeHarness.start(clientEvents: clientEvents);
      final connecting = harness.connect('challenge-cancel');
      await clientEvents.pairingStarted.future;

      final revoking = harness.client.setPeerTrust('server-peer', false);
      clientEvents.resolve(false);

      final result = await connecting;
      await revoking;
      expect(result.status, ConnectionAttemptStatus.cancelled);
      expect(result.reason, ConnectionAttemptReason.trustRevoked);
      expect(harness.client.isConnectedTo('server-peer'), isFalse);
      expect(await harness.database.fetchDevice('server-peer'), isNull);
    },
  );

  for (final mutation in <String>['revoke', 'delete']) {
    test('$mutation wins after DB commit and before registration', () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      final harness = await _HandshakeHarness.start(
        clientBarrier: (stage, peerId) async {
          if (peerId == 'server-peer' &&
              stage == ConnectionAuthCommitStage.afterPersistence) {
            if (!reached.isCompleted) reached.complete();
            await release.future;
          }
        },
      );
      final connecting = harness.connect('db-$mutation');
      await reached.future;

      final policy = mutation == 'revoke'
          ? harness.client.setPeerTrust('server-peer', false).then<void>((_) {})
          : harness.client.deletePeer('server-peer');
      release.complete();

      final result = await connecting;
      await policy;
      expect(result.status, ConnectionAttemptStatus.cancelled);
      expect(
        result.reason,
        mutation == 'delete'
            ? ConnectionAttemptReason.deviceDeleted
            : ConnectionAttemptReason.trustRevoked,
      );
      expect(harness.client.isConnectedTo('server-peer'), isFalse);
      final stored = await harness.database.fetchDevice('server-peer');
      if (mutation == 'delete') {
        expect(stored, isNull);
      } else {
        expect(stored?.auth ?? false, isFalse);
      }
    });
  }

  test(
    'inbound revoke wins after persistence and before registration',
    () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      final harness = await _HandshakeHarness.start(
        serverBarrier: (stage, peerId) async {
          if (peerId == 'client-peer' &&
              stage == ConnectionAuthCommitStage.afterPersistence) {
            if (!reached.isCompleted) reached.complete();
            await release.future;
          }
        },
      );
      final connecting = harness.connect('inbound-revoke');
      await reached.future;

      final revoking = harness.server.setPeerTrust('client-peer', false);
      release.complete();

      final result = await connecting;
      await revoking;
      expect(result.isAuthenticated, isFalse);
      expect(harness.server.isConnectedTo('client-peer'), isFalse);
      expect(await harness.database.fetchDevice('client-peer'), isNull);
    },
  );

  test(
    'manual disconnect wins after provisional registry registration',
    () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      final harness = await _HandshakeHarness.start(
        clientBarrier: (stage, peerId) async {
          if (peerId == 'server-peer' &&
              stage == ConnectionAuthCommitStage.afterRegistration) {
            if (!reached.isCompleted) reached.complete();
            await release.future;
          }
        },
      );
      final connecting = harness.connect('registry-cancel');
      await reached.future;

      final disconnecting = harness.client.disconnectPeer('server-peer');
      release.complete();

      final result = await connecting;
      await disconnecting;
      expect(result.status, ConnectionAttemptStatus.cancelled);
      expect(result.reason, ConnectionAttemptReason.manualDisconnect);
      expect(harness.client.isConnectedTo('server-peer'), isFalse);
      expect(await harness.database.fetchDevice('server-peer'), isNull);
    },
  );

  test(
    'automatic identity admission never opens an interactive pairing',
    () async {
      final harness = await _HandshakeHarness.start();
      final serverIdentity = await DeviceIdentity.fromSeed(
        Uint8List.fromList(List<int>.generate(32, (index) => index + 1)),
      );
      final result = await harness.client.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'automatic-untrusted',
          endpoint: PeerEndpoint.loopbackForTesting(port: harness.port),
          expectedPeerId: 'server-peer',
          expectedPublicKeyHash: identityPublicKeyHash(
            serverIdentity.publicKeyBase64Url,
          ),
          mode: ConnectionAttemptMode.automatic,
        ),
      );

      expect(result.status, ConnectionAttemptStatus.rejected);
      expect(result.reason, ConnectionAttemptReason.identityMismatch);
      expect(harness.clientEvents.pairingCount, 0);
      expect(harness.client.isConnectedTo('server-peer'), isFalse);
    },
  );

  test(
    'network socket loss schedules reconnect for the authenticated peer',
    () async {
      final harness = await _HandshakeHarness.start();
      final connected = await harness.connect('network-loss');
      expect(connected.isAuthenticated, isTrue);

      expect(
        await harness.server.debugDropPeerTransport('client-peer'),
        isTrue,
      );
      await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

      expect(harness.clientReconnects.activeTimerCount, 1);
      // 连接在 30s 稳定阈值内即断:视为一次连续失败,首个重连延迟升档到 2s。
      expect(harness.clientReconnects.scheduledDelays, const <Duration>[
        Duration(seconds: 2),
      ]);
    },
  );

  test(
    'scheduled reconnect completes signed auth and selects when idle',
    () async {
      final harness = await _HandshakeHarness.start();
      final connected = await harness.connect('reconnect-seed');
      expect(connected.isAuthenticated, isTrue);
      expect(
        await harness.server.debugDropPeerTransport('client-peer'),
        isTrue,
      );
      await _waitUntil(() => harness.clientReconnects.activeTimerCount == 1);

      await harness.clientReconnects.fireNext();
      await _waitUntil(() => harness.client.isConnectedTo('server-peer'));

      expect(harness.client.receiver, 'server-peer');
      expect(harness.clientReconnects.activeTimerCount, 0);
    },
  );

  test('inbound authenticated connection resets an existing retry', () async {
    final harness = await _HandshakeHarness.start();
    harness.server.scheduleReconnect('client-peer', '192.168.1.20', 10002);
    expect(harness.serverReconnects.activeTimerCount, 1);

    final connected = await harness.connect('inbound-resets-retry');

    expect(connected.isAuthenticated, isTrue);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
    expect(harness.serverReconnects.activeTimerCount, 0);
  });

  test(
    'discovery endpoint refresh survives a later profile heartbeat',
    () async {
      final harness = await _HandshakeHarness.start();
      final connected = await harness.connect('endpoint-refresh-heartbeat');
      expect(connected.isAuthenticated, isTrue);
      harness.client.selectPeer('server-peer');

      harness.client.updateReconnectEndpoint(
        'server-peer',
        '192.168.31.148',
        10002,
      );
      expect(
        harness.client.remoteProfileFor('server-peer')?.device.host,
        '192.168.31.148',
      );

      await harness.server.debugSendProfileHeartbeatTo('client-peer');
      for (var attempt = 0; attempt < 100; attempt += 1) {
        final stored = await harness.database.fetchDevice('server-peer');
        if (stored?.host == '192.168.31.148') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(
        (await harness.database.fetchDevice('server-peer'))?.host,
        '192.168.31.148',
      );
      expect(
        harness.client.remoteProfileFor('server-peer')?.device.host,
        '192.168.31.148',
      );
    },
  );

  test(
    'watchdog removal schedules reconnect for the authenticated peer',
    () async {
      final harness = await _HandshakeHarness.start();
      final connected = await harness.connect('watchdog-loss');
      expect(connected.isAuthenticated, isTrue);

      expect(
        await harness.client.debugRemovePeerForWatchdog('server-peer'),
        isTrue,
      );

      expect(harness.clientReconnects.activeTimerCount, 1);
      // 短命连接不复位退避:watchdog 摘除同样按连续失败升档到 2s。
      expect(harness.clientReconnects.scheduledDelays, const <Duration>[
        Duration(seconds: 2),
      ]);
    },
  );

  test('system sleep lets the peer go and redials it after waking', () async {
    final harness = await _HandshakeHarness.start();
    final connected = await harness.connect('sleep-seed');
    expect(connected.isAuthenticated, isTrue);

    await harness.client.prepareForSystemSleep();

    expect(harness.client.isConnectedTo('server-peer'), isFalse);
    await _waitUntil(() => !harness.server.isConnectedTo('client-peer'));
    // Redialling now would reconnect a host that is about to stop answering.
    expect(harness.clientReconnects.activeTimerCount, 0);

    harness.client.resumeFromSystemSleep();

    expect(harness.clientReconnects.activeTimerCount, 1);
    await harness.clientReconnects.fireNext();
    await _waitUntil(() => harness.client.isConnectedTo('server-peer'));
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
  });

  test('nothing connects to or from a sleeping system', () async {
    final harness = await _HandshakeHarness.start();

    await harness.server.prepareForSystemSleep();
    final refused = await harness.connect('sleeping-server');
    expect(refused.isAuthenticated, isFalse);
    expect(harness.server.isConnectedTo('client-peer'), isFalse);

    harness.server.resumeFromSystemSleep();
    await harness.client.prepareForSystemSleep();
    final cancelled = await harness.connect('sleeping-client');
    expect(cancelled.status, ConnectionAttemptStatus.cancelled);

    harness.client.resumeFromSystemSleep();
    final connected = await harness.connect('awake-again');
    expect(connected.isAuthenticated, isTrue);
  });

  test('a retry interrupted by system sleep resumes after waking', () async {
    final harness = await _HandshakeHarness.start();
    final connected = await harness.connect('sleep-retry-seed');
    expect(connected.isAuthenticated, isTrue);
    expect(await harness.server.debugDropPeerTransport('client-peer'), isTrue);
    await _waitUntil(() => harness.clientReconnects.activeTimerCount == 1);

    await harness.client.prepareForSystemSleep();
    await harness.clientReconnects.fireNext();
    expect(harness.client.isConnectedTo('server-peer'), isFalse);
    expect(harness.clientReconnects.activeTimerCount, 0);

    harness.client.resumeFromSystemSleep();

    expect(harness.clientReconnects.activeTimerCount, 1);
    await harness.clientReconnects.fireNext();
    await _waitUntil(() => harness.client.isConnectedTo('server-peer'));
  });

  for (final mutation in <String>['manual', 'delete']) {
    test('$mutation disconnect suppresses reconnect', () async {
      final harness = await _HandshakeHarness.start();
      final connected = await harness.connect('$mutation-disconnect');
      expect(connected.isAuthenticated, isTrue);

      switch (mutation) {
        case 'manual':
          await harness.client.disconnectPeer('server-peer');
          break;
        case 'revoke':
          await harness.client.setPeerTrust('server-peer', false);
          break;
        case 'delete':
          await harness.client.deletePeer('server-peer');
          break;
      }

      expect(harness.client.isConnectedTo('server-peer'), isFalse);
      expect(harness.clientReconnects.activeTimerCount, 0);
    });
  }

  test('revoking trust closes the active encrypted connection', () async {
    final harness = await _HandshakeHarness.start();
    expect(
      (await harness.connect('disable-admission')).isAuthenticated,
      isTrue,
    );

    expect(await harness.client.setPeerTrust('server-peer', false), isTrue);

    expect(harness.client.isConnectedTo('server-peer'), isFalse);
    expect((await harness.database.fetchDevice('server-peer'))?.auth, isFalse);
    expect(harness.clientReconnects.activeTimerCount, 0);
    expect(
      harness.client.reconnectSuppressionsFor('server-peer'),
      contains(ReconnectSuppressionReason.trustRevoked),
    );
  });

  test(
    'manual disconnect requires confirmation for a new inbound redial',
    () async {
      final harness = await _HandshakeHarness.start();
      final connected = await harness.connect('manual-policy-seed');
      expect(connected.isAuthenticated, isTrue);

      await harness.server.disconnectPeer('client-peer');
      await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

      final clientPairing = _BlockingPairingEvents();
      final serverPairing = _BlockingPairingEvents();
      harness.client.setEvent(clientPairing);
      harness.server.setEvent(serverPairing);
      final redial = harness.connect('manual-policy-redial');
      await Future.wait(<Future<void>>[
        clientPairing.pairingStarted.future,
        serverPairing.pairingStarted.future,
      ]).timeout(const Duration(seconds: 2));

      expect(clientPairing.request?.reason, PairingReason.newDevice);
      expect(serverPairing.request?.reason, PairingReason.newDevice);
      expect(
        clientPairing.request?.pairingCode,
        serverPairing.request?.pairingCode,
      );
      clientPairing.resolve(true);
      serverPairing.resolve(true);
      expect((await redial).isAuthenticated, isTrue);
      expect(harness.server.isConnectedTo('client-peer'), isTrue);
    },
  );

  test(
    'automatic redial cannot bypass manual disconnect confirmation',
    () async {
      final harness = await _HandshakeHarness.start();
      expect(
        (await harness.connect('manual-auto-seed')).isAuthenticated,
        isTrue,
      );
      final clientDevice = await harness.database.fetchDevice('client-peer');
      expect(clientDevice, isNotNull);
      await harness.server.disconnectPeer('client-peer');
      await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

      final result = await harness.client.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'manual-auto-redial',
          endpoint: PeerEndpoint.loopbackForTesting(port: harness.port),
          expectedPeerId: 'server-peer',
          expectedPublicKeyHash: identityPublicKeyHash(
            (await harness.database.fetchDevice(
              'server-peer',
            ))!.identityPublicKey,
          ),
          mode: ConnectionAttemptMode.automatic,
        ),
      );

      expect(result.status, ConnectionAttemptStatus.rejected);
      expect(result.reason, ConnectionAttemptReason.automaticPairingRequired);
      expect(harness.clientEvents.pairingCount, 1);
      expect(harness.serverEvents.pairingCount, 1);
    },
  );

  test('deleted peer can initiate a fresh signed re-pair', () async {
    final harness = await _HandshakeHarness.start();
    final connected = await harness.connect('delete-policy-seed');
    expect(connected.isAuthenticated, isTrue);

    await harness.server.deletePeer('client-peer');
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));
    expect(harness.server.shouldSuppressDiscoveredPeer('client-peer'), isTrue);

    final redial = await harness.connect('delete-policy-redial');

    expect(redial.isAuthenticated, isTrue);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
    expect(harness.server.shouldSuppressDiscoveredPeer('client-peer'), isFalse);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
  });

  test(
    'authenticated malformed transport closure does not schedule retry',
    () async {
      final harness = await _HandshakeHarness.start();
      final connected = await harness.connect('terminal-protocol-seed');
      expect(connected.isAuthenticated, isTrue);

      expect(
        harness.server.debugSendMalformedTransportFrame('client-peer'),
        isTrue,
      );
      await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

      expect(harness.clientReconnects.activeTimerCount, 0);
      expect(harness.clientReconnects.scheduledDelays, isEmpty);
    },
  );

  test('explicit interactive dial clears manual inbound suppression', () async {
    final harness = await _HandshakeHarness.start();
    expect(
      (await harness.connect('manual-clear-seed')).isAuthenticated,
      isTrue,
    );
    await harness.server.disconnectPeer('client-peer');
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

    final repaired = await harness.connectBack('manual-clear-explicit');

    expect(repaired.isAuthenticated, isTrue);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
  });

  test('client-only trust revoke shows matching codes on both peers', () async {
    final harness = await _HandshakeHarness.start();
    expect(
      (await harness.connect('trust-repair-seed')).isAuthenticated,
      isTrue,
    );
    await harness.client.setPeerTrust('server-peer', false);
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));
    expect((await harness.database.fetchDevice('server-peer'))?.auth, isFalse);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
    expect(harness.clientReconnects.activeTimerCount, 0);
    expect(harness.serverReconnects.activeTimerCount, 0);
    expect(
      harness.client.reconnectSuppressionsFor('server-peer'),
      contains(ReconnectSuppressionReason.trustRevoked),
    );

    final clientPairing = _BlockingPairingEvents();
    final serverPairing = _BlockingPairingEvents();
    harness.client.setEvent(clientPairing);
    harness.server.setEvent(serverPairing);
    final repairing = harness.connect('trust-repair-explicit');
    var repairCompleted = false;
    unawaited(repairing.then<void>((_) => repairCompleted = true));
    await Future.wait(<Future<void>>[
      clientPairing.pairingStarted.future,
      serverPairing.pairingStarted.future,
    ]).timeout(const Duration(seconds: 2));

    expect(clientPairing.request?.reason, PairingReason.newDevice);
    expect(clientPairing.request?.mode, PairingPromptMode.initiator);
    expect(serverPairing.request?.reason, PairingReason.newDevice);
    expect(serverPairing.request?.mode, PairingPromptMode.responder);
    expect(
      clientPairing.request?.pairingCode,
      serverPairing.request?.pairingCode,
    );
    expect((await harness.database.fetchDevice('server-peer'))?.auth, isFalse);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
    await pumpEventQueue();
    expect(repairCompleted, isFalse);

    clientPairing.resolve(true);
    serverPairing.resolve(true);
    final repaired = await repairing;
    await clientPairing.pairingDismissed.future.timeout(
      const Duration(seconds: 2),
    );

    expect(repaired.isAuthenticated, isTrue);
    expect((await harness.database.fetchDevice('server-peer'))?.auth, isTrue);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
    expect(
      harness.client.reconnectSuppressionsFor('server-peer'),
      isNot(contains(ReconnectSuppressionReason.trustRevoked)),
    );
  });

  test('trust-revoked inbound admission prompts the responder', () async {
    final harness = await _HandshakeHarness.start();
    expect(
      (await harness.connect('trust-inbound-seed')).isAuthenticated,
      isTrue,
    );
    await harness.server.setPeerTrust('client-peer', false);
    expect(harness.server.isConnectedTo('client-peer'), isFalse);
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

    final clientPairing = _BlockingPairingEvents();
    final serverPairing = _BlockingPairingEvents();
    harness.client.setEvent(clientPairing);
    harness.server.setEvent(serverPairing);
    final redial = harness.connect('trust-inbound-explicit');
    var redialCompleted = false;
    unawaited(redial.then<void>((_) => redialCompleted = true));
    await Future.wait(<Future<void>>[
      clientPairing.pairingStarted.future,
      serverPairing.pairingStarted.future,
    ]).timeout(const Duration(seconds: 2));

    expect(clientPairing.request?.reason, PairingReason.newDevice);
    expect(clientPairing.request?.mode, PairingPromptMode.initiator);
    expect(serverPairing.request?.reason, PairingReason.newDevice);
    expect(serverPairing.request?.mode, PairingPromptMode.responder);
    expect(
      clientPairing.request?.pairingCode,
      serverPairing.request?.pairingCode,
    );
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isFalse);
    await pumpEventQueue();
    expect(redialCompleted, isFalse);
    clientPairing.resolve(true);
    serverPairing.resolve(true);
    final result = await redial;

    expect(result.isAuthenticated, isTrue);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
  });

  test(
    'successful explicit re-pair clears deleted inbound suppression',
    () async {
      final harness = await _HandshakeHarness.start();
      expect(
        (await harness.connect('delete-clear-seed')).isAuthenticated,
        isTrue,
      );
      await harness.server.deletePeer('client-peer');
      await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

      final repaired = await harness.connectBack('delete-clear-explicit');
      expect(repaired.isAuthenticated, isTrue);
      expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
      expect(
        await harness.server.debugDropPeerTransport('client-peer'),
        isTrue,
      );
      await _waitUntil(() => !harness.server.isConnectedTo('client-peer'));

      final redial = await harness.connect('delete-clear-redial');
      expect(redial.isAuthenticated, isTrue);
    },
  );

  test(
    'failed explicit re-pair does not permanently suppress inbound pairing',
    () async {
      final harness = await _HandshakeHarness.start();
      expect(
        (await harness.connect('delete-failed-seed')).isAuthenticated,
        isTrue,
      );
      await harness.server.deletePeer('client-peer');
      await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

      final failedRepair = await harness.server.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'delete-failed-explicit',
          endpoint: PeerEndpoint.loopbackForTesting(port: harness.port),
          expectedPeerId: 'client-peer',
          mode: ConnectionAttemptMode.interactive,
        ),
      );
      expect(failedRepair.isAuthenticated, isFalse);

      final redial = await harness.connect('delete-failed-redial');
      expect(redial.isAuthenticated, isTrue);
      expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
    },
  );

  test('superseded connection does not schedule reconnect', () async {
    final harness = await _HandshakeHarness.start();
    final first = await harness.connect('superseded-first');
    final second = await harness.connect('superseded-second');

    expect(first.isAuthenticated, isTrue);
    expect(second.isAuthenticated, isTrue);
    expect(second.generation, isNot(first.generation));
    expect(
      harness.client.isCurrentConnectionGeneration(
        second.peerId,
        second.generation,
      ),
      isTrue,
    );
    expect(harness.clientReconnects.activeTimerCount, 0);
    expect(harness.clientReconnects.scheduledDelays, isEmpty);
  });

  test(
    'profile refresh keeps peers isolated and updates display topology',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      var displaysA = 1;
      var displaysB = 2;
      Completer<void>? profileGateA;
      final refreshRequestedA = Completer<void>();
      final peerA = WsSvrManager.forTesting(
        database: database,
        identityStore: _identityStore(1),
        localPeerProfileLoader: () async {
          if (profileGateA != null) {
            if (!refreshRequestedA.isCompleted) {
              refreshRequestedA.complete();
            }
            await profileGateA.future;
          }
          return _profile('peer-a', displayCount: displaysA);
        },
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
      );
      final peerB = WsSvrManager.forTesting(
        database: database,
        identityStore: _identityStore(33),
        localPeerProfileLoader: () async =>
            _profile('peer-b', displayCount: displaysB),
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
      );
      final hub = WsSvrManager.forTesting(
        database: database,
        identityStore: _identityStore(65),
        localPeerProfileLoader: () async => _profile('hub-peer'),
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
      );
      peerA.setEvent(_ApprovingEvents());
      peerB.setEvent(_ApprovingEvents());
      hub.setEvent(_ApprovingEvents());
      addTearDown(
        () => hub.closeGracefully(closeServer: true, forceServerClose: true),
      );
      addTearDown(
        () => peerB.closeGracefully(closeServer: true, forceServerClose: true),
      );
      addTearDown(
        () => peerA.closeGracefully(closeServer: true, forceServerClose: true),
      );
      final startedA = await peerA.startServer(0);
      final startedB = await peerB.startServer(0);
      expect(startedA.isSuccess, isTrue);
      expect(startedB.isSuccess, isTrue);

      final connectedA = await hub.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'profile-peer-a',
          endpoint: PeerEndpoint.loopbackForTesting(port: startedA.port),
          expectedPeerId: 'peer-a',
          mode: ConnectionAttemptMode.interactive,
        ),
      );
      expect(connectedA.isAuthenticated, isTrue);
      hub.selectPeer('peer-a');
      final selectedWaiter = hub.debugWaitForSelectedProfileUpdate();
      var waiterCompleted = false;
      unawaited(selectedWaiter.then<void>((_) => waiterCompleted = true));

      final connectedB = await hub.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'profile-peer-b',
          endpoint: PeerEndpoint.loopbackForTesting(port: startedB.port),
          expectedPeerId: 'peer-b',
          mode: ConnectionAttemptMode.interactive,
        ),
      );
      expect(connectedB.isAuthenticated, isTrue);
      await pumpEventQueue();
      expect(hub.receiver, 'peer-a');
      expect(hub.remoteProfileFor('peer-b')?.device.uid, 'peer-b');
      expect(waiterCompleted, isFalse);

      await peerA.debugSendProfileHeartbeatTo('hub-peer');
      final refreshed = await selectedWaiter.timeout(
        const Duration(seconds: 2),
      );
      expect(refreshed?.device.uid, 'peer-a');
      expect(hub.remoteDisplayTopologyFor('peer-a')?.displays.length, 1);
      expect(hub.remoteDisplayTopologyFor('peer-b')?.displays.length, 2);

      displaysA = 2;
      displaysB = 1;
      profileGateA = Completer<void>();
      addTearDown(() {
        if (!profileGateA!.isCompleted) profileGateA.complete();
      });
      var refreshACompleted = false;
      final refreshA = hub
          .requestRemoteProfileRefresh(
            peerId: 'peer-a',
            timeout: const Duration(seconds: 3),
          )
          .whenComplete(() => refreshACompleted = true);
      await refreshRequestedA.future.timeout(const Duration(seconds: 2));
      final refreshB = await hub.requestRemoteProfileRefresh(peerId: 'peer-b');
      expect(refreshB?.displayTopology?.displays.length, 1);
      expect(refreshACompleted, isFalse);
      expect(hub.remoteDisplayTopologyFor('peer-a')?.displays.length, 1);
      expect(hub.receiver, 'peer-a');

      profileGateA.complete();
      expect((await refreshA)?.displayTopology?.displays.length, 2);
      expect(
        hub.isCurrentConnectionGeneration('peer-a', connectedA.generation),
        isTrue,
      );
      expect(
        hub.isCurrentConnectionGeneration('peer-b', connectedB.generation),
        isTrue,
      );

      profileGateA = Completer<void>();
      final timedOut = await hub.requestRemoteProfileRefresh(
        peerId: 'peer-a',
        timeout: const Duration(milliseconds: 30),
      );
      expect(timedOut?.device.uid, 'peer-a');
      expect(timedOut?.displayTopology?.displays.length, 2);
      profileGateA.complete();
    },
  );

  test(
    'F22 & F31: closeGracefully cleans up peer subsystems and disconnectPeer '
    'only drops the failing peer',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final hub = WsSvrManager.forTesting(
        database: database,
        identityStore: _identityStore(1),
        localPeerProfileLoader: () async => _profile('hub-peer'),
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
      );
      final peerA = WsSvrManager.forTesting(
        database: database,
        identityStore: _identityStore(40),
        localPeerProfileLoader: () async => _profile('peer-a'),
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
      );
      final peerB = WsSvrManager.forTesting(
        database: database,
        identityStore: _identityStore(80),
        localPeerProfileLoader: () async => _profile('peer-b'),
        autoConnectEnabled: () async => true,
        manageSharedCoordinators: false,
      );
      hub.setEvent(_ApprovingEvents());
      peerA.setEvent(_ApprovingEvents());
      peerB.setEvent(_ApprovingEvents());
      addTearDown(
        () => peerB.closeGracefully(closeServer: true, forceServerClose: true),
      );
      addTearDown(
        () => peerA.closeGracefully(closeServer: true, forceServerClose: true),
      );
      addTearDown(
        () => hub.closeGracefully(closeServer: true, forceServerClose: true),
      );
      final started = await hub.startServer(0);
      expect(started.isSuccess, isTrue);

      final resA = await peerA.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'connect-a',
          endpoint: PeerEndpoint.loopbackForTesting(port: started.port),
          expectedPeerId: 'hub-peer',
          mode: ConnectionAttemptMode.interactive,
        ),
      );
      final resB = await peerB.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'connect-b',
          endpoint: PeerEndpoint.loopbackForTesting(port: started.port),
          expectedPeerId: 'hub-peer',
          mode: ConnectionAttemptMode.interactive,
        ),
      );
      expect(resA.isAuthenticated, isTrue);
      expect(resB.isAuthenticated, isTrue);
      expect(hub.isConnectedTo('peer-a'), isTrue);
      expect(hub.isConnectedTo('peer-b'), isTrue);

      // F31: disconnecting peer-a leaves peer-b connected.
      await hub.disconnectPeer('peer-a');
      expect(hub.isConnectedTo('peer-a'), isFalse);
      expect(hub.isConnectedTo('peer-b'), isTrue);

      // F22: closeGracefully cleans up FileBrowseHost, TransferPlacements,
      // WindowStreamViewer, and RemoteFilesClient for connected peers.
      const browseSessionId = '5a4f1f0e-1c2b-4d3e-8f9a-0b1c2d3e4f99';
      await FileBrowseHost.shared.permissions.setAlways('peer-b', true);
      await FileBrowseHost.shared.handle(
        const FileBrowseMessage(
          action: FileBrowseAction.open,
          sessionId: browseSessionId,
          clientPeerId: 'peer-b',
          hostPeerId: 'hub-peer',
        ),
        remotePeerId: 'peer-b',
        deviceName: 'Peer B',
      );
      expect(FileBrowseHost.shared.isOpen(browseSessionId), isTrue);
      TransferPlacements.shared.expect(
        'f22-placement',
        Directory.systemTemp.path,
        peerId: 'peer-b',
        fromRemote: true,
      );
      WindowStreamViewer.shared.peerConnected(
        const WindowStreamPeer(
          peerId: 'peer-b',
          name: 'Peer B',
          platform: WindowStreamPlatform.macos,
          takesWindows: true,
        ),
      );
      WindowStreamViewer.shared.peerAvailable(
        peerId: 'peer-b',
        name: 'Peer B',
        platform: WindowStreamPlatform.macos,
        host: '127.0.0.1',
        port: 10002,
      );
      expect(WindowStreamViewer.shared.isConnected('peer-b'), isTrue);
      expect(WindowStreamViewer.shared.sourceFor('peer-b'), isNotNull);
      final client = RemoteFilesClient('peer-b');
      RemoteFilesClient.sender = (_, _) async => true;
      final pendingOpen = client.open();
      final openFailed = expectLater(
        pendingOpen,
        throwsA(isA<RemoteFsException>()),
      );

      await hub.closeGracefully();

      expect(FileBrowseHost.shared.isOpen(browseSessionId), isFalse);
      expect(TransferPlacements.shared.isExpected('f22-placement'), isFalse);
      expect(WindowStreamViewer.shared.isConnected('peer-b'), isFalse);
      expect(WindowStreamViewer.shared.sourceFor('peer-b'), isNull);
      await openFailed;
    },
  );

  test('F7: manual IP dial without expectedPeerId joins simultaneous-dial '
      'tie-break and cancels the losing outgoing attempt', () async {
    final serverDb = LocalDatabase.forTesting(NativeDatabase.memory());
    final clientDb = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(serverDb.close);
    addTearDown(clientDb.close);
    final serverKey = await _publicKey(10);
    final clientKey = await _publicKey(60);
    // Pre-trust both sides so handshake completes without manual prompt.
    await _trust(serverDb, 'aaa-peer', clientKey);
    await _trust(clientDb, 'zzz-peer', serverKey);

    final server = WsSvrManager.forTesting(
      database: serverDb,
      identityStore: _identityStore(10),
      localPeerProfileLoader: () async => _profile('zzz-peer'),
      autoConnectEnabled: () async => true,
      manageSharedCoordinators: false,
    );
    final client = WsSvrManager.forTesting(
      database: clientDb,
      identityStore: _identityStore(60),
      localPeerProfileLoader: () async => _profile('aaa-peer'),
      autoConnectEnabled: () async => true,
      manageSharedCoordinators: false,
    );
    server.setEvent(_ApprovingEvents());
    client.setEvent(_ApprovingEvents());
    addTearDown(
      () => client.closeGracefully(closeServer: true, forceServerClose: true),
    );
    addTearDown(
      () => server.closeGracefully(closeServer: true, forceServerClose: true),
    );
    final serverStarted = await server.startServer(0);
    final clientStarted = await client.startServer(0);
    expect(serverStarted.isSuccess, isTrue);
    expect(clientStarted.isSuccess, isTrue);

    // zzz-peer (larger uid -> losing side) dials aaa-peer manually by IP
    // (expectedPeerId is empty) while aaa-peer dials zzz-peer at the same
    // time.
    final results = await Future.wait(<Future<ConnectionAttemptResult>>[
      server.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'manual-ip-dial',
          endpoint: PeerEndpoint.loopbackForTesting(port: clientStarted.port),
          expectedPeerId: '',
          mode: ConnectionAttemptMode.interactive,
        ),
      ),
      client.connectToServer(
        ConnectionAttemptRequest(
          requestId: 'peer-dial',
          endpoint: PeerEndpoint.loopbackForTesting(port: serverStarted.port),
          expectedPeerId: 'zzz-peer',
          mode: ConnectionAttemptMode.interactive,
        ),
      ),
    ]).timeout(const Duration(seconds: 5));

    // aaa-peer < zzz-peer: aaa-peer's outgoing wins; zzz-peer's manual IP dial
    // loses and is cancelled instead of creating a duplicate link.
    expect(results[1].isAuthenticated, isTrue);
    expect(results[0].isAuthenticated, isFalse);
    expect(server.isConnectedTo('aaa-peer'), isTrue);
    expect(client.isConnectedTo('zzz-peer'), isTrue);
  });

  // Regression: an outgoing dial still stuck before WebSocket upgrade
  // (e.g. reconnecting to a stale IP) must not win simultaneous-dial
  // tie-breaking and kill a working incoming connection from that peer.
  test('F7: unready outgoing dial is cancelled instead of killing a working '
      'incoming connection', () async {
    final aaaDb = LocalDatabase.forTesting(NativeDatabase.memory());
    final zzzDb = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(aaaDb.close);
    addTearDown(zzzDb.close);
    final aaaKey = await _publicKey(61);
    final zzzKey = await _publicKey(11);
    await _trust(aaaDb, 'zzz-peer', zzzKey);
    await _trust(zzzDb, 'aaa-peer', aaaKey);

    final aaa = WsSvrManager.forTesting(
      database: aaaDb,
      identityStore: _identityStore(61),
      localPeerProfileLoader: () async => _profile('aaa-peer'),
      autoConnectEnabled: () async => true,
      manageSharedCoordinators: false,
    );
    final zzz = WsSvrManager.forTesting(
      database: zzzDb,
      identityStore: _identityStore(11),
      localPeerProfileLoader: () async => _profile('zzz-peer'),
      autoConnectEnabled: () async => true,
      manageSharedCoordinators: false,
    );
    aaa.setEvent(_ApprovingEvents());
    zzz.setEvent(_ApprovingEvents());
    addTearDown(
      () => aaa.closeGracefully(closeServer: true, forceServerClose: true),
    );
    addTearDown(
      () => zzz.closeGracefully(closeServer: true, forceServerClose: true),
    );
    final aaaStarted = await aaa.startServer(0);
    expect(aaaStarted.isSuccess, isTrue);

    // Silent TCP listener that never answers the HTTP upgrade, keeping
    // aaa-peer's outgoing attempt unready (attempt.isReady == false).
    final blackhole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final acceptedSockets = <Socket>[];
    final blackholeAccepted = Completer<void>();
    blackhole.listen((socket) {
      acceptedSockets.add(socket);
      if (!blackholeAccepted.isCompleted) {
        blackholeAccepted.complete();
      }
    });
    addTearDown(() async {
      for (final socket in acceptedSockets) {
        socket.destroy();
      }
      await blackhole.close();
    });

    // aaa-peer (smaller uid) starts dialing zzz-peer at the stale/silent port.
    final stuckOutgoing = aaa.connectToServer(
      ConnectionAttemptRequest(
        requestId: 'stale-outgoing-dial',
        endpoint: PeerEndpoint.loopbackForTesting(port: blackhole.port),
        expectedPeerId: 'zzz-peer',
        mode: ConnectionAttemptMode.interactive,
      ),
    );
    await blackholeAccepted.future.timeout(const Duration(seconds: 2));

    // zzz-peer (larger uid) dials into aaa-peer's live server. Even though
    // aaa-peer < zzz-peer, aaa-peer's outgoing dial is not ready yet, so it
    // must be cancelled and zzz-peer's working incoming connection accepted.
    final incomingResult = await zzz
        .connectToServer(
          ConnectionAttemptRequest(
            requestId: 'working-incoming-dial',
            endpoint: PeerEndpoint.loopbackForTesting(port: aaaStarted.port),
            expectedPeerId: 'aaa-peer',
            mode: ConnectionAttemptMode.interactive,
          ),
        )
        .timeout(const Duration(seconds: 5));
    final outgoingResult = await stuckOutgoing.timeout(
      const Duration(seconds: 3),
    );

    expect(incomingResult.isAuthenticated, isTrue);
    expect(outgoingResult.status, ConnectionAttemptStatus.cancelled);
    expect(outgoingResult.reason, ConnectionAttemptReason.superseded);
    expect(aaa.isConnectedTo('zzz-peer'), isTrue);
    expect(zzz.isConnectedTo('aaa-peer'), isTrue);
  });
}

final class _UpgradeRequiredServer {
  _UpgradeRequiredServer._(
    this._server,
    this.version,
    this.minVersion,
    this.maxVersion,
  );

  final HttpServer _server;
  final int version;
  final int? minVersion;
  final int? maxVersion;
  final Set<WebSocket> _sockets = <WebSocket>{};
  int acceptedConnections = 0;

  int get port => _server.port;

  static Future<_UpgradeRequiredServer> start({
    required int version,
    int? minVersion,
    int? maxVersion,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = _UpgradeRequiredServer._(
      server,
      version,
      minVersion,
      maxVersion,
    );
    server.listen(stub._handleRequest);
    return stub;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final downstream = await WebSocketTransformer.upgrade(request);
    _sockets.add(downstream);
    acceptedConnections += 1;
    await downstream.first;
    downstream.add(
      _upgradeRequiredFrame(
        version: version,
        minVersion: minVersion,
        maxVersion: maxVersion,
      ),
    );
    await downstream.close();
    _sockets.remove(downstream);
  }

  Future<void> close() async {
    await Future.wait(_sockets.map((socket) => socket.close()));
    await _server.close(force: true);
  }
}

Uint8List _upgradeRequiredFrame({
  required int version,
  int? minVersion,
  int? maxVersion,
}) => _authFrame(
  'server-peer',
  jsonEncode(<String, Object?>{
    'action': 'upgrade_required',
    'version': version,
    if (minVersion != null) 'minVersion': minVersion,
    if (maxVersion != null) 'maxVersion': maxVersion,
  }),
);

Uint8List _authFrame(String sender, String content) => WhisperFrameV3(
  type: WhisperFrameType.message,
  transferId: '',
  offset: 0,
  sequence: 0,
  payload: Uint8List.fromList(
    utf8.encode(
      encodeWireMessage(
        MessageData(
          id: 0,
          sender: sender,
          receiver: '',
          name: '',
          clipboard: false,
          size: 0,
          type: MessageEnum.Auth,
          content: content,
          message: '',
          timestamp: 0,
          uuid: 'raw-auth-$sender',
          acked: false,
          path: '',
          md5: '',
          fileTimestamp: 0,
        ),
      ),
    ),
  ),
).encode();

final class _HandshakeHarness {
  const _HandshakeHarness({
    required this.database,
    required this.server,
    required this.client,
    required this.port,
    required this.serverEvents,
    required this.clientEvents,
    required this.clientReconnects,
    required this.serverReconnects,
  });

  final LocalDatabase database;
  final WsSvrManager server;
  final WsSvrManager client;
  final int port;
  final _ApprovingEvents serverEvents;
  final _ApprovingEvents clientEvents;
  final _ReconnectRecorder clientReconnects;
  final _ReconnectRecorder serverReconnects;

  static Future<_HandshakeHarness> start({
    _ApprovingEvents? clientEvents,
    _ApprovingEvents? serverEvents,
    ConnectionAuthCommitBarrier? clientBarrier,
    ConnectionAuthCommitBarrier? serverBarrier,
    AuthEnvelopeObserver? clientAuthObserver,
    AuthEnvelopeObserver? serverAuthObserver,
  }) async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final resolvedServerEvents = serverEvents ?? _ApprovingEvents();
    final resolvedClientEvents = clientEvents ?? _ApprovingEvents();
    final clientReconnects = _ReconnectRecorder();
    final serverReconnects = _ReconnectRecorder();
    final server = WsSvrManager.forTesting(
      database: database,
      identityStore: _identityStore(1),
      localPeerProfileLoader: () async => _profile('server-peer'),
      autoConnectEnabled: () async => true,
      reconnectControllerFactory: serverReconnects.create,
      manageSharedCoordinators: false,
      authCommitBarrier: serverBarrier,
      authEnvelopeObserver: serverAuthObserver,
    );
    final client = WsSvrManager.forTesting(
      database: database,
      identityStore: _identityStore(33),
      localPeerProfileLoader: () async => _profile('client-peer'),
      autoConnectEnabled: () async => true,
      reconnectControllerFactory: clientReconnects.create,
      manageSharedCoordinators: false,
      authCommitBarrier: clientBarrier,
      authEnvelopeObserver: clientAuthObserver,
    );
    server.setEvent(resolvedServerEvents);
    client.setEvent(resolvedClientEvents);
    addTearDown(
      () => client.closeGracefully(closeServer: true, forceServerClose: true),
    );
    addTearDown(
      () => server.closeGracefully(closeServer: true, forceServerClose: true),
    );
    final started = await server.startServer(0);
    expect(started.isSuccess, isTrue);
    return _HandshakeHarness(
      database: database,
      server: server,
      client: client,
      port: started.port,
      serverEvents: resolvedServerEvents,
      clientEvents: resolvedClientEvents,
      clientReconnects: clientReconnects,
      serverReconnects: serverReconnects,
    );
  }

  Future<ConnectionAttemptResult> connect(String requestId) => client
      .connectToServer(
        ConnectionAttemptRequest(
          requestId: requestId,
          endpoint: PeerEndpoint.loopbackForTesting(port: port),
          expectedPeerId: 'server-peer',
          mode: ConnectionAttemptMode.interactive,
        ),
      )
      .timeout(const Duration(seconds: 5));

  Future<ConnectionAttemptResult> connectVia(
    int proxyPort, {
    String publicKeyHash = '',
  }) => client
      .connectToServer(
        ConnectionAttemptRequest(
          requestId: 'legacy-via-$proxyPort',
          endpoint: PeerEndpoint.loopbackForTesting(port: proxyPort),
          expectedPeerId: 'server-peer',
          expectedPublicKeyHash: publicKeyHash,
          mode: ConnectionAttemptMode.interactive,
        ),
      )
      .timeout(const Duration(seconds: 5));

  Future<ConnectionAttemptResult> connectBack(String requestId) async {
    final started = await client.startServer(0);
    expect(started.isSuccess, isTrue);
    return server
        .connectToServer(
          ConnectionAttemptRequest(
            requestId: requestId,
            endpoint: PeerEndpoint.loopbackForTesting(port: started.port),
            expectedPeerId: 'client-peer',
            mode: ConnectionAttemptMode.interactive,
          ),
        )
        .timeout(const Duration(seconds: 5));
  }
}

Future<String> _publicKey(int seedStart) async =>
    (await _identityStore(seedStart).loadOrCreate()).publicKeyBase64Url;

/// A device paired earlier: trusted, with its identity key pinned.
Future<void> _trust(LocalDatabase database, String uid, String key) async {
  await database.upsertDevice(_profile(uid).device);
  await database.pinDeviceIdentity(uid, key);
  await database.authDevice(uid, true);
}

DeviceIdentityStore _identityStore(int seedStart) => DeviceIdentityStore(
  storage: _SeedStorage(
    Uint8List.fromList(List<int>.generate(32, (index) => seedStart + index)),
  ),
);

PeerProfile _profile(String uid, {int displayCount = 0}) => PeerProfile(
  device: DeviceData(
    id: 0,
    uid: uid,
    name: uid,
    host: '192.168.1.10',
    port: 10002,
    password: '',
    platform: 'test',
    isServer: true,
    online: true,
    clipboard: true,
    auth: false,
    lastTime: 1,
    around: true,
  ),
  trustedPeerIds: const <String>[],
  autoApproveNewDevices: false,
  autoConnectEnabled: true,
  protocolVersion: PeerSocketSession.protocolVersion,
  capabilities: PeerCapabilities(
    fileTransferV3: true,
    systemAudioSourceV1: false,
    speakerSinkV1: false,
    remoteInputSourceV1: displayCount > 0,
    remoteInputSinkV1: displayCount > 0,
    remoteInputTopologyV1: displayCount > 0,
    audioGroupSourceV1: false,
    audioGroupSinkV1: false,
    audioGroupRejoinV1: false,
    audioSyncClockV1: false,
    audioChannelRoleV1: false,
  ),
  displayTopology: displayCount == 0
      ? null
      : RemoteInputTopology(
          platform: 'test',
          updatedAt: 1,
          displays: List.generate(
            displayCount,
            (index) => RemoteInputDisplay(
              displayId: '$uid-$index',
              name: 'Display $index',
              x: index * 1920,
              y: 0,
              width: 1920,
              height: 1080,
              scale: 1,
              isPrimary: index == 0,
            ),
          ),
        ),
);

final class _SeedStorage implements DeviceIdentitySeedStorage {
  _SeedStorage(this.seed);

  final Uint8List seed;

  @override
  Future<String?> readSeed() async =>
      base64Url.encode(seed).replaceAll('=', '');

  @override
  Future<void> writeSeed(String value) async {}
}

class _ApprovingEvents implements ISocketEvent {
  int afterAuthCount = 0;
  int pairingCount = 0;

  @override
  void afterAuth(bool allow, DeviceData? device) {
    if (allow) afterAuthCount += 1;
  }

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) {
    pairingCount += 1;
    resolve(true);
  }

  @override
  void onClose() {}

  @override
  void onConnect() {}

  @override
  void onError(String message, {String? peerId}) {}

  @override
  void onMessage(MessageData messageData) {}

  @override
  void onNotice(String message) {}

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {}
}

final class _BlockingPairingEvents extends _ApprovingEvents {
  final Completer<void> pairingStarted = Completer<void>();
  final Completer<void> pairingDismissed = Completer<void>();
  void Function(bool)? _pendingResolve;
  PairingRequest? request;

  bool get hasPendingDecision => _pendingResolve != null;

  @override
  void onPairing(PairingRequest request, void Function(bool) resolve) {
    pairingCount += 1;
    this.request = request;
    _pendingResolve = resolve;
    final cancellation = request.cancellation;
    if (cancellation != null) {
      unawaited(
        cancellation.then((_) {
          _pendingResolve = null;
          if (!pairingDismissed.isCompleted) pairingDismissed.complete();
        }),
      );
    }
    if (!pairingStarted.isCompleted) pairingStarted.complete();
  }

  void resolve(bool allow) {
    final callback = _pendingResolve;
    _pendingResolve = null;
    callback?.call(allow);
  }
}

final class _ReconnectRecorder {
  final List<_HeldTimer> _timers = <_HeldTimer>[];
  final List<Duration> scheduledDelays = <Duration>[];

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;

  Future<void> fireNext() async {
    final timer = _timers.firstWhere((candidate) => candidate.isActive);
    timer.fire();
    await pumpEventQueue();
  }

  PeerReconnectController create({
    required ReconnectAttempt attempt,
    required ReconnectEligibility eligibility,
  }) {
    return PeerReconnectController(
      attempt: attempt,
      eligibility: eligibility,
      timerFactory: (delay, callback) {
        scheduledDelays.add(delay);
        final timer = _HeldTimer(callback);
        _timers.add(timer);
        return timer;
      },
      randomDouble: () => 0.5,
    );
  }
}

final class _HeldTimer implements Timer {
  _HeldTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException('condition was not reached');
}
