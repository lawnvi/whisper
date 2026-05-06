import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings back buttons use the app bar foreground color', () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(
      RegExp(
        r'CupertinoNavigationBarBackButton\([\s\S]*?color: colorScheme\.primary,',
      ).allMatches(source),
      isEmpty,
    );
    expect(
      RegExp(
        r'CupertinoNavigationBarBackButton\([\s\S]*?color: colorScheme\.onSurface,',
      ).allMatches(source),
      hasLength(2),
    );
  });

  test('remote input auto mode sheet uses settings menu colors', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final picker = RegExp(
      r'Future<void> _openRemoteInputAutoModePicker\([\s\S]*?Future<void> _openRemoteInputLayoutEditor',
    ).firstMatch(source)!.group(0)!;

    expect(
        picker, contains('final colorScheme = Theme.of(context).colorScheme;'));
    expect(
      picker,
      isNot(contains("child: const Text('关闭')")),
    );
    expect(
      picker,
      isNot(contains("child: const Text('本机控制对端')")),
    );
    expect(
      picker,
      isNot(contains("child: const Text('对端控制本机')")),
    );
    expect(
      RegExp(r'color: colorScheme\.onSurface').allMatches(picker),
      hasLength(4),
    );
    expect(picker, contains('style: const TextStyle(color: Colors.redAccent)'));
  });

  test('copy verification setting is not limited to Chinese locale', () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(source, contains('copyVerifyCode'));
    expect(
      RegExp(
        r'''if\s*\(\s*Localizations\.localeOf\(context\)\.languageCode\s*==\s*["']zh["']\s*\)\s*'''
        r'_buildSettingItem\([\s\S]{0,500}copyVerifyCode',
      ).hasMatch(source),
      isFalse,
    );
  });

  test('client settings use compact untitled cards', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final clientSettings = RegExp(
      r'class _ClientSettingsScreenState[\s\S]*?class _DeviceSettingTile',
    ).firstMatch(source)!.group(0)!;

    expect(clientSettings, contains('Widget _buildClientSettingsCard('));
    expect(
        clientSettings, isNot(contains('_buildClientSettingsSectionHeader')));
    expect(clientSettings, isNot(contains('_clientSettingsSectionText')));
    expect(clientSettings, contains('BorderRadius.circular(14.0)'));
    expect(clientSettings, isNot(contains('BorderRadius.circular(20.0)')));
  });

  test('client setting tiles keep row height consistent without dividers', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final tileStart = source.indexOf('class _DeviceSettingTile');
    expect(tileStart, isNonNegative);
    final tile = source.substring(tileStart);

    expect(tile, contains('BoxConstraints(minHeight: 56)'));
    expect(tile, contains('CrossAxisAlignment.center'));
    expect(tile, isNot(contains('Divider(')));
  });
}
