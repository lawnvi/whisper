import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/connection_models.dart';
import 'package:whisper/state/auto_connect_planner.dart';

void main() {
  group('AutoConnectPlanner', () {
    test('requires both local and remote trust before auto-connecting', () {
      final trusted = DevicePresence(
        peerId: 'trusted',
        name: 'Trusted',
        host: '192.168.1.20',
        port: 10002,
        platform: 'android',
        state: ConnectionLifecycleState.candidate,
        discovered: true,
        locallyTrusted: true,
        remotelyTrusted: true,
        lastSeenAt: DateTime(2026, 1, 1, 12),
      );
      final localOnly = trusted.copyWith(
        peerId: 'local-only',
        remotelyTrusted: false,
      );
      final remoteOnly = trusted.copyWith(
        peerId: 'remote-only',
        locallyTrusted: false,
      );

      expect(AutoConnectPlanner.isMutuallyTrusted(trusted), isTrue);
      expect(AutoConnectPlanner.isMutuallyTrusted(localOnly), isFalse);
      expect(AutoConnectPlanner.isMutuallyTrusted(remoteOnly), isFalse);
    });

    test(
        'prefers the most recent manual peer when it is still a valid candidate',
        () {
      final now = DateTime(2026, 1, 1, 12, 0);
      final result = AutoConnectPlanner.selectCandidate(
        autoConnectEnabled: true,
        activePeerId: null,
        lastManualPeerId: 'peer-b',
        candidates: [
          DevicePresence(
            peerId: 'peer-a',
            name: 'Peer A',
            host: '192.168.1.21',
            port: 10002,
            platform: 'linux',
            state: ConnectionLifecycleState.candidate,
            discovered: true,
            locallyTrusted: true,
            remotelyTrusted: true,
            lastSeenAt: now.subtract(const Duration(minutes: 1)),
          ),
          DevicePresence(
            peerId: 'peer-b',
            name: 'Peer B',
            host: '192.168.1.22',
            port: 10002,
            platform: 'windows',
            state: ConnectionLifecycleState.candidate,
            discovered: true,
            locallyTrusted: true,
            remotelyTrusted: true,
            lastSeenAt: now.subtract(const Duration(minutes: 5)),
          ),
        ],
      );

      expect(result?.peerId, 'peer-b');
    });

    test('does not pick a new candidate while another peer is active', () {
      final result = AutoConnectPlanner.selectCandidate(
        autoConnectEnabled: true,
        activePeerId: 'connected-peer',
        lastManualPeerId: 'peer-a',
        candidates: [
          DevicePresence(
            peerId: 'peer-a',
            name: 'Peer A',
            host: '192.168.1.21',
            port: 10002,
            platform: 'linux',
            state: ConnectionLifecycleState.candidate,
            discovered: true,
            locallyTrusted: true,
            remotelyTrusted: true,
            lastSeenAt: DateTime(2026, 1, 1, 12),
          ),
        ],
      );

      expect(result, isNull);
    });

    test('falls back to the freshest mutually trusted candidate', () {
      final now = DateTime(2026, 1, 1, 12, 0);
      final result = AutoConnectPlanner.selectCandidate(
        autoConnectEnabled: true,
        activePeerId: null,
        lastManualPeerId: 'missing-peer',
        candidates: [
          DevicePresence(
            peerId: 'older',
            name: 'Older',
            host: '192.168.1.31',
            port: 10002,
            platform: 'linux',
            state: ConnectionLifecycleState.candidate,
            discovered: true,
            locallyTrusted: true,
            remotelyTrusted: true,
            lastSeenAt: now.subtract(const Duration(minutes: 10)),
          ),
          DevicePresence(
            peerId: 'newer',
            name: 'Newer',
            host: '192.168.1.32',
            port: 10002,
            platform: 'android',
            state: ConnectionLifecycleState.candidate,
            discovered: true,
            locallyTrusted: true,
            remotelyTrusted: true,
            lastSeenAt: now.subtract(const Duration(minutes: 1)),
          ),
          DevicePresence(
            peerId: 'untrusted',
            name: 'Untrusted',
            host: '192.168.1.33',
            port: 10002,
            platform: 'macos',
            state: ConnectionLifecycleState.candidate,
            discovered: true,
            locallyTrusted: true,
            remotelyTrusted: false,
            lastSeenAt: now,
          ),
        ],
      );

      expect(result?.peerId, 'newer');
    });

    test('returns null when auto-connect is disabled', () {
      final result = AutoConnectPlanner.selectCandidate(
        autoConnectEnabled: false,
        activePeerId: null,
        lastManualPeerId: null,
        candidates: [
          DevicePresence(
            peerId: 'peer-a',
            name: 'Peer A',
            host: '192.168.1.21',
            port: 10002,
            platform: 'linux',
            state: ConnectionLifecycleState.candidate,
            discovered: true,
            locallyTrusted: true,
            remotelyTrusted: true,
            lastSeenAt: DateTime(2026, 1, 1, 12),
          ),
        ],
      );

      expect(result, isNull);
    });
  });
}
