import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_background.dart';

void main() {
  test('keep alive notification serializes progress for native Android', () {
    const notification = AndroidKeepAliveNotification(
      title: 'Whisper',
      description: 'Sending file 42%',
      progress: 42,
    );

    final arguments = notification.toChannelArguments();
    expect(arguments['title'], 'Whisper');
    expect(arguments['description'], 'Sending file 42%');
    expect(arguments['progress'], 42);
    expect(arguments['indeterminateProgress'], false);
    // channel 名/描述取自 l10n(测试环境回落 en),仅断言非空透传。
    expect(arguments['channelName'], isNotEmpty);
    expect(arguments['channelDescription'], isNotEmpty);
  });

  test('keep alive notification clamps progress to Android bounds', () {
    const notification = AndroidKeepAliveNotification(
      title: 'Whisper',
      description: 'Sending file',
      progress: 142,
      indeterminateProgress: true,
    );

    expect(notification.toChannelArguments()['progress'], 100);
    expect(notification.toChannelArguments()['indeterminateProgress'], true);
  });

  test('LAN listener and active session share one keep alive service',
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
  });

  test('keep alive operation queue recovers after native start failure',
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
  });
}
