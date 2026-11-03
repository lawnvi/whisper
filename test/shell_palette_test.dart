import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/shell/shell_palette.dart';
import 'package:whisper/theme/whisper_icons.dart';

PaletteItem _item(String name, {List<String> keywords = const []}) =>
    PaletteItem(
      glyph: WhisperGlyph.info,
      name: name,
      category: 'c',
      onRun: () {},
      keywords: keywords,
    );

void main() {
  group('palette matching', () {
    test('an empty query lists the first ones', () {
      final items = [for (var i = 0; i < 12; i++) _item('d$i')];
      expect(paletteMatches(items, '  ').length, 8);
      expect(paletteMatches(items, '').first.name, 'd0');
    });

    test('names that start with it come before names that contain it', () {
      final found = paletteMatches([
        _item('my imac'),
        _item('other', keywords: ['imac']),
        _item('iMac'),
      ], 'ima');
      expect(found.map((i) => i.name), ['iMac', 'my imac', 'other']);
    });

    test('nothing matching finds nothing', () {
      expect(paletteMatches([_item('iMac')], 'zzz'), isEmpty);
    });

    test('never more than the limit', () {
      final items = [for (var i = 0; i < 20; i++) _item('a$i')];
      expect(paletteMatches(items, 'a').length, 8);
    });
  });
}
