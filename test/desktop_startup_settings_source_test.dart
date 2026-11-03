import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop launch at startup setting is localized and desktop-only', () {
    final source =
        File('lib/page/settings.dart').readAsStringSync() +
        File('lib/new_ui/settings/settings_layout.dart').readAsStringSync();

    expect(
      source,
      contains("import 'package:whisper/helper/desktop_startup.dart';"),
    );
    expect(source, contains('bool _launchAtStartup = false;'));
    expect(source, contains('DesktopStartupManager().isEnabled()'));
    expect(
      source,
      matches(
        RegExp(r'DesktopStartupManager\(\)\s*\.setEnabled\(\s*value\s*,?\s*\)'),
      ),
    );
    expect(source, contains('title: l10n.launchAtStartup,'));
    expect(source, contains('l10n.launchAtStartupFailed,'));
  });

  test('launch at startup strings are localized', () {
    for (final path in [
      'lib/l10n/app_zh.arb',
      'lib/l10n/app_en.arb',
      'lib/l10n/app_es.arb',
    ]) {
      final arb = File(path).readAsStringSync();
      expect(arb, contains('"launchAtStartup"'));
      expect(arb, contains('"launchAtStartupDesc"'));
      expect(arb, contains('"launchAtStartupFailed"'));
    }
  });
}
