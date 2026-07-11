import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';

void main() {
  test('manager-owned controller refreshes an endpoint and accelerates retry',
      () async {
    final scheduler = _FakeScheduler();
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final manager = _manager(
      scheduler: scheduler,
      database: database,
      autoConnectEnabled: () async => false,
    );
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    manager.scheduleReconnect('peer-a', '192.168.1.10', 10002);
    manager.updateReconnectEndpoint('peer-a', '192.168.1.11', 10003);

    expect(manager.reconnectTargetFor('peer-a')?.host, '192.168.1.11');
    expect(manager.reconnectTargetFor('peer-a')?.port, 10003);
    expect(
      scheduler.scheduledDelays,
      const <Duration>[Duration(seconds: 1), Duration.zero],
    );
    expect(scheduler.activeTimerCount, 1);
  });

  test('eligibility is re-read and auto-connect disable suppresses dialing',
      () async {
    final scheduler = _FakeScheduler();
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    var enabled = false;
    final manager = _manager(
      scheduler: scheduler,
      database: database,
      autoConnectEnabled: () async => enabled,
    );
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));

    manager.scheduleReconnect('peer-a', '192.168.1.10', 10002);
    await scheduler.runNext();

    expect(
      manager.reconnectSuppressionsFor('peer-a'),
      contains(ReconnectSuppressionReason.autoConnectDisabled),
    );
    expect(manager.hasPendingConnectionAttemptForPeer('peer-a'), isFalse);

    enabled = true;
    manager.scheduleReconnect('peer-b', '192.168.1.12', 10002);
    await scheduler.runNext();
    expect(
      manager.reconnectSuppressionsFor('peer-b'),
      contains(ReconnectSuppressionReason.trustRevoked),
    );
  });

  test('trust revoke and delete invalidate local reconnect policy', () async {
    final scheduler = _FakeScheduler();
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.upsertDevice(_device('peer-a'));
    await database.pinDeviceIdentity('peer-a', 'pinned-key');
    await database.authDevice('peer-a', true);
    final manager = _manager(
      scheduler: scheduler,
      database: database,
      autoConnectEnabled: () async => true,
    );
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    manager.scheduleReconnect('peer-a', '192.168.1.10', 10002);

    await manager.setPeerTrust('peer-a', false);
    expect((await database.fetchDevice('peer-a'))?.auth, isFalse);
    expect(
      manager.reconnectSuppressionsFor('peer-a'),
      contains(ReconnectSuppressionReason.trustRevoked),
    );

    await manager.deletePeer('peer-a');
    expect(await database.fetchDevice('peer-a'), isNull);
    expect(scheduler.activeTimerCount, 0);
  });

  test('network failure schedules the next manager-owned retry', () async {
    final scheduler = _FakeScheduler();
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _trustPeer(database, 'peer-a');
    final manager = _manager(
      scheduler: scheduler,
      database: database,
      autoConnectEnabled: () async => true,
    );
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final unavailablePort = reserved.port;
    await reserved.close();

    manager.scheduleReconnectTarget(
      ReconnectTarget.endpoint(
        peerId: 'peer-a',
        endpoint: PeerEndpoint.loopbackForTesting(port: unavailablePort),
      ),
    );
    await scheduler.runNext();
    await _waitUntil(() => scheduler.activeTimerCount == 1);

    expect(
      scheduler.scheduledDelays,
      const <Duration>[Duration(seconds: 1), Duration(seconds: 2)],
    );
    expect(manager.hasPendingConnectionAttemptForPeer('peer-a'), isFalse);
  });

  test('accelerated endpoint refresh does not go dormant while the stale '
      'attempt is still cleaning up', () async {
    final scheduler = _FakeScheduler();
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _trustPeer(database, 'peer-a');
    final manager = _manager(
      scheduler: scheduler,
      database: database,
      autoConnectEnabled: () async => true,
    );
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final staleServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final freshServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => staleServer.close(force: true));
    addTearDown(() => freshServer.close(force: true));
    final staleReceived = Completer<void>();
    var freshRequests = 0;
    staleServer.listen((_) {
      if (!staleReceived.isCompleted) staleReceived.complete();
    });
    freshServer.listen((_) {
      freshRequests += 1;
    });

    manager.scheduleReconnectTarget(
      ReconnectTarget.endpoint(
        peerId: 'peer-a',
        endpoint: PeerEndpoint.loopbackForTesting(port: staleServer.port),
      ),
    );
    await scheduler.runNext();
    await staleReceived.future;

    // 端点刷新触发加速重拨(updateTarget accelerate):旧 attempt 被
    // invalidate 后其异步清理可能尚未 untrack,零延迟的新自动拨号
    // 不得因此永久休眠。
    manager.scheduleReconnectTarget(
      ReconnectTarget.endpoint(
        peerId: 'peer-a',
        endpoint: PeerEndpoint.loopbackForTesting(port: freshServer.port),
      ),
    );
    await scheduler.runNext();

    // 若加速拨号撞上尚未清理完的旧尝试(duplicateRequest),控制器应
    // 已按当前退避重排而不是休眠;驱动假计时器直到新端点真的收到拨号。
    for (var round = 0; round < 10 && freshRequests == 0; round += 1) {
      if (scheduler.activeTimerCount > 0) {
        await scheduler.runNext();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _waitUntil(() => freshRequests > 0);
  });

  test('protocol rejection stops instead of retrying', () async {
    final scheduler = _FakeScheduler();
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _trustPeer(database, 'peer-a');
    final manager = _manager(
      scheduler: scheduler,
      database: database,
      autoConnectEnabled: () async => true,
    );
    addTearDown(() => manager.closeGracefully(
          closeServer: true,
          forceServerClose: true,
        ));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final rejected = Completer<void>();
    server.listen((request) async {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      if (!rejected.isCompleted) rejected.complete();
    });

    manager.scheduleReconnectTarget(
      ReconnectTarget.endpoint(
        peerId: 'peer-a',
        endpoint: PeerEndpoint.loopbackForTesting(port: server.port),
      ),
    );
    await scheduler.runNext();
    await rejected.future;
    await _waitUntil(
      () => !manager.hasPendingConnectionAttemptForPeer('peer-a'),
    );

    expect(scheduler.scheduledDelays, const <Duration>[Duration(seconds: 1)]);
    expect(scheduler.activeTimerCount, 0);
  });
}

