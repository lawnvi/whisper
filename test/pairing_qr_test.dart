import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/state/pairing_invite.dart';

final _invite = PairingInvite(
  host: '192.168.1.20',
  port: 10002,
  peerId: '123e4567-e89b-42d3-a456-426614174000',
  publicKeyHash: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

void main() {
  Widget buildScreen() => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: PairingQrScreen(
          localInvite: _invite,
          startWithScanner: false,
        ),
      );

  testWidgets('shows an identity-pinned QR code and connection endpoint',
      (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump();

    expect(find.text('Connect with QR code'), findsOneWidget);
    expect(find.text('192.168.1.20:10002'), findsOneWidget);
    expect(find.textContaining('AAAAAAAA'), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('fits the QR code on a narrow mobile viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildScreen());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('192.168.1.20:10002'), findsOneWidget);
  });
}
