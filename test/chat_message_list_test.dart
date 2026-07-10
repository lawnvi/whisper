import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/widget/app_empty_state.dart';
import 'package:whisper/widget/chat_message_list.dart';
import 'package:whisper/widget/context_menu_region.dart';

void main() {
  testWidgets('shows a timestamp only on the tail of each visual group',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(uuid: 'a-new', sender: 'peer', timestamp: 600),
          _message(uuid: 'a-old', sender: 'peer', timestamp: 500),
          _message(uuid: 'b', sender: 'other', timestamp: 450),
        ],
        isMobileLayout: true,
      ),
    );

    expect(find.byKey(const ValueKey('chat-message-timestamp-a-new')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('chat-message-timestamp-a-old')),
        findsNothing);
    expect(
        find.byKey(const ValueKey('chat-message-timestamp-b')), findsOneWidget);
  });

  testWidgets('desktop hover reveals a fixed 44px copy action without shift',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(uuid: 'hover', sender: 'peer', timestamp: 600),
        ],
      ),
    );

    final bubble = find.byKey(const ValueKey('test-bubble-hover'));
    final beforeTopLeft = tester.getTopLeft(bubble);
    final beforeSize = tester.getSize(bubble);
    expect(find.byKey(const ValueKey('chat-message-copy-hover')), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(bubble));
    await tester.pump();

    final copy = find.byKey(const ValueKey('chat-message-copy-hover'));
    expect(copy, findsOneWidget);
    expect(tester.getSize(copy), const Size(44, 44));
    expect(tester.getTopLeft(bubble), beforeTopLeft);
    expect(tester.getSize(bubble), beforeSize);
    await mouse.removePointer();
  });

  testWidgets('desktop metadata stays adjacent to an intrinsic-width bubble',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(uuid: 'intrinsic', sender: 'peer', timestamp: 600),
        ],
        bubbleWidth: 120,
      ),
    );

    final bubble = find.byKey(const ValueKey('test-bubble-intrinsic'));
    expect(tester.getSize(bubble).width, 120);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(bubble));
    await tester.pump();

    final copy = find.byKey(const ValueKey('chat-message-copy-intrinsic'));
    expect(tester.getTopRight(bubble).dx, tester.getTopLeft(copy).dx);
    await mouse.removePointer();
  });

  testWidgets('outgoing desktop metadata stays on the bubble leading edge',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(
            uuid: 'outgoing',
            sender: 'me',
            receiver: 'peer',
            timestamp: 600,
          ),
        ],
        bubbleWidth: 120,
      ),
    );

    final bubble = find.byKey(const ValueKey('test-bubble-outgoing'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(bubble));
    await tester.pump();

    final copy = find.byKey(const ValueKey('chat-message-copy-outgoing'));
    expect(tester.getTopRight(copy).dx, tester.getTopLeft(bubble).dx);
    await mouse.removePointer();
  });

  testWidgets('desktop focus reveals the same copy action', (tester) async {
    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(uuid: 'focus', sender: 'peer', timestamp: 600),
        ],
      ),
    );

    expect(find.byKey(const ValueKey('chat-message-copy-focus')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(
        find.byKey(const ValueKey('chat-message-copy-focus')), findsOneWidget);
  });

  testWidgets('mobile keeps actions off-screen until the message is held',
      (tester) async {
    var copiedText = '';
    var deleted = false;
    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(uuid: 'mobile', sender: 'peer', timestamp: 600),
        ],
        isMobileLayout: true,
        onCopyText: (value) => copiedText = value,
        onDeleteMessage: (_, {deleteFile = false}) async {
          deleted = true;
        },
      ),
    );

    expect(find.byIcon(Icons.content_copy_rounded), findsNothing);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('test-bubble-mobile')),
        matching: find.byType(ContextMenuRegion),
      ),
      findsNothing,
    );
    await tester.longPress(find.byKey(const ValueKey('test-bubble-mobile')));
    await tester.pumpAndSettle();

    final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
      find.byType(AdaptiveTextSelectionToolbar),
    );
    expect(
      toolbar.buttonItems,
      contains(
        isA<ContextMenuButtonItem>()
            .having((item) => item.type, 'type', ContextMenuButtonType.copy),
      ),
    );
    expect(find.text('Copy Message Content'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Copy Message Content'));
    await tester.pumpAndSettle();
    expect(copiedText, 'mobile');

    await tester.longPress(find.byKey(const ValueKey('test-bubble-mobile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });

  testWidgets('renders localized connected and disconnected empty states',
      (tester) async {
    await tester.pumpWidget(
      _testApp(messages: const <MessageData>[], isConnected: true),
    );

    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(find.text('No messages yet'), findsOneWidget);
    expect(
      find.text('Send a message or file to start the conversation.'),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _testApp(messages: const <MessageData>[], isConnected: false),
    );
    await tester.pump();
    expect(
      find.text('Connect to this device before sending a message or file.'),
      findsOneWidget,
    );
  });

  testWidgets('AnimatedList insertion recomputes same and split groups',
      (tester) async {
    final harnessKey = GlobalKey<_MessageListHarnessState>();
    await tester.pumpWidget(
      _testAppWithHarness(
        key: harnessKey,
        messages: <MessageData>[
          _message(uuid: 'old', sender: 'peer', timestamp: 500),
        ],
      ),
    );

    harnessKey.currentState!.insertAt(
      0,
      _message(uuid: 'new', sender: 'peer', timestamp: 600),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-message-timestamp-new')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('chat-message-timestamp-old')), findsNothing);

    harnessKey.currentState!.insertAt(
      0,
      _message(uuid: 'split', sender: 'other', timestamp: 650),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-message-timestamp-split')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('chat-message-timestamp-new')),
        findsOneWidget);
  });

  testWidgets('uses four pixel in-group and twelve pixel group spacing',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(uuid: 'a-new', sender: 'a', timestamp: 600),
          _message(uuid: 'a-old', sender: 'a', timestamp: 500),
          _message(uuid: 'b-old', sender: 'b', timestamp: 450),
        ],
        isMobileLayout: true,
        bubbleWidth: 120,
        bubbleHeight: 40,
      ),
    );

    final newest = tester.getRect(
      find.byKey(const ValueKey('test-bubble-a-new')),
    );
    final olderSameGroup = tester.getRect(
      find.byKey(const ValueKey('test-bubble-a-old')),
    );
    final olderOtherGroup = tester.getRect(
      find.byKey(const ValueKey('test-bubble-b-old')),
    );
    final olderGroupTimestamp = tester.getRect(
      find.byKey(const ValueKey('chat-message-timestamp-b-old')),
    );
    expect(newest.top - olderSameGroup.bottom, 4);
    expect(olderGroupTimestamp.top, greaterThan(olderOtherGroup.bottom));
    expect(olderSameGroup.top - olderGroupTimestamp.bottom, 12);
  });

  testWidgets('deleting the group tail promotes the remaining message tail',
      (tester) async {
    final harnessKey = GlobalKey<_MessageListHarnessState>();
    await tester.pumpWidget(
      _testAppWithHarness(
        key: harnessKey,
        messages: <MessageData>[
          _message(uuid: 'new', sender: 'peer', timestamp: 600),
          _message(uuid: 'old', sender: 'peer', timestamp: 500),
        ],
      ),
    );

    harnessKey.currentState!.removeAt(0);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('chat-message-item-new')), findsNothing);
    expect(find.byKey(const ValueKey('chat-message-timestamp-old')),
        findsOneWidget);
  });

  testWidgets('same-uuid update stays in place and recomputes its group',
      (tester) async {
    final harnessKey = GlobalKey<_MessageListHarnessState>();
    await tester.pumpWidget(
      _testAppWithHarness(
        key: harnessKey,
        messages: <MessageData>[
          _message(uuid: 'stable', sender: 'peer', timestamp: 600),
          _message(uuid: 'old', sender: 'peer', timestamp: 500),
        ],
      ),
    );

    harnessKey.currentState!.updateUuid(
      'stable',
      _message(
        uuid: 'stable',
        sender: 'other',
        timestamp: 600,
        content: 'updated in place',
      ),
    );
    await tester.pump();

    expect(find.text('updated in place'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('chat-message-item-stable')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-message-timestamp-stable')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('chat-message-timestamp-old')),
        findsOneWidget);
  });

  testWidgets('pagination preserves group and AnimatedList index counts',
      (tester) async {
    final harnessKey = GlobalKey<_MessageListHarnessState>();
    await tester.pumpWidget(
      _testAppWithHarness(
        key: harnessKey,
        messages: <MessageData>[
          _message(uuid: 'new-a', sender: 'a', timestamp: 1200),
          _message(uuid: 'old-a', sender: 'a', timestamp: 1100),
        ],
      ),
    );

    harnessKey.currentState!.appendPage(<MessageData>[
      _message(uuid: 'page-a', sender: 'a', timestamp: 900),
      _message(uuid: 'page-b', sender: 'b', timestamp: 850),
    ]);
    await tester.pumpAndSettle();

    final items = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('chat-message-item-');
    });
    expect(items, findsNWidgets(4));
    expect(find.byKey(const ValueKey('chat-message-timestamp-new-a')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('chat-message-timestamp-old-a')),
        findsNothing);
    expect(find.byKey(const ValueKey('chat-message-timestamp-page-a')),
        findsNothing);
    expect(find.byKey(const ValueKey('chat-message-timestamp-page-b')),
        findsOneWidget);
  });

  testWidgets('desktop and mobile layouts do not overflow at 200 percent text',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(760, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(
            uuid: 'scaled',
            sender: 'peer',
            timestamp: 600,
            content:
                'A long selectable message that must wrap without overflow.',
          ),
        ],
        textScaler: const TextScaler.linear(2),
      ),
    );
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(320, 568);
    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(
            uuid: 'scaled-mobile',
            sender: 'peer',
            timestamp: 600,
            content:
                'A long selectable message that must wrap without overflow.',
          ),
        ],
        isMobileLayout: true,
        textScaler: const TextScaler.linear(2),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact desktop reserves only the 44px action slot',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      _testApp(
        messages: <MessageData>[
          _message(uuid: 'compact', sender: 'peer', timestamp: 600),
        ],
      ),
    );

    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('chat-message-metadata-compact')),
          )
          .width,
      44,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp({
  required List<MessageData> messages,
  bool isConnected = true,
  bool isMobileLayout = false,
  TextScaler textScaler = TextScaler.noScaling,
  double? bubbleWidth,
  double? bubbleHeight,
  void Function(String value)? onCopyText,
  Future<void> Function(MessageData message, {bool deleteFile})?
      onDeleteMessage,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(
      body: ChatMessageList(
        buildFileMessage: (message, _) => Text(message.name),
        buildTextMessage: (message, _) => Builder(
          builder: (context) {
            final text = message.content ?? '';
            final l10n = AppLocalizations.of(context)!;
            return Container(
              key: ValueKey('test-bubble-${message.uuid}'),
              width: bubbleWidth,
              height: bubbleHeight,
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                text,
                contextMenuBuilder: (context, editableTextState) =>
                    buildChatTextSelectionToolbar(
                  context,
                  editableTextState,
                  copyMessageLabel: l10n.copyMessage,
                  deleteMessageLabel: l10n.delete,
                  onCopyMessage: () => (onCopyText ?? (_) {})(text),
                  onDeleteMessage: () {
                    (onDeleteMessage ??
                        (_, {deleteFile = false}) async {})(message);
                  },
                ),
              ),
            );
          },
        ),
        controller: ScrollController(),
        listKey: GlobalKey<AnimatedListState>(),
        messages: messages,
        onOpenContainingFolder: (_) {},
        onOpenFile: (_) {},
        onCopyText: onCopyText ?? (_) {},
        onDeleteMessage: onDeleteMessage ?? (_, {deleteFile = false}) async {},
        selfUid: 'me',
        isConnected: isConnected,
        isMobileLayout: isMobileLayout,
        messageText: (message) => message.content ?? '',
      ),
    ),
  );
}

