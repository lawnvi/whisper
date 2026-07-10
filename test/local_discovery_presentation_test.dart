import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/local_network_permission.dart';
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

  group('LocalDiscoveryPresentation', () {
    test('maps a fully running service to active', () {
      final state = LocalDiscoveryPresentation.fromRuntime(
        permissionStatus: LocalNetworkPermissionStatus.granted,
        serverStarted: true,
        broadcasting: true,
        discovering: true,
      );

      expect(state.phase, LocalDiscoveryPhase.active);
      expect(state.canRetry, isFalse);
      expect(state.errorMessage, isNull);
    });

    test('keeps partial startup distinct from stopped', () {
      final starting = LocalDiscoveryPresentation.fromRuntime(
        permissionStatus: LocalNetworkPermissionStatus.unknown,
        serverStarted: true,
        broadcasting: false,
        discovering: true,
        startupInProgress: true,
      );
      final stopped = LocalDiscoveryPresentation.fromRuntime(
        permissionStatus: LocalNetworkPermissionStatus.granted,
        serverStarted: false,
        broadcasting: false,
        discovering: false,
      );

      expect(starting.phase, LocalDiscoveryPhase.starting);
      expect(starting.canRetry, isFalse);
      expect(stopped.phase, LocalDiscoveryPhase.stopped);
      expect(stopped.canRetry, isTrue);
    });

    test('only explicit startup progress maps partial runtime to starting', () {
      for (final runtime in <({bool server, bool broadcast, bool discover})>[
        (server: true, broadcast: false, discover: false),
        (server: false, broadcast: true, discover: false),
        (server: false, broadcast: false, discover: true),
        (server: true, broadcast: true, discover: false),
      ]) {
        final state = LocalDiscoveryPresentation.fromRuntime(
          permissionStatus: LocalNetworkPermissionStatus.granted,
          serverStarted: runtime.server,
          broadcasting: runtime.broadcast,
          discovering: runtime.discover,
        );

        expect(
          state.phase,
          LocalDiscoveryPhase.stopped,
          reason: runtime.toString(),
        );
        expect(state.canRetry, isTrue, reason: runtime.toString());
      }

      final explicitStartup = LocalDiscoveryPresentation.fromRuntime(
        permissionStatus: LocalNetworkPermissionStatus.granted,
        serverStarted: true,
        broadcasting: false,
        discovering: false,
        startupInProgress: true,
      );
      expect(explicitStartup.phase, LocalDiscoveryPhase.starting);
      expect(explicitStartup.canRetry, isFalse);
    });

    test('maps availability and network errors to unavailable with retry', () {
      final unavailable = LocalDiscoveryPresentation.fromRuntime(
        permissionStatus: LocalNetworkPermissionStatus.granted,
        serverStarted: false,
        broadcasting: false,
        discovering: false,
        available: false,
      );
      final failed = LocalDiscoveryPresentation.fromRuntime(
        permissionStatus: LocalNetworkPermissionStatus.granted,
        serverStarted: false,
        broadcasting: false,
        discovering: false,
        errorMessage: 'No LAN interface',
      );

      expect(unavailable.phase, LocalDiscoveryPhase.unavailable);
      expect(unavailable.canRetry, isTrue);
      expect(failed.phase, LocalDiscoveryPhase.unavailable);
      expect(failed.errorMessage, 'No LAN interface');
      expect(failed.canRetry, isTrue);
    });

    test('permission denial and policy restriction take priority', () {
      final denied = LocalDiscoveryPresentation.fromRuntime(
        permissionStatus: LocalNetworkPermissionStatus.denied,
        serverStarted: true,
        broadcasting: true,
        discovering: true,
        errorMessage: 'ignored network error',
      );
      final restricted = LocalDiscoveryPresentation.fromRuntime(
        permissionStatus: LocalNetworkPermissionStatus.restricted,
        serverStarted: true,
        broadcasting: true,
        discovering: true,
      );

      expect(denied.phase, LocalDiscoveryPhase.permissionDenied);
      expect(denied.canRetry, isTrue);
      expect(restricted.phase, LocalDiscoveryPhase.permissionRestricted);
      expect(restricted.canRetry, isFalse);
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
