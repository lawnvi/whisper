import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/helper/system_power.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/state/discovery_endpoint_resolver.dart';
import 'package:whisper/state/discovery_identity.dart';
import 'package:whisper/state/discovery_resolve_limiter.dart';
import 'package:whisper/state/discovery_service_presence.dart';
import 'package:whisper/state/network_change_watcher.dart';
import 'package:whisper/state/peer_endpoint.dart';

enum DiscoveryDiagnosticKind {
  broadcastEvent,
  discoveryEvent,
  serviceFound,
  discoveryStarted,
  serviceSkipped,
  serviceResolved,
  serviceLost,
}

/// What a discovery or broadcast event was, for the diagnostic log.
enum DiscoveryEventState {
  started,
  serviceFound,
  serviceResolved,
  serviceUpdated,
  serviceResolveFailed,
  serviceLost,
  nameAlreadyExists,
  stopped,
  unknown;

  static DiscoveryEventState ofDiscovery(BonsoirDiscoveryEvent event) {
    return switch (event) {
      BonsoirDiscoveryStartedEvent() => started,
      BonsoirDiscoveryServiceFoundEvent() => serviceFound,
      BonsoirDiscoveryServiceResolvedEvent() => serviceResolved,
      BonsoirDiscoveryServiceUpdatedEvent() => serviceUpdated,
      BonsoirDiscoveryServiceResolveFailedEvent() => serviceResolveFailed,
      BonsoirDiscoveryServiceLostEvent() => serviceLost,
      BonsoirDiscoveryStoppedEvent() => stopped,
      BonsoirDiscoveryUnknownEvent() => unknown,
    };
  }

  static DiscoveryEventState ofBroadcast(BonsoirBroadcastEvent event) {
    return switch (event) {
      BonsoirBroadcastStartedEvent() => started,
      BonsoirBroadcastNameAlreadyExistsEvent() => nameAlreadyExists,
      BonsoirBroadcastStoppedEvent() => stopped,
      _ => unknown,
    };
  }
}

String buildWhisperServiceName(String baseName, String uid) {
  final normalizedUid = uid.trim();
  if (normalizedUid.isEmpty) {
    return baseName;
  }
  return '$baseName-$normalizedUid';
}

/// Snapshot of local metadata advertised over LAN mDNS.
final class LanBroadcastConfig {
  const LanBroadcastConfig({
    required this.uid,
    required this.name,
    required this.platform,
    required this.port,
  });

  final String uid;
  final String name;
  final String platform;
  final int port;
}

/// One resolved, updated, or lost peer event emitted by [LanDiscoveryService].
final class LanDiscoveredPeerEvent {
  const LanDiscoveredPeerEvent({
    required this.peerId,
    required this.isLost,
    required this.port,
    required this.attributes,
    this.primaryHost,
    this.candidateEndpoints = const <PeerEndpoint>[],
    this.name,
    this.platform,
  });

  final String peerId;
  final bool isLost;
  final int port;
  final String? primaryHost;
  final List<PeerEndpoint> candidateEndpoints;
  final String? name;
  final String? platform;
  final Map<String, String> attributes;
}

/// Owns LAN mDNS broadcast, discovery, candidate-endpoint caching, and
/// network-change re-broadcasting outside UI pages.
final class LanDiscoveryService {
  LanDiscoveryService({
    required Future<LanBroadcastConfig?> Function() loadBroadcastConfig,
    required Future<void> Function(LanDiscoveredPeerEvent event) onPeerEvent,
    Future<void> Function()? onNetworkChanged,
    void Function(Object error, StackTrace stack)? onError,
    void Function()? onDiscoveryReady,
    this.serviceName = 'whisper',
    this.serviceType = '_whisper._tcp',
    this.broadcastPort = 10004,
  }) : _loadBroadcastConfig = loadBroadcastConfig,
       _onPeerEvent = onPeerEvent,
       _onNetworkChanged = onNetworkChanged,
       _onError = onError,
       _onDiscoveryReady = onDiscoveryReady {
    _networkWatcher = NetworkChangeWatcher(
      onNetworkChanged: (_) => _handleNetworkChanged(),
    );
  }

