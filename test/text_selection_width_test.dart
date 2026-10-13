import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/message_link_text.dart';

void main() {
  testWidgets('a selected line is highlighted only as far as its text', (
    tester,
  ) async {
    const style = TextStyle(fontSize: 16);
    const text = '  - short\n  - a much longer line';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MessageLinkText(
              text: text,
              style: style,
              linkStyle: style,
              onOpen: (_) async {},
            ),
          ),
        ),
      ),
    );

    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    double rightEdge(int start, int end) => editable
        .getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: end),
        )
        .map((box) => box.right)
        .reduce(math.max);
    final shortLine = rightEdge(0, 9);
    final longLine = rightEdge(10, text.length);

    expect(longLine, greaterThan(shortLine + 100));
    // The first line together with its line break, as a triple click selects.
    expect(rightEdge(0, 10), closeTo(shortLine, 0.5));
  });

  test('text inputs and selectable text keep the highlight to the text', () {
    const tight = 'selectionWidthStyle: BoxWidthStyle.tight';
    final expected = <String, int>{
      'lib/widget/message_link_text.dart': 1,
      'lib/page/transfer_assistant.dart': 1,
      'lib/page/settings.dart': 1,
      'lib/widget/chat_composer.dart': 2,
      'lib/remote_input/mobile_control_screen.dart': 1,
    };
    for (final entry in expected.entries) {
      final source = File(entry.key).readAsStringSync();
      expect(tight.allMatches(source).length, entry.value, reason: entry.key);
    }
  });
}
