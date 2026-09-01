import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/widget/glass_dialog.dart';

final _invite = PairingInvite(
  host: '192.168.1.20',
  port: 10002,
  peerId: '123e4567-e89b-42d3-a456-426614174000',
  publicKeyHash: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

void main() {
  Widget buildDialog() => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: PairingQrDialog(localInvite: _invite, startWithScanner: false),
  );

  testWidgets('shows an identity-pinned QR code and connection endpoint', (
    tester,
  ) async {
    await tester.pumpWidget(buildDialog());
    await tester.pump();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Connect with QR code'), findsOneWidget);
    expect(find.text('192.168.1.20:10002'), findsOneWidget);
    expect(find.textContaining('AAAAAAAA'), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.wifi_rounded), findsOneWidget);
    expect(find.byIcon(Icons.verified_user_rounded), findsOneWidget);
    final dialog = tester.widget<WhisperGlassDialog>(
      find.byType(WhisperGlassDialog),
    );
    expect(dialog.borderRadius, 26);
    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('pairing-qr-dialog-content')),
      ),
      const Size(640, 420),
    );
  });

  testWidgets('fits the QR code on a narrow mobile viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(buildDialog());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('192.168.1.20:10002'), findsOneWidget);
    final dialogSize = tester.getSize(
      find.byKey(const ValueKey<String>('pairing-qr-dialog-content')),
    );
    expect(dialogSize.width, 296);
    expect(dialogSize.height, lessThan(420));
  });

  testWidgets('controller removes the QR route below a pairing prompt', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = PairingQrDialogController();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              unawaited(
                showPairingQrDialog(
                  context,
                  localInvite: _invite,
                  startWithScanner: false,
                  controller: controller,
                ),
              );
            },
            child: const Text('Open QR'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open QR'));
    await tester.pumpAndSettle();
    expect(find.text('Connect with QR code'), findsOneWidget);

    unawaited(
      showDialog<void>(
        context: navigatorKey.currentContext!,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(content: Text('Pairing code')),
      ),
    );
    await tester.pumpAndSettle();
    controller.dismiss();
    await tester.pumpAndSettle();

    expect(find.text('Connect with QR code'), findsNothing);
    expect(find.text('Pairing code'), findsOneWidget);
  });
}
