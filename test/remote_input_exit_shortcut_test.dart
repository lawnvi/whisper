import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations_en.dart';
import 'package:whisper/l10n/app_localizations_es.dart';
import 'package:whisper/l10n/app_localizations_zh.dart';
import 'package:whisper/remote_input/remote_input_exit_shortcut.dart';

void main() {
  test('the release hotkey is written the way each keyboard labels it', () {
    expect(remoteInputReleaseHotkeyLabel(macOS: false), 'Ctrl+Alt+Esc');
    expect(remoteInputReleaseHotkeyLabel(macOS: true), '⌃⌥Esc');
  });

  test('every language names the shortcut it is given', () {
    const shortcut = 'Ctrl+Alt+Esc';
    expect(
      AppLocalizationsZh().remoteInputWorkspaceExitShortcut(shortcut),
      '按 Ctrl+Alt+Esc 退出共享',
    );
    expect(
      AppLocalizationsEn().remoteInputWorkspaceExitShortcut(shortcut),
      'Press Ctrl+Alt+Esc to stop sharing',
    );
    expect(
      AppLocalizationsEs().remoteInputWorkspaceExitShortcut(shortcut),
      'Pulsa Ctrl+Alt+Esc para dejar de compartir',
    );
  });

  test('the label describes the hotkey the native capture listens for', () {
    // Each backend only recognises this one combination, so the hint would be
    // wrong if a different hotkey were ever registered.
    expect(remoteInputReleaseHotkey, 'ctrl+alt+esc');
    for (final path in <String>[
      'macos/Runner/MainFlutterWindow.swift',
      'windows/runner/remote_input_plugin.cpp',
      'linux/remote_input_plugin.cc',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('"$remoteInputReleaseHotkey"'),
        reason: path,
      );
    }
  });

  test('the workspace always shows how to leave sharing', () {
    final source = File(
      'lib/remote_input/remote_input_workspace_screen.dart',
    ).readAsStringSync();
    final canvas = RegExp(
      r'Widget _buildCanvasPanel\([\s\S]*?\n  Widget _buildScreenCanvas',
    ).firstMatch(source)!.group(0)!;
    final hint = canvas.indexOf('l10n.remoteInputWorkspaceExitShortcut(');
    expect(hint, isNot(-1));
    expect(canvas, contains('remoteInputReleaseHotkeyLabel('));
    // Not behind any condition: it sits before the first conditional notice.
    expect(
      hint,
      lessThan(canvas.indexOf('if (_devices.isNotEmpty && selectedDevices')),
    );
    // It must not swallow drags on the screens underneath it.
    expect(
      canvas.lastIndexOf('IgnorePointer(', hint),
      greaterThan(canvas.lastIndexOf('Align(', hint)),
    );
    expect(source, contains('releaseHotkey: remoteInputReleaseHotkey,'));
  });
}
