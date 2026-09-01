import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/desktop_quick_send_inbox.dart';
import 'package:whisper/widget/desktop_quick_send_dialog.dart';
import 'package:whisper/widget/glass_dialog.dart';

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
                  peers: const <DesktopQuickSendPeer>[],
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
  });
}
