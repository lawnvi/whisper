import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/new_ui/probe/window_probe.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';

import 'support/source_reading.dart';

void main() {
  group('the old UI keeps its window', () {
    final main = File('lib/main.dart').readAsStringSync();

    test('its window options and first page are only replaced by the flag', () {
      expect(whisperNewUi, isFalse);
      expect(main, contains('home: const DeviceListScreen()'));
      expect(
        memberSource(deviceListSource(), 'Widget build(BuildContext context)'),
        contains('if (whisperNewUi)'),
      );
      final options = main.substring(
        main.indexOf('WindowOptions windowOptions = whisperNewUi'),
        main.indexOf('windowManager.waitUntilReadyToShow(windowOptions'),
      );
      expect(options, contains('titleBarStyle: TitleBarStyle.normal'));
      expect(options, contains('windowButtonVisibility: true'));
    });

    test('macOS touches nothing until Dart asks for the material', () {
      final window = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      expect(
        memberSource(window, 'override func awakeFromNib()'),
        isNot(contains('enableWindowMaterial')),
      );
      // The window is only ever not movable with the material on.
      final enable = memberSource(
        window,
        'private func enableWindowMaterial()',
      );
      expect(enable, contains('isMovable = false'));
      expect(
        memberSource(window, 'override func performDrag(with event: NSEvent)'),
        contains('guard windowMaterial != nil else'),
      );
    });

    test('macOS keeps the traffic lights where AppKit retiling moves them', () {
      final window = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      // A change of appearance put them 1 pt over the window's top edge.
      expect(
        memberSource(window, 'private func enableWindowMaterial()'),
        contains('keepTrafficLightsInPlace()'),
      );
      final keep = memberSource(
        window,
        'private func keepTrafficLightsInPlace()',
      );
      expect(keep, contains('NSView.frameDidChangeNotification'));
      expect(keep, contains('[container, titleBar]'));
      // Setting those frames posts the same notification.
      expect(
        memberSource(window, 'private func layoutTrafficLights()'),
        contains('guard !isLayingOutTrafficLights'),
      );
    });

    test('Windows only sets a backdrop once one is asked for', () {
      final plugin = File(
        'windows/runner/window_theme_plugin.cpp',
      ).readAsStringSync();
      expect(plugin, contains('int backdrop_ = 0;'));
      final apply = memberSource(plugin, 'bool ApplyBackdrop()');
      expect(apply, contains('backdrop_ == 0'));
      // Windows 10 refuses the attribute: nothing may stay see-through.
      expect(apply, contains('FAILED(hr)'));
      expect(apply, contains('margins = {0, 0, 0, 0}'));
    });

    test('Linux keeps its title bar logic without WHISPER_NEW_UI=1', () {
      final runner = File('linux/my_application.cc').readAsStringSync();
      expect(runner, contains('g_getenv("WHISPER_NEW_UI"), "1"'));
      expect(runner, contains('if (!new_ui && GDK_IS_X11_SCREEN(screen))'));
      expect(
        runner,
        contains('if (new_ui) {\n    window_theme_channel_register'),
      );
    });
  });

  group('the new window', () {
    test('has no system title bar, and a minimum size', () {
      final options = WhisperWindow.options(const Size(1000, 700));
      expect(options.titleBarStyle, TitleBarStyle.hidden);
      expect(options.backgroundColor, Colors.transparent);
      expect(options.minimumSize, const Size(720, 480));
      expect(options.windowButtonVisibility, Platform.isMacOS);
    });

    test(
      'asks for its material after window_manager has set up the window',
      () {
        final main = File('lib/main.dart').readAsStringSync();
        final ready = main.indexOf(
          'windowManager.waitUntilReadyToShow(windowOptions',
        );
        expect(ready, greaterThan(-1));
        expect(
          main.indexOf('WhisperWindow.enableMaterial(brightness)', ready),
          greaterThan(ready),
        );
      },
    );
  });

  group('the step 1 probe', () {
    Future<void> pump(WidgetTester t, Size size, Brightness b) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          home: const WindowProbe(autorun: false, tray: false),
        ),
      );
      await t.pumpAndSettle();
    }

    for (final b in Brightness.values) {
      testWidgets('lays out as a window, ${b.name}', (t) async {
        await pump(t, const Size(1144, 720), b);
        expect(find.byType(LiquidSegmented<int>), findsOneWidget);
        expect(find.byType(WhisperGlass), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('lays out as a phone, ${b.name}', (t) async {
        await pump(t, const Size(390, 780), b);
        expect(find.byType(LiquidSegmented<int>), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('fits the minimum window', (t) async {
      await pump(t, const Size(720, 480), Brightness.light);
      expect(t.takeException(), isNull);
    });

    testWidgets('switching tabs keeps the toolbar where it is', (t) async {
      await pump(t, const Size(1144, 720), Brightness.light);
      final before = t.getRect(find.byType(LiquidSegmented<int>));
      await t.tap(find.text('文件'));
      await t.pumpAndSettle();
      expect(find.text('项目资料 0'), findsOneWidget);
      expect(t.getRect(find.byType(LiquidSegmented<int>)), before);
    });
  });
}
