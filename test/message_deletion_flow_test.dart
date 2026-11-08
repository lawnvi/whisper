import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/widget/subtle_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/widget/chat_message_list.dart';

MessageData _message(int id, {bool file = true, bool sent = false}) =>
    MessageData(
      id: id,
      sender: sent ? 'me' : 'peer',
      receiver: sent ? 'peer' : 'me',
      name: 'message $id',
      clipboard: false,
      size: 1,
      type: file ? MessageEnum.File : MessageEnum.Text,
      content: 'message $id',
      message: '',
      timestamp: id,
      uuid: 'test-$id',
      acked: true,
      path: '/received-$id',
      md5: '',
      fileTimestamp: 0,
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<MessageData> messages,
  required Future<void> Function(List<MessageData>, bool) delete,
  bool desktopWorkspace = false,
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  final controller = ScrollController();
  addTearDown(controller.dispose);
  final listKey = GlobalKey<SliverAnimatedListState>();
  var selecting = false;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorKey: navigatorKey,
      home: StatefulBuilder(
        builder: (context, setState) {
          final list = ChatMessageList(
            buildFileMessage: (message, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(message.name),
            ),
            buildTextMessage: (message, _, trailing) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(message.content!),
            ),
            controller: controller,
            listKey: listKey,
            messages: messages,
            onOpenContainingFolder: (_) {},
            onOpenFile: (_) {},
            onCopyText: (_) {},
            onDeleteMessage: (message, {deleteFile = false}) =>
                delete([message], deleteFile),
            onDeleteMessages: (messages, {deleteFiles = false}) =>
                delete(messages, deleteFiles),
            onSelectionModeChanged: desktopWorkspace
                ? (active) => setState(() => selecting = active)
                : null,
            selfUid: 'me',
          );
          return Scaffold(
            body: desktopWorkspace
                ? Row(
                    children: [
                      const SizedBox(
                        width: 180,
                        child: TextField(key: ValueKey('device-search')),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(child: list),
                            WhisperAnimatedReveal(
                              visible: !selecting,
                              child: selecting
                                  ? null
                                  : const TextField(
                                      key: ValueKey('composer'),
                                      autofocus: true,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : list,
          );
        },
      ),
    ),
  );
}

Future<void> _action(WidgetTester tester, String action) async {
  await tester.longPress(find.text('message 1'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

void main() {
  for (final keep in [false, true]) {
    testWidgets('single file uses confirmation with keep=$keep', (
      tester,
    ) async {
      bool? deleteFiles;
      await _pump(
        tester,
        messages: [_message(1)],
        delete: (_, files) async => deleteFiles = files,
      );
      await _action(tester, '删除');
      expect(deleteFiles, isNull);
      expect(find.text('删除 (保留文件)'), findsNothing);
      final checkbox = find.byKey(const ValueKey('keep-received-files'));
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      if (keep) await tester.tap(checkbox);
      await tester.tap(find.byKey(const ValueKey('confirm-message-deletion')));
      await tester.pumpAndSettle();
      expect(deleteFiles, !keep);
    });
  }

  testWidgets(
    'cancel deletes nothing; sent originals have no delete-file option',
    (tester) async {
      var called = false;
      await _pump(
        tester,
        messages: [_message(1, sent: true)],
        delete: (_, files) async {
          called = true;
          expect(files, isFalse);
        },
      );
      await _action(tester, '删除');
      expect(find.byKey(const ValueKey('keep-received-files')), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(called, isFalse);
      await _action(tester, '删除');
      await tester.tap(find.byKey(const ValueKey('confirm-message-deletion')));
      await tester.pumpAndSettle();
      expect(called, isTrue);
    },
  );
}
