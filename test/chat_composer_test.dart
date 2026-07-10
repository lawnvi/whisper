import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/chat_composer.dart';

void main() {
  test('send gate rejects overlapping actions and reopens after completion',
      () async {
    final gate = ChatComposerSendGate();
    final pending = Completer<bool>();
    var actions = 0;

    final first = gate.run(() {
      actions++;
      return pending.future;
    });
    expect(gate.isInFlight, isTrue);

    final duplicate = await gate.run(() async {
      actions++;
      return true;
    });
    expect(duplicate, isFalse);
    expect(actions, 1);

    pending.complete(true);
    expect(await first, isTrue);
    expect(gate.isInFlight, isFalse);

    expect(
        await gate.run(() async {
          actions++;
          return true;
        }),
        isTrue);
    expect(actions, 2);

    await expectLater(
      gate.run(() async => throw StateError('send failed')),
      throwsStateError,
    );
    expect(gate.isInFlight, isFalse);
    expect(await gate.run(() async => false), isFalse);
  });

  testWidgets('clipboard button previews without sending', (tester) async {
    var previews = 0;
    var clipboardSends = 0;

    await tester.pumpWidget(
      _composerApp(
        onPreviewClipboard: () async => previews++,
        onSendClipboardDraft: () async {
          clipboardSends++;
          return true;
        },
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
        onSendText: (text) async {
          sentText = text;
          return true;
        },
      ),
    );

    expect(find.byKey(ChatComposer.attachmentButtonKey), findsNothing);
    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pump();

    expect(sentText, 'hello');
    expect(controller.text, isEmpty);
  });

  testWidgets('send button keeps ordinary text when sending returns false',
      (tester) async {
    final controller = TextEditingController(text: 'retry me');

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        onSendText: (_) async => false,
      ),
    );

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pump();

    expect(controller.text, 'retry me');
  });

  testWidgets('send button keeps ordinary text when sending throws',
      (tester) async {
    final controller = TextEditingController(text: 'retry after error');

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        onSendText: (_) => Future<bool>.error(StateError('send failed')),
      ),
    );

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pump();

    expect(controller.text, 'retry after error');
  });

  testWidgets('send completion does not clear text appended after button tap',
      (tester) async {
    final pending = Completer<bool>();
    final controller = TextEditingController(text: 'snapshot');

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        onSendText: (_) => pending.future,
      ),
    );

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pump();
    controller.text = 'snapshot plus new text';
    pending.complete(true);
    await tester.pump();

    expect(controller.text, 'snapshot plus new text');
  });

  testWidgets('send completion clears matching text after selection moves',
      (tester) async {
    final pending = Completer<bool>();
    final controller = TextEditingController(text: 'snapshot');
    controller.selection = const TextSelection.collapsed(offset: 8);

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        onSendText: (_) => pending.future,
      ),
    );

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 0);
    pending.complete(true);
    await tester.pump();

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
        onSendClipboardDraft: () async {
          draftSends++;
          return true;
        },
        onSendText: (_) async {
          textSends++;
          return true;
        },
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
        onSendClipboardDraft: () async {
          draftSends++;
          return true;
        },
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

  testWidgets('Escape invalidates a pending clipboard read without a draft',
      (tester) async {
    var invalidations = 0;
    final focusNode = FocusNode();

    await tester.pumpWidget(
      _composerApp(
        focusNode: focusNode,
        onClearClipboardDraft: () => invalidations++,
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    expect(invalidations, 1);
  });

  testWidgets('Shift Enter is delegated to the text field without sending',
      (tester) async {
    var sends = 0;
    final controller = TextEditingController(text: 'first line');
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    final focusNode = FocusNode();

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        focusNode: focusNode,
        isInputEmpty: false,
        onSendText: (_) async {
          sends++;
          return true;
        },
      ),
    );

    final focus = _composerKeyboardFocus(tester);
    final node = FocusNode();
    focus.onKeyEvent!(node, _keyDown(LogicalKeyboardKey.shiftLeft));
    final result = focus.onKeyEvent!(node, _keyDown(LogicalKeyboardKey.enter));

    expect(sends, 0);
    expect(result, KeyEventResult.ignored);
    expect(controller.text, 'first line');
  });

  testWidgets('Enter handles empty and whitespace-only input', (tester) async {
    for (final initialText in <String>['', '   ']) {
      var sends = 0;
      final controller = TextEditingController(text: initialText);
      final focusNode = FocusNode();

      await tester.pumpWidget(
        _composerApp(
          controller: controller,
          focusNode: focusNode,
          isInputEmpty: initialText.isEmpty,
          onSendText: (_) async {
            sends++;
            return true;
          },
        ),
      );
      final result = _composerKeyboardFocus(tester).onKeyEvent!(
        FocusNode(),
        _keyDown(LogicalKeyboardKey.enter),
      );

      expect(sends, 0);
      expect(result, KeyEventResult.handled);
      expect(controller.text, initialText);
    }
  });

  testWidgets('Enter does not send text or drafts while loading',
      (tester) async {
    var textSends = 0;
    var draftSends = 0;
    final controller = TextEditingController(text: 'ordinary');
    final focusNode = FocusNode();

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        focusNode: focusNode,
        isInputEmpty: false,
        isLoading: true,
        pendingClipboardDraft:
            const PendingClipboardTextDraft('clipboard text'),
        onSendText: (_) async {
          textSends++;
          return true;
        },
        onSendClipboardDraft: () async {
          draftSends++;
          return true;
        },
      ),
    );

    final result = _composerKeyboardFocus(tester).onKeyEvent!(
      FocusNode(),
      _keyDown(LogicalKeyboardKey.enter),
    );

    expect(textSends, 0);
    expect(draftSends, 0);
    expect(result, KeyEventResult.handled);
    expect(controller.text, 'ordinary');
  });

  testWidgets('Enter clears only a successfully sent matching snapshot',
      (tester) async {
    final controller = TextEditingController(text: 'send with enter');

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        onSendText: (_) async => true,
      ),
    );

    final result = _composerKeyboardFocus(tester).onKeyEvent!(
      FocusNode(),
      _keyDown(LogicalKeyboardKey.enter),
    );
    await tester.pump();

    expect(result, KeyEventResult.handled);
    expect(controller.text, isEmpty);
  });

  testWidgets('Enter keeps text after failure and newer typing after success',
      (tester) async {
    final controller = TextEditingController(text: 'first attempt');

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        onSendText: (_) async => false,
      ),
    );

    _composerKeyboardFocus(tester).onKeyEvent!(
      FocusNode(),
      _keyDown(LogicalKeyboardKey.enter),
    );
    await tester.pump();
    expect(controller.text, 'first attempt');

    final pending = Completer<bool>();
    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        isInputEmpty: false,
        onSendText: (_) => pending.future,
      ),
    );
    _composerKeyboardFocus(tester).onKeyEvent!(
      FocusNode(),
      _keyDown(LogicalKeyboardKey.enter),
    );
    controller.text = 'first attempt plus new text';
    pending.complete(true);
    await tester.pump();

    expect(controller.text, 'first attempt plus new text');
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

  testWidgets('desktop paste starts one top-level clipboard transaction',
      (tester) async {
    var transactions = 0;
    final controller = TextEditingController(text: 'hello ');
    final focusNode = FocusNode();

    await tester.pumpWidget(
      _composerApp(
        controller: controller,
        focusNode: focusNode,
        isInputEmpty: false,
        onPasteClipboard: () async {
          transactions++;
          return 'world';
        },
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(transactions, 1);
    expect(controller.text, 'hello world');
  });
}

Widget _composerApp({
  TextEditingController? controller,
  FocusNode? focusNode,
  PendingClipboardDraft? pendingClipboardDraft,
  bool isInputEmpty = true,
  bool isLoading = false,
  Future<void> Function()? onPreviewClipboard,
  Future<bool> Function()? onSendClipboardDraft,
  VoidCallback? onClearClipboardDraft,
  Future<bool> Function(String)? onSendText,
  Future<String?> Function()? onPasteClipboard,
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
        isLoading: isLoading,
        isLocalhost: false,
        isDesktopStyle: true,
        keyPressedMap: Map<String, bool>.of(const <String, bool>{}),
        controller: controller ?? TextEditingController(),
        focusNode: focusNode ?? FocusNode(),
        pendingClipboardDraft: pendingClipboardDraft,
        onPickFiles: () async {},
        onPreviewClipboard: onPreviewClipboard ?? () async {},
        onSendClipboardDraft: onSendClipboardDraft ?? () async => true,
        onClearClipboardDraft: onClearClipboardDraft ?? () {},
        onSendText: onSendText ?? (_) async => true,
        onPasteClipboard: onPasteClipboard ?? () async => null,
      ),
    ),
  );
}

void _expectMinimumTarget(WidgetTester tester, Key key) {
  final size = tester.getSize(find.byKey(key));
  expect(size.width, greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
  expect(size.height, greaterThanOrEqualTo(WhisperUi.minInteractiveSize));
}

Focus _composerKeyboardFocus(WidgetTester tester) {
  return tester.widget<Focus>(
    find
        .ancestor(
          of: find.byKey(const ValueKey('chat-composer-textfield')),
          matching: find.byType(Focus),
        )
        .first,
  );
}

KeyDownEvent _keyDown(LogicalKeyboardKey key) {
  return KeyDownEvent(
    physicalKey: key == LogicalKeyboardKey.enter
        ? PhysicalKeyboardKey.enter
        : PhysicalKeyboardKey.shiftLeft,
    logicalKey: key,
    timeStamp: Duration.zero,
  );
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
          onSendClipboardDraft: () async => true,
          onClearClipboardDraft: () => setState(() => draft = null),
          onSendText: (_) async => true,
          onPasteClipboard: () async => null,
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
