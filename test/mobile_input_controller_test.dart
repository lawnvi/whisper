import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/remote_input/mobile_control_keyboard.dart';
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
  test('idle bias correction removes drift without learning held motion', () {
    final mapper = MobileMotionMapper();
    MotionSample sample(int t, double yaw) =>
        MotionSample(t, [0, 0, yaw], [0, 0, 9.8]);
    for (var i = 0; i < 60; i++) {
      expect(mapper.add(sample(i * 10000, 0.025), enabled: false), Offset.zero);
    }
    var drift = Offset.zero;
    for (var i = 60; i < 1060; i++) {
      drift += mapper.add(sample(i * 10000, 0.025), enabled: true);
    }
    expect(drift.distance, lessThan(0.01));
    // A continuous deliberate slow turn must keep moving even after 50 samples.
    for (var i = 1060; i < 1160; i++) {
      mapper.add(sample(i * 10000, -0.03), enabled: true);
    }
    expect(
      mapper.add(sample(11600000, -0.03), enabled: true).dx,
      greaterThan(0.1),
    );
  });
  test('calibration rejects unstable, stale and duplicate samples', () {
    final mapper = MobileMotionMapper()..calibrate();
    for (var i = 0; i < 100; i++) {
      mapper.add(
        MotionSample(i * 10000, [0, 0, i.isEven ? 0.06 : -0.06], [0, 0, 9.8]),
        enabled: false,
      );
    }
    expect(mapper.calibrating, isTrue);
    for (var i = 0; i < 100; i++) {
      mapper.add(
        const MotionSample(1100000, [0, 0, 0.06], [0, 0, 9.8]),
        enabled: false,
      );
    }
    expect(mapper.calibrating, isTrue);
    for (var i = 0; i < 100; i++) {
      mapper.add(
        MotionSample(2000000 + i * 200000, [0, 0, 0.06], [0, 0, 9.8]),
        enabled: false,
      );
    }
    expect(mapper.calibrating, isTrue);
  });
  test(
    'slow wrist movement is precise while fast movement responds promptly',
    () {
      Offset travel(double yaw) {
        final mapper = MobileMotionMapper();
        var result = Offset.zero;
        for (var i = 0; i <= 100; i++) {
          result += mapper.add(
            MotionSample(i * 10000, [0, 0, -yaw], [0, 0, 9.8]),
            enabled: true,
          );
        }
        return result;
      }

      // A small 0.05-radian turn travels 15–30px, not the previous ~45px.
      expect(travel(0.05).dx, inInclusiveRange(15, 30));
      expect(travel(1).dx, inInclusiveRange(1100, 1200));
      final mapper = MobileMotionMapper();
      mapper.add(const MotionSample(0, [0, 0, -1], [0, 0, 9.8]), enabled: true);
      final first = mapper.add(
        const MotionSample(10000, [0, 0, -1], [0, 0, 9.8]),
        enabled: true,
      );
      expect(first.dx, greaterThan(6));
      expect(
        mapper.add(
          const MotionSample(20000, [0, 0, 0], [0, 0, 9.8]),
          enabled: true,
        ),
        Offset.zero,
      );
    },
  );
  test('alternating hand tremor has bounded cursor excursion', () {
    final mapper = MobileMotionMapper();
    var position = Offset.zero;
    var furthest = 0.0;
    for (var i = 0; i <= 1000; i++) {
      position += mapper.add(
        MotionSample(i * 10000, [0, 0, i.isEven ? 0.015 : -0.015], [0, 0, 9.8]),
        enabled: true,
      );
      if (position.distance > furthest) furthest = position.distance;
    }
    expect(furthest, lessThan(1));
  });
  test('pointer and scroll speeds scale independently without reordering', () {
    final sent = <(RemoteInputEventType, Map<String, dynamic>)>[];
    final input = MobileInputController((type, payload) {
      sent.add((type, payload));
      return sent.length;
    })..active = true;
    input.setPointerSpeed(2);
    input.setScrollSpeed(0.5);
    input.move(const Offset(3, 4));
    input.button(0, true);
    input.move(const Offset(0, 10), scroll: true);
    input.button(0, false);
    expect(sent.map((v) => v.$1), [
      RemoteInputEventType.mouseMove,
      RemoteInputEventType.mouseButton,
      RemoteInputEventType.mouseWheel,
      RemoteInputEventType.mouseButton,
    ]);
    expect(sent[0].$2['deltaX'], 6);
    expect(sent[0].$2['deltaY'], 8);
    expect(sent[2].$2['scrollDeltaY'], 5);
    input.move(const Offset(3, 4), fromMotion: true);
    input.flush();
    expect(sent.last.$2['deltaX'], 3);
    input.dispose();
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
  test('touchpad tap cannot release a separately held left button', () {
    controller.button(0, true);
    controller.click();
    expect(sent, hasLength(1));
    controller.button(0, false);
    expect(sent.map((event) => event.$2['down']), [true, false]);
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
  test(
    'all ASCII punctuation has a key mapping and balanced Shift override',
    () {
      final punctuation = [
        for (var code = 33; code < 127; code++)
          if (!RegExp(r'[a-zA-Z0-9]').hasMatch(String.fromCharCode(code)))
            String.fromCharCode(code),
      ];
      expect(mobileControlSymbols.keys, unorderedEquals(punctuation));
      for (final symbol in mobileControlSymbols.values) {
        sent.clear();
        controller.toggleModifier('meta');
        controller.toggleModifier('shift');
        controller.key(symbol.$1, shift: symbol.$2);
        expect(
          sent
              .where((e) => e.$2['keySemantic'] == 'shift')
              .map((e) => e.$2['down']),
          symbol.$2 ? [true, false] : isEmpty,
        );
        expect(
          sent.map((e) => e.$2['down']).where((v) => v == true).length,
          sent.map((e) => e.$2['down']).where((v) => v == false).length,
        );
        expect(controller.modifiers, isEmpty);
      }
    },
  );
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
  testWidgets(
    'latched motion continues without a touch and pause releases held input',
    (tester) async {
      var micros = 0;
      final input = MobileInputController((type, data) {
        sent.add((type, data));
        return sent.length;
      }, monotonicMicros: () => micros)..active = true;
      addTearDown(input.dispose);
      input.toggleMotion();
      micros = 80000;
      input.sample(MotionSample(micros, [0, 0, 1], [0, 0, 9.8]));
      micros = 90000;
      input.sample(MotionSample(micros, [0, 0, 1], [0, 0, 9.8]));
      input.flush();
      expect(sent.single.$1, RemoteInputEventType.mouseMove);
      input.button(0, true);
      input.toggleMotion();
      expect(input.moving, isFalse);
      expect(sent.last.$2, {'button': 0, 'down': false});
      final count = sent.length;
      micros = 300000;
      input.sample(MotionSample(micros, [0, 0, 1], [0, 0, 9.8]));
      micros = 310000;
      input.sample(MotionSample(micros, [0, 0, 1], [0, 0, 9.8]));
      input.flush();
      expect(sent.length, count);
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
