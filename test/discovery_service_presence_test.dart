import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/discovery_service_presence.dart';

void main() {
  group('DiscoveryServicePresenceTracker', () {
    test('uses the resolved mapping when a lost event has no TXT peer id', () {
      final tracker = DiscoveryServicePresenceTracker();
      tracker.resolved(serviceKey: 'whisper-peer-a|_whisper._tcp', peerId: 'a');

      final loss = tracker.lost(
        serviceKey: 'whisper-peer-a|_whisper._tcp',
      );

      expect(loss?.peerId, 'a');
      expect(loss?.stillDiscovered, isFalse);
    });

    test('keeps a peer nearby while another service instance remains', () {
      final tracker = DiscoveryServicePresenceTracker();
      tracker
        ..resolved(serviceKey: 'peer-a-v4', peerId: 'a')
        ..resolved(serviceKey: 'peer-a-v6', peerId: 'a');

      final firstLoss = tracker.lost(serviceKey: 'peer-a-v4');
      final finalLoss = tracker.lost(serviceKey: 'peer-a-v6');

      expect(firstLoss?.stillDiscovered, isTrue);
      expect(finalLoss?.stillDiscovered, isFalse);
    });

    test('accepts a peer id hint for an untracked lost event', () {
      final tracker = DiscoveryServicePresenceTracker();

      final loss = tracker.lost(
        serviceKey: 'unknown',
        peerIdHint: 'peer-a',
      );

      expect(loss?.peerId, 'peer-a');
      expect(loss?.stillDiscovered, isFalse);
    });
  });
}
