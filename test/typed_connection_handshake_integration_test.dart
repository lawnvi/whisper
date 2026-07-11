import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';

void main() {
  test('typed success waits for signed persistence and current registration',
      () async {
    final harness = await _HandshakeHarness.start();
    final result = await harness.connect('signed-success');

    expect(result.status, ConnectionAttemptStatus.authenticated);
    expect(result.peerId, 'server-peer');
    expect(result.generation, greaterThan(0));
    expect(
      harness.client
          .isCurrentConnectionGeneration(result.peerId, result.generation),
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
  });

  test('server confirmation completes while the initiator remains read-only',
      () async {
    final clientEvents = _BlockingPairingEvents();
    final serverEvents = _BlockingPairingEvents();
    final harness = await _HandshakeHarness.start(
      clientEvents: clientEvents,
      serverEvents: serverEvents,
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
        clientEvents.request?.pairingCode, serverEvents.request?.pairingCode);
    expect(await harness.database.fetchDevice('server-peer'), isNull);
    expect(await harness.database.fetchDevice('client-peer'), isNull);

    serverEvents.resolve(true);
    final result = await connecting;
    await clientEvents.pairingDismissed.future
        .timeout(const Duration(seconds: 2));
    expect(completed, isTrue);
    expect(clientEvents.hasPendingDecision, isFalse);
    expect(result.status, ConnectionAttemptStatus.authenticated);
    expect((await harness.database.fetchDevice('server-peer'))?.auth, isTrue);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
  });

  test('initiator sends proof and approval without a dialog decision',
      () async {
    final receivedActions = <AuthAction>[];
    final clientEvents = _BlockingPairingEvents();
    final serverEvents = _BlockingPairingEvents();
    final harness = await _HandshakeHarness.start(
      clientEvents: clientEvents,
      serverEvents: serverEvents,
      serverAuthObserver: (_, envelope) => receivedActions.add(envelope.action),
    );
    final connecting = harness.connect('prompts-before-proof');
    addTearDown(() async {
      clientEvents.resolve(false);
      serverEvents.resolve(false);
      await connecting;
    });

    await Future.wait(<Future<void>>[
      clientEvents.pairingStarted.future,
      serverEvents.pairingStarted.future,
    ]).timeout(const Duration(seconds: 2));

    expect(clientEvents.hasPendingDecision, isTrue);
    expect(serverEvents.hasPendingDecision, isTrue);
    expect(clientEvents.request?.mode, PairingPromptMode.initiator);
    expect(serverEvents.request?.mode, PairingPromptMode.responder);
    await _waitUntil(
      () =>
          receivedActions.contains(AuthAction.proof) &&
          receivedActions.contains(AuthAction.approval),
    );
  });

  test('client cancellation retracts the server prompt and persists no trust',
      () async {
    final receivedActions = <AuthAction>[];
    final clientEvents = _BlockingPairingEvents();
    final serverEvents = _BlockingPairingEvents();
    final harness = await _HandshakeHarness.start(
      clientEvents: clientEvents,
      serverEvents: serverEvents,
      serverAuthObserver: (_, envelope) => receivedActions.add(envelope.action),
    );
    final connecting = harness.connect('reject-before-proof');

    await Future.wait(<Future<void>>[
      clientEvents.pairingStarted.future,
      serverEvents.pairingStarted.future,
    ]).timeout(const Duration(seconds: 2));
    await _waitUntil(() => receivedActions.contains(AuthAction.proof));
    clientEvents.resolve(false);

    final result = await connecting;
    await serverEvents.pairingDismissed.future
        .timeout(const Duration(seconds: 2));
    expect(result.status, ConnectionAttemptStatus.cancelled);
    expect(result.reason, ConnectionAttemptReason.requestCancelled);
    expect(serverEvents.hasPendingDecision, isFalse);
    expect(receivedActions, contains(AuthAction.proof));
    expect(await harness.database.fetchDevice('server-peer'), isNull);
    expect(await harness.database.fetchDevice('client-peer'), isNull);
  });

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
    await clientEvents.pairingDismissed.future
        .timeout(const Duration(seconds: 2));
    expect(clientResults, hasLength(1));
    expect(clientResults.single.reason, 'pairing_rejected');
    expect(result.status, ConnectionAttemptStatus.rejected);
    expect(result.reason, ConnectionAttemptReason.peerRejected);
    expect(clientEvents.hasPendingDecision, isFalse);
    expect(await harness.database.fetchDevice('server-peer'), isNull);
    expect(await harness.database.fetchDevice('client-peer'), isNull);
  });

  test('cancellation while pairing cannot persist or register the peer',
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
  });

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

  test('inbound revoke wins after persistence and before registration',
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
  });

  test('manual disconnect wins after provisional registry registration',
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
  });

  test('automatic identity admission never opens an interactive pairing',
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
        expectedPublicKeyHash:
            identityPublicKeyHash(serverIdentity.publicKeyBase64Url),
        mode: ConnectionAttemptMode.automatic,
      ),
    );

    expect(result.status, ConnectionAttemptStatus.rejected);
    expect(result.reason, ConnectionAttemptReason.identityMismatch);
    expect(harness.clientEvents.pairingCount, 0);
    expect(harness.client.isConnectedTo('server-peer'), isFalse);
  });

  test('network socket loss schedules reconnect for the authenticated peer',
      () async {
    final harness = await _HandshakeHarness.start();
    final connected = await harness.connect('network-loss');
    expect(connected.isAuthenticated, isTrue);

    expect(await harness.server.debugDropPeerTransport('client-peer'), isTrue);
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

    expect(harness.clientReconnects.activeTimerCount, 1);
    // 连接在 30s 稳定阈值内即断:视为一次连续失败,首个重连延迟升档到 2s。
    expect(
      harness.clientReconnects.scheduledDelays,
      const <Duration>[Duration(seconds: 2)],
    );
  });

  test('scheduled reconnect completes signed auth and selects when idle',
      () async {
    final harness = await _HandshakeHarness.start();
    final connected = await harness.connect('reconnect-seed');
    expect(connected.isAuthenticated, isTrue);
    expect(await harness.server.debugDropPeerTransport('client-peer'), isTrue);
    await _waitUntil(() => harness.clientReconnects.activeTimerCount == 1);

    await harness.clientReconnects.fireNext();
    await _waitUntil(() => harness.client.isConnectedTo('server-peer'));

    expect(harness.client.receiver, 'server-peer');
    expect(harness.clientReconnects.activeTimerCount, 0);
  });

  test('inbound authenticated connection resets an existing retry', () async {
    final harness = await _HandshakeHarness.start();
    harness.server.scheduleReconnect(
      'client-peer',
      '192.168.1.20',
      10002,
    );
    expect(harness.serverReconnects.activeTimerCount, 1);

    final connected = await harness.connect('inbound-resets-retry');

    expect(connected.isAuthenticated, isTrue);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
    expect(harness.serverReconnects.activeTimerCount, 0);
  });

  test('watchdog removal schedules reconnect for the authenticated peer',
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
    expect(
      harness.clientReconnects.scheduledDelays,
      const <Duration>[Duration(seconds: 2)],
    );
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

  test('disabling automatic admission keeps the active connection', () async {
    final harness = await _HandshakeHarness.start();
    expect(
        (await harness.connect('disable-admission')).isAuthenticated, isTrue);

    expect(await harness.client.setPeerTrust('server-peer', false), isTrue);

    expect(harness.client.isConnectedTo('server-peer'), isTrue);
    expect((await harness.database.fetchDevice('server-peer'))?.auth, isFalse);
    expect(harness.clientReconnects.activeTimerCount, 0);
    expect(
      harness.client.reconnectSuppressionsFor('server-peer'),
      contains(ReconnectSuppressionReason.trustRevoked),
    );
  });

  test('manual disconnect policy blocks a new inbound signed redial', () async {
    final harness = await _HandshakeHarness.start();
    final connected = await harness.connect('manual-policy-seed');
    expect(connected.isAuthenticated, isTrue);

    await harness.server.disconnectPeer('client-peer');
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

    final redial = await harness.connect('manual-policy-redial');

    expect(redial.isAuthenticated, isFalse);
    expect(harness.server.isConnectedTo('client-peer'), isFalse);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
  });

  test('deleted peer can initiate a fresh signed re-pair', () async {
    final harness = await _HandshakeHarness.start();
    final connected = await harness.connect('delete-policy-seed');
    expect(connected.isAuthenticated, isTrue);

    await harness.server.deletePeer('client-peer');
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

    final redial = await harness.connect('delete-policy-redial');

    expect(redial.isAuthenticated, isTrue);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
  });

  test('authenticated malformed transport closure does not schedule retry',
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
  });

  test('explicit interactive dial clears manual inbound suppression', () async {
    final harness = await _HandshakeHarness.start();
    expect(
        (await harness.connect('manual-clear-seed')).isAuthenticated, isTrue);
    await harness.server.disconnectPeer('client-peer');
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

    final repaired = await harness.connectBack('manual-clear-explicit');

    expect(repaired.isAuthenticated, isTrue);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
  });

  test('client-only trust revoke shows matching codes on both peers', () async {
    final harness = await _HandshakeHarness.start();
    expect(
        (await harness.connect('trust-repair-seed')).isAuthenticated, isTrue);
    await harness.client.setPeerTrust('server-peer', false);
    expect(harness.client.isConnectedTo('server-peer'), isTrue);
    expect(await harness.server.debugDropPeerTransport('client-peer'), isTrue);
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

    serverPairing.resolve(true);
    final repaired = await repairing;
    await clientPairing.pairingDismissed.future
        .timeout(const Duration(seconds: 2));

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
        (await harness.connect('trust-inbound-seed')).isAuthenticated, isTrue);
    await harness.server.setPeerTrust('client-peer', false);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
    expect(await harness.server.debugDropPeerTransport('client-peer'), isTrue);
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
    serverPairing.resolve(true);
    final result = await redial;

    expect(result.isAuthenticated, isTrue);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
    expect(harness.server.isConnectedTo('client-peer'), isTrue);
  });

  test('successful explicit re-pair clears deleted inbound suppression',
      () async {
    final harness = await _HandshakeHarness.start();
    expect(
        (await harness.connect('delete-clear-seed')).isAuthenticated, isTrue);
    await harness.server.deletePeer('client-peer');
    await _waitUntil(() => !harness.client.isConnectedTo('server-peer'));

    final repaired = await harness.connectBack('delete-clear-explicit');
    expect(repaired.isAuthenticated, isTrue);
    expect((await harness.database.fetchDevice('client-peer'))?.auth, isTrue);
    expect(await harness.server.debugDropPeerTransport('client-peer'), isTrue);
    await _waitUntil(() => !harness.server.isConnectedTo('client-peer'));

    final redial = await harness.connect('delete-clear-redial');
    expect(redial.isAuthenticated, isTrue);
  });

  test('failed explicit re-pair does not permanently suppress inbound pairing',
      () async {
    final harness = await _HandshakeHarness.start();
    expect(
        (await harness.connect('delete-failed-seed')).isAuthenticated, isTrue);
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
  });

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

  test('background peer registration cannot complete the selected peer waiter',
      () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final peerA = WsSvrManager.forTesting(
      database: database,
      identityStore: _identityStore(1),
      localPeerProfileLoader: () async => _profile('peer-a'),
      autoConnectEnabled: () async => true,
      manageSharedCoordinators: false,
    );
    final peerB = WsSvrManager.forTesting(
      database: database,
      identityStore: _identityStore(33),
      localPeerProfileLoader: () async => _profile('peer-b'),
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
    addTearDown(() => hub.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    addTearDown(() => peerB.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    addTearDown(() => peerA.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
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
    final refreshed = await selectedWaiter.timeout(const Duration(seconds: 2));
    expect(refreshed?.device.uid, 'peer-a');
  });
}

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
    addTearDown(() => client.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    addTearDown(() => server.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
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

DeviceIdentityStore _identityStore(int seedStart) => DeviceIdentityStore(
      storage: _SeedStorage(
        Uint8List.fromList(
          List<int>.generate(32, (index) => seedStart + index),
        ),
      ),
    );

PeerProfile _profile(String uid) => PeerProfile(
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
      capabilities: const PeerCapabilities(
        fileTransferV3: true,
        systemAudioSourceV1: false,
        speakerSinkV1: false,
        remoteInputSourceV1: false,
        remoteInputSinkV1: false,
        remoteInputTopologyV1: false,
        audioGroupSourceV1: false,
        audioGroupSinkV1: false,
        audioGroupRejoinV1: false,
        audioSyncClockV1: false,
        audioChannelRoleV1: false,
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
  void onError(String message) {}

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
      unawaited(cancellation.then((_) {
        _pendingResolve = null;
        if (!pairingDismissed.isCompleted) pairingDismissed.complete();
      }));
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
