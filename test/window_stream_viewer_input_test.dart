import 'package:flutter/gestures.dart';
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

    test('arrows, modifiers and other pages', () {
      int? mac(PhysicalKeyboardKey key) =>
          HidMacKeyCodes.macKeyCode(key.usbHidUsage);
      expect(mac(PhysicalKeyboardKey.arrowLeft), 123);
      expect(mac(PhysicalKeyboardKey.arrowRight), 124);
      expect(mac(PhysicalKeyboardKey.arrowDown), 125);
      expect(mac(PhysicalKeyboardKey.arrowUp), 126);
      expect(mac(PhysicalKeyboardKey.metaLeft), 55);
      expect(mac(PhysicalKeyboardKey.controlRight), 62);
      expect(mac(PhysicalKeyboardKey.intlBackslash), 10);
      expect(HidMacKeyCodes.macKeyCodeForUsage(0x04), 0);
      expect(HidMacKeyCodes.macKeyCode(0x04), isNull);
      // Fn and consumer keys are not keyboard-page keys.
      expect(mac(PhysicalKeyboardKey.fn), isNull);
      expect(HidMacKeyCodes.keyboardUsage(0x000c00e9), isNull);
    });
  });

  group('hardware keys', () {
    KeyEvent down(PhysicalKeyboardKey key, {String? character}) => KeyDownEvent(
      physicalKey: key,
      logicalKey: LogicalKeyboardKey.keyA,
      character: character,
      timeStamp: Duration.zero,
    );
    KeyEvent repeat(PhysicalKeyboardKey key, {String? character}) =>
        KeyRepeatEvent(
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

    test('typing goes to the text system, or out as text without one', () {
      final router = HardwareKeyRouter();
      expect(
        route(router, down(PhysicalKeyboardKey.keyA, character: 'a')),
        isNull,
      );
      expect(route(router, up(PhysicalKeyboardKey.keyA)), isNull);
      expect(
        route(
          router,
          down(PhysicalKeyboardKey.keyA, character: 'A'),
          modifiers: InputModifiers.shift,
          textField: false,
        ),
        ['text A'],
      );
      expect(
        route(
          router,
          repeat(PhysicalKeyboardKey.keyA, character: 'A'),
          textField: false,
        ),
        ['text A'],
      );
      expect(
        route(router, up(PhysicalKeyboardKey.keyA), textField: false),
        isNull,
      );
    });

    test('keys that do not type, and editing keys, go as keys', () {
      final router = HardwareKeyRouter();
      for (final (key, code) in [
        (PhysicalKeyboardKey.arrowLeft, 123),
        (PhysicalKeyboardKey.escape, 53),
        (PhysicalKeyboardKey.enter, 36),
        (PhysicalKeyboardKey.backspace, 51),
        (PhysicalKeyboardKey.tab, 48),
        (PhysicalKeyboardKey.delete, 117),
        (PhysicalKeyboardKey.f5, 96),
        (PhysicalKeyboardKey.pageDown, 121),
      ]) {
        expect(route(router, down(key)), ['key down $code m0']);
        expect(route(router, repeat(key)), ['key down $code m0']);
        expect(route(router, up(key)), ['key up $code m0']);
      }
      // Modifier keys alone ride on the keys they change.
      expect(route(router, down(PhysicalKeyboardKey.metaLeft)), isNull);
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

    test('backspace on the empty field', () {
      final result = ImeTextBuffer.consume(value(''));
      expect(result.events.map(_describe), ['key down 51 m0', 'key up 51 m0']);
      expect(result.reset, isTrue);
    });

    test('typed text, Return and Tab', () {
      final result = ImeTextBuffer.consume(value('${s}Hello\n你好\t'));
      expect(result.events.map(_describe), [
        'text Hello',
        'key down 36 m0',
        'key up 36 m0',
        'text 你好',
        'key down 48 m0',
        'key up 48 m0',
      ]);
      expect(result.reset, isTrue);
    });

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

  group('pointing at the picture', () {
    testWidgets('a tap clicks where it landed, at once', (tester) async {
      final events = <WindowInputEvent>[];
      await tester.pumpWidget(_Harness(events));
      await tester.tapAt(const Offset(150, 125));
      expect(events.map(_describe), [
        'pointer move primary 0.25,0.25',
        'pointer down primary 0.25,0.25',
        'pointer up primary 0.25,0.25',
      ]);
      events.clear();
      // The black bars around the picture are not the window.
      await tester.tapAt(const Offset(20, 20));
      expect(events, isEmpty);
    });

    testWidgets('press and hold right-clicks; hold and move drags', (
      tester,
    ) async {
      final events = <WindowInputEvent>[];
      await tester.pumpWidget(_Harness(events));
      final hold = await tester.startGesture(const Offset(200, 150));
      await tester.pump(const Duration(milliseconds: 500));
      await hold.up();
      expect(events.map(_describe), [
        'pointer move primary 0.50,0.50',
        'pointer down secondary 0.50,0.50',
        'pointer up secondary 0.50,0.50',
      ]);
      events.clear();

      final drag = await tester.startGesture(const Offset(120, 120));
      await tester.pump(const Duration(milliseconds: 500));
      await drag.moveTo(const Offset(160, 140));
      await drag.moveTo(const Offset(280, 180));
      await drag.up();
      expect(events.map(_describe), [
        'pointer move primary 0.10,0.20',
        'pointer down primary 0.10,0.20',
        'pointer move primary 0.30,0.40',
        'pointer move primary 0.90,0.80',
        'pointer up primary 0.90,0.80',
      ]);
    });

    testWidgets('a finger scrolls, and a flick coasts to a stop', (
      tester,
    ) async {
      final events = <WindowInputEvent>[];
      await tester.pumpWidget(_Harness(events));
      final finger = await tester.startGesture(const Offset(200, 120));
      for (var i = 1; i <= 6; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await finger.moveTo(
          Offset(200, 120.0 + i * 12),
          timeStamp: Duration(milliseconds: i * 10),
        );
      }
      await finger.up(timeStamp: const Duration(milliseconds: 70));
      final scrolls = events.whereType<ScrollInput>().toList();
      expect(scrolls.first.phase, ScrollPhase.began);
      expect(
        scrolls.skip(1).every((e) => e.phase == ScrollPhase.changed),
        isTrue,
      );
      // Content follows the finger: down is positive, as a fraction.
      final moved = scrolls.fold<double>(0, (sum, e) => sum + e.dy);
      expect(moved, closeTo(72 / 100, 0.001));
      expect(events.whereType<PointerInput>(), isEmpty);
      events.clear();
      // The coast continues the same way and then ends the gesture.
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final coast = events.whereType<ScrollInput>().toList();
      expect(coast, isNotEmpty);
      expect(coast.last.phase, ScrollPhase.ended);
      expect(
        coast
            .where((e) => e.phase == ScrollPhase.changed)
            .every((e) => e.dy > 0),
        isTrue,
      );
      expect(coast.where((e) => e.phase == ScrollPhase.ended), hasLength(1));
    });

    testWidgets('touching a coasting scroll stops it', (tester) async {
      final events = <WindowInputEvent>[];
      await tester.pumpWidget(_Harness(events));
      await tester.flingFrom(const Offset(200, 120), const Offset(0, 60), 1500);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      events.clear();
      final stop = await tester.startGesture(const Offset(200, 150));
      expect(events.map(_describe), ['scroll ended']);
      await stop.up();
    });

    testWidgets('a two-finger tap right-clicks', (tester) async {
      final events = <WindowInputEvent>[];
      await tester.pumpWidget(_Harness(events));
      final first = await tester.startGesture(const Offset(150, 150));
      final second = await tester.startGesture(
        const Offset(200, 150),
        pointer: 7,
      );
      await tester.pump(const Duration(milliseconds: 80));
      await second.up();
      await first.up();
      expect(events.map(_describe), [
        'pointer move primary 0.25,0.50',
        'pointer down secondary 0.25,0.50',
        'pointer up secondary 0.25,0.50',
      ]);
    });

    testWidgets('a mouse hovers, clicks, right-clicks and drags', (
      tester,
    ) async {
      final events = <WindowInputEvent>[];
      await tester.pumpWidget(_Harness(events));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(0, 0));
      await mouse.moveTo(const Offset(120, 110));
      expect(events.map(_describe), ['pointer move primary 0.10,0.10']);
      events.clear();
      // Hover is held to 120 Hz; the last position always goes out.
      await mouse.moveTo(const Offset(140, 110));
      await mouse.moveTo(const Offset(160, 110));
      await tester.pump(const Duration(milliseconds: 20));
      expect(events.map(_describe).last, 'pointer move primary 0.30,0.10');
      events.clear();

      await mouse.down(const Offset(200, 150));
      await mouse.moveTo(const Offset(220, 160));
      await mouse.up();
      expect(events.map(_describe), [
        'pointer move primary 0.50,0.50',
        'pointer down primary 0.50,0.50',
        'pointer move primary 0.60,0.60',
        'pointer up primary 0.60,0.60',
      ]);
      events.clear();

      final right = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.down(const Offset(250, 175));
      await right.up();
      expect(events.map(_describe), [
        'pointer move primary 0.75,0.75',
        'pointer down secondary 0.75,0.75',
        'pointer up secondary 0.75,0.75',
      ]);
      await mouse.removePointer();
    });

    testWidgets('a wheel scrolls without phases', (tester) async {
      final events = <WindowInputEvent>[];
      await tester.pumpWidget(_Harness(events));
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 150),
          scrollDelta: Offset(0, 20),
          kind: PointerDeviceKind.mouse,
        ),
      );
      final scroll = events.single as ScrollInput;
      expect(scroll.phase, ScrollPhase.none);
      // Wheel down moves the content up.
      expect(scroll.dy, closeTo(-0.2, 1e-9));
      expect([scroll.x, scroll.y], [0.5, 0.5]);
    });

    testWidgets('the trackpad scrolls in phases, then coasts', (tester) async {
      final events = <WindowInputEvent>[];
      await tester.pumpWidget(_Harness(events));
      final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pad.panZoomStart(const Offset(200, 150));
      for (var i = 1; i <= 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await pad.panZoomUpdate(
          const Offset(200, 150),
          pan: Offset(0, -15.0 * i),
          timeStamp: Duration(milliseconds: i * 10),
        );
      }
      await pad.panZoomEnd(timeStamp: const Duration(milliseconds: 60));
      final during = events.whereType<ScrollInput>().toList();
      expect(during.first.phase, ScrollPhase.began);
      expect(
        during.skip(1).fold<double>(0, (sum, e) => sum + e.dy),
        closeTo(-0.75, 0.001),
      );
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final all = events.whereType<ScrollInput>().toList();
      expect(all.last.phase, ScrollPhase.ended);
      expect(all.where((e) => e.phase == ScrollPhase.ended), hasLength(1));
      expect(all.length, greaterThan(during.length));
    });
  });
}
