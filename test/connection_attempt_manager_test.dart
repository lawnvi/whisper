import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/peer_endpoint.dart';

ConnectionAttemptRequest _request({
  required String requestId,
  required int port,
  String peerId = '',
}) {
  return ConnectionAttemptRequest(
    requestId: requestId,
    endpoint: PeerEndpoint.loopbackForTesting(port: port),
    expectedPeerId: peerId,
    mode: ConnectionAttemptMode.interactive,
  );
}

void main() {
  test('transport failure returns a typed network result', () async {
    final unavailable =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unavailable.port;
    await unavailable.close();
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final manager = WsSvrManager.forTesting(database: database);
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    final result = await manager.connectToServer(
      _request(requestId: 'network-1', port: port),
    );

    expect(result.requestId, 'network-1');
    expect(result.status, ConnectionAttemptStatus.networkFailure);
    expect(result.reason, isNot(ConnectionAttemptReason.none));
  });

  test('only transport exceptions are retryable network failures', () {
    final manager = WsSvrManager.forTesting();
    final request = _request(requestId: 'classification', port: 10002);

    expect(
      manager
          .debugClassifyConnectionException(
            request,
            const SocketException('offline'),
          )
          .status,
      ConnectionAttemptStatus.networkFailure,
    );
    expect(
      manager
          .debugClassifyConnectionException(
            request,
            StateError('database failed'),
          )
          .status,
      ConnectionAttemptStatus.rejected,
    );
    expect(
      manager
          .debugClassifyConnectionException(
            request,
            const WebSocketException('invalid negotiation'),
          )
          .reason,
      ConnectionAttemptReason.protocolMismatch,
    );
  });

  test('manager close cancels a pending HTTP dial', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestReceived = Completer<void>();
    server.listen((_) {
      if (!requestReceived.isCompleted) requestReceived.complete();
    });
    final manager = WsSvrManager.forTesting();

    final connecting = manager.connectToServer(
      _request(requestId: 'closing-1', port: server.port, peerId: 'peer-a'),
    );
    await requestReceived.future;
    final closing = manager.closeGracefully();

    final result = await connecting.timeout(const Duration(seconds: 2));
    await closing.timeout(const Duration(seconds: 2));
    expect(result.status, ConnectionAttemptStatus.cancelled);
    expect(result.reason, ConnectionAttemptReason.managerClosed);
  });

  test('disconnect cancels only the matching pre-registration peer dial',
      () async {
    final serverA = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => serverA.close(force: true));
    addTearDown(() => serverB.close(force: true));
    final receivedA = Completer<void>();
    final receivedB = Completer<void>();
    serverA.listen((_) {
      if (!receivedA.isCompleted) receivedA.complete();
    });
    serverB.listen((_) {
      if (!receivedB.isCompleted) receivedB.complete();
    });
    final manager = WsSvrManager.forTesting();
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    final attemptA = manager.connectToServer(
      _request(requestId: 'peer-a-1', port: serverA.port, peerId: 'peer-a'),
    );
    final attemptB = manager.connectToServer(
      _request(requestId: 'peer-b-1', port: serverB.port, peerId: 'peer-b'),
    );
    await Future.wait(<Future<void>>[receivedA.future, receivedB.future]);

    await manager.disconnectPeer('peer-a');
    final resultA = await attemptA.timeout(const Duration(seconds: 2));
    expect(resultA.status, ConnectionAttemptStatus.cancelled);
    expect(resultA.reason, ConnectionAttemptReason.manualDisconnect);
    expect(manager.hasPendingConnectionAttempt('peer-b-1'), isTrue);

    await manager.cancelConnectionAttempt('peer-b-1');
    final resultB = await attemptB.timeout(const Duration(seconds: 2));
    expect(resultB.status, ConnectionAttemptStatus.cancelled);
    expect(resultB.reason, ConnectionAttemptReason.requestCancelled);
  });

  test('late unknown-peer binding cannot cross a prior revoke policy epoch',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<void>();
    server.listen((_) {
      if (!received.isCompleted) received.complete();
    });
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final manager = WsSvrManager.forTesting(database: database);
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final connecting = manager.connectToServer(
      _request(requestId: 'unknown-peer', port: server.port),
    );
    await received.future;

    await manager.setPeerTrust('peer-a', false);

    expect(
      manager.debugBindPendingConnectionPeer('unknown-peer', 'peer-a'),
      isFalse,
    );
    await manager.cancelConnectionAttempt('unknown-peer');
    expect(
      (await connecting).status,
      ConnectionAttemptStatus.cancelled,
    );
  });

  test('auto-connect disable cancels automatic but not interactive dialing',
      () async {
    final autoServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final manualServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => autoServer.close(force: true));
    addTearDown(() => manualServer.close(force: true));
    final autoReceived = Completer<void>();
    final manualReceived = Completer<void>();
    autoServer.listen((_) {
      if (!autoReceived.isCompleted) autoReceived.complete();
    });
    manualServer.listen((_) {
      if (!manualReceived.isCompleted) manualReceived.complete();
    });
    var enabled = true;
    final manager = WsSvrManager.forTesting(
      autoConnectEnabled: () async => enabled,
      setAutoConnectEnabled: (value) async => enabled = value,
    );
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final automatic = manager.connectToServer(
      ConnectionAttemptRequest(
        requestId: 'automatic',
        endpoint: PeerEndpoint.loopbackForTesting(port: autoServer.port),
        expectedPeerId: 'peer-auto',
        expectedPublicKeyHash: List<String>.filled(43, 'A').join(),
        mode: ConnectionAttemptMode.automatic,
      ),
    );
    final manual = manager.connectToServer(
      _request(
        requestId: 'interactive',
        port: manualServer.port,
        peerId: 'peer-manual',
      ),
    );
    await Future.wait(
        <Future<void>>[autoReceived.future, manualReceived.future]);

    await manager.setAutoConnectPolicy(false);

    final automaticResult = await automatic;
    expect(automaticResult.status, ConnectionAttemptStatus.cancelled);
    expect(
      automaticResult.reason,
      ConnectionAttemptReason.autoConnectDisabled,
    );
    expect(manager.hasPendingConnectionAttempt('interactive'), isTrue);
    await manager.cancelConnectionAttempt('interactive');
    expect((await manual).status, ConnectionAttemptStatus.cancelled);
  });
}
