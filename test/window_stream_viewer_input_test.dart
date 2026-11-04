import 'package:flutter/services.dart' hide TextInput;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/window_stream/viewer/viewer_keyboard.dart';
import 'package:whisper/page/window_stream/viewer/viewer_pointer_input.dart';
import 'package:whisper/window_stream/core/hid_mac_keycodes.dart';
import 'package:whisper/window_stream/core/window_input_event.dart';

import '../script/gen_wsn_keymap.dart';

/// "Key A" → keyA, "Numpad Decimal" → numpadDecimal, "F12" → f12.
String _camel(String debugName) {
  final words = debugName.split(' ');
  return [
    words.first.toLowerCase(),
    for (final word in words.skip(1))
      word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1),
  ].join();
}

String _describe(WindowInputEvent event) => switch (event) {
  PointerInput(:final action, :final button, :final x, :final y) =>
    'pointer ${action.name} ${button.name} '
        '${x.toStringAsFixed(2)},${y.toStringAsFixed(2)}',
  ScrollInput(:final phase) => 'scroll ${phase.name}',
  KeyInput(:final down, :final macKeyCode, :final modifiers) =>
    'key ${down ? 'down' : 'up'} $macKeyCode m$modifiers',
  TextInput(:final text) => 'text $text',
  NavigationInput() => 'navigation',
};

/// A 400×300 listener whose picture is its 200×100 middle.
class _Harness extends StatefulWidget {
  const _Harness(this.events);

  final List<WindowInputEvent> events;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with TickerProviderStateMixin {
  late final input = ViewerPointerInput(send: widget.events.add, vsync: this)
    ..picture = const Rect.fromLTWH(100, 100, 200, 100);

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 300,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: input.onPointerDown,
            onPointerMove: input.onPointerMove,
            onPointerUp: input.onPointerUp,
            onPointerCancel: input.onPointerCancel,
            onPointerHover: input.onPointerHover,
            onPointerSignal: input.onPointerSignal,
            onPointerPanZoomStart: input.onPointerPanZoomStart,
            onPointerPanZoomUpdate: input.onPointerPanZoomUpdate,
            onPointerPanZoomEnd: input.onPointerPanZoomEnd,
          ),
        ),
      ),
    );
  }
}

void main() {
  group('HID usages to Mac key codes', () {
    test('agree with the window-stream key map for every key it knows', () {
      final byName = {
        for (final key in PhysicalKeyboardKey.knownPhysicalKeys)
          if (key.debugName != null) _camel(key.debugName!): key,
      };
      var checked = 0;
      for (final row in resolveWsnKeys()) {
        final physical = byName[row.name];
        if (physical == null) {
          continue;
        }
        expect(
          HidMacKeyCodes.macKeyCode(physical.usbHidUsage),
          row.mac,
          reason: row.name,
        );
        checked++;
      }
      expect(checked, greaterThan(100));
    });
  });

  group('hardware keys', () {
    KeyEvent down(PhysicalKeyboardKey key, {String? character}) => KeyDownEvent(
      physicalKey: key,
      logicalKey: LogicalKeyboardKey.keyA,
      character: character,
      timeStamp: Duration.zero,
    );
    KeyEvent up(PhysicalKeyboardKey key) => KeyUpEvent(
      physicalKey: key,
      logicalKey: LogicalKeyboardKey.keyA,
      timeStamp: Duration.zero,
    );
    List<String>? route(
      HardwareKeyRouter router,
      KeyEvent event, {
      int modifiers = 0,
      bool textField = true,
      bool composing = false,
    }) => router
        .route(
          event,
          modifiers: modifiers,
          textField: textField,
          composing: composing,
        )
        ?.map(_describe)
        .toList();

    test('shortcuts go as keys, with the up following its down', () {
      final router = HardwareKeyRouter();
      const command = InputModifiers.command;
      expect(
        route(
          router,
          down(PhysicalKeyboardKey.keyA, character: 'a'),
          modifiers: command,
        ),
        ['key down 0 m8'],
      );
      // ⌘ let go before A: A still comes up over there, without ⌘.
      expect(route(router, up(PhysicalKeyboardKey.keyA)), ['key up 0 m0']);
      expect(router.hasKeysDown, isFalse);
      expect(
        route(
          router,
          down(PhysicalKeyboardKey.keyV, character: 'v'),
          modifiers: InputModifiers.control | InputModifiers.shift,
        ),
        ['key down 9 m3'],
      );
    });

    test('while the input method composes, every key is its own', () {
      final router = HardwareKeyRouter();
      expect(
        route(router, down(PhysicalKeyboardKey.enter), composing: true),
        isNull,
      );
      expect(
        route(router, down(PhysicalKeyboardKey.arrowDown), composing: true),
        isNull,
      );
      expect(route(router, up(PhysicalKeyboardKey.enter)), isNull);
    });

    test('everything held comes up when the viewer lets go', () {
      final router = HardwareKeyRouter();
      route(router, down(PhysicalKeyboardKey.arrowLeft));
      route(
        router,
        down(PhysicalKeyboardKey.keyS, character: 's'),
        modifiers: InputModifiers.command,
      );
      expect(router.releaseAll().map(_describe), [
        'key up 1 m0',
        'key up 123 m0',
      ]);
      expect(router.releaseAll(), isEmpty);
    });
  });

  group('the input method buffer', () {
    TextEditingValue value(String text, {TextRange? composing}) =>
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
          composing: composing ?? TextRange.empty,
        );
    const s = ImeTextBuffer.sentinel;

    test('a draft is shown, not sent, until it commits', () {
      final draft = value(
        '${s}ni hao',
        composing: const TextRange(start: 1, end: 7),
      );
      expect(ImeTextBuffer.composingOf(draft), 'ni hao');
      final pending = ImeTextBuffer.consume(draft);
      expect(pending.events, isEmpty);
      expect(pending.reset, isFalse);
      final committed = ImeTextBuffer.consume(value('$s你好'));
      expect(committed.events.map(_describe), ['text 你好']);
      expect(ImeTextBuffer.composingOf(value('$s你好')), '');
    });

    test('the untouched field sends nothing', () {
      final result = ImeTextBuffer.consume(ImeTextBuffer.empty);
      expect(result.events, isEmpty);
      expect(result.reset, isFalse);
    });
  });
}
