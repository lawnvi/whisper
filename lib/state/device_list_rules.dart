import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/socket/peer_socket_session.dart';

/// What the device list knows about a peer it sees on the network. Discovery
/// is fresher about where the peer is and what it is called; only the store
/// knows whether it is trusted and which identity is pinned to it.
DeviceData mergeStoredDeviceWithDiscovery(
  DeviceData? stored,
  DeviceData discovered,
) {
  if (stored == null) {
    return discovered;
  }
  return DeviceData(
    id: stored.id,
    uid: discovered.uid,
    identityPublicKey: stored.identityPublicKey,
    name: discovered.name.isNotEmpty ? discovered.name : stored.name,
    host: discovered.host.isNotEmpty ? discovered.host : stored.host,
    port: discovered.port,
    password: stored.password,
    platform: discovered.platform.isNotEmpty
        ? discovered.platform
        : stored.platform,
    isServer: stored.isServer,
    online: stored.online,
    clipboard: stored.clipboard,
    auth: stored.auth,
    lastTime: discovered.lastTime,
    around: discovered.around,
  );
}

/// The hash of the identity pinned to a peer this device trusts, null when
/// there is no such identity. Quick send only goes to a peer with one.
String? trustedDeviceIdentityHash({
  required Iterable<DeviceData> devices,
  required String peerId,
  required bool Function(DeviceData candidate) isLocallyTrusted,
}) {
  for (final candidate in devices) {
    if (candidate.uid != peerId ||
        !candidate.auth ||
        candidate.identityPublicKey.isEmpty ||
        !isLocallyTrusted(candidate)) {
      continue;
    }
    try {
      return identityPublicKeyHash(candidate.identityPublicKey);
    } on Object {
      return null;
    }
  }
  return null;
}

/// Whether keyboard and mouse sharing is really going on. A stale offering or
/// armed state can survive briefly while a peer is being disconnected, so it
/// only counts with a live authenticated peer behind it.
bool isRemoteInputSessionLive({
  required RemoteInputWorkspaceSnapshot workspace,
  required RemoteInputRuntimeState legacy,
  required bool legacyIsManual,
  required bool Function(String peerId) isConnected,
}) {
  final legacyLive =
      !legacyIsManual &&
      legacy.status != RemoteInputRuntimeStatus.idle &&
      legacy.status != RemoteInputRuntimeStatus.failed &&
      legacy.peerId.isNotEmpty &&
      isConnected(legacy.peerId);
  final workspaceLive =
      workspace.isControllerLive &&
      workspace.targets.values.any((target) => target.isConnected);
  return workspaceLive || workspace.isControlledLive || legacyLive;
}

/// Decides when a refresh of the device list starts the server. A start closes
/// every session, each close refreshes the list, and refreshes that only
/// looked at the device (still unknown until the first refresh finishes)
/// restarted the server again, for minutes. So the port is remembered here, at
/// the moment of deciding, before the start is awaited.
class DeviceListServerStart {
  int? _port;

  bool shouldStart({required bool isFirst, required int port}) {
    if (!isFirst && _port == port) return false;
    _port = port;
    return true;
  }
}
