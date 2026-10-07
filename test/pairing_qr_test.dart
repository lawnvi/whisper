import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
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

  testWidgets(
    'shows an identity-pinned QR code and connection endpoint',
    (tester) async {
      await tester.pumpWidget(buildDialog());
      await tester.pump();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Connect Device'), findsOneWidget);
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
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'fits the QR code on a narrow mobile viewport',
    (tester) async {
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
      expect(dialogSize.height, lessThanOrEqualTo(568 - 24));
      expect(
        tester.getSize(find.byType(QrImageView)).width,
        greaterThanOrEqualTo(200),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'desktop QR stays visible and stationary while the right tabs change',
    (tester) async {
      await tester.pumpWidget(buildDialog());
      await tester.pumpAndSettle();
      final qr = find.byKey(const ValueKey('persistent-pairing-qr'));
      final before = tester.getRect(qr);
      final copyHeight = tester
          .getSize(find.byWidgetPredicate((widget) => widget is FilledButton))
          .height;
      await tester.tap(find.text('IP / port'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(qr), before);
      await tester.pumpAndSettle();
      expect(tester.getRect(qr), before);
      expect(
        tester.getSize(find.byKey(const ValueKey('connect-by-address'))).height,
        copyHeight,
      );
      await tester.enterText(
        find.byKey(const ValueKey('connection-address')),
        'desk.local',
      );
      await tester.tap(find.text('This device'));
      await tester.pumpAndSettle();
      expect(tester.getRect(qr), before);
      await tester.tap(find.text('IP / port'));
      await tester.pumpAndSettle();
      expect(find.text('desk.local'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'phone panels keep a stable frame and preserve manual drafts',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(buildDialog());
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('pairing-qr-dialog-content'));
      final qr = find.byType(QrImageView);
      expect(tester.getSize(qr).width, inInclusiveRange(200, 240));
      final qrRect = tester.getRect(panel);
      final qrHeight = qrRect.height;
      final fingerprint = find.textContaining('AAAAAAAA');
      expect(
        tester.getRect(panel).bottom - tester.getRect(fingerprint).bottom,
        inInclusiveRange(16, 28),
      );
      await tester.tap(find.text('IP / port'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(panel), qrRect);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), qrRect);
      final address = find.byKey(const ValueKey('connection-address'));
      await tester.enterText(address, 'desk.local');
      final submit = find.byKey(const ValueKey('connect-by-address'));
      expect(
        tester.getRect(panel).bottom - tester.getRect(submit).bottom,
        inInclusiveRange(16, 28),
      );
      await tester.tap(find.text('QR code'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(360, 720);
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, qrHeight);
      await tester.tap(find.text('IP / port'));
      await tester.pumpAndSettle();
      expect(find.text('desk.local'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'copy shows an inline check only after success, then resets without a toast',
    (tester) async {
      final complete = Completer<void>();
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
          await complete.future;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(buildDialog());
      await tester.pumpAndSettle();
      final copy = find.byKey(const ValueKey('copy-pairing-invite'));
      final before = tester.getRect(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      complete.complete();
      await tester.pumpAndSettle();
      expect(copied, _invite.encode());
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.getRect(copy), before);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.macOS,
    }),
  );

  testWidgets(
    'failed copy stays inline and can be retried',
    (tester) async {
      var shouldFail = true;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData' && shouldFail) {
          throw PlatformException(code: 'test-denied');
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(buildDialog());
      await tester.pumpAndSettle();
      final copy = find.byKey(const ValueKey('copy-pairing-invite'));
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      shouldFail = false;
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'copy can finish after the dialog is dismissed',
    (tester) async {
      final complete = Completer<void>();
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') await complete.future;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(buildDialog());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('copy-pairing-invite')));
      await tester.pumpWidget(const SizedBox.shrink());
      complete.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'tab transitions retain drafts and disable outgoing actions; reduced=$reduceMotion',
      (tester) async {
        tester.view.physicalSize = const Size(360, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reduceMotion);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pumpWidget(buildDialog());
        await tester.pumpAndSettle();
        final panel = find.byKey(const ValueKey('pairing-qr-dialog-content'));
        final bounds = tester.getRect(panel);
        await tester.tap(find.text('IP / port'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(
          find.byKey(const ValueKey('copy-pairing-invite')).hitTestable(),
          findsNothing,
        );
        expect(tester.getRect(panel), bounds);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('connection-address')),
          'desk.local',
        );
        await tester.tap(find.text('QR code'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(
          find.byKey(const ValueKey('connect-by-address')).hitTestable(),
          findsNothing,
        );
        await tester.tap(find.text('IP / port'));
        await tester.pumpAndSettle();
        expect(find.text('desk.local'), findsOneWidget);
        expect(tester.getRect(panel), bounds);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'controller removes the QR route below a pairing prompt',
    (tester) async {
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
      expect(find.text('Connect Device'), findsOneWidget);

      unawaited(
        showDialog<void>(
          context: navigatorKey.currentContext!,
          barrierDismissible: false,
          builder: (context) =>
              const AlertDialog(content: Text('Pairing code')),
        ),
      );
      await tester.pumpAndSettle();
      controller.dismiss();
      await tester.pumpAndSettle();

      expect(find.text('Connect Device'), findsNothing);
      expect(find.text('Pairing code'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
