import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/widget/chat_message_list.dart';

void main() {
  testWidgets('long pressing a text message opens message actions',
      (tester) async {
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
}
