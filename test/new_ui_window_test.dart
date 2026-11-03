import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';

import 'support/source_reading.dart';

void main() {
  group('the window material', () {
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

    test('Linux always has the header bar and the theme channel', () {
      final runner = File('linux/my_application.cc').readAsStringSync();
      expect(runner, isNot(contains('WHISPER_NEW_UI')));
      expect(runner, contains('gtk_window_set_titlebar(window'));
      expect(runner, contains('  window_theme_channel_register(view);'));
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
}
