import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/peer_endpoint.dart';

ConnectionAttemptRequest _interactive({
  required String requestId,
  required int port,
  required String peerId,
}) {
  return ConnectionAttemptRequest(
    requestId: requestId,
    endpoint: PeerEndpoint.loopbackForTesting(port: port),
    expectedPeerId: peerId,
    mode: ConnectionAttemptMode.interactive,
  );
}

ConnectionAttemptRequest _automatic({
  required String requestId,
  required int port,
  required String peerId,
}) {
  return ConnectionAttemptRequest(
    requestId: requestId,
    endpoint: PeerEndpoint.loopbackForTesting(port: port),
    expectedPeerId: peerId,
    expectedPublicKeyHash: List<String>.filled(43, 'A').join(),
    mode: ConnectionAttemptMode.automatic,
  );
}

final class _HangingServer {
  _HangingServer(this.server);

  final HttpServer server;
  int requestCount = 0;
  final Completer<void> firstReceived = Completer<void>();
  final Completer<void> secondReceived = Completer<void>();

  static Future<_HangingServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hanging = _HangingServer(server);
    server.listen((_) {
      hanging.requestCount += 1;
      if (hanging.requestCount == 1 && !hanging.firstReceived.isCompleted) {
        hanging.firstReceived.complete();
      }
      if (hanging.requestCount == 2 && !hanging.secondReceived.isCompleted) {
        hanging.secondReceived.complete();
      }
    });
    return hanging;
  }

  int get port => server.port;
}

void main() {
  test('interactive dial preempts an in-flight automatic attempt', () async {
    final hanging = await _HangingServer.start();
    addTearDown(() => hanging.server.close(force: true));
    final manager = WsSvrManager.forTesting();
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    final automatic = manager.connectToServer(
      _automatic(requestId: 'auto-1', port: hanging.port, peerId: 'peer-x'),
    );
    await hanging.firstReceived.future;

    final interactive = manager.connectToServer(
      _interactive(
        requestId: 'manual-1',
        port: hanging.port,
        peerId: 'peer-x',
      ),
    );

    final automaticResult =
        await automatic.timeout(const Duration(seconds: 5));
    expect(automaticResult.status, ConnectionAttemptStatus.cancelled);
    expect(automaticResult.reason, ConnectionAttemptReason.superseded);

    // 手动尝试必须真实拨号(第二次到达服务器),而不是撞门直接失败。
    await hanging.secondReceived.future.timeout(const Duration(seconds: 5));
    expect(manager.hasPendingConnectionAttempt('manual-1'), isTrue);

    await manager.cancelConnectionAttempt('manual-1');
    final interactiveResult =
        await interactive.timeout(const Duration(seconds: 5));
    expect(
      interactiveResult.reason,
      isNot(ConnectionAttemptReason.duplicateRequest),
    );
    expect(interactiveResult.status, ConnectionAttemptStatus.cancelled);
    expect(
      interactiveResult.reason,
      ConnectionAttemptReason.requestCancelled,
    );
  });

  test('in-flight automatic attempt dedupes a new automatic dial', () async {
    final hanging = await _HangingServer.start();
    addTearDown(() => hanging.server.close(force: true));
    final manager = WsSvrManager.forTesting();
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    final automatic = manager.connectToServer(
      _automatic(requestId: 'auto-1', port: hanging.port, peerId: 'peer-x'),
    );
    await hanging.firstReceived.future;

    final duplicate = manager.connectToServer(
      _automatic(requestId: 'auto-2', port: hanging.port, peerId: 'peer-x'),
    );
    // 护栏应在建立 attempt/socket 之前直接拒绝。
    expect(manager.hasPendingConnectionAttempt('auto-2'), isFalse);
    final duplicateResult =
        await duplicate.timeout(const Duration(seconds: 2));
    expect(duplicateResult.status, ConnectionAttemptStatus.rejected);
    expect(duplicateResult.reason, ConnectionAttemptReason.duplicateRequest);
    expect(hanging.requestCount, 1);
    expect(manager.hasPendingConnectionAttempt('auto-1'), isTrue);

    await manager.cancelConnectionAttempt('auto-1');
    final automaticResult =
        await automatic.timeout(const Duration(seconds: 5));
    expect(automaticResult.status, ConnectionAttemptStatus.cancelled);
  });

  test('in-flight interactive attempt skips a new automatic dial', () async {
    final hanging = await _HangingServer.start();
    addTearDown(() => hanging.server.close(force: true));
    final manager = WsSvrManager.forTesting();
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    final interactive = manager.connectToServer(
      _interactive(
        requestId: 'manual-1',
        port: hanging.port,
        peerId: 'peer-x',
      ),
    );
    await hanging.firstReceived.future;

    final duplicate = manager.connectToServer(
      _automatic(requestId: 'auto-1', port: hanging.port, peerId: 'peer-x'),
    );
    expect(manager.hasPendingConnectionAttempt('auto-1'), isFalse);
    final duplicateResult =
        await duplicate.timeout(const Duration(seconds: 2));
    expect(duplicateResult.status, ConnectionAttemptStatus.rejected);
    expect(duplicateResult.reason, ConnectionAttemptReason.duplicateRequest);
    expect(hanging.requestCount, 1);
    expect(manager.hasPendingConnectionAttempt('manual-1'), isTrue);

    await manager.cancelConnectionAttempt('manual-1');
    final interactiveResult =
        await interactive.timeout(const Duration(seconds: 5));
    expect(interactiveResult.status, ConnectionAttemptStatus.cancelled);
  });
}
