import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/connection_coordinator.dart';

void main() {
  test('new attempts invalidate only the older attempt for the same target',
      () {
    final tracker = ConnectionAttemptTracker();
    final firstA = tracker.begin('peer-a');
    final firstB = tracker.begin('peer-b');
    final secondA = tracker.begin('peer-a');

    expect(tracker.isCurrent('peer-a', firstA), isFalse);
    expect(tracker.isCurrent('peer-a', secondA), isTrue);
    expect(tracker.isCurrent('peer-b', firstB), isTrue);
  });

  test('complete and cancellation reject late callbacks', () {
    final tracker = ConnectionAttemptTracker();
    final completed = tracker.begin('completed');
    final cancelled = tracker.begin('cancelled');
    final disposed = tracker.begin('disposed');

    expect(tracker.complete('completed', completed), isTrue);
    expect(tracker.complete('completed', completed), isFalse);
    tracker.cancel('cancelled');
    expect(tracker.isCurrent('cancelled', cancelled), isFalse);
    tracker.cancelAll();
    expect(tracker.isCurrent('disposed', disposed), isFalse);
  });

  test('background reconnect records a peer without changing selection', () {
    final coordinator = ConnectionCoordinator();
    coordinator.markDisconnected();
    coordinator.markConnected(_device('peer-b'));

    coordinator.markConnected(_device('peer-a'), select: false);

    expect(coordinator.snapshot.activePeerId, 'peer-b');
    expect(coordinator.snapshot.connectedPeerIds,
        containsAll(['peer-a', 'peer-b']));
    coordinator.markDisconnected();
  });
}

DeviceData _device(String uid) => DeviceData(
      id: 0,
      uid: uid,
      name: uid,
      host: '192.168.1.10',
      port: 10002,
      password: '',
      platform: 'test',
      isServer: false,
      online: true,
      clipboard: true,
      auth: true,
      lastTime: 1,
      around: true,
    );