  final Future<LanBroadcastConfig?> Function() _loadBroadcastConfig;
  final Future<void> Function(LanDiscoveredPeerEvent event) _onPeerEvent;
  final Future<void> Function()? _onNetworkChanged;
  final void Function(Object error, StackTrace stack)? _onError;
  final void Function()? _onDiscoveryReady;

  final String serviceName;
  final String serviceType;
  final int broadcastPort;

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirBroadcastEvent>? _broadcastSubscription;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySubscription;
  StreamSubscription<SystemPowerEvent>? _powerSubscription;
  Timer? _broadcastRestartTimer;
  late final NetworkChangeWatcher _networkWatcher;

  final DiscoveryResolveLimiter _resolveLimiter = DiscoveryResolveLimiter(
    minimumInterval: const Duration(seconds: 5),
  );
  final DiscoveryServicePresenceTracker _discoveryPresence =
      DiscoveryServicePresenceTracker();
  final Map<String, List<PeerEndpoint>> _candidatesByPeerId =
      <String, List<PeerEndpoint>>{};

  bool _isBroadcasting = false;
  bool _isDiscovering = false;
  bool _disposed = false;

  bool get isBroadcasting => _isBroadcasting;
  bool get isDiscovering => _isDiscovering;

  /// Ordered deduplicated candidate endpoints for [peerId] (up to 4).
  /// When [primary] is supplied, it is placed first and remaining cached
  /// candidates follow as fallbacks.
  List<PeerEndpoint> candidateEndpointsFor(
    String peerId, {
    PeerEndpoint? primary,
  }) {
    final result = <PeerEndpoint>[];
    void add(PeerEndpoint? ep) {
      if (ep == null || result.contains(ep) || result.length >= 4) return;
      result.add(ep);
    }

    add(primary);
    final cached = _candidatesByPeerId[peerId];
    if (cached != null) {
      for (final ep in cached) {
        add(ep);
      }
    }
    return List<PeerEndpoint>.unmodifiable(result);
  }

  /// Promotes an endpoint that just authenticated successfully so subsequent
  /// dials try it first while preserving other discovered fallbacks.
  void rememberWorkingEndpoint(String peerId, PeerEndpoint endpoint) {
    if (peerId.isEmpty) return;
    _candidatesByPeerId[peerId] = candidateEndpointsFor(
      peerId,
      primary: endpoint,
    );
  }

  /// Starts network-change polling and system-wake immediate sampling.
  Future<void> startNetworkWatch() async {
    if (_disposed) return;
    _powerSubscription ??= SystemPowerBridge.events.listen((event) {
      if (event == SystemPowerEvent.didWake) {
        unawaited(_networkWatcher.checkNow());
      }
    });
    await _networkWatcher.start();
  }

  void setBackgrounded(bool backgrounded) {
    if (_disposed) return;
    _networkWatcher.setBackgrounded(backgrounded);
  }

  Future<void> checkNetworkNow() => _networkWatcher.checkNow();

  void scheduleBroadcastRestart({
    int? portOverride,
    Duration delay = const Duration(milliseconds: 100),
  }) {
    if (_disposed) return;
    _isBroadcasting = true;
    _broadcastRestartTimer?.cancel();
    _broadcastRestartTimer = Timer(delay, () {
      _broadcastRestartTimer = null;
      unawaited(
        startBroadcast(portOverride: portOverride).catchError((
          Object error,
          StackTrace stack,
        ) {
          _onError?.call(error, stack);
        }),
      );
    });
  }

