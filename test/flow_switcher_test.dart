import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/window_stream/flow_recents_deck.dart';
import 'package:whisper/page/window_stream/flow_switcher.dart';

void main() {
  testWidgets('swipe across to browse, up to close, tap to open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1233, 2580);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final closed = <String>[];
    final opened = <String>[];
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    showFlowSwitcher(
      page,
      cards: [
        for (var i = 0; i < 5; i++)
          FlowTaskCard(key: '$i', title: 'Window $i', hue: Colors.indigo),
      ],
      cardAspect: 16 / 10,
      origins: () => const {'0': Rect.fromLTWH(20, 200, 120, 260)},
      onOpen: (card, _) => opened.add(card.key),
      onClose: (card) => closed.add(card.key),
    );
    await tester.pumpAndSettle();

    // Swiping right brings an older window to the front.
    await tester.timedDragFrom(
      const Offset(200, 430),
      const Offset(220, 0),
      const Duration(milliseconds: 700),
    );
    await tester.pumpAndSettle();
    // Thrown up, it closes; the rest close the gap.
    await tester.flingFrom(const Offset(205, 430), const Offset(0, -300), 2000);
    await tester.pumpAndSettle();
    expect(closed, ['1']);
    // The next older one is in front now.
    await tester.tapAt(const Offset(205, 430));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(opened, ['2']);
    expect(find.byType(FlowSwitcher), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rest close the gap while a thrown window flies out', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1233, 2580);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    showFlowSwitcher(
      page,
      cards: [
        for (var i = 0; i < 3; i++)
          FlowTaskCard(key: '$i', title: 'Window $i', hue: Colors.indigo),
      ],
      cardAspect: 9 / 19.5,
      origins: () => const {},
      onOpen: (_, _) {},
      onClose: (_) {},
    );
    await tester.pumpAndSettle();
    final front = tester.getTopLeft(find.text('Window 0'));
    await tester.flingFrom(
      front + const Offset(40, 200),
      const Offset(0, -150),
      1500,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    // Not waiting for the thrown one to be long gone: the next is in front,
    // and the stack has already settled back against the edge.
    final moving = tester.getTopLeft(find.text('Window 1'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final settled = tester.getTopLeft(find.text('Window 1'));
    expect(moving.dx, closeTo(settled.dx, 4));
    Navigator.of(page).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    // Exactly where a switcher with the two left would show it.
    showFlowSwitcher(
      page,
      cards: [
        for (var i = 1; i < 3; i++)
          FlowTaskCard(key: '$i', title: 'Window $i', hue: Colors.indigo),
      ],
      cardAspect: 9 / 19.5,
      origins: () => const {},
      onOpen: (_, _) {},
      onClose: (_) {},
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Window 1')).dx, closeTo(settled.dx, 1));
    Navigator.of(page).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the deepest card rests against the left edge', (tester) async {
    tester.view.physicalSize = const Size(1233, 2742);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    for (final count in [2, 3, 5]) {
      showFlowSwitcher(
        page,
        cards: [
          for (var i = 0; i < count; i++)
            FlowTaskCard(key: '$i', title: 'Window $i', hue: Colors.indigo),
        ],
        cardAspect: 9 / 19.5,
        origins: () => const {},
        onOpen: (_, _) {},
        onClose: (_) {},
      );
      await tester.pumpAndSettle();
      final cards = tester
          .widgetList(
            find.byWidgetPredicate(
              (widget) => widget.runtimeType.toString() == '_SwitcherCard',
            ),
          )
          .map((widget) => tester.getRect(find.byWidget(widget)))
          .toList();
      expect(cards, hasLength(count));
      final deepest = cards.reduce((a, b) => a.left < b.left ? a : b);
      final front = cards.reduce((a, b) => a.height > b.height ? a : b);
      // Tucked a hair under the edge, never a gap.
      expect(deepest.left, inInclusiveRange(-3.0, 0.0));
      // Each layer back is 2.5% shorter.
      final next = cards
          .where((rect) => rect != front)
          .reduce((a, b) => a.height > b.height ? a : b);
      expect(next.height / front.height, closeTo(0.975, 0.002));
      Navigator.of(page).pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
    }
  });

  test('swiping stays light on a slow tablet', () {
    // Measured on an iPad (A10) with tool/perf/switcher_perf.dart: live
    // card shadows, a wide blur under each name and the page drawn under
    // the switcher every frame made half the frames late.
    final source = File(
      'lib/page/window_stream/flow_switcher.dart',
    ).readAsStringSync();
    final card = source.substring(
      source.indexOf('class _SwitcherCard'),
      source.indexOf('class _CardShadow'),
    );
    expect(card, isNot(contains('BoxShadow(')));
    expect(card, contains('CustomPaint(painter: _CardShadow())'));
    expect(card, contains('blurRadius: 2'));
    expect(source, contains('overlayEntries.first.opaque = true'));
    expect(source, contains('route.backdropShown()'));
    // The dim is in the picture, not a layer over it.
    expect(
      source,
      contains('canvas.drawColor(const Color(0x4D000000), BlendMode.srcOver)'),
    );
    expect(source, isNot(contains('ColoredBox(color: Color(0x4D000000))')));
  });
}
