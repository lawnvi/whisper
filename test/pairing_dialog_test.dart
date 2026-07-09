import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/widget/pairing_dialog.dart';

DeviceData _device() => const DeviceData(
      id: 0,
      uid: 'peer-a',
      name: 'Desk PC',
      host: '',
      port: 0,
      platform: 'windows',
      isServer: false,
      online: true,
      clipboard: false,
      auth: false,
      lastTime: 0,
    );

Widget _app(PairingRequest request, ValueChanged<bool> onResolved) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: PairingDialog(request: request, onResolved: onResolved),
    ),
  );
}

void main() {
  testWidgets('shows grouped code with an ungrouped semantic label',
      (tester) async {
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.newDevice,
      canApprove: true,
    );
    await tester.pumpWidget(_app(request, (_) {}));

    expect(find.text('123 456'), findsOneWidget);
    final semantics = tester.getSemantics(find.byKey(pairingCodeKey));
    expect(semantics.label, contains('123456'));
    expect(find.textContaining('Desk PC'), findsWidgets);
  });

  testWidgets('identity change has explicit reject and approve actions',
      (tester) async {
    final decisions = <bool>[];
    final request = PairingRequest(
      device: _device(),
      pairingCode: '654321',
      reason: PairingReason.identityChanged,
      canApprove: true,
    );
    await tester.pumpWidget(_app(request, decisions.add));

    expect(find.textContaining('identity'), findsWidgets);
    await tester.tap(find.byKey(pairingRejectKey));
    expect(decisions, <bool>[false]);

    await tester.tap(find.byKey(pairingApproveKey));
    expect(decisions, <bool>[false, true]);
  });

  testWidgets('read-only request does not expose an approve action',
      (tester) async {
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.legacyTrustWithoutPin,
      canApprove: false,
    );
    await tester.pumpWidget(_app(request, (_) {}));

    expect(find.byKey(pairingApproveKey), findsNothing);
    expect(find.byKey(pairingRejectKey), findsOneWidget);
  });
}
