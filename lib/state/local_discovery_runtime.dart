import 'dart:async';

import 'package:whisper/helper/local_network_permission.dart';

enum LocalDiscoveryFailure { permission, server, broadcast, browse }

final class LocalDiscoverySnapshot {
  const LocalDiscoverySnapshot({
    this.permission = LocalNetworkPermissionStatus.unknown,
    this.port,
    this.serverRunning = false,
    this.broadcastRunning = false,
    this.browseRunning = false,
    this.failure,
  });

  final LocalNetworkPermissionStatus permission;
  final int? port;
  final bool serverRunning;
  final bool broadcastRunning;
  final bool browseRunning;
  final LocalDiscoveryFailure? failure;

  bool get isRunning =>
      serverRunning && broadcastRunning && browseRunning && failure == null;
}

final class LocalDiscoveryStartResult {
  const LocalDiscoveryStartResult(this.snapshot);

  final LocalDiscoverySnapshot snapshot;

  LocalNetworkPermissionStatus get permission => snapshot.permission;
  int? get port => snapshot.port;
  LocalDiscoveryFailure? get failure => snapshot.failure;
  bool get isRunning => snapshot.isRunning;
}

final class LocalDiscoveryRuntime {
  LocalDiscoveryRuntime({
    required Future<LocalNetworkPermissionStatus> Function() ensurePermission,
    required Future<int> Function() startServer,
    required Future<void> Function() stopServer,
    required Future<void> Function(int port) startBroadcast,
    required Future<void> Function() stopBroadcast,
    required Future<void> Function() startBrowse,
    required Future<void> Function() stopBrowse,
  })  : _ensurePermission = ensurePermission,
        _startServer = startServer,
        _stopServer = stopServer,
        _startBroadcast = startBroadcast,
        _stopBroadcast = stopBroadcast,
        _startBrowse = startBrowse,
        _stopBrowse = stopBrowse;

  final Future<LocalNetworkPermissionStatus> Function() _ensurePermission;
  final Future<int> Function() _startServer;
  final Future<void> Function() _stopServer;
  final Future<void> Function(int port) _startBroadcast;
  final Future<void> Function() _stopBroadcast;
  final Future<void> Function() _startBrowse;
  final Future<void> Function() _stopBrowse;

  Future<void> _tail = Future<void>.value();
  LocalDiscoverySnapshot _snapshot = const LocalDiscoverySnapshot();
  int _generation = 0;
  bool _disposed = false;

  LocalDiscoverySnapshot get snapshot => _snapshot;
  int get generation => _generation;

  Future<LocalDiscoveryStartResult> start() {
    if (_disposed) {
      return Future<LocalDiscoveryStartResult>.error(
        StateError('local discovery runtime is disposed'),
      );
    }
    final generation = ++_generation;
    return _serialize(() => _start(generation));
  }

  Future<void> stop() {
    _generation += 1;
    return _serialize(() async {
      await _teardown();
      _snapshot = LocalDiscoverySnapshot(permission: _snapshot.permission);
    });
  }

  Future<void> dispose() {
    _disposed = true;
    return stop();
  }

  Future<LocalDiscoveryStartResult> _start(int generation) async {
    if (!_isCurrent(generation)) {
      return LocalDiscoveryStartResult(_snapshot);
    }
    await _teardown();

    final LocalNetworkPermissionStatus permission;
    try {
      permission = await _ensurePermission();
    } catch (_) {
      _snapshot = const LocalDiscoverySnapshot(
        failure: LocalDiscoveryFailure.permission,
      );
      return LocalDiscoveryStartResult(_snapshot);
    }
    if (!_isCurrent(generation)) {
      return LocalDiscoveryStartResult(_snapshot);
    }
    _snapshot = LocalDiscoverySnapshot(permission: permission);
    if (permission != LocalNetworkPermissionStatus.granted) {
      return LocalDiscoveryStartResult(_snapshot);
    }

    try {
      final port = await _startServer();
      if (port < 1 || port > 65535) {
        throw StateError('server returned an invalid bound port');
      }
      _snapshot = LocalDiscoverySnapshot(
        permission: permission,
        port: port,
        serverRunning: true,
      );
      if (!_isCurrent(generation)) {
        await _teardown();
        return LocalDiscoveryStartResult(_snapshot);
      }

      await _startBroadcast(port);
      _snapshot = LocalDiscoverySnapshot(
        permission: permission,
        port: port,
        serverRunning: true,
        broadcastRunning: true,
      );
      if (!_isCurrent(generation)) {
        await _teardown();
        return LocalDiscoveryStartResult(_snapshot);
      }

      await _startBrowse();
      _snapshot = LocalDiscoverySnapshot(
        permission: permission,
        port: port,
        serverRunning: true,
        broadcastRunning: true,
        browseRunning: true,
      );
      if (!_isCurrent(generation)) {
        await _teardown();
      }
      return LocalDiscoveryStartResult(_snapshot);
    } catch (_) {
      final failure = !_snapshot.serverRunning
          ? LocalDiscoveryFailure.server
          : !_snapshot.broadcastRunning
              ? LocalDiscoveryFailure.broadcast
              : LocalDiscoveryFailure.browse;
      await _teardown();
      _snapshot = LocalDiscoverySnapshot(
        permission: permission,
        failure: failure,
      );
      return LocalDiscoveryStartResult(_snapshot);
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> _teardown() async {
    final browseRunning = _snapshot.browseRunning;
    final broadcastRunning = _snapshot.broadcastRunning;
    final serverRunning = _snapshot.serverRunning;
    if (browseRunning) {
      await _ignoreFailure(_stopBrowse);
    }
    if (broadcastRunning) {
      await _ignoreFailure(_stopBroadcast);
    }
    if (serverRunning) {
      await _ignoreFailure(_stopServer);
    }
    _snapshot = LocalDiscoverySnapshot(permission: _snapshot.permission);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then<void>((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }, onError: (Object _, StackTrace __) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

Future<void> _ignoreFailure(Future<void> Function() operation) async {
  try {
    await operation();
  } catch (_) {
    // Teardown continues so later resources cannot remain active.
  }
}
