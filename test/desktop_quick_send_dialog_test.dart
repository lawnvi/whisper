import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/desktop_quick_send_inbox.dart';
import 'package:whisper/widget/desktop_quick_send_dialog.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/quick_send_chooser.dart';

void main() {
  testWidgets('lays out pending quick-send content instead of only a barrier', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDesktopQuickSendDialog(
                  context,
                  drafts: const <DesktopQuickSendDraft>[
                    DesktopQuickSendDraft(
                      id: 'draft-1',
                      source: DesktopQuickSendSource.clipboardShortcut,
                      text: 'hello',
                      filePaths: <String>[],
                      receivedAt: 1,
                    ),
                  ],
                  targets: ValueNotifier<List<QuickSendTarget>>(
                    const <QuickSendTarget>[],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(WhisperGlassDialog), findsOneWidget);
    expect(find.text('快捷发送'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('发送'), findsOneWidget);
  });

  test('flattens drafts into texts and files in their original order', () {
    final items = desktopQuickSendItems(const <DesktopQuickSendDraft>[
      DesktopQuickSendDraft(
        id: 'draft-1',
        source: DesktopQuickSendSource.clipboardShortcut,
        text: 'hello',
        filePaths: <String>[],
        receivedAt: 1,
      ),
      DesktopQuickSendDraft(
        id: 'draft-2',
        source: DesktopQuickSendSource.systemService,
        text: '',
        filePaths: <String>['/tmp/a/photo.jpg', '/tmp/a/notes.pdf'],
        receivedAt: 2,
      ),
    ]);

    expect(items.map((item) => item.isText), <bool>[true, false, false]);
    expect(items[1].name, 'photo.jpg');
    expect(items[1].isVisualMedia, isTrue);
    expect(items[2].name, 'notes.pdf');
    expect(items[2].isVisualMedia, isFalse);
  });
}
