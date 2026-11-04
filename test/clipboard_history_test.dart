import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/tray/clipboard_history.dart';

ClipEntry _clip(String text) =>
    ClipEntry(text: text, from: '', at: DateTime(2026));

void main() {
  group('the clipboard history', () {
    test('what is marked sensitive is not kept', () {
      final history = ClipboardHistory()
        ..add(_clip('hunter2'), sensitive: true);
      expect(history.entries, isEmpty);
    });
  });
}
