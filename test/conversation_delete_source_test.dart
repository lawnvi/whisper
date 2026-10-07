import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('single and batch deletion use the same received-file policy', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    expect(
      source,
      contains('_deleteMessages([message], deleteFiles: deleteFile)'),
    );
    expect(source, contains('onDeleteMessages: _deleteMessages'));
    final deletion = source.substring(
      source.indexOf('Future<void> _deleteMessages('),
      source.indexOf('Future<void> _deleteItems('),
    );
    expect(
      deletion,
      contains('canDeleteReceivedMessageFile(message, self?.uid)'),
    );
    expect(
      deletion.indexOf('await _cancelTransfer('),
      lessThan(deletion.indexOf('await deleteReceivedMessageFile(')),
    );
    expect(deletion, contains('path: _effectiveMessagePath(message)'));
    expect(
      deletion,
      contains('await _deleteItems(messages.map((message) => message.id))'),
    );
    expect(source, contains('db.deleteMessages(ids)'));
  });
}
