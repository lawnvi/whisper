import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop file drop shares the native drag and drop plugin', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(pubspec, isNot(contains('desktop_drop:')));
    expect(pubspec, contains('super_drag_and_drop:'));
    expect(conversation, contains('DropRegion('));
    expect(conversation, contains('Formats.fileUri'));
    expect(
      conversation,
      contains('unawaited(_handleFileDrop(paths.cast<String>()))'),
    );
    expect(conversation, isNot(contains('DropTarget(')));
  });
}
