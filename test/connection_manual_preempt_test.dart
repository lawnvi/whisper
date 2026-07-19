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

  test('a cancelled attempt awaiting cleanup does not dedupe the next '
      'automatic dial', () async {
    final staleServer = await _HangingServer.start();
    final freshServer = await _HangingServer.start();
    addTearDown(() => staleServer.server.close(force: true));
    addTearDown(() => freshServer.server.close(force: true));
    final manager = WsSvrManager.forTesting();
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    final stale = manager.connectToServer(
      _automatic(
        requestId: 'auto-stale',
        port: staleServer.port,
        peerId: 'peer-x',
      ),
    );
    await staleServer.firstReceived.future;

    // 同步启动取消:isCancelled 立即置位,但异步清理(transport abort、
    // 释放鉴权门、untrack)尚未跑完,旧 attempt 仍在 per-peer 索引里。
    final cancelling = manager.cancelConnectionAttempt('auto-stale');
    expect(manager.hasPendingConnectionAttemptForPeer('peer-x'), isTrue);

    final fresh = manager.connectToServer(
      _automatic(
        requestId: 'auto-fresh',
        port: freshServer.port,
        peerId: 'peer-x',
      ),
    );

    // 加速重拨不得被垂死的旧尝试在自动去重预检里挡下:
    // 必须真实建立 attempt,而不是不建 attempt 直接拒绝。
    expect(manager.hasPendingConnectionAttempt('auto-fresh'), isTrue);

    // 这个同步窗口里旧尝试仍占着 peer 级出站鉴权门,新拨号得到的
    // duplicateRequest 是暂态拒绝(由重连控制器按当前退避短延迟重试)。
    final freshResult = await fresh.timeout(const Duration(seconds: 5));
    expect(freshResult.status, ConnectionAttemptStatus.rejected);
    expect(freshResult.reason, ConnectionAttemptReason.duplicateRequest);

    await cancelling;
    final staleResult = await stale.timeout(const Duration(seconds: 5));
    expect(staleResult.status, ConnectionAttemptStatus.cancelled);

    // 旧尝试清理完成后,重试拨号必须畅通并真实到达新端点。
    final retry = manager.connectToServer(
      _automatic(
        requestId: 'auto-retry',
        port: freshServer.port,
        peerId: 'peer-x',
      ),
    );
    expect(manager.hasPendingConnectionAttempt('auto-retry'), isTrue);
    await freshServer.firstReceived.future.timeout(const Duration(seconds: 5));

    await manager.cancelConnectionAttempt('auto-retry');
    final retryResult = await retry.timeout(const Duration(seconds: 5));
    expect(retryResult.status, ConnectionAttemptStatus.cancelled);
    expect(retryResult.reason, isNot(ConnectionAttemptReason.duplicateRequest));
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