Widget _testAppWithHarness({
  required GlobalKey<_MessageListHarnessState> key,
  required List<MessageData> messages,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: _MessageListHarness(key: key, initialMessages: messages),
    ),
  );
}

class _MessageListHarness extends StatefulWidget {
  const _MessageListHarness({
    super.key,
    required this.initialMessages,
  });

  final List<MessageData> initialMessages;

  @override
  State<_MessageListHarness> createState() => _MessageListHarnessState();
}

class _MessageListHarnessState extends State<_MessageListHarness> {
  final GlobalKey<AnimatedListState> listKey = GlobalKey<AnimatedListState>();
  final ScrollController controller = ScrollController();
  late final List<MessageData> messages =
      List<MessageData>.of(widget.initialMessages);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void insertAt(int index, MessageData message) {
    setState(() => messages.insert(index, message));
    listKey.currentState!
        .insertItem(index, duration: const Duration(milliseconds: 1));
  }

  void removeAt(int index) {
    final removed = messages.removeAt(index);
    listKey.currentState!.removeItem(
      index,
      (context, animation) => Text(removed.uuid),
      duration: const Duration(milliseconds: 1),
    );
    setState(() {});
  }

  void updateUuid(String uuid, MessageData replacement) {
    final index = messages.indexWhere((message) => message.uuid == uuid);
    setState(() => messages[index] = replacement);
  }

