import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/remote_input/mobile_control_keyboard.dart';
import 'package:whisper/remote_input/mobile_motion.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
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

  late List<(RemoteInputEventType, Map<String, dynamic>)> sent;
  late MobileInputController controller;
  setUp(() {
    sent = [];
    controller = MobileInputController((type, data) {
      sent.add((type, data));
      return sent.length;
    }, monotonicMicros: () => 0)..active = true;
  });
  tearDown(() {
    controller.dispose();
  });
  testWidgets('movement batches without crossing button boundaries', (
    tester,
  ) async {
    controller.move(const Offset(1, 2));
    controller.move(const Offset(3, 4));
    controller.move(const Offset(0.25, 0.5));
    expect(sent.single.$2, {'deltaX': 1.0, 'deltaY': 2.0});
    controller.button(0, true);
    controller.move(const Offset(5, 6));
    controller.button(0, false);
    expect(sent.map((e) => e.$1), [
      RemoteInputEventType.mouseMove,
      RemoteInputEventType.mouseMove,
      RemoteInputEventType.mouseButton,
      RemoteInputEventType.mouseMove,
      RemoteInputEventType.mouseButton,
    ]);
    expect(sent[1].$2, {'deltaX': 3.25, 'deltaY': 4.5});
    await tester.pump(const Duration(milliseconds: 20));
    expect(sent, hasLength(5));
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
}
