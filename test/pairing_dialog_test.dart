import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
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
  test('external decision dismisses the presentation before resolving',
      () async {
    final sessionCancellation = Completer<void>();
    var dismissedBeforeResolve = false;
    final decisions = <bool>[];
    late PairingPresentationBinding presentation;
    presentation = PairingPresentationBinding(
      sessionCancellation: sessionCancellation.future,
      onResolve: (allow) {
        dismissedBeforeResolve = presentation.isDismissed;
        decisions.add(allow);
      },
    );

    presentation.resolve(true);

    await expectLater(presentation.cancellation, completes);
    expect(dismissedBeforeResolve, isTrue);
    expect(decisions, <bool>[true]);
  });

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

  test('resolved dialogs detach their pending session cancellation listener',
      () {
    final source = File('lib/widget/pairing_dialog.dart').readAsStringSync();

    expect(source, contains('cancellation.asStream().listen'));
    expect(source, contains('cancellationSubscription?.cancel()'));
    expect(source, isNot(contains('unawaited(cancellation.then')));
  });

  testWidgets('shows grouped code with an ungrouped semantic label',
      (tester) async {
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.newDevice,
      mode: PairingPromptMode.responder,
    );
    await tester.pumpWidget(_app(request, (_) {}));

    expect(find.text('123 456'), findsOneWidget);
    final semantics = tester.getSemantics(find.byKey(pairingCodeKey));
    expect(semantics.label, contains('123456'));
    expect(find.textContaining('Desk PC'), findsWidgets);
  });

  testWidgets('identity change resolves only the first decision',
      (tester) async {
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
    final reject =
        tester.widget<CupertinoDialogAction>(find.byKey(pairingRejectKey));
    final approve =
        tester.widget<CupertinoDialogAction>(find.byKey(pairingApproveKey));
    expect(reject.onPressed, isNull);
    expect(approve.onPressed, isNull);
  });

  testWidgets('reject is the destructive action', (tester) async {
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.newDevice,
      mode: PairingPromptMode.responder,
    );
    await tester.pumpWidget(_app(request, (_) {}));
    final reject =
        tester.widget<CupertinoDialogAction>(find.byKey(pairingRejectKey));
    expect(reject.isDestructiveAction, isTrue);
  });

  testWidgets('repeated route decisions cannot pop the underlying page',
      (tester) async {
    final decisions = <bool>[];
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.newDevice,
      mode: PairingPromptMode.responder,
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
        home: Builder(builder: (context) {
          pageContext = context;
          return const Scaffold(body: Text('underlying page'));
        }),
      ),
    );
    final shown = showPairingDialog(
      pageContext,
      request: request,
      resolve: decisions.add,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(pairingRejectKey), warnIfMissed: false);
    await tester.tap(find.byKey(pairingRejectKey), warnIfMissed: false);
    await tester.pumpAndSettle();
    await shown;

    expect(decisions, <bool>[false]);
    expect(find.text('underlying page'), findsOneWidget);
  });

  testWidgets('user decision detaches a pending session cancellation',
      (tester) async {
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
        home: Builder(builder: (context) {
          pageContext = context;
          return const Scaffold(body: Text('underlying page'));
        }),
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

  testWidgets('session cancellation dismisses only the pairing route',
      (tester) async {
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
        home: Builder(builder: (context) {
          pageContext = context;
          return const Scaffold(body: Text('underlying page'));
        }),
      ),
    );
    final shown = showPairingDialog(
      pageContext,
      request: request,
      resolve: decisions.add,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(pairingCodeKey), findsOneWidget);

    cancellation.complete();
    await tester.pumpAndSettle();
    await shown;

    expect(decisions, isEmpty);
    expect(find.byKey(pairingCodeKey), findsNothing);
    expect(find.text('underlying page'), findsOneWidget);
  });

  testWidgets('notification decision dismisses a background pairing route',
      (tester) async {
    final sessionCancellation = Completer<void>();
    final decisions = <bool>[];
    late PairingPresentationBinding presentation;
    presentation = PairingPresentationBinding(
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
        home: Builder(builder: (context) {
          pageContext = context;
          return const Scaffold(body: Text('underlying page'));
        }),
      ),
    );
    final shown = showPairingDialog(
      pageContext,
      request: request,
      resolve: presentation.resolve,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(pairingCodeKey), findsOneWidget);

    presentation.resolve(true);
    await tester.pumpAndSettle();
    await shown;

    expect(decisions, <bool>[true]);
    expect(find.byKey(pairingCodeKey), findsNothing);
    expect(find.text('underlying page'), findsOneWidget);
  });

  testWidgets('notification decision removes only the pairing route',
      (tester) async {
    final sessionCancellation = Completer<void>();
    late BuildContext pageContext;
    late PairingPresentationBinding presentation;
    presentation = PairingPresentationBinding(
      sessionCancellation: sessionCancellation.future,
      onResolve: (_) {
        unawaited(
          Navigator.of(pageContext).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('connected page')),
            ),
          ),
        );
      },
    );
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.newDevice,
      mode: PairingPromptMode.responder,
      cancellation: presentation.cancellation,
      presentation: presentation,
    );
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
        home: Builder(builder: (context) {
          pageContext = context;
          return const Scaffold(body: Text('underlying page'));
        }),
      ),
    );
    final shown = showPairingDialog(
      pageContext,
      request: request,
      resolve: presentation.resolve,
    );
    await tester.pumpAndSettle();

    presentation.resolve(true);
    await tester.pumpAndSettle();
    await shown;

    expect(find.byKey(pairingCodeKey), findsNothing);
    expect(find.text('connected page'), findsOneWidget);
  });

  testWidgets('background notification decision never creates a stale dialog',
      (tester) async {
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
        home: Builder(builder: (context) {
          pageContext = context;
          return const Scaffold(body: Text('underlying page'));
        }),
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

  testWidgets('initiator sees only a cancel action', (tester) async {
    final decisions = <bool>[];
    final request = PairingRequest(
      device: _device(),
      pairingCode: '123456',
      reason: PairingReason.legacyTrustWithoutPin,
      mode: PairingPromptMode.initiator,
    );
    await tester.pumpWidget(_app(request, decisions.add));

    expect(find.byKey(pairingApproveKey), findsNothing);
    expect(find.byKey(pairingRejectKey), findsNothing);
    expect(find.byKey(pairingCancelKey), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.byKey(pairingCancelKey));
    expect(decisions, <bool>[false]);
  });
}
