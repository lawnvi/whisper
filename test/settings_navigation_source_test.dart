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

  test('screen layout editor opens immediately and reapplies active sharing',
      () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final clientSettings = RegExp(
      r'class _ClientSettingsScreenState[\s\S]*?class _DeviceSettingTile',
    ).firstMatch(source)!.group(0)!;
    final openEditorStart =
        clientSettings.indexOf('Future<void> _openRemoteInputLayoutEditor');
    final restartStart = clientSettings
        .indexOf('Future<void> _restartRemoteInputSharingIfActive');
    expect(openEditorStart, isNonNegative);
    expect(restartStart, isNonNegative);
    final openEditor = clientSettings.substring(openEditorStart, restartStart);
    final saveLayoutStart =
        clientSettings.indexOf('Future<void> _saveRemoteInputLayout');
    expect(saveLayoutStart, isNonNegative);
    final saveLayout =
        clientSettings.substring(saveLayoutStart, openEditorStart);

    expect(openEditor,
        isNot(contains('await WsSvrManager().requestRemoteProfileRefresh')));
    expect(openEditor, contains('WsSvrManager().remoteDisplayTopology'));
    expect(openEditor, contains('remoteTopologyLoader'));
    expect(openEditor, contains('WsSvrManager().requestRemoteProfileRefresh'));

    expect(saveLayout, contains('_restartRemoteInputSharingIfActive(next)'));
    expect(clientSettings,
        contains('Future<void> _restartRemoteInputSharingIfActive'));
    expect(clientSettings, contains('RemoteInputRuntimeRole.source'));
    expect(clientSettings, contains('state.isForPeer(device.uid)'));
    expect(clientSettings, contains('stopSharing('));
    expect(clientSettings,
        contains('sendControl: socketManager.sendRemoteInputControl'));
    expect(clientSettings, contains('startSharingToConnectedPeer'));
  });
}
