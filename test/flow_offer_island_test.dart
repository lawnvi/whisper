import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/window_stream/flow_animated_grid.dart';
import 'package:whisper/page/window_stream/flow_offer_banner.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';

void main() {
  testWidgets('a sent window swells into a card and goes when dismissed', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final viewer = WindowStreamViewer.shared;
    viewer.peerAvailable(
      peerId: 'mac',
      name: 'MacBook',
      platform: WindowStreamPlatform.macos,
      host: '127.0.0.1',
      port: 1,
    );
    addTearDown(() => viewer.peerGone('mac'));
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        navigatorKey: navigatorKey,
        builder: (context, child) =>
            WindowOfferHost(navigatorKey: navigatorKey, child: child!),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    viewer.handleControl(
      const WindowStreamControlMessage(
        action: WindowStreamControlAction.offer,
        sessionId: 's',
        viewerPeerId: 'phone',
        hostPeerId: 'mac',
        payload: {
          'window': {
            'id': 7,
            'appName': 'Notes',
            'title': 'Groceries',
            'bundleId': 'com.apple.Notes',
          },
        },
      ),
      remotePeerId: 'mac',
      remoteHost: '127.0.0.1',
      sendKey: Uint8List(32),
      receiveKey: Uint8List(32),
    );
    await tester.pump();
    // The small island, then the card.
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('From MacBook'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(viewer.offers.value, isEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Groceries'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('apps that stay slide over, the ones that go fade out', (
    tester,
  ) async {
    Widget grid(List<String> items) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FlowAnimatedGrid<String>(
            items: items,
            keyOf: (item) => item,
            itemBuilder: (context, item) => Text(item),
            maxCrossAxisExtent: 100,
            mainAxisExtent: 100,
          ),
        ),
      ),
    );
    await tester.pumpWidget(grid(['a', 'b', 'c']));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('c'));

    await tester.pumpWidget(grid(['a', 'c']));
    await tester.pump(const Duration(milliseconds: 60));
    // Still there, on its way out.
    expect(find.text('b'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
    expect(tester.getTopLeft(find.text('c')).dx, lessThan(before.dx));

    // Back again: it grows in where it belongs.
    await tester.pumpWidget(grid(['a', 'b', 'c']));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('c')), before);
    expect(tester.takeException(), isNull);
  });
}
