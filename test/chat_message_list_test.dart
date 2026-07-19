import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/widget/chat_message_list.dart';

void main() {
  testWidgets('long pressing a text message opens message actions', (
    tester,
  ) async {
    final listKey = GlobalKey<AnimatedListState>();
    final controller = ScrollController();
    var copiedText = '';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            buildFileMessage: (_, __) => const SizedBox.shrink(),
            buildTextMessage: (message, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText(
                message.content ?? '',
                contextMenuBuilder: (context, editableTextState) {
                  return AdaptiveTextSelectionToolbar(
                    anchors: editableTextState.contextMenuAnchors,
                    children: const [],
                  );
                },
              ),
            ),
            controller: controller,
            listKey: listKey,
            messages: const [
              MessageData(
                id: 1,
                sender: 'peer',
                receiver: 'me',
                name: '',
                clipboard: false,
                size: 0,
                type: MessageEnum.Text,
                content: 'hello from mobile',
                message: '',
                timestamp: 1,
                uuid: 'message-1',
                acked: true,
                path: '',
                md5: '',
                fileTimestamp: 0,
              ),
            ],
            onOpenContainingFolder: (_) {},
            onOpenFile: (_) {},
            onCopyText: (content) {
              copiedText = content;
            },
            onDeleteMessage: (_, {deleteFile = false}) async {},
            onDeleteMessages: (_) async {},
            selfUid: 'me',
          ),
        ),
      ),
    );

    await tester.longPress(find.text('hello from mobile'));
    await tester.pumpAndSettle();

    expect(find.text('复制消息'), findsOneWidget);

    await tester.tap(find.text('复制消息'));
    await tester.pumpAndSettle();

    expect(copiedText, 'hello from mobile');
  });

  testWidgets('selects multiple messages and deletes them together', (
    tester,
  ) async {
    final listKey = GlobalKey<AnimatedListState>();
    final controller = ScrollController();
    final deletedIds = <int>[];
    final selectionStates = <bool>[];
    final messages = <MessageData>[
      _message(id: 1, content: 'first message'),
      _message(id: 2, content: 'second message'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            buildFileMessage: (_, __) => const SizedBox.shrink(),
            buildTextMessage: (message, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(message.content ?? ''),
            ),
            controller: controller,
            listKey: listKey,
            messages: messages,
            onOpenContainingFolder: (_) {},
            onOpenFile: (_) {},
            onCopyText: (_) {},
            onDeleteMessage: (_, {deleteFile = false}) async {},
            onDeleteMessages: (selected) async {
              deletedIds.addAll(selected.map((message) => message.id));
            },
            onSelectionModeChanged: selectionStates.add,
            selfUid: 'me',
          ),
        ),
      ),
    );

    await tester.longPress(find.text('first message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('message-selection-toolbar')),
      findsOneWidget,
    );
    expect(find.text('已选 1 条'), findsOneWidget);

    await tester.tap(find.text('second message'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-selected-messages')));
    await tester.pumpAndSettle();

    expect(find.text('删除 2 条消息'), findsOneWidget);
    expect(find.text('将删除所选聊天记录，本地文件会保留。'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    expect(deletedIds, <int>[1, 2]);
    expect(selectionStates, <bool>[true, false]);
    expect(
      find.byKey(const ValueKey('message-selection-toolbar')),
      findsNothing,
    );
  });
}

MessageData _message({required int id, required String content}) {
  return MessageData(
    id: id,
    sender: 'peer',
    receiver: 'me',
    name: '',
    clipboard: false,
    size: 0,
    type: MessageEnum.Text,
    content: content,
    message: '',
    timestamp: id,
    uuid: 'message-$id',
    acked: true,
    path: '',
    md5: '',
    fileTimestamp: 0,
  );
}
