import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/page/remote_files/files_menu.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  const window = Size(800, 600);

  Future<void> open(
    WidgetTester tester,
    Offset at, {
    int rows = 6,
    bool alignRight = false,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showFilesMenu(
                context,
                position: at,
                alignRight: alignRight,
                items: [
                  for (var i = 0; i < rows; i++)
                    FilesMenuItem(label: 'row $i', onSelected: () {}),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void expectAllInWindow(WidgetTester tester, int rows) {
    for (var i = 0; i < rows; i++) {
      final rect = tester.getRect(find.text('row $i'));
      expect(rect.top, greaterThanOrEqualTo(0), reason: 'row $i');
      expect(rect.bottom, lessThanOrEqualTo(window.height), reason: 'row $i');
      expect(rect.left, greaterThanOrEqualTo(0), reason: 'row $i');
      expect(rect.right, lessThanOrEqualTo(window.width), reason: 'row $i');
    }
  }

  testWidgets('with room it opens under the pointer', (tester) async {
    await open(tester, const Offset(100, 100));
    expect(tester.getTopLeft(find.text('row 0')).dy, greaterThan(100));
    expectAllInWindow(tester, 6);
  });

  testWidgets('at the bottom of the window it opens over the pointer', (
    tester,
  ) async {
    await open(tester, const Offset(100, 585));
    expect(tester.getBottomLeft(find.text('row 5')).dy, lessThan(585));
    expectAllInWindow(tester, 6);
  });

  testWidgets('at the right edge it stays in the window', (tester) async {
    await open(tester, const Offset(790, 585));
    expectAllInWindow(tester, 6);
  });

  group('a desktop menu is as wide as its longest row', () {
    Future<double> widthWith(WidgetTester tester, String label) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showFilesMenu(
                  context,
                  position: const Offset(100, 100),
                  items: [FilesMenuItem(label: label, onSelected: () {})],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(BackdropFilter).last).width;
    }

    testWidgets('short rows: the narrowest it gets', (tester) async {
      expect(await widthWith(tester, 'Copy'), 190);
    });

    testWidgets('a long row is not cut off', (tester) async {
      const label = 'Show in that folder';
      final width = await widthWith(tester, label);
      expect(width, greaterThan(190));
      expect(width, lessThanOrEqualTo(320));
      expect(
        tester
            .renderObject<RenderParagraph>(find.text(label))
            .didExceedMaxLines,
        isFalse,
      );
    });

    testWidgets('a very long row stops at the widest', (tester) async {
      expect(await widthWith(tester, 'word ' * 60), 320);
    });
  });

  testWidgets(
    'aligned right, its right edge is the anchor, whatever its width',
    (tester) async {
      await open(tester, const Offset(600, 100), alignRight: true);
      expect(tester.getTopRight(find.byType(BackdropFilter).last).dx, 600);
    },
  );
}
