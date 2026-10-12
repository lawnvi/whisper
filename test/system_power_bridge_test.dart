import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/system_power.dart';

void main() {
  test('sleep is answered only after peers have been let go', () async {
    final released = Completer<void>();
    final bridge = SystemPowerBridge(
      prepareForSleep: () => released.future,
      resumeFromSleep: () {},
    );

    var answered = false;
    final answer = bridge
        .handle(const MethodCall('willSleep'))
        .then((_) => answered = true);
    await pumpEventQueue();
    expect(answered, isFalse);

    released.complete();
    await answer;
    expect(answered, isTrue);
    await bridge.handle(const MethodCall('didWake'));
  });

  test('waking takes peers back once', () async {
    var resumed = 0;
    final bridge = SystemPowerBridge(
      prepareForSleep: () async {},
      resumeFromSleep: () => resumed += 1,
      missedWakeTimeout: const Duration(milliseconds: 20),
    );

    await bridge.handle(const MethodCall('willSleep'));
    expect(resumed, 0);

    await bridge.handle(const MethodCall('didWake'));
    expect(resumed, 1);

    await Future<void>.delayed(bridge.missedWakeTimeout * 3);
    expect(resumed, 1);
  });

  test('peers are taken back even if the wake notice never arrives', () async {
    var resumed = 0;
    final bridge = SystemPowerBridge(
      prepareForSleep: () async {},
      resumeFromSleep: () => resumed += 1,
      missedWakeTimeout: const Duration(milliseconds: 20),
    );

    await bridge.handle(const MethodCall('willSleep'));
    expect(resumed, 0);

    await Future<void>.delayed(bridge.missedWakeTimeout * 3);
    expect(resumed, 1);
  });

  test('unknown calls are reported as unimplemented', () {
    final bridge = SystemPowerBridge(
      prepareForSleep: () async {},
      resumeFromSleep: () {},
    );

    expect(
      bridge.handle(const MethodCall('didDim')),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
