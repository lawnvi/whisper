import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/local_network_permission.dart';
import 'package:whisper/state/local_discovery_runtime.dart';

void main() {
  test('starts permission server broadcast and browse in exact order',
      () async {
    final events = <String>[];
    final runtime = LocalDiscoveryRuntime(
      ensurePermission: () async {
        events.add('permission');
        return LocalNetworkPermissionStatus.granted;
      },
      startServer: () async {
        events.add('server:0');
        return 43210;
      },
      stopServer: () async => events.add('stop-server'),
      startBroadcast: (port) async => events.add('broadcast:$port'),
      stopBroadcast: () async => events.add('stop-broadcast'),
      startBrowse: () async => events.add('browse'),
      stopBrowse: () async => events.add('stop-browse'),
    );

    final result = await runtime.start();

    expect(result.isRunning, isTrue);
    expect(result.port, 43210);
    expect(runtime.snapshot.isRunning, isTrue);
    expect(events, <String>[
      'permission',
      'server:0',
      'broadcast:43210',
      'browse',
    ]);
  });

  test('permission denial tears down in reverse order without prompting loop',
      () async {
    final events = <String>[];
    final runtime = LocalDiscoveryRuntime(
      ensurePermission: () async => LocalNetworkPermissionStatus.denied,
      startServer: () async {
        events.add('server');
        return 1;
      },
      stopServer: () async => events.add('stop-server'),
      startBroadcast: (_) async => events.add('broadcast'),
      stopBroadcast: () async => events.add('stop-broadcast'),
      startBrowse: () async => events.add('browse'),
      stopBrowse: () async => events.add('stop-browse'),
    );

    final result = await runtime.start();

    expect(result.permission, LocalNetworkPermissionStatus.denied);
    expect(result.isRunning, isFalse);
    expect(events, isEmpty);
  });

  test('stop invalidates an in-flight start and awaits reverse teardown',
      () async {
    final events = <String>[];
    final serverStarted = Completer<int>();
    final runtime = LocalDiscoveryRuntime(
      ensurePermission: () async {
        events.add('permission');
        return LocalNetworkPermissionStatus.granted;
      },
      startServer: () {
        events.add('server-starting');
        return serverStarted.future;
      },
      stopServer: () async => events.add('stop-server'),
      startBroadcast: (port) async => events.add('broadcast:$port'),
      stopBroadcast: () async => events.add('stop-broadcast'),
      startBrowse: () async => events.add('browse'),
      stopBrowse: () async => events.add('stop-browse'),
    );

    final starting = runtime.start();
    await Future<void>.delayed(Duration.zero);
    final stopping = runtime.stop();
    serverStarted.complete(45000);

    expect((await starting).isRunning, isFalse);
    await stopping;
    expect(runtime.snapshot.isRunning, isFalse);
    expect(events, <String>[
      'permission',
      'server-starting',
      'stop-server',
    ]);
  });

  test('component failure tears down only started resources in reverse order',
      () async {
    final events = <String>[];
    final runtime = LocalDiscoveryRuntime(
      ensurePermission: () async => LocalNetworkPermissionStatus.granted,
      startServer: () async {
        events.add('server');
        return 45000;
      },
      stopServer: () async => events.add('stop-server'),
      startBroadcast: (_) async => events.add('broadcast'),
      stopBroadcast: () async => events.add('stop-broadcast'),
      startBrowse: () async {
        events.add('browse');
        throw StateError('browse failed');
      },
      stopBrowse: () async => events.add('stop-browse'),
    );

    final result = await runtime.start();

    expect(result.isRunning, isFalse);
    expect(result.failure, LocalDiscoveryFailure.browse);
    expect(events, <String>[
      'server',
      'broadcast',
      'browse',
      'stop-broadcast',
      'stop-server',
    ]);
  });

  test('concurrent starts coalesce to the newest generation', () async {
    final events = <String>[];
    var starts = 0;
    final runtime = LocalDiscoveryRuntime(
      ensurePermission: () async => LocalNetworkPermissionStatus.granted,
      startServer: () async {
        starts += 1;
        events.add('server:$starts');
        return 45000 + starts;
      },
      stopServer: () async => events.add('stop-server'),
      startBroadcast: (port) async => events.add('broadcast:$port'),
      stopBroadcast: () async => events.add('stop-broadcast'),
      startBrowse: () async => events.add('browse'),
      stopBrowse: () async => events.add('stop-browse'),
    );

    final first = runtime.start();
    final second = runtime.start();
    await Future.wait(<Future<LocalDiscoveryStartResult>>[first, second]);

    expect(runtime.snapshot.isRunning, isTrue);
    expect(runtime.snapshot.port, 45001);
    expect(starts, 1);
  });
}