  Future<void> startBroadcast({int? portOverride}) async {
    if (_disposed) return;
    final wifiIP = await getLocalIpAddress();
    if (_disposed) return;
    if (wifiIP == '127.0.0.1') {
      _isBroadcasting = false;
      return;
    }

    await stopBroadcast(close: false);
    if (_disposed) return;
    final config = await _loadBroadcastConfig();
    if (_disposed || config == null) return;
    final identity = await DeviceIdentityStore().loadOrCreate();
    if (_disposed) return;
    final discoveryId = DiscoveryIdentity.fromPublicKey(
      identity.publicKeyBase64Url,
    );
    final service = BonsoirService(
      name: buildWhisperServiceName(serviceName, config.uid),
      type: serviceType,
      port: broadcastPort,
      attributes: discoveryId.buildBroadcastAttributes(
        host: wifiIP,
        port: portOverride ?? config.port,
        name: config.name,
        platform: config.platform,
        uid: config.uid,
      ),
    );

    final broadcast = BonsoirBroadcast(service: service);
    _broadcast = broadcast;
    await broadcast.initialize();
    if (_disposed || !identical(_broadcast, broadcast)) {
      await broadcast.stop();
      return;
    }
    unawaited(_broadcastSubscription?.cancel());
    _broadcastSubscription = broadcast.eventStream!.listen((event) {
      _logDiscovery(
        DiscoveryDiagnosticKind.broadcastEvent,
        state: DiscoveryEventState.ofBroadcast(event),
      );
    });
    await broadcast.start();
    if (!_disposed && identical(_broadcast, broadcast)) {
      _isBroadcasting = true;
    }
  }

  Future<void> stopBroadcast({bool close = true}) async {
    _broadcastRestartTimer?.cancel();
    _broadcastRestartTimer = null;
    final subscription = _broadcastSubscription;
    final broadcast = _broadcast;
    _broadcastSubscription = null;
    _broadcast = null;
    _isBroadcasting = !close;
    await subscription?.cancel();
    await broadcast?.stop();
  }

  Future<void> startDiscovery() async {
    await stopDiscovery();
    if (_disposed) return;
    final discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
    _discovery = discovery;
    await discovery.initialize();
    if (_disposed || !identical(_discovery, discovery)) {
      await discovery.stop();
      return;
    }

    unawaited(_discoverySubscription?.cancel());
    _discoverySubscription = discovery.eventStream!.listen((event) async {
      if (_disposed || !identical(_discovery, discovery)) return;
      _logDiscovery(
        DiscoveryDiagnosticKind.discoveryEvent,
        state: DiscoveryEventState.ofDiscovery(event),
      );
      final service = event.service;
      if (service == null) return;
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          _logDiscovery(DiscoveryDiagnosticKind.serviceFound);
          if (service.name.startsWith(serviceName) &&
              _resolveLimiter.shouldResolve(_serviceResolveKey(service))) {
            unawaited(service.resolve(discovery.serviceResolver));
          }
        case BonsoirDiscoveryStartedEvent():
          _logDiscovery(DiscoveryDiagnosticKind.discoveryStarted);
        case BonsoirDiscoveryServiceResolvedEvent() ||
            BonsoirDiscoveryServiceUpdatedEvent() ||
            BonsoirDiscoveryServiceLostEvent():
          await _handleServiceEvent(event, service, discovery);
        case BonsoirDiscoveryServiceResolveFailedEvent() ||
            BonsoirDiscoveryStoppedEvent() ||
            BonsoirDiscoveryUnknownEvent():
          break;
      }
    });

