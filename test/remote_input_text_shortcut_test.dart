import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Remote input Flutter text shortcuts', () {
    testWidgets('select all targets the current focused EditableText',
        (tester) async {
      final controller = TextEditingController(text: 'mirror');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              focusNode: focusNode,
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();

      final handled = handleRemoteInputTextShortcut(
        RemoteInputTextShortcut.selectAll,
      );

      expect(handled, isTrue);
      expect(controller.selection.baseOffset, 0);
      expect(controller.selection.extentOffset, controller.text.length);
    });

    testWidgets('undo and redo target the current focused EditableText', (
      tester,
    ) async {
      final controller = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(controller: controller, focusNode: focusNode),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(find.byType(TextField), 'first second');
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        handleRemoteInputTextShortcut(RemoteInputTextShortcut.undo),
        isTrue,
      );
      expect(controller.text, 'first');
      expect(
        handleRemoteInputTextShortcut(RemoteInputTextShortcut.redo),
        isTrue,
      );
      expect(controller.text, 'first second');
    });
  });
}
