import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/chat_message_groups.dart';

void main() {
  test('groups adjacent messages from the same sender at five minutes', () {
    final messages = <MessageData>[
      _message(uuid: 'newer', sender: 'peer', timestamp: 600),
      _message(uuid: 'older', sender: 'peer', timestamp: 300),
    ];

    final groups = groupChatMessages(messages);

    expect(groups, hasLength(1));
    expect(groups.single.messages.map((message) => message.uuid),
        <String>['newer', 'older']);
    expect(groups.single.startIndex, 0);
    expect(groups.single.endIndex, 1);
    expect(groups.single.tailIndex, 0);
  });

  test('splits groups when the sender changes or threshold is exceeded', () {
    final messages = <MessageData>[
      _message(uuid: 'a-1', sender: 'a', timestamp: 1000),
      _message(uuid: 'b-1', sender: 'b', timestamp: 950),
      _message(uuid: 'b-2', sender: 'b', timestamp: 649),
    ];

    final groups = groupChatMessages(messages);

    expect(
      groups.map(
          (group) => group.messages.map((message) => message.uuid).toList()),
      <List<String>>[
        <String>['a-1'],
        <String>['b-1'],
        <String>['b-2'],
      ],
    );
  });

  test('treats every file message as a visual group boundary', () {
    final messages = <MessageData>[
      _message(uuid: 'text-new', sender: 'peer', timestamp: 900),
      _message(
        uuid: 'file',
        sender: 'peer',
        timestamp: 850,
        type: MessageEnum.File,
      ),
      _message(uuid: 'text-old', sender: 'peer', timestamp: 800),
    ];

    final groups = groupChatMessages(messages);

    expect(groups, hasLength(3));
    expect(
      groups.map((group) => group.messages.single.uuid),
      <String>['text-new', 'file', 'text-old'],
    );
  });

  test('preserves reverse-list order and covers every source index once', () {
    final messages = <MessageData>[
      _message(uuid: '4', sender: 'a', timestamp: 400),
      _message(uuid: '3', sender: 'a', timestamp: 350),
      _message(uuid: '2', sender: 'b', timestamp: 300),
      _message(uuid: '1', sender: 'b', timestamp: 250),
    ];

    final groups = groupChatMessages(messages);

    expect(
      groups.expand((group) => group.messages).map((message) => message.uuid),
      messages.map((message) => message.uuid),
    );
    expect(groups.map((group) => group.startIndex), <int>[0, 2]);
    expect(groups.map((group) => group.endIndex), <int>[1, 3]);
    expect(
      groups.expand((group) sync* {
        for (var index = group.startIndex; index <= group.endIndex; index++) {
          yield index;
        }
      }),
      <int>[0, 1, 2, 3],
    );
  });

  test('formats notification display text and falls back on malformed data',
      () {
    final notification = _message(
      uuid: 'notification',
      sender: 'peer',
      timestamp: 500,
      type: MessageEnum.Notification,
      content: '{"app":"Mail","title":"Hello","text":"Body"}',
    );
    final malformed = _message(
      uuid: 'malformed',
      sender: 'peer',
      timestamp: 400,
      type: MessageEnum.Notification,
      content: 'not-json',
    );

    expect(chatMessageDisplayText(notification), '【Mail】Hello\nBody');
    expect(chatMessageDisplayText(malformed), 'not-json');
  });

  test('filters existing and repeated UUIDs before AnimatedList insertion', () {
    final existing = <MessageData>[
      _message(uuid: 'existing', sender: 'peer', timestamp: 600),
    ];
    final incoming = <MessageData>[
      _message(uuid: 'existing', sender: 'peer', timestamp: 600),
      _message(uuid: 'new', sender: 'peer', timestamp: 500),
      _message(uuid: 'new', sender: 'peer', timestamp: 500),
    ];

    final unique = uniqueChatMessagesForInsertion(existing, incoming);

    expect(unique.map((message) => message.uuid), <String>['new']);
  });
}

MessageData _message({
  required String uuid,
  required String sender,
  required int timestamp,
  MessageEnum type = MessageEnum.Text,
  String? content,
}) {
  return MessageData(
    id: int.parse(uuid.replaceAll(RegExp(r'\D'), '').padLeft(1, '0')),
    sender: sender,
    receiver: 'me',
    name: type == MessageEnum.File ? 'file.txt' : '',
    clipboard: false,
    size: 0,
    type: type,
    content: content ?? uuid,
    message: '',
    timestamp: timestamp,
    uuid: uuid,
    acked: true,
    path: type == MessageEnum.File ? '/tmp/file.txt' : '',
    md5: '',
    fileTimestamp: 0,
  );
}
