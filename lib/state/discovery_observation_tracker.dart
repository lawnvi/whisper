import 'dart:collection';

import 'package:whisper/state/discovery_identity.dart';
import 'package:whisper/state/peer_endpoint.dart';

final class DiscoveryObservationHandle {
  const DiscoveryObservationHandle._({
    required this.generation,
    required this.id,
    required this.serviceName,
    required this.serviceType,
  });

  final int generation;
  final int id;
  final String serviceName;
  final String serviceType;
}

final class DiscoveredServiceCandidate {
  DiscoveredServiceCandidate({
    required this.publicKeyHash,
    required this.serviceName,
    required this.advertisedProtocolVersion,
    required this.endpoint,
    required Iterable<PeerEndpoint> endpoints,
    required this.lastSeenAt,
  }) : endpoints = UnmodifiableListView<PeerEndpoint>(
         endpoints.toList(growable: false),
       );

  final String publicKeyHash;
  final String serviceName;
  final int advertisedProtocolVersion;
  final PeerEndpoint endpoint;
  final List<PeerEndpoint> endpoints;
  final DateTime lastSeenAt;

  bool get isProtocolCompatible =>
      advertisedProtocolVersion == int.parse(DiscoveryIdentity.protocolVersion);
}

final class DiscoveryObservationTracker {
  DiscoveryObservationTracker({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const serviceType = '_whisper._tcp';

  final DateTime Function() _clock;
  final Map<int, _DiscoveryObservation> _observations =
      <int, _DiscoveryObservation>{};
  int _generation = 0;
  int _nextId = 0;
  bool _running = false;

  int get generation => _generation;
  bool get isRunning => _running;

  List<DiscoveredServiceCandidate> get candidates {
    final byHash = <String, List<_DiscoveryObservation>>{};
    for (final observation in _observations.values) {
      if (!observation.active ||
          observation.publicKeyHash == null ||
          observation.advertisedProtocolVersion == null ||
          observation.endpoint == null) {
        continue;
      }
      byHash
          .putIfAbsent(
            observation.publicKeyHash!,
            () => <_DiscoveryObservation>[],
          )
          .add(observation);
    }

    final values = <DiscoveredServiceCandidate>[];
    for (final entry in byHash.entries) {
      entry.value.sort(
        (left, right) => right.resolvedAt!.compareTo(left.resolvedAt!),
      );
      final newest = entry.value.first;
      final endpoints = <PeerEndpoint>{
        for (final observation in entry.value) observation.endpoint!,
      };
      values.add(
        DiscoveredServiceCandidate(
          publicKeyHash: entry.key,
          serviceName: newest.serviceName,
          advertisedProtocolVersion: newest.advertisedProtocolVersion!,
          endpoint: newest.endpoint!,
          endpoints: endpoints,
          lastSeenAt: newest.resolvedAt!,
        ),
      );
    }
    values.sort((left, right) => right.lastSeenAt.compareTo(left.lastSeenAt));
    return List<DiscoveredServiceCandidate>.unmodifiable(values);
  }

  int start() {
    _generation += 1;
    _running = true;
    _observations.clear();
    return _generation;
  }

  void stop() {
    _generation += 1;
    _running = false;
    _observations.clear();
  }

  DiscoveryObservationHandle found({
    required String serviceName,
    required String serviceType,
  }) {
    if (!_running) {
      throw StateError('discovery tracker is not running');
    }
    final id = ++_nextId;
    final observation = _DiscoveryObservation(
      id: id,
      generation: _generation,
      serviceName: serviceName,
      serviceType: serviceType,
    );
    _observations[id] = observation;
    return DiscoveryObservationHandle._(
      generation: _generation,
      id: id,
      serviceName: serviceName,
      serviceType: serviceType,
    );
  }

  bool resolve(
    DiscoveryObservationHandle handle, {
    required Map<String, String> attributes,
    required String? host,
    required int port,
  }) {
    final observation = _observations[handle.id];
    if (!_running ||
        handle.generation != _generation ||
        observation == null ||
        !observation.active ||
        observation.generation != handle.generation ||
        observation.serviceName != handle.serviceName ||
        observation.serviceType != handle.serviceType ||
        observation.serviceType != serviceType ||
        !observation.serviceName.startsWith('whisper-') ||
        host == null) {
      return false;
    }

    final advertisedProtocolVersion = _parseStrictTxtVersion(attributes);
    if (advertisedProtocolVersion == null) {
      return false;
    }

    final PeerEndpoint endpoint;
    try {
      endpoint = PeerEndpoint(host: host, port: port);
    } on ArgumentError {
      return false;
    }
    observation
      ..publicKeyHash = attributes['pkh']
      ..advertisedProtocolVersion = advertisedProtocolVersion
      ..endpoint = endpoint
      ..resolvedAt = _clock();
    return true;
  }

  bool lost({required String serviceName, String? serviceType}) {
    final matches =
        _observations.values
            .where(
              (observation) =>
                  observation.active &&
                  observation.generation == _generation &&
                  observation.serviceName == serviceName &&
                  (serviceType == null ||
                      observation.serviceType == serviceType),
            )
            .toList(growable: false)
          ..sort((left, right) => left.id.compareTo(right.id));
    if (matches.isEmpty) {
      return false;
    }
    matches.first.active = false;
    return true;
  }

  static int? _parseStrictTxtVersion(Map<String, String> attributes) {
    if (attributes.length != 2 ||
        !attributes.containsKey('v') ||
        !attributes.containsKey('pkh')) {
      return null;
    }
    final rawVersion = attributes['v'];
    final publicKeyHash = attributes['pkh'];
    if (rawVersion == null ||
        !RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(rawVersion) ||
        publicKeyHash == null ||
        !DiscoveryIdentity.isCanonicalPublicKeyHash(publicKeyHash)) {
      return null;
    }
    final version = int.parse(rawVersion);
    return version <= 0xffff ? version : null;
  }
}

final class _DiscoveryObservation {
  _DiscoveryObservation({
    required this.id,
    required this.generation,
    required this.serviceName,
    required this.serviceType,
  });

  final int id;
  final int generation;
  final String serviceName;
  final String serviceType;
  bool active = true;
  String? publicKeyHash;
  int? advertisedProtocolVersion;
  PeerEndpoint? endpoint;
  DateTime? resolvedAt;
}
