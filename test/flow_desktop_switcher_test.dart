import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/window_stream/flow_desktop_switcher.dart';
import 'package:whisper/page/window_stream/flow_recents_deck.dart';
import 'package:whisper/theme/app_theme.dart';

/// On a desktop every recent window is a click away: a grid that fits the
/// window (scrolling with the wheel when there are many), not a row that
/// runs off the side where only a trackpad reaches.
void main() {
  group('grid', () {
    test('a few windows fit, as large as they can be', () {
      const area = Size(1000, 560);
      final grid = FlowDesktopSwitcher.layout(area, 3, 16 / 10);
      expect(grid.rects, hasLength(3));
      expect(grid.size.height, lessThanOrEqualTo(area.height));
      for (final rect in grid.rects) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(area.width));
        expect(rect.width, closeTo(rect.height * 16 / 10, 0.01));
      }
      for (var i = 0; i < grid.rects.length; i++) {
        for (var j = i + 1; j < grid.rects.length; j++) {
          expect(grid.rects[i].overlaps(grid.rects[j]), isFalse);
        }
      }
      // Centred: as much room left of the first row as right of it.
      final row = grid.rects.where((r) => r.top == grid.rects.first.top);
      final left = row.first.left;
      final right = area.width - row.last.right;
      expect(left, closeTo(right, 0.5));
    });

    test('many windows scroll rather than shrink past reading', () {
      const area = Size(1000, 560);
      final grid = FlowDesktopSwitcher.layout(area, 40, 16 / 10);
      expect(grid.size.height, greaterThan(area.height));
      expect(grid.rects.first.width, greaterThanOrEqualTo(220));
      expect(grid.columns, greaterThan(1));
    });
  });

  testWidgets('a click on the stack shows every window; any one opens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <String>[];
    final closed = <String>[];
    final cards = [
      for (var i = 0; i < 7; i++)
        FlowTaskCard(key: '$i', title: 'Window $i', hue: Colors.indigo),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.topLeft,
              child: FlowRecentsDeck(
                cards: cards,
                cardWidth: 240,
                cardAspect: 16 / 10,
                onOpen: (card, _) => opened.add(card.key),
                onClose: (card) => closed.add(card.key),
                onShowAll: (origins) => showFlowDesktopSwitcher(
                  context,
                  cards: cards,
                  cardAspect: 16 / 10,
                  origins: origins,
                  onOpen: (card, _) => opened.add(card.key),
                  onClose: (card) => closed.add(card.key),
                  title: 'Recents',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Hovering leaves the stack where it is (it used to fan out past the
    // window's edge).
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(60, 60));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(80, 80));
    await tester.pumpAndSettle();
    expect(find.byType(FlowDesktopSwitcher), findsNothing);

    await tester.tap(find.text('Window 0'));
    await tester.pumpAndSettle();
    expect(find.byType(FlowDesktopSwitcher), findsOneWidget);
    // Named for screen readers, not written over the page's own title.
    expect(find.text('Recents'), findsNothing);
    expect(find.bySemanticsLabel('Recents'), findsOneWidget);
    // Every window is on screen, the last one too.
    final last = tester.getRect(find.text('Window 6').last);
    expect(const Rect.fromLTWH(0, 0, 1100, 720).contains(last.center), isTrue);

    await tester.tap(find.text('Window 6').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(opened, ['6']);
    expect(find.byType(FlowDesktopSwitcher), findsNothing);

    // Esc goes back into the stack.
    await tester.tap(find.text('Window 0'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(FlowDesktopSwitcher), findsNothing);

    // Keys move through the grid and open the one chosen.
    await tester.tap(find.text('Window 0'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, ['6', '2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single window opens straight from the stack', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <String>[];
    const card = FlowTaskCard(key: 'only', title: 'Only', hue: Colors.teal);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.topLeft,
              child: FlowRecentsDeck(
                cards: const [card],
                cardWidth: 240,
                cardAspect: 16 / 10,
                onOpen: (card, _) => opened.add(card.key),
                onShowAll: (origins) => showFlowDesktopSwitcher(
                  context,
                  cards: const [card],
                  cardAspect: 16 / 10,
                  origins: origins,
                  onOpen: (card, _) => opened.add(card.key),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Only'));
    await tester.pumpAndSettle();
    expect(opened, ['only']);
    expect(find.byType(FlowDesktopSwitcher), findsNothing);
  });
}
