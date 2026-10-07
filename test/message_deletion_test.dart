import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/message_deletion.dart';

MessageData message({
  String sender = 'peer',
  String receiver = 'me',
  MessageEnum type = MessageEnum.File,
}) => MessageData(
  id: 1,
  sender: sender,
  receiver: receiver,
  name: 'file',
  clipboard: false,
  size: 1,
  type: type,
  content: '',
  message: '',
  timestamp: 1,
  uuid: 'test',
  acked: true,
  path: '',
  md5: '',
  fileTimestamp: 0,
);

void main() {
  test('only received files belong to the deletion policy', () {
    expect(canDeleteReceivedMessageFile(message(), 'me'), isTrue);
    for (final item in [
      message(sender: 'me', receiver: 'peer'),
      message(sender: 'me'),
      message(receiver: 'another'),
      message(type: MessageEnum.Text),
    ]) {
      expect(canDeleteReceivedMessageFile(item, 'me'), isFalse);
    }
    expect(canDeleteReceivedMessageFile(message(), null), isFalse);
  });

  test(
    'removes a received file, tolerates missing files, preserves originals',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'whisper-message-delete-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final received = await File(
        '${dir.path}/received',
      ).writeAsString('received');
      final source = await File('${dir.path}/source').writeAsString('original');
      await deleteReceivedMessageFile(
        message(),
        selfUid: 'me',
        path: received.path,
      );
      expect(await received.exists(), isFalse);
      await deleteReceivedMessageFile(
        message(),
        selfUid: 'me',
        path: received.path,
      );
      await deleteReceivedMessageFile(message(), selfUid: 'me', path: '');
      await deleteReceivedMessageFile(
        message(sender: 'me', receiver: 'peer'),
        selfUid: 'me',
        path: source.path,
      );
      await deleteReceivedMessageFile(
        message(sender: 'me'),
        selfUid: 'me',
        path: source.path,
      );
      await deleteReceivedMessageFile(
        message(),
        selfUid: null,
        path: source.path,
      );
      expect(await source.readAsString(), 'original');
    },
  );
}
