import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/widget/glass_dialog.dart';
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
  test('presentation accepts only one decision', () {
    final sessionCancellation = Completer<void>();
    final decisions = <bool>[];
    final presentation = PairingPresentationBinding(
      sessionCancellation: sessionCancellation.future,
      onResolve: decisions.add,
    );

    presentation.resolve(true);
    presentation.resolve(false);

    expect(decisions, <bool>[true]);
  });

  testWidgets('identity change resolves only the first decision', (
    tester,
  ) async {
    final decisions = <bool>[];
    final request = PairingRequest(
      device: _device(),
      pairingCode: '654321',
      reason: PairingReason.identityChanged,
      mode: PairingPromptMode.responder,
    );
    await tester.pumpWidget(_app(request, decisions.add));

    expect(find.textContaining('identity'), findsWidgets);
    await tester.tap(find.byKey(pairingRejectKey));
    expect(decisions, <bool>[false]);

    await tester.tap(find.byKey(pairingApproveKey));
    expect(decisions, <bool>[false]);
    await tester.pump();
    final reject = tester.widget<WhisperDialogButton>(
      find.byKey(pairingRejectKey),
    );
    final approve = tester.widget<WhisperDialogButton>(
      find.byKey(pairingApproveKey),
    );
    expect(reject.onPressed, isNull);
    expect(approve.onPressed, isNull);
  });

  testWidgets('user decision detaches a pending session cancellation', (
    tester,
  ) async {
    final cancellation = Completer<void>();
    final decisions = <bool>[];
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.newDevice,
      mode: PairingPromptMode.responder,
      cancellation: cancellation.future,
    );
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const Scaffold(body: Text('underlying page'));
          },
        ),
      ),
    );
    final shown = showPairingDialog(
      pageContext,
      request: request,
      resolve: decisions.add,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(pairingApproveKey));
    await tester.pumpAndSettle();
    await shown.timeout(const Duration(seconds: 1));
    cancellation.complete();
    await tester.pump();

    expect(decisions, <bool>[true]);
    expect(find.text('underlying page'), findsOneWidget);
  });

  testWidgets('background notification decision never creates a stale dialog', (
    tester,
  ) async {
    final sessionCancellation = Completer<void>();
    final decisions = <bool>[];
    final presentation = PairingPresentationBinding(
      sessionCancellation: sessionCancellation.future,
      onResolve: decisions.add,
    );
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.newDevice,
      mode: PairingPromptMode.responder,
      cancellation: presentation.cancellation,
      presentation: presentation,
    );
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const Scaffold(body: Text('underlying page'));
          },
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    final shown = showPairingDialog(
      pageContext,
      request: request,
      resolve: presentation.resolve,
    );
    await tester.pump();
    expect(find.byKey(pairingCodeKey), findsNothing);

    presentation.resolve(true);
    await tester.pump();
    await shown;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(decisions, <bool>[true]);
    expect(find.byKey(pairingCodeKey), findsNothing);
    expect(find.text('underlying page'), findsOneWidget);
  });

  testWidgets('initiator must explicitly confirm matching codes', (
    tester,
  ) async {
    final decisions = <bool>[];
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.legacyTrustWithoutPin,
      mode: PairingPromptMode.initiator,
    );
    await tester.pumpWidget(_app(request, decisions.add));

    expect(find.byKey(pairingApproveKey), findsOneWidget);
    expect(find.byKey(pairingRejectKey), findsNothing);
    expect(find.byKey(pairingCancelKey), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    tester
        .widget<WhisperDialogButton>(find.byKey(pairingApproveKey))
        .onPressed!();
    expect(decisions, <bool>[true]);
  });
}
