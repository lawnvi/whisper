import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile client settings hide remote input entries', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final clientSettings = RegExp(
      r'class _ClientSettingsScreenState[\s\S]*?class _DeviceSettingTile',
    ).firstMatch(source)!.group(0)!;

    expect(clientSettings, contains('if (isDesktop()) {'));
    expect(clientSettings,
        contains('final showRemoteInputSettings = isDesktop();'));
    expect(
      RegExp(r'if \(showRemoteInputSettings\)[\s\S]*remoteInputAutoModeSetting')
          .hasMatch(clientSettings),
      isTrue,
    );
    expect(
      RegExp(r'if \(showRemoteInputSettings\)[\s\S]*remoteInputLayoutSetting')
          .hasMatch(clientSettings),
      isTrue,
    );
  });

  test('mobile conversation header never shows remote input action', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final getter = RegExp(
      r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;

    expect(getter, contains('isDesktop() &&'));
  });
}
