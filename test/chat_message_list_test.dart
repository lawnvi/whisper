import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/widget/chat_message_list.dart';

class _Counted extends StatefulWidget {
  const _Counted({required this.onCreated});

  final VoidCallback onCreated;

  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  @override
  void initState() {
    super.initState();
    widget.onCreated();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 120, height: 40);
}

void main() {
  testWidgets('a new message does not build the others again', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final listKey = GlobalKey<SliverAnimatedListState>();
    final messages = [
      _message(id: 2, content: 'b').copyWith(uuid: 'b'),
      _message(id: 1, content: 'a').copyWith(uuid: 'a'),
    ];
    var created = 0;
    Widget list() => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ChatMessageList(
          buildFileMessage: (_, __) => const SizedBox.shrink(),
          buildTextMessage: (_, __, ___) =>
              _Counted(onCreated: () => created++),
          controller: controller,
          listKey: listKey,
          messages: messages,
          onOpenContainingFolder: (_) {},
          onOpenFile: (_) {},
          onCopyText: (_) {},
          onDeleteMessage: (_, {deleteFile = false}) async {},
          onDeleteMessages: (_, {deleteFiles = false}) async {},
          selfUid: 'me',
        ),
      ),
    );
    await tester.pumpWidget(list());
    await tester.pumpAndSettle();
    expect(created, 2);

    messages.insert(0, _message(id: 3, content: 'c').copyWith(uuid: 'c'));
    listKey.currentState!.insertItem(0);
    await tester.pumpWidget(list());
    await tester.pumpAndSettle();
    // Only the new one. The two already there kept what they had.
    expect(created, 3);
    await tester.pumpWidget(const SizedBox.shrink());
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
