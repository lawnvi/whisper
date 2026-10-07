import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:whisper/widget/subtle_motion.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/widget/chat_message_list.dart';
import 'package:whisper/widget/message_deletion_dialog.dart';

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
}) async {
  final controller = ScrollController();
  addTearDown(controller.dispose);
  final listKey = GlobalKey<AnimatedListState>();
  var selecting = false;
  await tester.pumpWidget(
    MaterialApp(
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

  for (final keep in [false, true]) {
    testWidgets('mixed multi-select shares the file choice keep=$keep', (
      tester,
    ) async {
      final deleted = <int>[];
      bool? deleteFiles;
      await _pump(
        tester,
        messages: [
          _message(1),
          _message(2, sent: true),
          _message(3, file: false),
        ],
        delete: (messages, files) async {
          deleted.addAll(messages.map((m) => m.id));
          deleteFiles = files;
        },
      );
      await _action(tester, '多选');
      await tester.tap(find.byTooltip('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-selected-messages')));
      await tester.pumpAndSettle();
      expect(find.text('删除 3 条消息'), findsOneWidget);
      expect(deleted, isEmpty);
      if (keep) {
        await tester.tap(find.byKey(const ValueKey('keep-received-files')));
      }
      await tester.tap(find.byKey(const ValueKey('confirm-message-deletion')));
      await tester.pumpAndSettle();
      expect(deleted, [1, 2, 3]);
      expect(deleteFiles, !keep);
      expect(
        find.byKey(const ValueKey('message-selection-toolbar')),
        findsNothing,
      );
    });
  }

  testWidgets('Escape dismisses confirmation first, then exits selection', (
    tester,
  ) async {
    await _pump(
      tester,
      messages: [_message(1)],
      delete: (_, _) async => fail('Must not delete'),
    );
    await _action(tester, '多选');
    await tester.tap(find.byKey(const ValueKey('delete-selected-messages')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('confirm-message-deletion')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('message-selection-toolbar')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('message-selection-toolbar')),
      findsNothing,
    );
  });

  for (final focusSearch in [false, true]) {
    testWidgets(
      'desktop right-click selection exits on Escape; search focus=$focusSearch',
      (tester) async {
        await _pump(
          tester,
          messages: [_message(1)],
          delete: (_, _) async => fail('Must not delete'),
          desktopWorkspace: true,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('message 1'),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('多选'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('message-selection-toolbar')),
          findsOneWidget,
        );
        if (focusSearch) {
          await tester.tap(find.byKey(const ValueKey('device-search')));
          await tester.enterText(
            find.byKey(const ValueKey('device-search')),
            'desk',
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('message-selection-toolbar')),
          findsNothing,
        );
        if (focusSearch) expect(find.text('desk'), findsOneWidget);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      }),
    );
  }

  testWidgets(
    'desktop selection Escape yields to overlays and unregisters on disposal',
    (tester) async {
      await _pump(
        tester,
        messages: [_message(1)],
        delete: (_, _) async => fail('Must not delete'),
        desktopWorkspace: true,
      );
      await _action(tester, '多选');
      final context = tester.element(find.byType(ChatMessageList));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('Other dialog')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Other dialog'), findsNothing);
      expect(
        find.byKey(const ValueKey('message-selection-toolbar')),
        findsOneWidget,
      );
      final navigator = Navigator.of(context);
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-selection-toolbar')),
        findsOneWidget,
      );
      var escapeReceived = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  escapeReceived = true;
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: const Text('Replacement workspace'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(escapeReceived, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('failed deletion shows feedback and retains selected messages', (
    tester,
  ) async {
    await _pump(
      tester,
      messages: [_message(1)],
      delete: (_, _) async => throw StateError('test failure'),
    );
    await _action(tester, '多选');
    await tester.tap(find.byKey(const ValueKey('delete-selected-messages')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-message-deletion')));
    await tester.pumpAndSettle();
    expect(find.text('删除未完成，请重试。'), findsOneWidget);
    expect(find.text('已选 1 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape cannot leave selection during an in-flight deletion', (
    tester,
  ) async {
    final done = Completer<void>();
    await _pump(tester, messages: [_message(1)], delete: (_, _) => done.future);
    await _action(tester, '多选');
    await tester.tap(find.byKey(const ValueKey('delete-selected-messages')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-message-deletion')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('message-selection-toolbar')),
      findsOneWidget,
    );
    done.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('message-selection-toolbar')),
      findsNothing,
    );
  });

  testWidgets('confirmation fits a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(), home: const Scaffold()),
    );
    final result = showMessageDeletionDialog(
      tester.element(find.byType(Scaffold)),
      count: 12,
      hasReceivedFiles: true,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}
