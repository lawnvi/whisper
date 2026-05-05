import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop launch at startup setting is localized and desktop-only', () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(source,
        contains("import 'package:whisper/helper/desktop_startup.dart';"));
    expect(source, contains("import 'package:whisper/helper/toast.dart';"));
    expect(source, contains('bool _launchAtStartup = false;'));
    expect(source, contains('DesktopStartupManager().isEnabled()'));
    expect(source, contains('DesktopStartupManager().setEnabled(value)'));
    expect(source, contains('l10n.launchAtStartup'));
    expect(source, contains('l10n.launchAtStartupDesc'));
    expect(source, contains('l10n.launchAtStartupFailed('));

    final desktopSection = RegExp(
      r'if \(isDesktop\(\)\)[\s\S]*?l10n\.launchAtStartup[\s\S]*?CupertinoSwitch',
    );
    expect(desktopSection.hasMatch(source), isTrue);
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
