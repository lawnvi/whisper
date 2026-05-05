import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('light mode page surfaces are white across desktop platforms', () {
    final themeSource = File('lib/theme/app_theme.dart').readAsStringSync();
    final settingsSource = File('lib/page/settings.dart').readAsStringSync();
    final conversationSource =
        File('lib/page/conversation.dart').readAsStringSync();

    final lightScheme = RegExp(
      r'static const _lightScheme = ColorScheme\([\s\S]*?\n  \);',
    ).firstMatch(themeSource)!.group(0)!;

    expect(lightScheme, contains('surface: Colors.white'));
    expect(lightScheme, isNot(contains('surface: Color(0xFFF8FAFC)')));
    expect(
        themeSource, contains('scaffoldBackgroundColor: colorScheme.surface'));
    expect(settingsSource, contains('backgroundColor: colorScheme.surface'));
    expect(conversationSource, contains('color: colorScheme.surface'));
  });
}