    await discovery.start();
    if (!_disposed && identical(_discovery, discovery)) {
      _isDiscovering = true;
      _onDiscoveryReady?.call();
    }
  }

  Future<void> stopDiscovery() async {
    final subscription = _discoverySubscription;
    final discovery = _discovery;
    _discoverySubscription = null;
    _discovery = null;
    _discoveryPresence.clear();
    _isDiscovering = false;
    await subscription?.cancel();
    await discovery?.stop();
  }

  Future<void> stopAll({bool stopDiscoveryOnWindows = false}) async {
    _disposed = true;
    _networkWatcher.stop();
    await _powerSubscription?.cancel();
    _powerSubscription = null;
    if (!Platform.isWindows || stopDiscoveryOnWindows) {
      await stopDiscovery();
    }
    await stopBroadcast();
  }

  Future<void> _handleServiceEvent(
    BonsoirDiscoveryEvent event,
    BonsoirService service,
    BonsoirDiscovery discovery,
  ) async {
    final isLost = event is BonsoirDiscoveryServiceLostEvent;
    final serviceKey = _serviceResolveKey(service);
    final advertisedUid = service.attributes['uid'];
    final String uid;
    if (isLost) {
      _resolveLimiter.clear(serviceKey);
      final loss = _discoveryPresence.lost(
        serviceKey: serviceKey,
        peerIdHint: advertisedUid,
      );
      if (loss == null) {
        _logDiscovery(DiscoveryDiagnosticKind.serviceSkipped);
        return;
      }
      if (loss.stillDiscovered) return;
      uid = loss.peerId;
    } else {
      if (advertisedUid == null || advertisedUid.isEmpty) {
        _logDiscovery(DiscoveryDiagnosticKind.serviceSkipped);
        return;
      }
      uid = advertisedUid;
      _discoveryPresence.resolved(serviceKey: serviceKey, peerId: uid);
    }

    final port = int.tryParse(service.attributes['port'] ?? '10002') ?? 10002;
    String? primaryHost;
    var candidateEndpoints = const <PeerEndpoint>[];
    if (!isLost) {
      final candidateHosts = await resolveDiscoveryCandidateHosts(
        resolvedHost: service.hostname,
        resolvedAddresses: service.hostAddresses,
        advertisedHost: service.attributes['host'],
        port: port,
      );
      if (_disposed || !identical(_discovery, discovery)) return;
      if (candidateHosts.isEmpty) {
        _logDiscovery(DiscoveryDiagnosticKind.serviceSkipped);
        return;
      }
      primaryHost = candidateHosts.first;
      final built = <PeerEndpoint>[];
      for (final h in candidateHosts) {
        try {
          built.add(PeerEndpoint(host: h, port: port));
        } on ArgumentError {
          // Skip invalid candidate hosts.
        }
      }
      if (built.isEmpty) {
        _logDiscovery(DiscoveryDiagnosticKind.serviceSkipped);
        return;
      }
      _candidatesByPeerId[uid] = List<PeerEndpoint>.unmodifiable(built);
      candidateEndpoints = _candidatesByPeerId[uid]!;
    }

    _logDiscovery(
      isLost
          ? DiscoveryDiagnosticKind.serviceLost
          : DiscoveryDiagnosticKind.serviceResolved,
    );
    await _onPeerEvent(
      LanDiscoveredPeerEvent(
        peerId: uid,
        isLost: isLost,
        port: port,
        primaryHost: primaryHost,
        candidateEndpoints: candidateEndpoints,
        name: service.attributes['name'],
        platform: service.attributes['platform'],
        attributes: service.attributes,
      ),
    );
  }

  Future<void> _handleNetworkChanged() async {
    if (_disposed) return;
    await _onNetworkChanged?.call();
    if (_disposed) return;
    scheduleBroadcastRestart();
    // Restart discovery on network switch except on Windows where older
    // Bonsoir stop paths can crash during rapid restarts.
    if (_isDiscovering && !Platform.isWindows) {
      unawaited(
        startDiscovery().catchError((Object error, StackTrace stack) {
          _onError?.call(error, stack);
        }),
      );
    }
  }

  static String _serviceResolveKey(BonsoirService service) =>
      '${service.name}|${service.type}';

  static void _logDiscovery(DiscoveryDiagnosticKind kind, {Enum? state}) {
    privacyLog.event(PrivacyEvent.discoveryState, <PrivacyField, Object>{
      PrivacyField.kind: kind,
      if (state != null) PrivacyField.state: state,
    });
  }
}
