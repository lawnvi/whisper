import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/widget/chat_composer.dart';

void main() {
  testWidgets('desktop composer shows attachment as primary action when empty',
      (tester) async {
    var pickedFiles = 0;
    var sentClipboard = 0;
    var sentText = 0;
    final controller = TextEditingController();
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: true,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: true,
            keyPressedMap: Map<String, bool>.of(const <String, bool>{}),
            controller: controller,
            focusNode: focusNode,
            onPickFiles: () async {
              pickedFiles++;
            },
            onSendClipboard: () async {
              sentClipboard++;
            },
            onSendText: (text) async {
              sentText++;
            },
          ),
        ),
      ),
    );

    expect(find.byKey(ChatComposer.desktopContainerKey), findsOneWidget);
    expect(find.byKey(ChatComposer.attachmentButtonKey), findsOneWidget);
    expect(find.byKey(ChatComposer.clipboardButtonKey), findsOneWidget);
    expect(find.byKey(ChatComposer.sendButtonKey), findsNothing);

    await tester.tap(find.byKey(ChatComposer.attachmentButtonKey));
    await tester.pumpAndSettle();
    expect(pickedFiles, 1);
    expect(sentClipboard, 0);
    expect(sentText, 0);
  });

  testWidgets('desktop composer swaps to send action when text exists',
      (tester) async {
    String? sentText;
    final controller = TextEditingController(text: 'hello');
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: false,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: true,
            keyPressedMap: Map<String, bool>.of(const <String, bool>{}),
            controller: controller,
            focusNode: focusNode,
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (text) async {
              sentText = text;
            },
          ),
        ),
      ),
    );

    expect(find.byKey(ChatComposer.attachmentButtonKey), findsNothing);
    expect(find.byKey(ChatComposer.sendButtonKey), findsOneWidget);

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pumpAndSettle();

    expect(sentText, 'hello');
    expect(controller.text, '');
  });

  testWidgets('mobile composer also toggles between attachment and send',
      (tester) async {
    final emptyController = TextEditingController();
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: true,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: false,
            keyPressedMap: const <String, bool>{},
            controller: emptyController,
            focusNode: focusNode,
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (text) async {},
          ),
        ),
      ),
    );

    expect(find.byKey(ChatComposer.attachmentButtonKey), findsOneWidget);
    expect(find.byKey(ChatComposer.sendButtonKey), findsNothing);

    final filledController = TextEditingController(text: 'hello');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: false,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: false,
            keyPressedMap: const <String, bool>{},
            controller: filledController,
            focusNode: FocusNode(),
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (text) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byKey(ChatComposer.attachmentButtonKey), findsNothing);
    expect(find.byKey(ChatComposer.sendButtonKey), findsOneWidget);
  });

  testWidgets('desktop composer previews a pasted clipboard image before send',
      (tester) async {
    var pickedFiles = 0;
    var sentImages = 0;
    var clearedImages = 0;
    final draft = ClipboardImageDraft(
      path: '/tmp/Screenshot.png',
      fileName: 'Screenshot.png',
      size: _transparentPng.length,
      bytes: _transparentPng,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: true,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: true,
            keyPressedMap: const <String, bool>{},
            controller: TextEditingController(),
            focusNode: FocusNode(),
            pendingClipboardImage: draft,
            onPickFiles: () async {
              pickedFiles++;
            },
            onSendClipboard: () async {},
            onSendText: (text) async {},
            onPasteClipboardImage: () async => true,
            onSendClipboardImage: () async {
              sentImages++;
            },
            onClearClipboardImage: () {
              clearedImages++;
            },
          ),
        ),
      ),
    );

    expect(find.byKey(ChatComposer.clipboardImagePreviewKey), findsOneWidget);
    expect(find.text('Screenshot.png'), findsOneWidget);
    expect(find.byKey(ChatComposer.attachmentButtonKey), findsNothing);
    expect(find.byKey(ChatComposer.sendButtonKey), findsOneWidget);

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pumpAndSettle();

    expect(sentImages, 1);
    expect(pickedFiles, 0);

    await tester.tap(find.byKey(ChatComposer.clipboardImageRemoveButtonKey));
    await tester.pumpAndSettle();

    expect(clearedImages, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: true,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: true,
            keyPressedMap: const <String, bool>{},
            controller: TextEditingController(),
            focusNode: FocusNode(),
            onPickFiles: () async {
              pickedFiles++;
            },
            onSendClipboard: () async {},
            onSendText: (text) async {},
            onPasteClipboardImage: () async => true,
            onSendClipboardImage: () async {
              sentImages++;
            },
            onClearClipboardImage: () {
              clearedImages++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ChatComposer.clipboardImagePreviewKey), findsNothing);
    expect(find.byKey(ChatComposer.attachmentButtonKey), findsOneWidget);
    expect(find.byKey(ChatComposer.sendButtonKey), findsNothing);
  });

  testWidgets('desktop composer sends a pending clipboard image on Enter',
      (tester) async {
    var sentImages = 0;
    String? sentText;
    final controller = TextEditingController(text: 'keep this text');
    final focusNode = FocusNode();
    final draft = ClipboardImageDraft(
      path: '/tmp/Screenshot.png',
      fileName: 'Screenshot.png',
      size: _transparentPng.length,
      bytes: _transparentPng,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: false,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: true,
            keyPressedMap: Map<String, bool>.of(const <String, bool>{}),
            controller: controller,
            focusNode: focusNode,
            pendingClipboardImage: draft,
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (text) async {
              sentText = text;
            },
            onSendClipboardImage: () async {
              sentImages++;
            },
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sentImages, 1);
    expect(sentText, isNull);
    expect(controller.text, 'keep this text');
  });

  testWidgets('desktop composer previews pasted clipboard files before send',
      (tester) async {
    var pickedFiles = 0;
    var sentFiles = 0;
    var clearedFiles = 0;
    final drafts = <ClipboardFileDraft>[
      const ClipboardFileDraft(
        path: '/tmp/report.pdf',
        fileName: 'report.pdf',
        size: 2048,
      ),
      const ClipboardFileDraft(
        path: '/tmp/photo.jpg',
        fileName: 'photo.jpg',
        size: 4096,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: true,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: true,
            keyPressedMap: const <String, bool>{},
            controller: TextEditingController(),
            focusNode: FocusNode(),
            pendingClipboardFiles: drafts,
            onPickFiles: () async {
              pickedFiles++;
            },
            onSendClipboard: () async {},
            onSendText: (text) async {},
            onSendClipboardFiles: () async {
              sentFiles++;
            },
            onClearClipboardFiles: () {
              clearedFiles++;
            },
          ),
        ),
      ),
    );

    expect(find.byKey(ChatComposer.clipboardFilesPreviewKey), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.textContaining('2 files'), findsOneWidget);
    expect(find.byKey(ChatComposer.attachmentButtonKey), findsNothing);
    expect(find.byKey(ChatComposer.sendButtonKey), findsOneWidget);

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pumpAndSettle();

    expect(sentFiles, 1);
    expect(pickedFiles, 0);

    await tester.tap(find.byKey(ChatComposer.clipboardFilesRemoveButtonKey));
    await tester.pumpAndSettle();

    expect(clearedFiles, 1);
  });

  testWidgets('desktop paste sends copied files before images or text',
      (tester) async {
    var filePasteAttempts = 0;
    var imagePasteAttempts = 0;
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
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: false,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: true,
            keyPressedMap: const <String, bool>{},
            controller: controller,
            focusNode: focusNode,
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (text) async {},
            onPasteClipboardFiles: () async {
              filePasteAttempts++;
              return true;
            },
            onPasteClipboardImage: () async {
              imagePasteAttempts++;
              return false;
            },
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(filePasteAttempts, 1);
    expect(imagePasteAttempts, 0);
    expect(controller.text, 'hello ');
  });

  testWidgets('desktop composer falls back to text paste when no image exists',
      (tester) async {
    var imagePasteAttempts = 0;
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
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: false,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: true,
            keyPressedMap: const <String, bool>{},
            controller: controller,
            focusNode: focusNode,
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (text) async {},
            onPasteClipboardFiles: () async => false,
            onPasteClipboardImage: () async {
              imagePasteAttempts++;
              return false;
            },
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(imagePasteAttempts, 1);
    expect(controller.text, 'hello world');
  });

  testWidgets('mobile composer does not render clipboard file preview',
      (tester) async {
    const drafts = <ClipboardFileDraft>[
      ClipboardFileDraft(
        path: '/tmp/report.pdf',
        fileName: 'report.pdf',
        size: 2048,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: true,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: false,
            keyPressedMap: const <String, bool>{},
            controller: TextEditingController(),
            focusNode: FocusNode(),
            pendingClipboardFiles: drafts,
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (text) async {},
          ),
        ),
      ),
    );

    expect(find.byKey(ChatComposer.clipboardFilesPreviewKey), findsNothing);
  });

  testWidgets('mobile composer does not render clipboard image preview',
      (tester) async {
    final draft = ClipboardImageDraft(
      path: '/tmp/Screenshot.png',
      fileName: 'Screenshot.png',
      size: _transparentPng.length,
      bytes: _transparentPng,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            clipboardEnabled: true,
            isInputEmpty: true,
            isLoading: false,
            isLocalhost: false,
            canSend: true,
            isDesktopStyle: false,
            keyPressedMap: const <String, bool>{},
            controller: TextEditingController(),
            focusNode: FocusNode(),
            pendingClipboardImage: draft,
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (text) async {},
          ),
        ),
      ),
    );

    expect(find.byKey(ChatComposer.clipboardImagePreviewKey), findsNothing);
  });
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
