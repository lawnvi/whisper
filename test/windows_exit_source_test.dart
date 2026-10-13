import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows ends the process itself once its own things are closed', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    // Left to the engine, taking the plugins down ends every exit on Windows
    // in a crash, and Windows spends a couple of seconds on each one. Older
    // versions of the discovery plugin also crashed when stopped. Both are
    // kept out of the way out.
    final resources = source.substring(
      source.indexOf('Future<void> _shutdownDesktopResources() {'),
      source.indexOf('Future<void> _shutdownAndDestroyWindow() async {'),
    );
    expect(resources, contains('if (!Platform.isWindows) _stopDiscovery,'));
    for (final step in <String>[
      '_stopBroadcast,',
      '_stopSocketServer,',
      '_closeDatabase,',
      '_destroyTray,',
    ]) {
      expect(resources, contains(step));
    }

    final end = source.substring(
      source.indexOf('void _endWindowsProcess() {'),
      source.indexOf('Future<void> _stopClipboardWatcher() async {'),
    );
    expect(end, contains('if (Platform.isWindows) {\n      exit(0);'));

    // Both ways out reach it only after everything has been closed.
    final requested = source.substring(
      source.indexOf('Future<AppExitResponse> didRequestAppExit() async {'),
      source.indexOf('void _endWindowsProcess() {'),
    );
    expect(
      requested.indexOf('await _shutdownDesktopResources();'),
      inInclusiveRange(0, requested.indexOf('_endWindowsProcess();')),
    );
    final destroy = source.substring(
      source.indexOf('Future<void> _shutdownAndDestroyWindow() async {'),
    );
    expect(
      destroy.indexOf('_endWindowsProcess();'),
      inInclusiveRange(
        destroy.indexOf('await _shutdownDesktopResources();'),
        destroy.indexOf('await windowManager.destroy();'),
      ),
    );
  });
}
