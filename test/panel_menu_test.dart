import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/phone/panel_menu.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  const screen = Size(380, 780);
  const statusBar = 44.0, gestureBar = 24.0;

  Future<Rect> pumpMenu(
    WidgetTester tester, {
    required Rect anchor,
    required int rows,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(
      top: statusBar,
      bottom: gestureBar,
    );
    tester.view.viewPadding = const FakeViewPadding(
      top: statusBar,
      bottom: gestureBar,
    );
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Material(
          child: PanelMenu(
            anchor: anchor,
            touch: true,
            items: [
              for (var i = 0; i < rows; i++)
                PanelMenuEntry(label: 'row $i', onSelected: () {}),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.getRect(find.byType(IntrinsicWidth).first);
  }

  const underBar = Rect.fromLTWH(20, 100, 80, 34);

  testWidgets('it opens under its button when it fits', (tester) async {
    final menu = await pumpMenu(tester, anchor: underBar, rows: 4);
    expect(menu.top, underBar.bottom + 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long one scrolls, and stays off the system bars', (
    tester,
  ) async {
    final menu = await pumpMenu(tester, anchor: underBar, rows: 60);
    expect(menu.top, underBar.bottom + 6);
    expect(menu.bottom, lessThanOrEqualTo(screen.height - gestureBar - 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('it does not go under the keyboard', (tester) async {
    final menu = await pumpMenu(
      tester,
      anchor: underBar,
      rows: 60,
      keyboard: 300,
    );
    expect(menu.bottom, lessThanOrEqualTo(screen.height - 300 - 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('near the bottom it opens upwards, under the status bar', (
    tester,
  ) async {
    const low = Rect.fromLTWH(20, 650, 80, 34);
    final menu = await pumpMenu(tester, anchor: low, rows: 60);
    expect(menu.bottom, low.top - 6);
    expect(menu.top, greaterThanOrEqualTo(statusBar + 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('it stays within the width of a narrow window', (tester) async {
    const right = Rect.fromLTWH(320, 100, 48, 48);
    final menu = await pumpMenu(tester, anchor: right, rows: 3);
    expect(menu.right, lessThanOrEqualTo(screen.width - 10));
    expect(menu.left, greaterThanOrEqualTo(10));
  });
}
