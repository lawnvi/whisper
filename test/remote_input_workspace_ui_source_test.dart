import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop sidebar owns the keyboard mouse workspace entry', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('RemoteInputWorkspaceScreen'));
    expect(source, contains('_buildDesktopRemoteInputWorkspaceAction'));
    expect(source, contains('Icons.keyboard_alt_outlined'));
  });

  test(
      'embedded conversation no longer exposes the single peer remote input action',
      () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final shouldShowRemoteInputAction = RegExp(
      r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;

    expect(shouldShowRemoteInputAction, contains('!widget.embedded'));
  });
}
