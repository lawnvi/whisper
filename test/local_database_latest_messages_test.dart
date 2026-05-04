import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

MessageData buildMessage({
  required int id,
  required String sender,
  required String receiver,
  required String content,
}) {
  return MessageData(
    id: id,
    deviceId: null,
    sender: sender,
    receiver: receiver,
    name: '',
    clipboard: false,
    size: 0,
    type: MessageEnum.Text,
    content: content,
    message: '',
    timestamp: id,
    uuid: 'uuid-$id',
    acked: true,
    path: '',
    md5: '',
    fileTimestamp: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalDatabase.fetchLatestMessagesByPeers', () {
    late LocalDatabase database;

    setUp(() {
      SharedPreferences.setMockInitialValues({
        '_uuid': 'self-device',
        '_name': 'Local device',
        '_port': 10002,
        '_is_server': false,
        '_clipboard': true,
        '_no_auth': false,
        '_password': '',
      });
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('does not assign remote conversation messages to localhost entry',
        () async {
      await database.insertMessage(
        buildMessage(
          id: 1,
          sender: 'self-device',
          receiver: '',
          content: 'local draft',
        ),
      );
      await database.insertMessage(
        buildMessage(
          id: 2,
          sender: 'peer-a',
          receiver: 'self-device',
          content: 'message from peer',
        ),
      );
      await database.insertMessage(
        buildMessage(
          id: 3,
          sender: 'self-device',
          receiver: 'peer-a',
          content: 'reply to peer',
        ),
      );

      final latest = await database.fetchLatestMessagesByPeers([
        'self-device',
        'peer-a',
      ]);

      expect(latest['self-device']?.content, 'local draft');
      expect(latest['peer-a']?.content, 'reply to peer');
    });
  });
}
