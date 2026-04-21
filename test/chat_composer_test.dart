import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
            keyPressedMap: const <String, bool>{},
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
            keyPressedMap: const <String, bool>{},
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
}
