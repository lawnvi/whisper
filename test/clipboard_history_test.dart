import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/tray/clipboard_history.dart';

ClipEntry _clip(String text) =>
    ClipEntry(text: text, from: '', at: DateTime(2026));

void main() {
  group('the clipboard history', () {
    test('newest first, five at most', () {
      final history = ClipboardHistory();
      for (var i = 0; i < 7; i++) {
        history.add(_clip('$i'));
      }
      expect(history.entries.map((e) => e.text), ['6', '5', '4', '3', '2']);
    });

    test('what is marked sensitive is not kept', () {
      final history = ClipboardHistory()
        ..add(_clip('hunter2'), sensitive: true);
      expect(history.entries, isEmpty);
    });

    test('copying the same thing again moves it up, not in twice', () {
      final history = ClipboardHistory()
        ..add(_clip('a'))
        ..add(_clip('b'))
        ..add(_clip('a'));
      expect(history.entries.map((e) => e.text), ['a', 'b']);
    });

    test('blank text is not worth a row', () {
      final history = ClipboardHistory()..add(_clip('  \n'));
      expect(history.entries, isEmpty);
    });

    test('copying from the list makes it current, and nothing moves', () {
      final history = ClipboardHistory()
        ..add(_clip('a'))
        ..add(_clip('b'));
      expect(history.current, 'b');
      history.markCurrent('a');
      expect(history.current, 'a');
      expect(history.entries.map((e) => e.text), ['b', 'a']);
    });

    test('the system reporting that same copy does not move it either', () {
      final history = ClipboardHistory()
        ..add(_clip('a'))
        ..add(_clip('b'))
        ..markCurrent('a')
        ..add(_clip('a'));
      expect(history.entries.map((e) => e.text), ['b', 'a']);
      expect(history.current, 'a');
    });

    test('copying back and forth never changes the rows', () {
      final history = ClipboardHistory()
        ..add(_clip('a'))
        ..add(_clip('b'));
      for (final text in ['a', 'b', 'a', 'b']) {
        history
          ..markCurrent(text)
          ..add(_clip(text));
        expect(history.entries.map((e) => e.text), ['b', 'a']);
        expect(history.current, text);
      }
    });

    test('something new copied elsewhere goes on top and is current', () {
      final history = ClipboardHistory()
        ..add(_clip('a'))
        ..add(_clip('b'))
        ..markCurrent('a')
        ..add(_clip('c'));
      expect(history.entries.map((e) => e.text), ['c', 'b', 'a']);
      expect(history.current, 'c');
    });
  });
}
