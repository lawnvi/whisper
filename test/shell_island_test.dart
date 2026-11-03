import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/shell/shell_island.dart';

void main() {
  const window = 1144.0;
  Offset place({
    double width = 260,
    double windowWidth = window,
    double controlsLeft = 900,
    double titleRight = 320,
    bool expanded = false,
    double buttonsLeft = 1006,
    double buttonsBottom = 32,
  }) => shellIslandOrigin(
    width: width,
    windowWidth: windowWidth,
    controlsLeft: controlsLeft,
    titleRight: titleRight,
    expanded: expanded,
    buttonsLeft: buttonsLeft,
    buttonsBottom: buttonsBottom,
  );

  group('where the island goes', () {
    test('the middle of the window, 9 from the top, when it fits', () {
      final o = place();
      expect(o.dy, 9);
      expect(o.dx + 130, window / 2);
    });

    test('never sideways: it goes under the toolbar to clear the controls', () {
      final o = place(controlsLeft: 650);
      expect(o.dy, 58);
      expect(o.dx + 130, window / 2);
    });

    test('and to clear the title', () {
      final o = place(titleRight: 500);
      expect(o.dy, 58);
      expect(o.dx + 130, window / 2);
    });

    test('opened, it goes down past the window buttons', () {
      final o = place(
        width: 372,
        windowWidth: 720,
        expanded: true,
        buttonsLeft: 540,
      );
      expect(o.dy, 32 + 6);
      expect(o.dx + 186, 360);
    });

    test('opened and clear of the buttons, it stays at the top', () {
      final o = place(width: 372, expanded: true);
      expect(o.dy, 9);
      expect(o.dx + 186, window / 2);
    });
  });
}
