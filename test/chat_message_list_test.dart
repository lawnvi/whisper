import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/message_link_text.dart';
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
  test('building a file message does not ask the disk every time', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final build = source.substring(
      source.indexOf('Widget _buildFileMessage('),
      source.indexOf('void _openMessageFile('),
    );
    expect(build, isNot(contains('existsSync')));
    expect(build, isNot(contains('typeSync')));
    expect(source, contains('_knownOnDisk.putIfAbsent'));
  });

  test('a page of history is not animated in', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final insert = source.substring(
      source.indexOf('void _insertItems('),
      source.indexOf('TransferSnapshot? _transferForMessage'),
    );
    expect(insert, contains('duration: Duration.zero'));
  });

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

  testWidgets('file and text bubbles use conversation width beside a sidebar', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final listKey = GlobalKey<SliverAnimatedListState>();
    final messages = [
      _message(id: 101, content: '').copyWith(type: MessageEnum.File),
      _message(
        id: 102,
        content: '',
      ).copyWith(type: MessageEnum.File, sender: 'me', receiver: 'peer'),
      _message(id: 103, content: 'long text'),
    ];
    for (final width in [704.0, 320.0]) {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 50),
                SizedBox(
                  width: width,
                  child: ChatMessageList(
                    buildFileMessage: (_, __) =>
                        const SizedBox(width: 10000, height: 60),
                    buildTextMessage: (_, __, ___) =>
                        const SizedBox(width: 10000, height: 40),
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
              ],
            ),
          ),
        ),
      );
      final incoming = tester.getRect(
        find.byKey(const ValueKey('message-bubble-101')),
      );
      final outgoing = tester.getRect(
        find.byKey(const ValueKey('message-bubble-102')),
      );
      final text = tester.getSize(
        find.byKey(const ValueKey('message-bubble-103')),
      );
      expect(incoming.width, lessThanOrEqualTo(276));
      expect(text.width, lessThanOrEqualTo((width - 32) * 0.72));
      expect(incoming.left, 50 + 16);
      expect(outgoing.right, 50 + width - 16);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('keeps breathing room below the newest message', (tester) async {
    final listKey = GlobalKey<SliverAnimatedListState>();
    final controller = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
            onDeleteMessages: (_, {deleteFiles = false}) async {},
            selfUid: 'me',
          ),
        ),
      ),
    );

    final list = tester.widget<SliverPadding>(find.byType(SliverPadding).first);
    expect(list.padding, const EdgeInsets.fromLTRB(16, 8, 16, 84));
  });

  testWidgets('long pressing a text message opens message actions', (
    tester,
  ) async {
    final listKey = GlobalKey<SliverAnimatedListState>();
    final controller = ScrollController();
    var copiedText = '';

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
            onDeleteMessages: (_, {deleteFiles = false}) async {},
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
    final listKey = GlobalKey<SliverAnimatedListState>();
    final controller = ScrollController();
    final deletedIds = <int>[];
    final selectionStates = <bool>[];
    final messages = <MessageData>[
      _message(id: 1, content: 'first message'),
      _message(id: 2, content: 'second message'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
            onDeleteMessages: (selected, {deleteFiles = false}) async {
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
    Color? rowColor(int id) =>
        (tester
                    .widget<DecoratedBox>(
                      find.byKey(ValueKey('message-row-$id')),
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(rowColor(1), WhisperColors.light.tint);
    expect(rowColor(2), isNull);

    await tester.tap(find.text('second message'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);
    expect(rowColor(2), WhisperColors.light.tint);

    await tester.tap(find.byKey(const ValueKey('delete-selected-messages')));
    await tester.pumpAndSettle();

    expect(find.text('删除 2 条消息'), findsOneWidget);
    expect(find.text('将删除所选消息，无法撤销。'), findsOneWidget);
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
    final listKey = GlobalKey<SliverAnimatedListState>();
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
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
            onDeleteMessages: (_, {deleteFiles = false}) async {},
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

  group('selecting a message of mine', () {
    for (final (name, theme, c) in [
      ('light', AppTheme.lightTheme, WhisperColors.light),
      ('dark', AppTheme.darkTheme, WhisperColors.dark),
    ]) {
      testWidgets('$name: selected text shows on its colour', (tester) async {
        late TextSelectionThemeData selection;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: MessageSelectionColors(
              mine: true,
              child: Builder(
                builder: (context) {
                  selection = TextSelectionTheme.of(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        double contrast(Color a, Color b) {
          final x = a.computeLuminance(), y = b.computeLuminance();
          return (math.max(x, y) + .05) / (math.min(x, y) + .05);
        }

        final highlight = selection.selectionColor!;
        expect(highlight.a, 1);
        expect(contrast(highlight, c.tintHover), greaterThan(1.5));
        expect(contrast(c.onTint, highlight), greaterThan(4.5));
      });
    }

    testWidgets('someone else\'s keeps the theme\'s selection', (tester) async {
      late TextSelectionThemeData selection;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: MessageSelectionColors(
            mine: false,
            child: Builder(
              builder: (context) {
                selection = TextSelectionTheme.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(selection.selectionColor, Radix.blueA5);
    });
  });
}
