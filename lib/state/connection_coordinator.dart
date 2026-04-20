import 'package:flutter/foundation.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/auto_connect_planner.dart';
import 'package:whisper/state/connection_models.dart';

class ConnectionCoordinator extends ChangeNotifier {
  ConnectionCoordinator._internal();

  static final ConnectionCoordinator _singleton =
      ConnectionCoordinator._internal();

  factory ConnectionCoordinator() {
    return _singleton;
  }

  final LocalDatabase _database = LocalDatabase();
  final LocalSetting _settings = LocalSetting();

  final Map<String, DevicePresence> _presenceByPeerId = {};
  ConnectionSnapshot _snapshot = const ConnectionSnapshot();
  String _localPeerId = '';

  ConnectionSnapshot get snapshot => _snapshot;

  List<DevicePresence> get peers {
    final values = _presenceByPeerId.values.toList()
      ..sort((left, right) => right.lastSeenAt.compareTo(left.lastSeenAt));
    return values;
  }

  Future<void> bootstrap(String localPeerId) async {
    if (_localPeerId == localPeerId) {
      await refreshTrustState();
      return;
    }
    _localPeerId = localPeerId;
    await refreshTrustState();
  }

  Future<void> refreshTrustState() async {
    final trustedPeerIds = await _database.fetchTrustedPeerIds();
    final trustedSet = trustedPeerIds.toSet();
    for (final entry in _presenceByPeerId.entries) {
      _presenceByPeerId[entry.key] = entry.value.copyWith(
        locallyTrusted: trustedSet.contains(entry.key),
      );
    }
    notifyListeners();
  }

  Future<void> syncKnownDevices(Iterable<DeviceData> devices) async {
    final trustedPeerIds = (await _database.fetchTrustedPeerIds()).toSet();
    for (final device in devices) {
      _presenceByPeerId[device.uid] = _buildPresence(
        device,
        locallyTrusted: trustedPeerIds.contains(device.uid),
        existing: _presenceByPeerId[device.uid],
      );
    }
    notifyListeners();
  }

  Future<void> updateDiscovery(
    DeviceData device, {
    required bool discovered,
    List<String> remoteTrustedPeerIds = const [],
    bool remoteAutoConnectEnabled = true,
  }) async {
    final trustedPeerIds = (await _database.fetchTrustedPeerIds()).toSet();
    final previous = _presenceByPeerId[device.uid];
    final remotelyTrusted = remoteAutoConnectEnabled &&
        _localPeerId.isNotEmpty &&
        remoteTrustedPeerIds.contains(_localPeerId);

    _presenceByPeerId[device.uid] = DevicePresence(
      peerId: device.uid,
      name: device.name,
      host: device.host,
      port: device.port,
      platform: device.platform,
      state: discovered
          ? ConnectionLifecycleState.candidate
          : ConnectionLifecycleState.disconnected,
      discovered: discovered,
      locallyTrusted: trustedPeerIds.contains(device.uid),
      remotelyTrusted: remotelyTrusted,
      lastSeenAt: DateTime.now(),
      lastError: previous?.lastError,
    );

    notifyListeners();
  }

  Future<void> markManualSelection(String peerId) async {
    await _settings.setLastManualPeerId(peerId);
  }

  void markConnecting(String peerId, {bool reconnecting = false}) {
    _snapshot = ConnectionSnapshot(
      activePeerId: peerId,
      state: reconnecting
          ? ConnectionLifecycleState.reconnecting
          : ConnectionLifecycleState.connecting,
    );
    _presenceByPeerId.update(
      peerId,
      (value) => value.copyWith(state: _snapshot.state),
      ifAbsent: () => DevicePresence(
        peerId: peerId,
        name: peerId,
        host: '',
        port: 10002,
        platform: '',
        state: _snapshot.state,
        discovered: false,
        locallyTrusted: false,
        remotelyTrusted: false,
        lastSeenAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  void markConnected(DeviceData device) {
    _snapshot = ConnectionSnapshot(
      activePeerId: device.uid,
      state: ConnectionLifecycleState.connected,
    );
    final previous = _presenceByPeerId[device.uid];
    _presenceByPeerId[device.uid] = _buildPresence(
      device,
      locallyTrusted: previous?.locallyTrusted ?? device.auth,
      existing: previous,
      state: ConnectionLifecycleState.connected,
      discovered: true,
    );
    notifyListeners();
  }

  void markDisconnected({String? error}) {
    final activePeerId = _snapshot.activePeerId;
    if (activePeerId != null && _presenceByPeerId.containsKey(activePeerId)) {
      _presenceByPeerId[activePeerId] =
          _presenceByPeerId[activePeerId]!.copyWith(
        state: ConnectionLifecycleState.disconnected,
        lastError: error,
      );
    }
    _snapshot = ConnectionSnapshot(
      activePeerId: null,
      state: error == null
          ? ConnectionLifecycleState.disconnected
          : ConnectionLifecycleState.rejected,
      errorMessage: error,
    );
    notifyListeners();
  }

  DevicePresence? peer(String peerId) => _presenceByPeerId[peerId];

  bool isConnectedTo(String peerId) {
    return _snapshot.activePeerId == peerId &&
        _snapshot.state == ConnectionLifecycleState.connected;
  }

  Future<DevicePresence?> chooseAutoConnectCandidate() async {
    final autoConnectEnabled = await _settings.autoConnectEnabled();
    final lastManualPeerId = await _settings.lastManualPeerId();
    return AutoConnectPlanner.selectCandidate(
      autoConnectEnabled: autoConnectEnabled,
      activePeerId: _snapshot.activePeerId,
      lastManualPeerId: lastManualPeerId,
      candidates: peers,
    );
  }

  DevicePresence _buildPresence(
    DeviceData device, {
    required bool locallyTrusted,
    DevicePresence? existing,
    ConnectionLifecycleState? state,
    bool? discovered,
  }) {
    return DevicePresence(
      peerId: device.uid,
      name: device.name,
      host: device.host,
      port: device.port,
      platform: device.platform,
      state: state ??
          existing?.state ??
          (_snapshot.activePeerId == device.uid
              ? ConnectionLifecycleState.connected
              : ConnectionLifecycleState.idle),
      discovered: discovered ?? existing?.discovered ?? (device.around == true),
      locallyTrusted: locallyTrusted,
      remotelyTrusted: existing?.remotelyTrusted ?? false,
      lastSeenAt: existing?.lastSeenAt ??
          DateTime.fromMillisecondsSinceEpoch(device.lastTime * 1000),
      lastError: existing?.lastError,
    );
  }
}
