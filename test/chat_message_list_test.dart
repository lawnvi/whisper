import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/widget/chat_message_list.dart';

void main() {
  testWidgets('keeps breathing room below the newest message', (tester) async {
    final listKey = GlobalKey<AnimatedListState>();
    final controller = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            buildFileMessage: (_, __) => const SizedBox.shrink(),
            buildTextMessage: (message, _, __) => Text(message.content ?? ''),
            controller: controller,
            listKey: listKey,
            messages: <MessageData>[_message(id: 1, content: 'latest')],
            onOpenContainingFolder: (_) {},
            onOpenFile: (_) {},
            onCopyText: (_) {},
            onDeleteMessage: (_, {deleteFile = false}) async {},
            onDeleteMessages: (_) async {},
            selfUid: 'me',
          ),
        ),
      ),
    );

    final list = tester.widget<AnimatedList>(find.byType(AnimatedList));
    expect(list.padding, const EdgeInsets.only(bottom: 12));
  });

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
            buildTextMessage: (message, _, trailingAction) => Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    message.content ?? '',
                    contextMenuBuilder: (context, editableTextState) {
                      return AdaptiveTextSelectionToolbar(
                        anchors: editableTextState.contextMenuAnchors,
                        children: const [],
                      );
                    },
                  ),
                  if (trailingAction != null) trailingAction,
                ],
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
            buildTextMessage: (message, _, trailingAction) => Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message.content ?? ''),
                  if (trailingAction != null) trailingAction,
                ],
              ),
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

  testWidgets('file message context menu copies the received file', (
    tester,
  ) async {
    final listKey = GlobalKey<AnimatedListState>();
    final controller = ScrollController();
    MessageData? copiedFile;
    const message = MessageData(
      id: 7,
      sender: 'peer',
      receiver: 'me',
      name: 'received-image.jpg',
      clipboard: false,
      size: 128,
      type: MessageEnum.File,
      content: '',
      message: '',
      timestamp: 7,
      uuid: 'file-message-7',
      acked: true,
      path: '/tmp/received-image.jpg',
      md5: '',
      fileTimestamp: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: ChatMessageList(
            buildFileMessage: (_, __) => const Text('received image'),
            buildTextMessage: (_, __, ___) => const SizedBox.shrink(),
            controller: controller,
            listKey: listKey,
            messages: const <MessageData>[message],
            onOpenContainingFolder: (_) {},
            onOpenFile: (_) {},
            onCopyText: (_) {},
            onCopyFile: (value) async {
              copiedFile = value;
            },
            onDeleteMessage: (_, {deleteFile = false}) async {},
            onDeleteMessages: (_) async {},
            selfUid: 'me',
          ),
        ),
      ),
    );

    await tester.tap(
      find.text('received image'),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('复制文件'), findsOneWidget);

    await tester.tap(find.text('复制文件'));
    await tester.pumpAndSettle();
    expect(copiedFile?.id, 7);
  });

  testWidgets('copy icon morphs into a check and resets', (tester) async {
    final listKey = GlobalKey<AnimatedListState>();
    final controller = ScrollController();
    var copied = '';
    final message = _message(id: 8, content: 'copy me');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            buildFileMessage: (_, __) => const SizedBox.shrink(),
            buildTextMessage: (message, _, trailingAction) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message.content ?? ''),
                if (trailingAction != null) trailingAction,
              ],
            ),
            controller: controller,
            listKey: listKey,
            messages: <MessageData>[message],
            onOpenContainingFolder: (_) {},
            onOpenFile: (_) {},
            onCopyText: (value) => copied = value,
            onDeleteMessage: (_, {deleteFile = false}) async {},
            onDeleteMessages: (_) async {},
            selfUid: 'me',
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('message-copy-8')));
    await tester.pump(const Duration(milliseconds: 180));
    expect(copied, 'copy me');
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
  });

  test('timestamps appear only at the start of five-minute clusters', () {
    final messages = <MessageData>[
      _message(id: 3, content: 'newest', timestamp: 1000),
      _message(id: 2, content: 'same cluster', timestamp: 940),
      _message(id: 1, content: 'older cluster', timestamp: 300),
    ];

    expect(shouldShowChatTimestamp(messages, 0), isFalse);
    expect(shouldShowChatTimestamp(messages, 1), isTrue);
    expect(shouldShowChatTimestamp(messages, 2), isTrue);
  });
}

MessageData _message({
  required int id,
  required String content,
  int? timestamp,
}) {
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
    timestamp: timestamp ?? id,
    uuid: 'message-$id',
    acked: true,
    path: '',
    md5: '',
    fileTimestamp: 0,
  );
}
