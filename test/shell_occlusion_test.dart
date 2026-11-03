// What floats over a window must not cover what is under it: sheets and the
// window's buttons, a sheet's buttons in a short window, a long draft and the
// newest messages. And the switch's knob, which sits evenly in its track.

import 'dart:async';

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_palette.dart';
import 'package:whisper/new_ui/shell/shell_window_chrome.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_window.dart';
import 'package:whisper/widget/chat_message_list.dart';
import 'package:whisper/widget/measure_size.dart';

import 'support/golden_support.dart';

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

PaletteItem _item(String name, void Function(String) ran) => PaletteItem(
  glyph: WhisperGlyph.info,
  name: name,
  category: 'c',
  onRun: () => ran(name),
);

void main() {
  group('the layer above the navigator', () {
    testWidgets('has an overlay, so a tooltip in it can show', (tester) async {
      _window(tester, const Size(900, 600));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => ShellWindowChrome(
            debugLayer: const Align(
              alignment: Alignment.topRight,
              child: Tooltip(
                message: '最大化',
                child: SizedBox(key: ValueKey('button'), width: 46, height: 32),
              ),
            ),
            child: child!,
          ),
          home: const Scaffold(body: Text('content')),
        ),
      );
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('button'))),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      expect(find.text('最大化'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('what is under it still gets the clicks', (tester) async {
      _window(tester, const Size(900, 600));
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => ShellWindowChrome(child: child!),
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => tapped++,
                child: const Text('under'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('under'));
      await tester.pump();
      expect(tapped, 1);
    });
  });

  group('the switch', () {
    Rect knobIn(WidgetTester tester) => tester.getRect(
      find
          .descendant(
            of: find.byType(ShellSwitch),
            matching: find.byWidgetPredicate(
              (w) => w is Positioned && w.width == 18,
            ),
          )
          .first,
    );

    for (final on in [false, true]) {
      testWidgets(
        'its knob has the same gap on both sides, ${on ? 'on' : 'off'}',
        (tester) async {
          await tester.pumpWidget(
            goldenApp(
              Center(
                child: ShellSwitch(value: on, onChanged: (_) {}, label: 's'),
              ),
            ),
          );
          await tester.pump(const Duration(seconds: 2));
          final track = tester.getRect(find.byType(ShellSwitch));
          final knob = knobIn(tester);
          expect(knob.top - track.top, 2);
          if (on) {
            expect(track.right - knob.right, 2);
          } else {
            expect(knob.left - track.left, 2);
          }
        },
      );
    }
  });

  group('sheets', () {
    testWidgets('stay clear of the window buttons and the island', (
      tester,
    ) async {
      _window(tester, const Size(720, 480));
      late BuildContext context;
      await tester.pumpWidget(
        goldenApp(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      showShellSheet<void>(
        context,
        builder: (_) => const SizedBox(key: ValueKey('tall'), height: 2000),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final sheet = tester.getRect(find.byType(SingleChildScrollView));
      // The closed island ends at 45, the window's buttons sooner.
      expect(sheet.top, greaterThanOrEqualTo(45));
      expect(sheet.top, WhisperWindow.sheetGap / 2);
    });

    testWidgets('keep their buttons in reach in a short window', (
      tester,
    ) async {
      _window(tester, const Size(720, 480));
      late BuildContext context;
      await tester.pumpWidget(
        goldenApp(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      showShellSheet<void>(
        context,
        scrolls: false,
        builder: (_) => ShellSheetBody(
          content: const SizedBox(height: 2000),
          actions: ShellButton(label: '完成', onTap: () {}),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final button = tester.getRect(find.text('完成'));
      expect(
        button.bottom,
        lessThanOrEqualTo(480 - WhisperWindow.sheetGap / 2),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the composer', () {
    test('one line leaves the usual room', () {
      expect(chatListBottomInset(composerHeight: null, touch: false), 84);
      expect(chatListBottomInset(composerHeight: 40, touch: false), 84);
      expect(chatListBottomInset(composerHeight: null, touch: true), 92);
    });

    test('a long draft pushes the messages up', () {
      expect(chatListBottomInset(composerHeight: 130, touch: false), 158);
      // A phone's gesture bar is part of what was measured.
      expect(chatListBottomInset(composerHeight: 90, touch: true), 126);
    });

    testWidgets('its height is reported when it changes, and only then', (
      tester,
    ) async {
      final reported = <double>[];
      Widget at(double height) => Align(
        alignment: Alignment.topLeft,
        child: MeasureSize(
          onChange: (size) => reported.add(size.height),
          child: SizedBox(width: 100, height: height),
        ),
      );
      await tester.pumpWidget(at(40));
      await tester.pump();
      await tester.pumpWidget(at(40));
      await tester.pump();
      await tester.pumpWidget(at(120));
      await tester.pump();
      expect(reported, [40, 120]);
    });
  });

  group('the palette', () {
    Future<void> pumpPalette(
      WidgetTester tester, {
      required List<PaletteItem> items,
      required Future<List<PaletteItem>> Function(String) search,
    }) async {
      _window(tester, const Size(900, 700));
      await tester.pumpWidget(
        goldenApp(
          Scaffold(
            body: ShellPalette(items: items, searchMessages: search),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('never says there are no results while it is still looking', (
      tester,
    ) async {
      final found = Completer<List<PaletteItem>>();
      await pumpPalette(
        tester,
        items: [_item('iMac', (_) {})],
        search: (_) => found.future,
      );
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      // Still what was there: no empty line, no empty list.
      expect(find.text('iMac'), findsOneWidget);

      found.complete([_item('hello there', (_) {})]);
      await tester.pump();
      expect(find.text('hello there'), findsOneWidget);
      expect(find.text('iMac'), findsNothing);
    });

    testWidgets('the list changes once, with direct results and messages', (
      tester,
    ) async {
      final found = Completer<List<PaletteItem>>();
      await pumpPalette(
        tester,
        items: [_item('iMac', (_) {}), _item('arch', (_) {})],
        search: (_) => found.future,
      );
      await tester.enterText(find.byType(TextField), 'ar');
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('iMac'), findsOneWidget, reason: 'not changed yet');

      found.complete([_item('ar message', (_) {})]);
      await tester.pump();
      expect(find.text('iMac'), findsNothing);
      expect(find.text('arch'), findsOneWidget);
      expect(find.text('ar message'), findsOneWidget);
    });

    testWidgets('a slow search does not hold up what is already known', (
      tester,
    ) async {
      final found = Completer<List<PaletteItem>>();
      await pumpPalette(
        tester,
        items: [_item('iMac', (_) {}), _item('arch', (_) {})],
        search: (_) => found.future,
      );
      await tester.enterText(find.byType(TextField), 'ar');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('arch'), findsOneWidget);
      expect(find.text('iMac'), findsNothing);
      found.complete(const []);
      await tester.pump();
    });

    testWidgets('a search that fails still shows the rest', (tester) async {
      await pumpPalette(
        tester,
        items: [_item('arch', (_) {}), _item('iMac', (_) {})],
        search: (_) async => throw StateError('no database'),
      );
      await tester.enterText(find.byType(TextField), 'ar');
      await tester.pump();
      expect(find.text('arch'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
