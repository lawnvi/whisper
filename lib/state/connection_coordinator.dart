import 'package:flutter/foundation.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/auto_connect_planner.dart';
import 'package:whisper/state/connection_models.dart';
import 'package:whisper/state/peer_endpoint.dart';

enum LocalDiscoveryComponent { server, broadcast, discoveryEngine }

@immutable
class LocalDiscoveryErrorState {
  const LocalDiscoveryErrorState({
    this.server,
    this.broadcast,
    this.discoveryEngine,
  });

  final String? server;
  final String? broadcast;
  final String? discoveryEngine;

  String? get message => server ?? broadcast ?? discoveryEngine;

  LocalDiscoveryErrorState withFailure(
    LocalDiscoveryComponent component,
    String message,
  ) {
    return switch (component) {
      LocalDiscoveryComponent.server => LocalDiscoveryErrorState(
          server: message,
          broadcast: broadcast,
          discoveryEngine: discoveryEngine,
        ),
      LocalDiscoveryComponent.broadcast => LocalDiscoveryErrorState(
          server: server,
          broadcast: message,
          discoveryEngine: discoveryEngine,
        ),
      LocalDiscoveryComponent.discoveryEngine => LocalDiscoveryErrorState(
          server: server,
          broadcast: broadcast,
          discoveryEngine: message,
        ),
    };
  }

  LocalDiscoveryErrorState clear(LocalDiscoveryComponent component) {
    return switch (component) {
      LocalDiscoveryComponent.server => LocalDiscoveryErrorState(
          broadcast: broadcast,
          discoveryEngine: discoveryEngine,
        ),
      LocalDiscoveryComponent.broadcast => LocalDiscoveryErrorState(
          server: server,
          discoveryEngine: discoveryEngine,
        ),
      LocalDiscoveryComponent.discoveryEngine => LocalDiscoveryErrorState(
          server: server,
          broadcast: broadcast,
        ),
    };
  }
}

@immutable
class NearbyCandidatePresentation {
  const NearbyCandidatePresentation({
    required this.publicKeyHash,
    required this.serviceName,
    required this.endpoint,
    required this.lastSeenAt,
    this.displayName,
    this.platform,
  });

  final String publicKeyHash;
  final String serviceName;
  final PeerEndpoint endpoint;
  final DateTime lastSeenAt;
  final String? displayName;
  final String? platform;

  String get id => publicKeyHash;
}

class ConnectionAttemptTracker {
  final Map<String, int> _generationByTarget = <String, int>{};
  int _nextGeneration = 0;

  int begin(String target) {
    final generation = ++_nextGeneration;
    _generationByTarget[target] = generation;
    return generation;
  }

  bool isCurrent(String target, int generation) {
    return _generationByTarget[target] == generation;
  }

  bool complete(String target, int generation) {
    if (!isCurrent(target, generation)) {
      return false;
    }
    _generationByTarget.remove(target);
    return true;
  }

  void cancel(String target) {
    _generationByTarget.remove(target);
  }

  void cancelAll() {
    _generationByTarget.clear();
  }
}

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
  final Map<String, NearbyCandidatePresentation> _nearbyCandidatesByPkh = {};
  ConnectionSnapshot _snapshot = const ConnectionSnapshot();
  String _localPeerId = '';

  ConnectionSnapshot get snapshot => _snapshot;

  List<DevicePresence> get peers {
    final values = _presenceByPeerId.values.toList()
      ..sort((left, right) => right.lastSeenAt.compareTo(left.lastSeenAt));
    return values;
  }

  List<NearbyCandidatePresentation> get nearbyCandidates {
    final values = _nearbyCandidatesByPkh.values.toList()
      ..sort((left, right) => right.lastSeenAt.compareTo(left.lastSeenAt));
    return List<NearbyCandidatePresentation>.unmodifiable(values);
  }

  void presentNearbyCandidate(NearbyCandidatePresentation candidate) {
    _nearbyCandidatesByPkh[candidate.id] = candidate;
    notifyListeners();
  }

  void removeNearbyCandidate(String publicKeyHash) {
    if (_nearbyCandidatesByPkh.remove(publicKeyHash) != null) {
      notifyListeners();
    }
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
      activePeerId: _snapshot.activePeerId ?? peerId,
      activePeerIds: _snapshot.activePeerIds,
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

  void markConnected(DeviceData device, {bool select = true}) {
    final connectedPeerIds = <String>{
      ..._snapshot.activePeerIds,
      device.uid,
    };
    _snapshot = ConnectionSnapshot(
      activePeerId: select ? device.uid : _snapshot.activePeerId,
      activePeerIds: connectedPeerIds,
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

  void markDisconnected({String? peerId, String? error}) {
    final peersToDisconnect =
        peerId == null ? _snapshot.connectedPeerIds : <String>{peerId};
    for (final disconnectedPeerId in peersToDisconnect) {
      if (!_presenceByPeerId.containsKey(disconnectedPeerId)) {
        continue;
      }
      _presenceByPeerId[disconnectedPeerId] =
          _presenceByPeerId[disconnectedPeerId]!.copyWith(
        state: ConnectionLifecycleState.disconnected,
        lastError: error,
      );
    }
    final remainingPeerIds = peerId == null
        ? <String>{}
        : _snapshot.connectedPeerIds
            .where((connectedPeerId) => connectedPeerId != peerId)
            .toSet();
    final selectedPeerId = remainingPeerIds.contains(_snapshot.activePeerId)
        ? _snapshot.activePeerId
        : (remainingPeerIds.isEmpty ? null : remainingPeerIds.first);
    _snapshot = ConnectionSnapshot(
      activePeerId: selectedPeerId,
      activePeerIds: remainingPeerIds,
      state: remainingPeerIds.isNotEmpty
          ? ConnectionLifecycleState.connected
          : (error == null
              ? ConnectionLifecycleState.disconnected
              : ConnectionLifecycleState.rejected),
      errorMessage: error,
    );
    notifyListeners();
  }

  DevicePresence? peer(String peerId) => _presenceByPeerId[peerId];

  bool isConnectedTo(String peerId) {
    return _snapshot.isConnectedTo(peerId);
  }

  Future<DevicePresence?> chooseAutoConnectCandidate() async {
    final autoConnectEnabled = await _settings.autoConnectEnabled();
    final lastManualPeerId = await _settings.lastManualPeerId();
    return AutoConnectPlanner.selectCandidate(
      autoConnectEnabled: autoConnectEnabled,
      activePeerId: _snapshot.activePeerId,
      connectedPeerIds: _snapshot.connectedPeerIds,
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
          (_snapshot.isConnectedTo(device.uid)
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
