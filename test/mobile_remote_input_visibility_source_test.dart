import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile conversation header never shows remote input action', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final getter = RegExp(
      r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;

    expect(getter, contains('isDesktop() &&'));
  });
}
