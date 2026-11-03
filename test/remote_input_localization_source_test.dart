import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device settings do not retain legacy remote input pages', () {
    final source = File('lib/page/settings.dart').readAsStringSync();
    final remoteInputSection = RegExp(
      r'class _ClientSettingsScreenState[\s\S]*$',
    ).firstMatch(source)!.group(0)!;

    expect(remoteInputSection, isNot(contains('remoteInputAutoModeSetting')));
    expect(remoteInputSection, isNot(contains('remoteInputLayoutSetting')));
    expect(
      remoteInputSection,
      isNot(contains('RemoteInputLayoutEditorScreen')),
    );
    expect(
      remoteInputSection,
      isNot(contains('AppLocalizations.of(context)?')),
    );
    expect(remoteInputSection, contains('GestureDetector('));
  });

  test('the input page has no hard-coded labels', () {
    final source = File(
      'lib/new_ui/input/shell_input_page.dart',
    ).readAsStringSync();

    for (final text in ['屏幕排列', '本机', '左侧', '右侧', '上方', '下方', '未贴边']) {
      expect(source, isNot(contains("'$text'")));
      expect(source, isNot(contains('"$text"')));
    }
  });
}
