import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text message body font size is slightly toned down', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final textMessageBuilder = RegExp(
      r'Widget _buildTextMessage\([\s\S]*?Widget _buildFileMessage',
    ).firstMatch(source)!.group(0)!;

    expect(textMessageBuilder, isNot(contains('isDesktop() ? 17 : 16.5')));
    expect(textMessageBuilder, contains('fontSize: isDesktop() ? 16.5 : 16'));
    expect(textMessageBuilder, contains('height: 1.55'));
  });
}
