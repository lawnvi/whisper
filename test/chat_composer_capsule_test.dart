// The new composer, which is behind the flag until the old one goes:
//   flutter test --no-pub --dart-define=WHISPER_NEW_UI=true \
//     test/chat_composer_capsule_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/chat_composer.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    bool canSend = true,
    Future<bool> Function()? sync,
    TextEditingController? controller,
    ValueChanged<TextEditingController>? onController,
    bool empty = true,
  }) async {
    final text = controller ?? TextEditingController();
    onController?.call(text);
    final focus = FocusNode();
    if (controller == null) addTearDown(text.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Material(
          child: Center(
            child: ChatComposer(
              controller: text,
              focusNode: focus,
              canSend: canSend,
              isDesktopStyle: false,
              isLoading: false,
              isLocalhost: false,
              isInputEmpty: empty,
              keyPressedMap: const {},
              clipboardEnabled: true,
              onSendClipboard: () async {},
              onSyncClipboard: sync,
              onSendText: (_) async => true,
              onPickFiles: () async {},
              disabledHint: '连接后可以发送',
            ),
          ),
        ),
      ),
    );
  }

  bool shows(WhisperGlyph glyph) => find
      .byWidgetPredicate((w) => w is WhisperIcon && w.glyph == glyph)
      .evaluate()
      .isNotEmpty;

  testWidgets('the clipboard button says that it went, for a moment', (
    tester,
  ) async {
    await pump(tester, sync: () async => true);
    expect(shows(WhisperGlyph.check), isFalse);
    await tester.tap(find.byKey(ChatComposer.clipboardButtonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shows(WhisperGlyph.check), isTrue);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(shows(WhisperGlyph.check), isFalse);
    expect(shows(WhisperGlyph.clip), isTrue);
  }, skip: !whisperNewUi);

  testWidgets('typing puts the buttons away, and only send is left', (
    tester,
  ) async {
    late TextEditingController controller;
    await pump(
      tester,
      sync: () async => true,
      onController: (c) => controller = c,
    );
    expect(find.byKey(ChatComposer.clipboardButtonKey), findsOneWidget);
    expect(find.byKey(ChatComposer.attachmentButtonKey), findsOneWidget);
    controller.text = '第一行\n第二行\n第三行';
    await pump(
      tester,
      sync: () async => true,
      controller: controller,
      empty: false,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(ChatComposer.clipboardButtonKey), findsNothing);
    final send = find.byKey(ChatComposer.sendButtonKey);
    expect(send, findsOneWidget);
    final field = tester.getRect(
      find.byKey(const ValueKey('chat-composer-textfield')),
    );
    // Down at the bottom right, with the words all the way to it.
    expect(tester.getRect(send).bottom, greaterThanOrEqualTo(field.bottom));
    expect(tester.getRect(send).left, greaterThanOrEqualTo(field.right));
    expect(tester.getRect(send).left - field.right, lessThan(8));
  }, skip: !whisperNewUi);

  testWidgets('no tick when nothing went', (tester) async {
    await pump(tester, sync: () async => false);
    await tester.tap(find.byKey(ChatComposer.clipboardButtonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shows(WhisperGlyph.check), isFalse);
  }, skip: !whisperNewUi);

  testWidgets('no words in the box, also when it cannot be used', (
    tester,
  ) async {
    await pump(tester, canSend: false);
    expect(find.text('连接后可以发送'), findsNothing);
    expect(find.bySemanticsLabel('连接后可以发送'), findsOneWidget);
    expect(find.byKey(ChatComposer.clipboardButtonKey), findsNothing);
    expect(find.byKey(ChatComposer.sendButtonKey), findsNothing);
    expect(find.byKey(ChatComposer.attachmentButtonKey), findsNothing);
  }, skip: !whisperNewUi);
}
