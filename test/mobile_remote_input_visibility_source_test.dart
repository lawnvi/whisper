import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client settings leave multi-device input layout to the workspace', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final clientSettings = RegExp(
      r'class _ClientSettingsScreenState[\s\S]*?class _DeviceSettingTile',
    ).firstMatch(source)!.group(0)!;

    expect(clientSettings, isNot(contains('_canConfigureRemoteInput')));
    expect(clientSettings, isNot(contains('remoteInputAutoModeSetting')));
    expect(clientSettings, isNot(contains('remoteInputLayoutSetting')));
  });

  test('mobile conversation header never shows remote input action', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final getter = RegExp(
      r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;

    expect(getter, contains('isDesktop() &&'));
  });
}
