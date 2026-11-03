import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/whisper_icons.dart';

void main() {
  test('every glyph has a path that stays inside its box', () {
    for (final glyph in WhisperGlyph.values) {
      final box = whisperGlyphPath(glyph).getBounds();
      expect(box.isEmpty && box.width == 0 && box.height == 0, isFalse);
      expect(box.left, greaterThanOrEqualTo(0), reason: glyph.name);
      expect(box.top, greaterThanOrEqualTo(0), reason: glyph.name);
      expect(box.right, lessThanOrEqualTo(20), reason: glyph.name);
      expect(box.bottom, lessThanOrEqualTo(20), reason: glyph.name);
    }
  });

  test('numbers run together are read apart', () {
    final box = whisperSvgPath('M1 1c-.7.4-1 .8-1 1.6').getBounds();
    expect(box.top, closeTo(1, .01));
    expect(box.bottom, closeTo(2.6, .01));
  });

  testWidgets('it takes the size it is given', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: WhisperIcon(WhisperGlyph.gear, size: 22)),
      ),
    );
    expect(tester.getSize(find.byType(WhisperIcon)), const Size.square(22));
  });
}
