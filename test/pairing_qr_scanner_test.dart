import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/state/pairing_invite.dart';

void main() {
  for (final size in [
    const Size(360, 720),
    const Size(320, 568),
    const Size(720, 360),
  ]) {
    testWidgets('tabs keep a stable frame and release the camera at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (size.width == 320) {
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      final calls = <String>[];
      final channels = <MethodChannel>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        calls.add('view:${call.method}');
        if (call.method == 'create') {
          final id = (call.arguments as Map)['id'];
          final channel = MethodChannel(
            'net.touchcapture.qr.flutterqrplus/qrview_$id',
          );
          channels.add(channel);
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return null;
          });
          return 1;
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(),
        ),
      );
      final result = showPairingQrDialog(
        tester.element(find.byType(Scaffold)),
        localInvite: PairingInvite(
          host: '192.168.1.20',
          port: 10002,
          peerId: '123e4567-e89b-42d3-a456-426614174000',
          publicKeyHash: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(QRView), findsOneWidget);
      expect(calls, contains('startScan'));
      final panel = find.byKey(const ValueKey('pairing-qr-dialog-content'));
      final bounds = tester.getRect(panel);
      final tabRect = tester.getRect(find.byType(TabBar));
      final videoRect = tester.getRect(find.byType(QRView));
      expect(videoRect.left, tabRect.left - 4);
      expect(videoRect.right, tabRect.right + 4);
      await tester.ensureVisible(find.text('IP / port'));
      await tester.tap(find.text('IP / port'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(panel), bounds);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), bounds);
      expect(find.byType(QRView), findsNothing);
      expect(calls, contains('view:dispose'));
      final hint = find.text(
        AppLocalizations.of(tester.element(panel))!.connectionAddressHint,
      );
      expect(tester.getRect(hint).left, videoRect.left);
      expect(tester.getRect(hint).right, videoRect.right);
      await tester.enterText(
        find.byKey(const ValueKey('connection-address')),
        'desk.local',
      );
      await tester.ensureVisible(find.text('QR code'));
      await tester.tap(find.text('QR code'));
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), bounds);
      await tester.ensureVisible(find.text('IP / port'));
      await tester.tap(find.text('IP / port'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(panel), bounds);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), bounds);
      expect(find.text('desk.local'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('connect-by-address')),
      );
      await tester.tap(find.byKey(const ValueKey('connect-by-address')));
      await tester.pumpAndSettle();
      expect((await result)!.endpoint.host, 'desk.local');
      expect(tester.takeException(), isNull);
    });
  }
}
