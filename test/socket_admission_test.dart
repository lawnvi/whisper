import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/socket_admission.dart';

void main() {
  group('SocketAdmissionController', () {
    test('authenticated lease keeps chat capacity until socket closes', () {
      final admission = SocketAdmissionController(
        maxChatConnections: 2,
        maxPreAuthConnections: 2,
        maxPreAuthConnectionsPerIp: 2,
      );
      final now = DateTime.utc(2026, 7, 10);

      final first = admission.tryOpen('192.168.1.2', now).lease!;
      first.markAuthenticated();
      final second = admission.tryOpen('192.168.1.3', now).lease!;
      second.markAuthenticated();

      expect(
        admission.tryOpen('192.168.1.4', now).rejection,
        SocketAdmissionRejection.chatCapacity,
      );
      expect(admission.preAuthConnectionCount, 0);

      first.close();
      expect(admission.tryOpen('192.168.1.4', now).isAllowed, isTrue);
    });

    // Four addresses used to fill the pool and keep everyone out for 30 s.
    test('a full pre-auth pool evicts the oldest handshake that may go', () {
      final admission = SocketAdmissionController(
        maxChatConnections: 16,
        maxPreAuthConnections: 4,
        maxPreAuthConnectionsPerIp: 2,
      );
      final evicted = <String>[];
      AdmissionLease open(String address, String name, {bool may = true}) =>
          admission.tryOpenChat(address).lease!
            ..evictWith(() => evicted.add(name))
            ..evictableWhile(() => may);

      // A prompt waiting on the user is never evicted, nor is a lease that
      // gave no way to close it.
      open('10.0.0.1', 'prompt', may: false);
      admission.tryOpenChat('10.0.0.2');
      final oldest = open('10.0.0.3', 'oldest');
      open('10.0.0.4', 'newer');

      final fifth = admission.tryOpenChat('10.0.0.5').lease!;
      expect(evicted, <String>['oldest']);
      expect(oldest.isClosed, isTrue);

      // An address at its own limit evicts only its own oldest.
      fifth.close();
      open('10.0.0.4', 'same address');
      final last = admission.tryOpenChat('10.0.0.4').lease!;
      expect(evicted, <String>['oldest', 'newer']);

      // Authenticated leases have left the pool and are never evicted.
      last.markAuthenticated();
      expect(admission.preAuthConnectionCount, 3);
      expect(admission.tryOpenChat('10.0.0.7').isAllowed, isTrue);
      expect(evicted, <String>['oldest', 'newer']);
    });

    test('markAuthenticated only releases pre-auth and per-IP slots', () {
      final admission = SocketAdmissionController(
        maxChatConnections: 4,
        maxPreAuthConnections: 4,
        maxPreAuthConnectionsPerIp: 1,
      );
      final now = DateTime.utc(2026, 7, 10);
      final lease = admission.tryOpen('10.0.0.8', now).lease!;

      expect(
        admission.tryOpen('::ffff:10.0.0.8', now).rejection,
        SocketAdmissionRejection.preAuthPerIpCapacity,
      );

      lease.markAuthenticated();
      expect(admission.chatConnectionCount, 1);
      expect(admission.preAuthConnectionCount, 0);
      expect(admission.tryOpen('::ffff:10.0.0.8', now).isAllowed, isTrue);

      lease.close();
      lease.close();
      expect(admission.chatConnectionCount, 1);
    });

    test('normalizes mapped IPv4 and limits upgrades in a rolling minute', () {
      final admission = SocketAdmissionController(
        maxChatConnections: 64,
        maxPreAuthConnections: 64,
        maxPreAuthConnectionsPerIp: 64,
        maxUpgradeAttemptsPerMinutePerIp: 2,
      );
      final now = DateTime.utc(2026, 7, 10, 12);

      final first = admission.tryOpen('::ffff:192.168.3.7', now).lease!;
      first.close();
      final second = admission.tryOpen('192.168.3.7', now).lease!;
      second.close();
      expect(
        admission.tryOpen('::FFFF:C0A8:0307', now).rejection,
        SocketAdmissionRejection.upgradeRateLimit,
      );

      expect(
        admission
            .tryOpen('192.168.3.7', now.add(const Duration(seconds: 61)))
            .isAllowed,
        isTrue,
      );
    });

    test('shares upgrade rate limits without reserving chat capacity', () {
      final admission = SocketAdmissionController(
        maxChatConnections: 1,
        maxPreAuthConnections: 1,
        maxPreAuthConnectionsPerIp: 1,
        maxUpgradeAttemptsPerMinutePerIp: 2,
      );
      final now = DateTime.utc(2026, 7, 10, 12);

      expect(admission.tryUpgrade('192.168.3.7', now), isNull);
      expect(admission.tryUpgrade('::ffff:192.168.3.7', now), isNull);
      expect(
        admission.tryUpgrade('192.168.3.7', now),
        SocketAdmissionRejection.upgradeRateLimit,
      );
      expect(admission.chatConnectionCount, 0);
      expect(admission.preAuthConnectionCount, 0);
    });

    test('chat capacity can be reserved after a separate rate check', () {
      final admission = SocketAdmissionController(
        maxChatConnections: 1,
        maxPreAuthConnections: 1,
        maxPreAuthConnectionsPerIp: 1,
      );
      final now = DateTime.utc(2026, 7, 10, 12);

      expect(admission.tryUpgrade('10.0.0.8', now), isNull);
      final lease = admission.tryOpenChat('10.0.0.8').lease;

      expect(lease, isNotNull);
      expect(admission.chatConnectionCount, 1);
      expect(admission.preAuthConnectionCount, 1);
      expect(
        admission.tryOpenChat('10.0.0.9').rejection,
        SocketAdmissionRejection.chatCapacity,
      );
      lease!.close();
    });

    test(
      'default policy permits 32 authenticated chats and rejects the 33rd',
      () {
        final admission = SocketAdmissionController();
        final now = DateTime.utc(2026, 7, 10);

        for (var index = 0; index < 32; index += 1) {
          final lease = admission.tryOpen('10.0.0.${index + 1}', now).lease;
          expect(lease, isNotNull);
          lease!.markAuthenticated();
        }

        expect(
          admission.tryOpen('10.0.1.1', now).rejection,
          SocketAdmissionRejection.chatCapacity,
        );
      },
    );

    test('bounds tracked IPv6 sources and globally expires old attempts', () {
      final admission = SocketAdmissionController(
        maxChatConnections: 16,
        maxPreAuthConnections: 16,
        maxPreAuthConnectionsPerIp: 16,
        maxUpgradeAttemptsPerMinutePerIp: 16,
        maxTrackedUpgradeAddresses: 4,
        globalCleanupInterval: const Duration(seconds: 30),
      );
      final now = DateTime.utc(2026, 7, 10, 12);

      for (var index = 0; index < 4; index += 1) {
        admission.tryOpen('2001:db8::$index', now).lease!.close();
      }
      expect(admission.trackedUpgradeAddressCount, 4);
      expect(
        admission.tryOpen('2001:db8::ffff', now).rejection,
        SocketAdmissionRejection.upgradeRateLimit,
      );
      expect(admission.trackedUpgradeAddressCount, 4);

      final later = now.add(const Duration(seconds: 61));
      expect(admission.tryOpen('2001:db8::ffff', later).isAllowed, isTrue);
      expect(admission.trackedUpgradeAddressCount, 1);
    });
  });
}