  void appendPage(List<MessageData> page) {
    final index = messages.length;
    setState(() => messages.addAll(page));
    listKey.currentState!.insertAllItems(
      index,
      page.length,
      duration: const Duration(milliseconds: 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChatMessageList(
      buildFileMessage: (message, _) => Text(message.name),
      buildTextMessage: (message, _) => Builder(
        builder: (context) {
          final text = message.content ?? '';
          final l10n = AppLocalizations.of(context)!;
          return Container(
            key: ValueKey('test-bubble-${message.uuid}'),
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              text,
              contextMenuBuilder: (context, editableTextState) =>
                  buildChatTextSelectionToolbar(
                context,
                editableTextState,
                copyMessageLabel: l10n.copyMessage,
                deleteMessageLabel: l10n.delete,
                onCopyMessage: () {},
                onDeleteMessage: () {},
              ),
            ),
          );
        },
      ),
      controller: controller,
      listKey: listKey,
      messages: messages,
      onOpenContainingFolder: (_) {},
      onOpenFile: (_) {},
      onCopyText: (_) {},
      onDeleteMessage: (_, {deleteFile = false}) async {},
      selfUid: 'me',
      isConnected: true,
      isMobileLayout: true,
      messageText: (message) => message.content ?? '',
    );
  }
}

MessageData _message({
  required String uuid,
  required String sender,
  String receiver = 'me',
  required int timestamp,
  String? content,
  MessageEnum type = MessageEnum.Text,
}) {
  return MessageData(
    id: timestamp,
    sender: sender,
    receiver: receiver,
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
