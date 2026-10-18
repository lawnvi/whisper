import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = File(
    'lib/window_stream/remote/window_stream_host.dart',
  ).readAsStringSync();

  test('a viewer can only name apps and windows this host listed', () {
    // An app id can be a path on Windows: never run or read one a viewer
    // made up.
    expect(host, contains('!await _isKnownApp(appId)'));
    expect(host, contains('await _isKnownApp(appId)) {'));
    // Thumbnails only of listed windows.
    expect(host, contains('!await _isListedWindow(windowId)'));
  });

  test('the same viewer reopening a window ends the old capture first', () {
    expect(host, contains('old.window.id == window.id'));
    expect(host, contains('old.viewerPeerId == message.viewerPeerId'));
  });

  test('window sharing can be turned off and then offers nothing', () {
    final support = File(
      'lib/window_stream/window_stream_support.dart',
    ).readAsStringSync();
    expect(support, contains('WindowStreamHost.shared.sharingAllowed'));
    expect(host, contains("'window_stream.share_windows'"));
    final settings = File('lib/page/settings.dart').readAsStringSync();
    expect(settings, contains('WindowStreamHost.shared.setSharingAllowed('));
  });

  test('test hooks exist only in debug builds', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('if (kDebugMode) {\n    registerAutomationHooks();'));
    final hooks = File('lib/debug/automation_hooks.dart').readAsStringSync();
    expect(hooks, contains('if (_registered || !kDebugMode)'));
  });
}
