import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/peer_endpoint.dart';

void main() {
  group('LocalDiscoveryErrorState', () {
    test('success only clears the matching component failure', () {
      final failed = const LocalDiscoveryErrorState()
          .withFailure(LocalDiscoveryComponent.broadcast, 'broadcast failed')
          .withFailure(
            LocalDiscoveryComponent.discoveryEngine,
            'discovery failed',
          );

      final discoveryRecovered =
          failed.clear(LocalDiscoveryComponent.discoveryEngine);

      expect(discoveryRecovered.message, 'broadcast failed');
      expect(discoveryRecovered.broadcast, 'broadcast failed');
      expect(discoveryRecovered.discoveryEngine, isNull);
    });

    test('component failures retain deterministic presentation priority', () {
      final failures = const LocalDiscoveryErrorState()
          .withFailure(LocalDiscoveryComponent.discoveryEngine, 'discovery')
          .withFailure(LocalDiscoveryComponent.broadcast, 'broadcast')
          .withFailure(LocalDiscoveryComponent.server, 'server');

      expect(failures.message, 'server');
      expect(
        failures.clear(LocalDiscoveryComponent.server).message,
        'broadcast',
      );
    });
  });

  test('nearby candidate is identity keyed without requiring DeviceData', () {
    const publicKeyHash =
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    final candidate = NearbyCandidatePresentation(
      publicKeyHash: publicKeyHash,
      serviceName: 'whisper-ffffffff',
      endpoint: PeerEndpoint(host: '192.168.1.20', port: 10002),
      displayName: 'Nearby Mac',
      platform: 'macos',
      lastSeenAt: DateTime.utc(2026, 7, 10),
    );

    expect(candidate.id, publicKeyHash);
    expect(candidate.endpoint.host, '192.168.1.20');
    expect(candidate.displayName, 'Nearby Mac');
  });

  test('coordinator replaces candidates by pkh and exposes newest first', () {
    const firstHash =
        '1111111111111111111111111111111111111111111111111111111111111111';
    const secondHash =
        '2222222222222222222222222222222222222222222222222222222222222222';
    final coordinator = ConnectionCoordinator();
    addTearDown(() {
      coordinator.removeNearbyCandidate(firstHash);
      coordinator.removeNearbyCandidate(secondHash);
    });

    coordinator.presentNearbyCandidate(
      NearbyCandidatePresentation(
        publicKeyHash: firstHash,
        serviceName: 'whisper-11111111',
        endpoint: PeerEndpoint(host: '192.168.1.20', port: 10002),
        lastSeenAt: DateTime.utc(2026, 7, 10, 10),
      ),
    );
    coordinator.presentNearbyCandidate(
      NearbyCandidatePresentation(
        publicKeyHash: secondHash,
        serviceName: 'whisper-22222222',
        endpoint: PeerEndpoint(host: '192.168.1.21', port: 10002),
        lastSeenAt: DateTime.utc(2026, 7, 10, 11),
      ),
    );
    coordinator.presentNearbyCandidate(
      NearbyCandidatePresentation(
        publicKeyHash: firstHash,
        serviceName: 'whisper-11111111',
        endpoint: PeerEndpoint(host: '192.168.1.30', port: 10002),
        lastSeenAt: DateTime.utc(2026, 7, 10, 12),
      ),
    );

    final candidates = coordinator.nearbyCandidates
        .where((item) => item.id == firstHash || item.id == secondHash)
        .toList();
    expect(candidates.map((item) => item.id), [firstHash, secondHash]);
    expect(candidates.first.endpoint.host, '192.168.1.30');

    coordinator.removeNearbyCandidate(firstHash);
    expect(
      coordinator.nearbyCandidates.any((item) => item.id == firstHash),
      isFalse,
    );
  });
}