WsSvrManager _manager({
  required _FakeScheduler scheduler,
  required LocalDatabase database,
  required Future<bool> Function() autoConnectEnabled,
}) {
  return WsSvrManager.forTesting(
    database: database,
    autoConnectEnabled: autoConnectEnabled,
    setAutoConnectEnabled: (_) async {},
    reconnectControllerFactory: ({
      required attempt,
      required eligibility,
    }) =>
        PeerReconnectController(
      attempt: attempt,
      eligibility: eligibility,
      clock: scheduler.now,
      timerFactory: scheduler.createTimer,
      randomDouble: () => 0.5,
    ),
  );
}

DeviceData _device(String uid) => DeviceData(
      id: 0,
      uid: uid,
      name: 'Peer',
      host: '192.168.1.10',
      port: 10002,
      password: '',
      platform: 'test',
      isServer: false,
      online: true,
      clipboard: true,
      auth: false,
      lastTime: 1,
      around: true,
    );

Future<void> _trustPeer(LocalDatabase database, String peerId) async {
  final identity = await DeviceIdentity.fromSeed(
    Uint8List.fromList(List<int>.generate(32, (index) => index + 1)),
  );
  await database.upsertDevice(_device(peerId));
  await database.pinDeviceIdentity(peerId, identity.publicKeyBase64Url);
  await database.authDevice(peerId, true);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException('condition was not reached');
}

final class _FakeScheduler {
  DateTime _now = DateTime.utc(2026, 7, 10, 12);
  final List<_FakeTimer> _timers = <_FakeTimer>[];
  final List<Duration> scheduledDelays = <Duration>[];

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;

  DateTime now() => _now;

  Timer createTimer(Duration delay, void Function() callback) {
    scheduledDelays.add(delay);
    final timer = _FakeTimer(_now.add(delay), callback);
    _timers.add(timer);
    return timer;
  }

  Future<void> runNext() async {
    final active = _timers.where((timer) => timer.isActive).toList()
      ..sort((left, right) => left.dueAt.compareTo(right.dueAt));
    if (active.isEmpty) throw StateError('No timer is pending');
    final timer = active.first;
    _now = timer.dueAt;
    timer.fire();
    await pumpEventQueue();
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this.dueAt, this._callback);

  final DateTime dueAt;
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
