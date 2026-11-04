import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_background.dart';

void main() {
  test(
    'LAN listener and active session share one keep alive service',
    () async {
      var starts = 0;
      var stops = 0;
      final coordinator = AndroidBackgroundKeepAliveCoordinator(
        isAndroid: true,
        start: (_) async {
          starts += 1;
        },
        stop: () async {
          stops += 1;
        },
      );

      await coordinator.setReason(AndroidKeepAliveReason.lanServer, true);
      expect(starts, 0);
      expect(stops, 1);

      await coordinator.setEnabled(true);
      expect(coordinator.shouldRun, isTrue);
      expect(starts, 1);

      await coordinator.setReason(AndroidKeepAliveReason.activeSession, true);
      await coordinator.setReason(AndroidKeepAliveReason.activeSession, false);
      expect(coordinator.shouldRun, isTrue);
      expect(stops, 1, reason: 'session close must not stop the LAN listener');

      await coordinator.setReason(AndroidKeepAliveReason.lanServer, false);
      expect(coordinator.shouldRun, isFalse);
      expect(stops, 2);
    },
  );

  test(
    'keep alive operation queue recovers after native start failure',
    () async {
      var failStart = true;
      var stops = 0;
      final coordinator = AndroidBackgroundKeepAliveCoordinator(
        isAndroid: true,
        start: (_) async {
          if (failStart) {
            throw StateError('foreground start rejected');
          }
        },
        stop: () async {
          stops += 1;
        },
      );

      await coordinator.setReason(AndroidKeepAliveReason.lanServer, true);
      await expectLater(coordinator.setEnabled(true), throwsStateError);
      failStart = false;
      await coordinator.setEnabled(false);

      expect(stops, 2);
    },
  );
}
