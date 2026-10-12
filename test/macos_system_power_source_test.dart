import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/system_power.dart';

void main() {
  final runner = File(
    'macos/Runner/MainFlutterWindow.swift',
  ).readAsStringSync();
  final bridge = runner.substring(
    runner.indexOf('final class SystemPowerBridge'),
    runner.indexOf('final class DesktopClipboardImagePlugin'),
  );

  test(
    'macOS runner reports sleep and wake on the channel Dart listens to',
    () {
      expect(runner, contains('"${SystemPowerBridge.channelName}"'));
      expect(
        runner,
        contains('SystemPowerBridge.shared.attach(channel: channel)'),
      );
      expect(bridge, contains('IORegisterForSystemPower('));
      expect(bridge, contains('channel.invokeMethod("willSleep"'));
      expect(bridge, contains('channel?.invokeMethod("didWake"'));

      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('SystemPowerBridge().attach();'));
    },
  );

  test('the message values match IOMessage.h', () {
    expect(
      runner,
      contains('systemPowerCanSleepMessage: UInt32 = 0xE000_0270'),
    );
    expect(
      runner,
      contains('systemPowerWillSleepMessage: UInt32 = 0xE000_0280'),
    );
    expect(
      runner,
      contains('systemPowerHasPoweredOnMessage: UInt32 = 0xE000_0300'),
    );
  });

  test('sleep is never left waiting on Dart', () {
    // An unanswered query or notice stalls the system's sleep for 30 seconds.
    final canSleep = bridge.substring(
      bridge.indexOf('case systemPowerCanSleepMessage:'),
      bridge.indexOf('case systemPowerWillSleepMessage:'),
    );
    expect(
      canSleep,
      contains('IOAllowPowerChange(rootDomain, notificationId)'),
    );

    final hold = bridge.substring(
      bridge.indexOf('private func holdSleep'),
      bridge.indexOf('@objc private func screensDidWake'),
    );
    expect(hold, contains('guard let channel = channel else {\n      allow()'));
    expect(hold, contains('invokeMethod("willSleep", arguments: nil) { _ in'));
    expect(
      hold,
      contains('asyncAfter(deadline: .now() + sleepHold, execute: allow)'),
    );
    expect(hold, contains('guard !allowed else {'));
  });

  test('a maintenance wake does not bring peers back', () {
    final poweredOn = bridge.substring(
      bridge.indexOf('case systemPowerHasPoweredOnMessage:'),
      bridge.indexOf('private func holdSleep'),
    );
    expect(poweredOn, contains('CGDisplayIsAsleep(CGMainDisplayID()) == 0'));
    expect(bridge, contains('NSWorkspace.screensDidWakeNotification'));
    expect(bridge, contains('guard asleep else {'));
  });
}
