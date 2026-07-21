import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings back buttons use accessible icon actions', () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(
      RegExp(r'CupertinoNavigationBarBackButton\(').allMatches(source),
      hasLength(2),
    );
    expect(RegExp(r'const BackButton\(').allMatches(source), isEmpty);
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

  test('client settings retain the original localized card sections', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final clientSettings = RegExp(
      r'class _ClientSettingsScreenState[\s\S]*?class _DeviceSettingTile',
    ).firstMatch(source)!.group(0)!;

    expect(clientSettings, contains('Widget _buildClientSettingsSection('));
    expect(clientSettings, contains('l10n.dangerousActions'));
    expect(
        clientSettings, contains('SettingsSectionSurface(children: children)'));
  });

  test('client setting tiles keep row height consistent without dividers', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final tileStart = source.indexOf('class _DeviceSettingTile');
    expect(tileStart, isNonNegative);
    final tile = source.substring(tileStart);

    expect(tile, contains('GestureDetector('));
    expect(tile, contains('Container('));
    expect(tile, contains('Row('));
    expect(tile, contains('BoxConstraints(minHeight: 56)'));
    expect(tile, isNot(contains('Divider(')));
  });

  test('client settings no longer expose legacy per-device input pages', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final clientSettings = RegExp(
      r'class _ClientSettingsScreenState[\s\S]*?class _DeviceSettingTile',
    ).firstMatch(source)!.group(0)!;

    expect(clientSettings, isNot(contains('remoteInputAutoModeSetting')));
    expect(clientSettings, isNot(contains('remoteInputLayoutSetting')));
    expect(clientSettings, isNot(contains('RemoteInputLayoutEditorScreen')));
    expect(clientSettings,
        isNot(contains('_restartRemoteInputSharingIfActive')));
  });
}
