import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop window theme bridge', () {
    test('syncs app theme mode to the native desktop window', () {
      final mainSource = File('lib/main.dart').readAsStringSync();

      expect(mainSource, contains('MethodChannel('));
      expect(mainSource, contains("'com.vireen.whisper/window_theme'"));
      expect(mainSource, contains('Future<void> _applyDesktopWindowTheme'));
      expect(mainSource, contains('windowManager.setBrightness(brightness)'));
      expect(mainSource, contains('Platform.isWindows'));
      expect(mainSource, contains('Platform.isMacOS'));
      expect(
        mainSource,
        contains("_windowThemeChannel.invokeMethod<void>('setBrightness'"),
      );
      expect(mainSource, contains('didChangePlatformBrightness'));
      expect(
        mainSource,
        contains('unawaited(_applyDesktopWindowTheme(mode));'),
      );
    });

    test('keeps the macOS native title bar on the Flutter page surface', () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final runner = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();

      expect(
        mainSource,
        contains('AppTheme.fallbackPalette(brightness).surfaceCanvas'),
      );
      expect(mainSource, contains('backgroundColor: windowBackground'));
      expect(
        mainSource,
        contains("'backgroundColor': windowBackground.toARGB32()"),
      );
      expect(runner, contains('com.vireen.whisper/window_theme'));
      expect(runner, contains('titlebarAppearsTransparent = true'));
      expect(runner, contains('titleVisibility = .visible'));
      expect(runner, contains('styleMask.remove(.fullSizeContentView)'));
      expect(runner, contains('backgroundARGB: UInt32?'));
      expect(runner, contains('backgroundColor = NSColor('));
      expect(runner, contains('CGFloat((argb >> 16) & 0xFF) / 255.0'));
      expect(runner, contains('forInfoDictionaryKey: "CFBundleDisplayName"'));
    });

    test(
      'adds a Windows runner channel that ignores the system theme gate',
      () {
        final mainSource = File('lib/main.dart').readAsStringSync();
        final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
        final flutterWindow = File(
          'windows/runner/flutter_window.cpp',
        ).readAsStringSync();
        final plugin = File(
          'windows/runner/window_theme_plugin.cpp',
        ).readAsStringSync();
        final header = File(
          'windows/runner/window_theme_plugin.h',
        ).readAsStringSync();

        expect(cmake, contains('"window_theme_plugin.cpp"'));
        expect(flutterWindow, contains('#include "window_theme_plugin.h"'));
        expect(
          flutterWindow,
          contains('WindowThemePluginRegisterWithRegistrar'),
        );
        expect(header, contains('WindowThemePluginRegisterWithRegistrar'));
        expect(plugin, contains('com.vireen.whisper/window_theme'));
        expect(plugin, contains('DwmSetWindowAttribute'));
        expect(plugin, contains('brightness == "dark"'));
        expect(mainSource, contains('windowButtonVisibility: true'));
        expect(
          mainSource,
          contains('await windowManager.setMinimizable(true)'),
        );

        final setBrightness = RegExp(
          r'void SetBrightness\([\s\S]*?\n  \}',
        ).firstMatch(plugin)!.group(0)!;
        expect(setBrightness, isNot(contains('RegGetValue')));
        expect(setBrightness, isNot(contains('light_mode == 0')));
      },
    );

    test('the Windows title bar keeps the brightness the app chose', () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final runner = File(
        'windows/runner/win32_window.cpp',
      ).readAsStringSync();
      final plugin = File(
        'windows/runner/window_theme_plugin.cpp',
      ).readAsStringSync();

      // Windows reports a colour change whenever the accent colour or the
      // wallpaper changes. The runner used to set the title bar from the
      // system theme each time, which gave a light app white caption
      // buttons on a system set to dark: minimise and maximise vanished.
      final updateTheme = runner.substring(
        runner.indexOf('void Win32Window::UpdateTheme('),
      );
      expect(
        updateTheme.indexOf('WindowThemeChosenDarkMode(window'),
        inInclusiveRange(0, updateTheme.indexOf('RegGetValue')),
      );
      expect(runner, contains('WindowThemeForget(hwnd);'));
      expect(plugin, contains('SetPropW(window_, kChosenBrightnessProperty'));
      expect(plugin, contains('bool WindowThemeChosenDarkMode('));

      // The window plugin colours the window by painting over the title
      // bar as well, and Windows then draws the caption buttons white: on
      // the light theme they could not be seen. The title bar gets the page
      // colour as its caption colour instead.
      expect(plugin, contains('DWMWA_CAPTION_COLOR'));
      expect(plugin, contains('GetIntValue(*args, "backgroundColor")'));
      expect(
        mainSource,
        contains("'backgroundColor': windowBackground.toARGB32()"),
      );

      // The window plugin only darkens while the system is dark, so it is
      // left out of this on Windows.
      expect(
        mainSource,
        contains(
          'if (!Platform.isWindows) {\n'
          '      await windowManager.setBrightness(brightness);',
        ),
      );
    });
  });
}
