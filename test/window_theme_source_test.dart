import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop window theme bridge', () {
    test('syncs app theme mode to the native desktop window', () {
      final mainSource = File('lib/main.dart').readAsStringSync();

      expect(mainSource,
          contains("MethodChannel('com.vireen.whisper/window_theme')"));
      expect(mainSource, contains('Future<void> _applyDesktopWindowTheme'));
      expect(mainSource, contains('windowManager.setBrightness(brightness)'));
      expect(mainSource, contains('Platform.isWindows'));
      expect(mainSource,
          contains("_windowThemeChannel.invokeMethod<void>('setBrightness'"));
      expect(mainSource, contains('didChangePlatformBrightness'));
      expect(
          mainSource, contains('unawaited(_applyDesktopWindowTheme(mode));'));
    });

    test('adds a Windows runner channel that ignores the system theme gate',
        () {
      final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
      final flutterWindow =
          File('windows/runner/flutter_window.cpp').readAsStringSync();
      final plugin =
          File('windows/runner/window_theme_plugin.cpp').readAsStringSync();
      final header =
          File('windows/runner/window_theme_plugin.h').readAsStringSync();

      expect(cmake, contains('"window_theme_plugin.cpp"'));
      expect(flutterWindow, contains('#include "window_theme_plugin.h"'));
      expect(flutterWindow, contains('WindowThemePluginRegisterWithRegistrar'));
      expect(header, contains('WindowThemePluginRegisterWithRegistrar'));
      expect(plugin, contains('com.vireen.whisper/window_theme'));
      expect(plugin, contains('DwmSetWindowAttribute'));
      expect(plugin, contains('brightness == "dark"'));

      final setBrightness = RegExp(
        r'void SetBrightness\([\s\S]*?\n  \}',
      ).firstMatch(plugin)!.group(0)!;
      expect(setBrightness, isNot(contains('RegGetValue')));
      expect(setBrightness, isNot(contains('light_mode == 0')));
    });
  });
}
