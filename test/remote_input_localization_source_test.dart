import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings remote input labels use AppLocalizations', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final remoteInputSection = RegExp(
      r'class _ClientSettingsScreenState[\s\S]*$',
    ).firstMatch(source)!.group(0)!;

    for (final text in [
      '键鼠共享自动模式',
      '屏幕排列',
      '关闭',
      '本机控制对端',
      '对端控制本机',
      '左侧',
      '右侧',
      '上方',
      '下方',
      '未贴边',
    ]) {
      expect(remoteInputSection, isNot(contains("'$text'")));
      expect(remoteInputSection, isNot(contains('"$text"')));
    }

    expect(
      remoteInputSection,
      contains('l10n.remoteInputAutoModeSetting('),
    );
    expect(
      remoteInputSection,
      contains('l10n.remoteInputLayoutSetting('),
    );
    expect(remoteInputSection, contains('l10n.remoteInputAutoModeTitle'));
  });

  test('remote input layout editor labels use AppLocalizations', () {
    final source = File('lib/remote_input/remote_input_layout_editor.dart')
        .readAsStringSync();

    for (final text in [
      '屏幕排列',
      '保存',
      '当前',
      '贴左',
      '贴右',
      '贴上',
      '贴下',
      '本机',
      '对端',
      '左侧',
      '右侧',
      '上方',
      '下方',
      '未贴边',
    ]) {
      expect(source, isNot(contains("'$text'")));
      expect(source, isNot(contains('"$text"')));
    }

    expect(source, contains('l10n.remoteInputLayoutTitle'));
    expect(source, contains('l10n.remoteInputCurrentEdge('));
    expect(source, contains('l10n.remoteInputSnapLeft'));
    expect(source, contains('l10n.remoteInputLocalScreen'));
    expect(source, contains('l10n.remoteInputPeerScreen'));
  });
}
