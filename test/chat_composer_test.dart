import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/chat_composer.dart';

void main() {
  testWidgets('clipboard button previews without sending', (tester) async {
    var previews = 0;
    var clipboardSends = 0;

    await tester.pumpWidget(
      _composerApp(
        onPreviewClipboard: () async => previews++,
        onSendClipboardDraft: () async => clipboardSends++,
      ),
    );

    await tester.tap(find.byKey(ChatComposer.clipboardButtonKey));
    await tester.pump();

    expect(previews, 1);
    expect(clipboardSends, 0);
  });

  testWidgets('desktop composer sends ordinary text and clears only that text',
      (tester) async {
    String? sentText;
    final controller = TextEditingController(text: 'hello');

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        onSendText: (text) async => sentText = text,
      ),
    );

    expect(find.byKey(ChatComposer.attachmentButtonKey), findsNothing);
    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pump();

    expect(sentText, 'hello');
    expect(controller.text, isEmpty);
  });

  testWidgets('one typed draft replaces files image and text previews',
      (tester) async {
    final controller = TextEditingController(text: 'ordinary text');
    final drafts = <PendingClipboardDraft>[
      PendingClipboardImageDraft(_imageDraft()),
      const PendingClipboardTextDraft('replacement text'),
      const PendingClipboardFilesDraft(<ClipboardFileDraft>[
        ClipboardFileDraft(
          path: '/tmp/final.txt',
          fileName: 'final.txt',
          size: 12,
        ),
      ]),
      const PendingClipboardFilesDraft(<ClipboardFileDraft>[
        ClipboardFileDraft(
          path: '/tmp/report.pdf',
          fileName: 'report.pdf',
          size: 2048,
        ),
      ]),
    ];

    await tester.pumpWidget(
      _DraftHarness(controller: controller, replacements: drafts),
    );

    expect(find.byKey(ChatComposer.clipboardFilesPreviewKey), findsOneWidget);
    expect(find.byKey(ChatComposer.clipboardImagePreviewKey), findsNothing);
    expect(find.byKey(ChatComposer.clipboardTextPreviewKey), findsNothing);

    await tester.tap(find.byKey(ChatComposer.clipboardButtonKey));
    await tester.pump();
    expect(find.byKey(ChatComposer.clipboardImagePreviewKey), findsOneWidget);
    expect(find.byKey(ChatComposer.clipboardFilesPreviewKey), findsNothing);

    await tester.tap(find.byKey(ChatComposer.clipboardButtonKey));
    await tester.pump();
    expect(find.byKey(ChatComposer.clipboardTextPreviewKey), findsOneWidget);
    expect(find.byKey(ChatComposer.clipboardImagePreviewKey), findsNothing);

    await tester.tap(find.byKey(ChatComposer.clipboardButtonKey));
    await tester.pump();
    expect(find.byKey(ChatComposer.clipboardFilesPreviewKey), findsOneWidget);
    expect(find.byKey(ChatComposer.clipboardTextPreviewKey), findsNothing);
    expect(controller.text, 'ordinary text');
  });

  testWidgets('text draft is three lines with count and removable',
      (tester) async {
    const text = 'one\ntwo\nthree\nfour';
    var clears = 0;
    final controller = TextEditingController(text: 'keep ordinary text');

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        pendingClipboardDraft: const PendingClipboardTextDraft(text),
        onClearClipboardDraft: () => clears++,
      ),
    );

    final preview = tester.widget<SelectableText>(
      find.byKey(ChatComposer.clipboardTextPreviewKey),
    );
    expect(preview.maxLines, 3);
    expect(find.text('${text.runes.length} characters'), findsOneWidget);

    await tester.tap(find.byKey(ChatComposer.clipboardRemoveButtonKey));
    await tester.pump();

    expect(clears, 1);
    expect(controller.text, 'keep ordinary text');
  });

  testWidgets('send button sends draft without sending or clearing typed text',
      (tester) async {
    var draftSends = 0;
    var textSends = 0;
    final controller = TextEditingController(text: 'keep ordinary text');

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        pendingClipboardDraft:
            const PendingClipboardTextDraft('clipboard text'),
        onSendClipboardDraft: () async => draftSends++,
        onSendText: (_) async => textSends++,
      ),
    );

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pump();

    expect(draftSends, 1);
    expect(textSends, 0);
    expect(controller.text, 'keep ordinary text');
  });

  testWidgets('Enter sends and Escape removes a draft without clearing text',
      (tester) async {
    var draftSends = 0;
    var clears = 0;
    final controller = TextEditingController(text: 'keep ordinary text');
    final focusNode = FocusNode();

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        focusNode: focusNode,
        isInputEmpty: false,
        pendingClipboardDraft:
            const PendingClipboardTextDraft('clipboard text'),
        onSendClipboardDraft: () async => draftSends++,
        onClearClipboardDraft: () => clears++,
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(draftSends, 1);
    expect(controller.text, 'keep ordinary text');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(clears, 1);
    expect(controller.text, 'keep ordinary text');
  });

  testWidgets('composer buttons keep at least a 44 logical pixel target',
      (tester) async {
    await tester.pumpWidget(_composerApp());

    _expectMinimumTarget(tester, ChatComposer.clipboardButtonKey);
    _expectMinimumTarget(tester, ChatComposer.attachmentButtonKey);

    await tester.pumpWidget(
      _composerApp(
        pendingClipboardDraft:
            const PendingClipboardTextDraft('clipboard text'),
      ),
    );
    await tester.pump();

    _expectMinimumTarget(tester, ChatComposer.clipboardButtonKey);
    _expectMinimumTarget(tester, ChatComposer.clipboardRemoveButtonKey);
    _expectMinimumTarget(tester, ChatComposer.sendButtonKey);
  });

  testWidgets('desktop paste still prefers files before images and text',
      (tester) async {
    var fileReads = 0;
    var imageReads = 0;
    final controller = TextEditingController(text: 'hello ');
    final focusNode = FocusNode();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': 'world'};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        focusNode: focusNode,
        isInputEmpty: false,
        onPasteClipboardFiles: () async {
          fileReads++;
          return true;
        },
        onPasteClipboardImage: () async {
          imageReads++;
          return false;
        },
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(fileReads, 1);
    expect(imageReads, 0);
    expect(controller.text, 'hello ');
  });

  testWidgets('desktop paste falls back to ordinary text insertion',
      (tester) async {
    final controller = TextEditingController(text: 'hello ');
    final focusNode = FocusNode();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': 'world'};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        focusNode: focusNode,
        isInputEmpty: false,
        onPasteClipboardFiles: () async => false,
        onPasteClipboardImage: () async => false,
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.text, 'hello world');
  });
}

