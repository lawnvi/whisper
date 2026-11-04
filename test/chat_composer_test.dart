import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/chat_composer.dart';

void main() {
  testWidgets('failed text send keeps the original draft', (tester) async {
    final controller = TextEditingController(text: 'retry me');
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
            focusNode: FocusNode(),
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (_) async => false,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.text, 'retry me');
  });

  testWidgets('send completion never clears text typed after submission', (
    tester,
  ) async {
    final pending = Completer<bool>();
    final controller = TextEditingController(text: 'first');
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
            focusNode: FocusNode(),
            onPickFiles: () async {},
            onSendClipboard: () async {},
            onSendText: (_) => pending.future,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(ChatComposer.sendButtonKey));
    controller.text = 'first plus more';
    pending.complete(true);
    await tester.pumpAndSettle();

    expect(controller.text, 'first plus more');
  });

  testWidgets('desktop composer does not send while IME is composing', (
    tester,
  ) async {
    String? sentText;
    final controller = TextEditingController.fromValue(
      const TextEditingValue(
        text: 'github',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
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
              return true;
            },
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sentText, isNull);
    expect(controller.text, 'github');
  });
}
