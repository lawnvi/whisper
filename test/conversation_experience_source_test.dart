import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop pairing requests reveal and focus the app window', () {
    final helper = File(
      'lib/helper/desktop_window_attention.dart',
    ).readAsStringSync();
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(helper, contains('windowManager.restore()'));
    expect(helper, contains('windowManager.show()'));
    expect(helper, contains('windowManager.focus()'));
    expect(deviceList, contains('revealDesktopWindowForAttention()'));
    expect(conversation, contains('revealDesktopWindowForAttention()'));
  });

  test('desktop app closes resources before accepting system exit', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();

    expect(deviceList, contains('with WidgetsBindingObserver'));
    expect(deviceList, contains('Future<AppExitResponse> didRequestAppExit()'));
    expect(deviceList, contains('await _shutdownDesktopResources()'));
  });

  test('Windows close-to-tray cancels the exit request before cleanup', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final exitHandler = RegExp(
      r'Future<AppExitResponse> didRequestAppExit\(\) async \{[\s\S]*?\n  \}',
    ).firstMatch(deviceList)!.group(0)!;

    final hideIndex = exitHandler.indexOf('await windowManager.hide();');
    final cancelIndex = exitHandler.indexOf('return AppExitResponse.cancel;');
    final cleanupIndex = exitHandler.indexOf(
      'await _shutdownDesktopResources();',
    );

    expect(exitHandler, contains('Platform.isWindows'));
    expect(hideIndex, greaterThanOrEqualTo(0));
    expect(cancelIndex, greaterThan(hideIndex));
    expect(cleanupIndex, greaterThan(cancelIndex));
  });

  test('server presents only one pairing prompt per socket session', () {
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(manager, contains('session.tryClaimLocalApprovalPrompt()'));
  });

}
