import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/android_keycodes.dart';
import 'package:whisper/window_stream/android/scrcpy/scrcpy_input_mapper.dart';
import 'package:whisper/window_stream/android/scrcpy/scrcpy_protocol.dart';
import 'package:whisper/window_stream/core/window_input_event.dart';
import 'package:whisper/window_stream/pipeline/native_input_decoder.dart';

ScrcpyInputMapper _mapper({ScrollMode mode = ScrollMode.wheel}) {
  return ScrcpyInputMapper(scrollMode: mode)
    ..frameWidth = 1080
    ..frameHeight = 2400;
}

int _type(Uint8List bytes) => bytes[0];

void main() {
  test('primary pointer becomes a finger touch at frame pixels', () {
    final out = _mapper().map(
      const PointerInput(action: PointerAction.down, x: 0.5, y: 1),
    );
    final data = ByteData.sublistView(out.single.bytes);
    expect(_type(out.single.bytes), ScrcpyControl.typeInjectTouch);
    expect(data.getInt64(2), ScrcpyControl.pointerIdGenericFinger);
    expect(data.getInt32(10), 540);
    expect(data.getInt32(14), 2399);
  });

  test('pointer moves with no button down (hover) never touch the phone', () {
    final mapper = _mapper();
    expect(
      mapper.map(
        const PointerInput(action: PointerAction.move, x: 0.3, y: 0.3),
      ),
      isEmpty,
    );
    expect(
      mapper.map(const PointerInput(action: PointerAction.up, x: 0.3, y: 0.3)),
      isEmpty,
    );
    expect(
      mapper.map(
        const PointerInput(action: PointerAction.down, x: 0.3, y: 0.3),
      ),
      hasLength(1),
    );
    expect(
      mapper.map(
        const PointerInput(action: PointerAction.move, x: 0.4, y: 0.4),
      ),
      hasLength(1),
    );
    expect(
      mapper.map(const PointerInput(action: PointerAction.up, x: 0.4, y: 0.4)),
      hasLength(1),
    );
    expect(
      mapper.map(
        const PointerInput(action: PointerAction.move, x: 0.5, y: 0.5),
      ),
      isEmpty,
    );
  });

  test('nothing is sent before the frame size is known', () {
    final mapper = ScrcpyInputMapper();
    expect(
      mapper.map(
        const PointerInput(action: PointerAction.down, x: 0.1, y: 0.1),
      ),
      isEmpty,
    );
  });

  test('secondary button is back', () {
    final mapper = _mapper();
    final down = mapper.map(
      const PointerInput(
        action: PointerAction.down,
        x: 0,
        y: 0,
        button: PointerButton.secondary,
      ),
    );
    expect(down.single.bytes, [
      ScrcpyControl.typeBackOrScreenOn,
      ScrcpyControl.actionDown,
    ]);
  });

  test('trackpad scroll in wheel mode converts to notches', () {
    final out = _mapper().map(
      const ScrollInput(x: 0.5, y: 0.5, dx: 0, dy: 0.066, precise: true),
    );
    final data = ByteData.sublistView(out.single.bytes);
    expect(_type(out.single.bytes), ScrcpyControl.typeInjectScroll);
    // One notch up = 1/16 of the i16 range.
    expect(data.getInt16(15), closeTo(0x8000 / 16, 2));
  });

  test('trackpad scroll in drag mode follows the fingers and lifts on end', () {
    final mapper = _mapper(mode: ScrollMode.drag);
    final began = mapper.map(
      const ScrollInput(
        x: 0.5,
        y: 0.5,
        dx: 0,
        dy: 0,
        phase: ScrollPhase.began,
        precise: true,
      ),
    );
    expect(began.map((m) => m.bytes[1]).toList(), [ScrcpyControl.actionDown]);
    final moved = mapper.map(
      const ScrollInput(
        x: 0.5,
        y: 0.5,
        dx: 0,
        dy: -0.1,
        phase: ScrollPhase.changed,
        precise: true,
      ),
    );
    final moveData = ByteData.sublistView(moved.single.bytes);
    expect(moved.single.bytes[1], ScrcpyControl.actionMove);
    expect(moveData.getInt32(14), (0.4 * 2399).round());
    final ended = mapper.map(
      const ScrollInput(
        x: 0.5,
        y: 0.5,
        dx: 0,
        dy: 0,
        phase: ScrollPhase.ended,
        precise: true,
      ),
    );
    expect(ended.single.bytes[1], ScrcpyControl.actionUp);
    // Momentum after lift-off is ignored: the app flings by itself.
    expect(
      mapper.map(
        const ScrollInput(
          x: 0.5,
          y: 0.5,
          dx: 0,
          dy: -0.2,
          momentumPhase: ScrollPhase.changed,
          precise: true,
        ),
      ),
      isEmpty,
    );
  });

  test('mouse wheel in drag mode becomes one timed swipe', () {
    final out = _mapper(
      mode: ScrollMode.drag,
    ).map(const ScrollInput(x: 0.5, y: 0.5, dx: 0, dy: -1));
    expect(out.first.bytes[1], ScrcpyControl.actionDown);
    expect(out.last.bytes[1], ScrcpyControl.actionUp);
    expect(out.last.delay, greaterThan(Duration.zero));
    final startY = ByteData.sublistView(out.first.bytes).getInt32(14);
    final endY = ByteData.sublistView(out.last.bytes).getInt32(14);
    expect(endY, lessThan(startY), reason: 'wheel down means next: swipe up');
  });

  group('keys', () {
    test('escape is back, return is enter, with key up', () {
      final mapper = _mapper();
      final esc = mapper.map(const KeyInput(down: true, macKeyCode: 53));
      expect(
        ByteData.sublistView(esc.single.bytes).getInt32(2),
        AndroidKeycodes.back,
      );
      final enterUp = mapper.map(const KeyInput(down: false, macKeyCode: 36));
      expect(enterUp.single.bytes[1], ScrcpyControl.actionUp);
      expect(
        ByteData.sublistView(enterUp.single.bytes).getInt32(2),
        AndroidKeycodes.enter,
      );
    });

    test('printable ASCII is injected as text on key down only', () {
      final mapper = _mapper();
      final down = mapper.map(
        const KeyInput(down: true, macKeyCode: 0, characters: 'a'),
      );
      expect(_type(down.single.bytes), ScrcpyControl.typeInjectText);
      expect(utf8.decode(down.single.bytes.sublist(5)), 'a');
      expect(
        mapper.map(const KeyInput(down: false, macKeyCode: 0, characters: 'a')),
        isEmpty,
      );
    });

    test('command shortcuts map to ctrl on Android', () {
      final out = _mapper().map(
        const KeyInput(
          down: true,
          macKeyCode: 8,
          characters: 'c',
          modifiers: InputModifiers.command,
        ),
      );
      final data = ByteData.sublistView(out.single.bytes);
      expect(data.getInt32(2), AndroidKeycodes.c);
      expect(data.getInt32(10), ScrcpyControl.metaCtrl);
    });

    test('non-ASCII text and pastes go through the clipboard', () {
      final mapper = _mapper();
      final chinese = mapper.map(const TextInput('你好'));
      expect(_type(chinese.single.bytes), ScrcpyControl.typeSetClipboard);
      expect(chinese.single.bytes[9], 1, reason: 'paste flag');
      final paste = mapper.map(const TextInput('abc', paste: true));
      expect(_type(paste.single.bytes), ScrcpyControl.typeSetClipboard);
    });
  });

  test('native input decoder maps scalar callback arguments', () {
    final scroll = NativeInputDecoder.decode(
      kind: 4,
      code: 0,
      modifiers: 0,
      x: 0.2,
      y: 0.3,
      dx: 0,
      dy: 0.1,
      phase: 4 | (2 << 8) | (1 << 16),
    );
    expect(scroll, isA<ScrollInput>());
    scroll as ScrollInput;
    expect(scroll.phase, ScrollPhase.changed);
    expect(scroll.momentumPhase, ScrollPhase.stationary);
    expect(scroll.precise, isTrue);

    final paste = NativeInputDecoder.decode(
      kind: 7,
      code: 1,
      modifiers: 0,
      x: 0,
      y: 0,
      dx: 0,
      dy: 0,
      phase: 0,
      text: 'x',
    );
    expect(paste, isA<TextInput>().having((e) => e.paste, 'paste', isTrue));

    final right = NativeInputDecoder.decode(
      kind: 1,
      code: 1,
      modifiers: 0,
      x: 0,
      y: 0,
      dx: 0,
      dy: 0,
      phase: 0,
    );
    expect(
      right,
      isA<PointerInput>().having(
        (e) => e.button,
        'button',
        PointerButton.secondary,
      ),
    );
  });
}
