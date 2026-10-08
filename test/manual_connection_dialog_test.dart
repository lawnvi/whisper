import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/state/pairing_invite.dart';
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

Future<PairingQrResult?> _open(WidgetTester tester, {String? localHost}) =>
    showPairingQrDialog(
      tester.element(find.byType(Scaffold)),
      localInvite: localHost == null
          ? null
          : PairingInvite(
              host: localHost,
              port: 10002,
              peerId: '123e4567-e89b-42d3-a456-426614174000',
              publicKeyHash: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
            ),
      startWithAddress: true,
    );

void main() {
  testWidgets(
    'rapid field switches keep one keyboard layout without hiding it',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await _host(tester, 'zh');
      final result = _open(tester);
      await tester.pumpAndSettle();
      final address = find.byKey(const ValueKey('connection-address'));
      final port = find.byKey(const ValueKey('connection-port'));
      final panel = find.byKey(const ValueKey('pairing-qr-dialog-content'));
      await tester.enterText(address, 'desk.local');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final frame = tester.getRect(panel);
      final keyboard = Map<String, dynamic>.from(
        tester.testTextInput.setClientArgs!,
      );
      tester.testTextInput.log.clear();
      for (var i = 0; i < 30; i++) {
        final field = i.isEven ? port : address;
        await tester.tap(field);
        await tester.pump(const Duration(milliseconds: 16));
        final configuration = tester.testTextInput.setClientArgs!;
        for (final option in [
          'inputType',
          'autocorrect',
          'enableSuggestions',
          'smartDashesType',
          'smartQuotesType',
        ]) {
          expect(
            configuration[option],
            keyboard[option],
            reason: 'switch $i changed $option',
          );
        }
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.getRect(panel), frame);
        final editable = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        expect(
          tester.widget<EditableText>(editable).focusNode.hasFocus,
          isTrue,
        );
      }
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      final portInput = find.descendant(
        of: port,
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(portInput).focusNode.hasFocus, isTrue);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.hide',
        ),
        isEmpty,
      );
      expect(tester.getRect(panel), frame);
      await tester.enterText(port, '1a2b345');
      expect(tester.widget<TextFormField>(port).controller!.text, '12345');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final endpoint = (await result)!.endpoint;
      expect(endpoint.host, 'desk.local');
      expect(endpoint.port, 12345);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact dialog keeps its size while smoothing keyboard inset changes',
    (tester) async {
      tester.view.physicalSize = const Size(375, 817);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);
      await _host(tester, 'zh');
      final result = _open(tester);
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('pairing-qr-dialog-content'));
      final address = find.byKey(const ValueKey('connection-address'));
      final port = find.byKey(const ValueKey('connection-port'));
      await tester.tap(address);
      await tester.pumpAndSettle();
      final initial = tester.getRect(panel);
      final submit = find.byKey(const ValueKey('connect-by-address'));
      final buttonOffset = tester.getTopLeft(submit).dy - initial.top;
      expect(initial.height, 424);
      expect(
        initial.bottom - tester.getRect(submit).bottom,
        inInclusiveRange(20, 32),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      tester.view.padding = const FakeViewPadding(top: 24);
      await tester.pump();
      expect(tester.getRect(panel), initial);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(panel), initial);
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(panel).top, lessThan(initial.top));
      await tester.pumpAndSettle();
      final keyboardOpen = tester.getRect(panel);
      expect(keyboardOpen.top, lessThan(initial.top));
      expect(keyboardOpen.bottom, lessThanOrEqualTo(817 - 300));
      expect(keyboardOpen.size, initial.size);
      expect(
        tester.getTopLeft(submit).dy - keyboardOpen.top,
        closeTo(buttonOffset, 0.01),
      );
      final fieldTop = tester.getTopLeft(address).dy - keyboardOpen.top;
      await tester.tap(port);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), keyboardOpen);
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      await tester.pump();
      final settled = tester.getRect(panel);
      expect(settled.top, lessThan(keyboardOpen.top));
      expect(settled.bottom, lessThanOrEqualTo(817 - 336));
      expect(settled.size, initial.size);
      expect(
        tester.getTopLeft(submit).dy - settled.top,
        closeTo(buttonOffset, 0.01),
      );
      expect(
        tester.getTopLeft(address).dy - settled.top,
        closeTo(fieldTop, 0.01),
      );
      final portInput = find.descendant(
        of: port,
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(portInput).focusNode.hasFocus, isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(panel), settled);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect((await result)!.endpoint.port, 10002);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in <String?, String>{
    null: '192.168.1.10',
    '10.20.30.84': '10.20.30.10',
    '172.16.5.10': '172.16.5.20',
    'desk.local': '192.168.1.10',
    'fd00::1': '192.168.1.10',
  }.entries) {
    testWidgets('editable default address uses local prefix ${entry.key}', (
      tester,
    ) async {
      await _host(tester, 'zh');
      final result = _open(tester, localHost: entry.key);
      await tester.pumpAndSettle();
      final address = find.byKey(const ValueKey('connection-address'));
      final field = tester.widget<TextFormField>(address);
      expect(field.controller!.text, entry.value);
      await tester.enterText(
        address,
        '${entry.value.substring(0, entry.value.lastIndexOf('.') + 1)}99',
      );
      await tester.tap(find.byKey(const ValueKey('connect-by-address')));
      await tester.pumpAndSettle();
      expect((await result)!.endpoint.host, endsWith('.99'));
    });
  }
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
