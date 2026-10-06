import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/remote_input/mobile_motion.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  test('motion uses gravity yaw and horizontal pitch without roll', () {
    MotionSample sample(int t, List<double> w) =>
        MotionSample(t, w, [0, 0, 9.8]);
    final mapper = MobileMotionMapper();
    expect(mapper.add(sample(0, [0, 1, 0]), enabled: true), Offset.zero);
    expect(mapper.add(sample(10000, [0, 1, 0]), enabled: true), Offset.zero);
    final yaw = mapper.add(sample(20000, [0, 0, -1]), enabled: true);
    expect(yaw.dx, greaterThan(0));
    expect(yaw.dy, 0);
    final pitch = mapper.add(sample(30000, [1, 0, 0]), enabled: true);
    expect(pitch.dy, lessThan(0));
    expect(pitch.dx, 0);
  });
  test(
    'stationary samples, pause, stale time and invalid values never jump',
    () {
      final mapper = MobileMotionMapper();
      MotionSample sample(int t, double v) =>
          MotionSample(t, [0, 0, v], [0, 0, 9.8]);
      mapper.add(sample(0, 1), enabled: true);
      expect(mapper.add(sample(10000, 0.005), enabled: true), Offset.zero);
      mapper.add(sample(20000, 1), enabled: true);
      expect(mapper.add(sample(30000, 0), enabled: true), Offset.zero);
      mapper.add(sample(40000, 1), enabled: false);
      expect(mapper.add(sample(90000, 1), enabled: true), Offset.zero);
      expect(mapper.add(sample(300000, 1), enabled: true), Offset.zero);
      expect(
        mapper.add(sample(300001, double.nan), enabled: true),
        Offset.zero,
      );
      expect(mapper.add(sample(300000, 1), enabled: true), Offset.zero);
      expect(mapper.add(sample(200000, 1), enabled: true), Offset.zero);
    },
  );
  test('calibration removes sensor bias and rejects moving calibration', () {
    final mapper = MobileMotionMapper()..calibrate();
    for (var i = 0; i < 50; i++) {
      mapper.add(
        MotionSample(i * 10000, [0, 0, 0.06], [0, 0, 9.8]),
        enabled: false,
      );
    }
    expect(mapper.calibrating, isFalse);
    mapper.add(
      const MotionSample(500000, [0, 0, 0.06], [0, 0, 9.8]),
      enabled: true,
    );
    expect(
      mapper.add(
        const MotionSample(510000, [0, 0, 0.06], [0, 0, 9.8]),
        enabled: true,
      ),
      Offset.zero,
    );
    mapper.calibrate();
    for (var i = 0; i < 100; i++) {
      mapper.add(
        MotionSample(i * 10000, [0, 0, 1], [0, 0, 9.8]),
        enabled: false,
      );
    }
    expect(mapper.calibrating, isTrue);
    mapper.cancelCalibration();
  });
  test(
    'keyboard lookup covers full keys with independent modifier mappings',
    () {
      final semantics = [
        for (final c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) 'key$c',
        for (var i = 0; i < 10; i++) 'digit$i',
        for (var i = 1; i <= 12; i++) 'f$i',
        'escape',
        'tab',
        'capsLock',
        'space',
        'enter',
        'backspace',
        'delete',
        'arrowLeft',
        'arrowUp',
        'arrowRight',
        'arrowDown',
        'home',
        'end',
        'pageUp',
        'pageDown',
        'meta',
        'control',
        'alt',
        'shift',
      ];
      expect(
        semantics.map((s) => remoteInputKeyCodes(s).macKeyCode).toSet(),
        hasLength(semantics.length),
      );
      expect(remoteInputKeyCodes('f12').macKeyCode, 111);
      expect(() => remoteInputKeyCodes('unknown'), throwsArgumentError);
    },
  );

  late List<(RemoteInputEventType, Map<String, dynamic>)> sent;
  late MobileInputController controller;
  setUp(() {
    sent = [];
    controller = MobileInputController((type, data) {
      sent.add((type, data));
      return sent.length;
    })..active = true;
  });
  tearDown(() {
    controller.dispose();
  });
  testWidgets('movement batches without crossing button boundaries', (
    tester,
  ) async {
    controller.move(const Offset(1, 2));
    controller.move(const Offset(3, 4));
    expect(sent, isEmpty);
    controller.button(0, true);
    controller.move(const Offset(5, 6));
    controller.button(0, false);
    expect(sent.map((e) => e.$1), [
      RemoteInputEventType.mouseMove,
      RemoteInputEventType.mouseButton,
      RemoteInputEventType.mouseMove,
      RemoteInputEventType.mouseButton,
    ]);
    expect(sent.first.$2, {'deltaX': 4.0, 'deltaY': 6.0});
    await tester.pump(const Duration(milliseconds: 20));
    expect(sent, hasLength(4));
  });
  test('modifiers remain local until a key and unwind in reverse order', () {
    controller.toggleModifier('meta');
    controller.toggleModifier('shift');
    expect(sent, isEmpty);
    controller.key('keyZ');
    expect(sent.map((e) => (e.$2['keySemantic'], e.$2['down'])), [
      ('meta', true),
      ('shift', true),
      ('keyZ', true),
      ('keyZ', false),
      ('shift', false),
      ('meta', false),
    ]);
    expect(controller.modifiers, isEmpty);
  });
  testWidgets(
    'repeat starts at 400ms and reset releases drag and cancels repeat',
    (tester) async {
      controller.beginRepeat('backspace');
      await tester.pump(const Duration(milliseconds: 399));
      expect(sent, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(sent, hasLength(2));
      await tester.pump(const Duration(milliseconds: 60));
      expect(sent, hasLength(4));
      controller.button(0, true);
      controller.reset();
      expect(sent.last.$2, {'button': 0, 'down': false});
      final count = sent.length;
      await tester.pump(const Duration(seconds: 1));
      expect(sent, hasLength(count));
    },
  );
  testWidgets('inactive controller sends no packets', (tester) async {
    controller.active = false;
    controller.move(const Offset(1, 2));
    controller.button(0, true);
    controller.key('keyA');
    controller.beginRepeat('backspace');
    await tester.pump(const Duration(seconds: 1));
    expect(sent, isEmpty);
  });
  testWidgets('drag suppresses the first 80ms and release resets motion', (
    tester,
  ) async {
    var micros = 0;
    final drag = MobileInputController((type, data) {
      sent.add((type, data));
      return sent.length;
    }, monotonicMicros: () => micros)..active = true;
    addTearDown(drag.dispose);
    drag.button(0, true);
    void sample() => drag.sample(MotionSample(micros, [1, 0, 0], [0, 0, 9.8]));
    sample();
    micros = 79000;
    sample();
    drag.flush();
    expect(sent, hasLength(1));
    micros = 80000;
    sample();
    micros = 90000;
    sample();
    drag.flush();
    expect(sent.last.$1, RemoteInputEventType.mouseMove);
    expect(sent.last.$2['deltaY'], lessThan(0));
    drag.button(0, false);
    final count = sent.length;
    micros = 200000;
    sample();
    micros = 210000;
    sample();
    drag.flush();
    expect(sent, hasLength(count));
    expect(sent.last.$2, {'button': 0, 'down': false});
  });
}
