import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deleting a missing file message still deletes the message row', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();

    expect(source, contains('Future<void> _deleteMessageFileIfExists'));
    expect(source, contains('final file = File(path);'));
    expect(source, contains('await file.exists()'));
    expect(source, contains('FileSystemException'));

    final callback = RegExp(
      r'onDeleteMessage: \(message, \{deleteFile = false\}\) async \{[\s\S]*?\n            \},',
    ).firstMatch(source)!.group(0)!;

    expect(callback, isNot(contains('File(message.path).delete()')));
    expect(callback, contains('await _deleteMessageFileIfExists(message);'));
    expect(callback, contains('await _deleteItems(<int>[message.id]);'));
    expect(source, contains('onDeleteMessages: (messages) =>'));
    expect(source, contains('db.deleteMessages(ids)'));
  });
}
