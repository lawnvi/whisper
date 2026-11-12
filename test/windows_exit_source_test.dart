import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_reading.dart';

void main() {
  test('Windows ends the process itself once its own things are closed', () {
    final source = deviceListSource();

    // Left to the engine, taking the plugins down ends every exit on Windows
    // in a crash, and Windows spends a couple of seconds on each one. Older
    // versions of the discovery plugin also crashed when stopped. Both are
    // kept out of the way out.
    final resources = memberSource(
      source,
      'Future<void> _shutdownDesktopResources() {',
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

    // Not by exit either: ExitProcess runs every library's unload code,
    // and flutter_windows.dll crashed in it now and then (0.0.59, 0.0.60).
    final end = File('lib/helper/process_end.dart').readAsStringSync();
    expect(end, contains("'TerminateProcess'"));

    // Both ways out reach it only after everything has been closed.
    final requested = memberSource(
      source,
      'Future<AppExitResponse> didRequestAppExit() async {',
    );
    expect(
      requested.indexOf('await _shutdownDesktopResources();'),
      inInclusiveRange(0, requested.indexOf('await endWindowsProcess();')),
    );
    final destroy = memberSource(
      source,
      'Future<void> _shutdownAndDestroyWindow() async {',
    );
    expect(
      destroy.indexOf('await endWindowsProcess();'),
      inInclusiveRange(
        destroy.indexOf('await _shutdownDesktopResources();'),
        destroy.indexOf('await windowManager.destroy();'),
      ),
    );
  });
}
