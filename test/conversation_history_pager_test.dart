import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/conversation_history_pager.dart';

MessageData message(int id, {String? uuid}) => MessageData(
  id: id,
  sender: 'peer',
  receiver: 'self',
  name: '',
  clipboard: false,
  size: 0,
  type: MessageEnum.Text,
  timestamp: id,
  uuid: uuid ?? 'message-$id',
  acked: true,
  path: '',
  md5: '',
);

void main() {
  test(
    'history merge preserves live arrivals and removes overlapping rows',
    () {
      final existing = [message(22), message(21)];
      final page = unseenHistoryMessages(existing, [
        message(21),
        message(20),
        message(20),
        message(19, uuid: ''),
      ]);
      expect(page.map((m) => m.id), [20, 19]);
      expect(
        unseenHistoryMessages([message(19, uuid: '')], page).map((m) => m.id),
        [20],
      );
    },
  );
}
