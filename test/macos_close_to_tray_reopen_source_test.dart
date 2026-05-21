import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS close-to-tray hides the window instead of sending it behind', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final closeHandler = RegExp(
      r'void onWindowClose\(\) async \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;

    expect(closeHandler, contains('await windowManager.hide();'));
    expect(closeHandler, isNot(contains('windowManager.blur')));
    expect(closeHandler, isNot(contains('lastClickCloseTimestamp')));
  });

  test('macOS dock reopen restores hidden main window', () {
    final source = File('macos/Runner/AppDelegate.swift').readAsStringSync();

    expect(source, contains('applicationShouldHandleReopen'));
    expect(source, contains('makeKeyAndOrderFront'));
    expect(source, contains('activate(ignoringOtherApps: true)'));
  });
}
