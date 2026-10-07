import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_dialog.dart';

Future<void> _host(WidgetTester tester, String locale) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(),
    ),
  );
}

Future<PairingQrResult?> _open(WidgetTester tester) => showPairingQrDialog(
  tester.element(find.byType(Scaffold)),
  localInvite: null,
  startWithAddress: true,
);

void main() {
  for (final locale in ['zh', 'en', 'es']) {
    testWidgets('$locale manual tab validates and returns a trimmed endpoint', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Do not await the route's result until it is dismissed.
      await _host(tester, locale);
      final result = _open(tester);
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
      expect(find.text(l10n.connectionAddressHint), findsOneWidget);
      final address = find.byKey(const ValueKey('connection-address'));
      final port = find.byKey(const ValueKey('connection-port'));
      final submit = find.byKey(const ValueKey('connect-by-address'));
      await tester.enterText(address, '192.168.1.20');
      for (final invalid in ['', '0', '65536', '999999999999999999999999']) {
        await tester.enterText(port, invalid);
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(find.text(l10n.manualConnectPortInvalid), findsOneWidget);
        expect(find.byType(WhisperGlassDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.enterText(port, '14567');
      await tester.enterText(address, 'https://example.com');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text(l10n.manualConnectAddressInvalid), findsOneWidget);
      await tester.enterText(address, ' 192.168.1.20 ');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final target = await result;
      expect(target!.endpoint.host, '192.168.1.20');
      expect(target.endpoint.port, 14567);
      expect(target.invite, isNull);
    });
  }

  testWidgets('manual draft survives tabs and remains usable above keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _host(tester, 'zh');
    final result = _open(tester);
    await tester.pumpAndSettle();
    final address = find.byKey(const ValueKey('connection-address'));
    final port = find.byKey(const ValueKey('connection-port'));
    await tester.enterText(address, 'desk.local');
    await tester.enterText(port, '12345');
    await tester.tap(find.text('二维码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Wi-Fi'), findsOneWidget);
    await tester.tap(find.text('IP / 端口'));
    await tester.pumpAndSettle();
    expect(find.text('desk.local'), findsOneWidget);
    expect(find.text('12345'), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 256);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(port);
    await tester.tap(port);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect((await result)!.endpoint.host, 'desk.local');
    expect(tester.takeException(), isNull);
  });
}