Widget _composerApp({
  TextEditingController? controller,
  FocusNode? focusNode,
  PendingClipboardDraft? pendingClipboardDraft,
  bool isInputEmpty = true,
  Future<void> Function()? onPreviewClipboard,
  Future<void> Function()? onSendClipboardDraft,
  VoidCallback? onClearClipboardDraft,
  Future<void> Function(String)? onSendText,
  Future<bool> Function()? onPasteClipboardFiles,
  Future<bool> Function()? onPasteClipboardImage,
}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ChatComposer(
        clipboardEnabled: true,
        canSend: true,
        isInputEmpty: isInputEmpty,
        isLoading: false,
        isLocalhost: false,
        isDesktopStyle: true,
        keyPressedMap: Map<String, bool>.of(const <String, bool>{}),
        controller: controller ?? TextEditingController(),
        focusNode: focusNode ?? FocusNode(),
        pendingClipboardDraft: pendingClipboardDraft,
        onPickFiles: () async {},
        onPreviewClipboard: onPreviewClipboard ?? () async {},
        onSendClipboardDraft: onSendClipboardDraft ?? () async {},
        onClearClipboardDraft: onClearClipboardDraft ?? () {},
        onSendText: onSendText ?? (_) async {},
        onPasteClipboardFiles: onPasteClipboardFiles,
        onPasteClipboardImage: onPasteClipboardImage,
      ),
    ),
  );
}

void _expectMinimumTarget(WidgetTester tester, Key key) {
  final size = tester.getSize(find.byKey(key));
  expect(size.width, greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
  expect(size.height, greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
}

ClipboardImageDraft _imageDraft() {
  return ClipboardImageDraft(
    path: '/tmp/Screenshot.png',
    fileName: 'Screenshot.png',
    size: _transparentPng.length,
    bytes: _transparentPng,
  );
}

class _DraftHarness extends StatefulWidget {
  const _DraftHarness({
    required this.controller,
    required this.replacements,
  });

  final TextEditingController controller;
  final List<PendingClipboardDraft> replacements;

  @override
  State<_DraftHarness> createState() => _DraftHarnessState();
}

class _DraftHarnessState extends State<_DraftHarness> {
  late PendingClipboardDraft? draft = widget.replacements.removeLast();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ChatComposer(
          clipboardEnabled: true,
          canSend: true,
          isInputEmpty: false,
          isLoading: false,
          isLocalhost: false,
          isDesktopStyle: true,
          keyPressedMap: Map<String, bool>.of(const <String, bool>{}),
          controller: widget.controller,
          focusNode: FocusNode(),
          pendingClipboardDraft: draft,
          onPickFiles: () async {},
          onPreviewClipboard: () async {
            setState(() => draft = widget.replacements.removeAt(0));
          },
          onSendClipboardDraft: () async {},
          onClearClipboardDraft: () => setState(() => draft = null),
          onSendText: (_) async {},
        ),
      ),
    );
  }
}

final _transparentPng = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);
