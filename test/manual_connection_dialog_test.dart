import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/manual_connection_dialog.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  testWidgets('small phone keeps both fields reachable above the keyboard', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: const EdgeInsets.only(bottom: 256)),
          child: child!,
        ),
        home: const Scaffold(),
      ),
    );
    final result = showManualConnectionDialog(
      tester.element(find.byType(Scaffold)),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(CupertinoTextField);
    expect(
      tester.getRect(fields.last).bottom,
      lessThan(tester.getRect(find.byType(WhisperDialogButton).first).top),
    );
    expect(tester.takeException(), isNull);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(
      tester.widget<CupertinoTextField>(fields.last).focusNode!.hasFocus,
      isTrue,
    );
    await tester.tap(find.byType(WhisperDialogButton).first);
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  for (final locale in ['zh', 'en', 'es']) {
    testWidgets('$locale manual connection validates before dismissing', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(),
        ),
      );
      final context = tester.element(find.byType(Scaffold));
      final l10n = AppLocalizations.of(context)!;
      final result = showManualConnectionDialog(context);
      await tester.pumpAndSettle();
      final fields = find.byType(CupertinoTextField);
      final submit = find.widgetWithText(WhisperDialogButton, l10n.connect);
      await tester.enterText(fields.first, '192.168.1.20');
      for (final invalid in ['', '0', '65536', '999999999999999999999999']) {
        await tester.enterText(fields.last, invalid);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(find.text(l10n.manualConnectPortInvalid), findsOneWidget);
        expect(find.byType(WhisperGlassDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.enterText(fields.last, '14567');
      await tester.enterText(fields.first, 'https://example.com');
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text(l10n.manualConnectAddressInvalid), findsOneWidget);
      await tester.enterText(fields.first, ' 192.168.1.20 ');
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final endpoint = await result;
      expect(endpoint!.host, '192.168.1.20');
      expect(endpoint.port, 14567);
      expect(tester.takeException(), isNull);
    });
  }
}
