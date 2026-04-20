import 'package:flutter/foundation.dart';

enum ConnectionLifecycleState {
  idle,
  discovering,
  candidate,
  connecting,
  connected,
  reconnecting,
  rejected,
  disconnected,
}

@immutable
class DevicePresence {
  const DevicePresence({
    required this.peerId,
    required this.name,
    required this.host,
    required this.port,
    required this.platform,
    required this.state,
    required this.discovered,
    required this.locallyTrusted,
    required this.remotelyTrusted,
    required this.lastSeenAt,
    this.lastError,
  });

  final String peerId;
  final String name;
  final String host;
  final int port;
  final String platform;
  final ConnectionLifecycleState state;
  final bool discovered;
  final bool locallyTrusted;
  final bool remotelyTrusted;
  final DateTime lastSeenAt;
  final String? lastError;

  DevicePresence copyWith({
    String? peerId,
    String? name,
    String? host,
    int? port,
    String? platform,
    ConnectionLifecycleState? state,
    bool? discovered,
    bool? locallyTrusted,
    bool? remotelyTrusted,
    DateTime? lastSeenAt,
    String? lastError,
  }) {
    return DevicePresence(
      peerId: peerId ?? this.peerId,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      platform: platform ?? this.platform,
      state: state ?? this.state,
      discovered: discovered ?? this.discovered,
      locallyTrusted: locallyTrusted ?? this.locallyTrusted,
      remotelyTrusted: remotelyTrusted ?? this.remotelyTrusted,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastError: lastError ?? this.lastError,
    );
  }
}

@immutable
class ConnectionSnapshot {
  const ConnectionSnapshot({
    this.activePeerId,
    this.state = ConnectionLifecycleState.idle,
    this.errorMessage,
  });

  final String? activePeerId;
  final ConnectionLifecycleState state;
  final String? errorMessage;

  ConnectionSnapshot copyWith({
    String? activePeerId,
    ConnectionLifecycleState? state,
    String? errorMessage,
  }) {
    return ConnectionSnapshot(
      activePeerId: activePeerId ?? this.activePeerId,
      state: state ?? this.state,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
