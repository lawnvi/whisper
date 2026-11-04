import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/scrcpy/scrcpy_input_mapper.dart';
import 'package:whisper/window_stream/android/scrcpy/scrcpy_protocol.dart';
import 'package:whisper/window_stream/core/window_input_event.dart';

ScrcpyInputMapper _mapper({ScrollMode mode = ScrollMode.wheel}) {
  return ScrcpyInputMapper(scrollMode: mode)
    ..frameWidth = 1080
    ..frameHeight = 2400;
}

int _type(Uint8List bytes) => bytes[0];

void main() {
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

  group('keys', () {
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

    test('non-ASCII text and pastes go through the clipboard', () {
      final mapper = _mapper();
      final chinese = mapper.map(const TextInput('你好'));
      expect(_type(chinese.single.bytes), ScrcpyControl.typeSetClipboard);
      expect(chinese.single.bytes[9], 1, reason: 'paste flag');
      final paste = mapper.map(const TextInput('abc', paste: true));
      expect(_type(paste.single.bytes), ScrcpyControl.typeSetClipboard);
    });
  });
}
