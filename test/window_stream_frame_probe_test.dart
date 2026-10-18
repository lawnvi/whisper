import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../tool/frame_probe.dart';

/// A 240×64 snapshot-sized picture with the counter at 8 px per cell
/// (counter 0xA5C3), saved by macOS as a 4:2:0 JPEG at quality 45.
const _jpegFixture = [
  '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAA',
  'AAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAA8KADAAQAAAABAAAAQAAAAAD/7QA4UGhvdG9z',
  'aG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgA',
  'QADwAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIB',
  'AwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYX',
  'GBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeI',
  'iYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn',
  '6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIB',
  'AgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDTh',
  'JfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWG',
  'h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm',
  '5+jp6vLz9PX29/j5+v/bAEMABwcHBwcHDAcHDBEMDAwRFxEREREXHhcXFxcXHiQeHh4eHh4k',
  'JCQkJCQkJCsrKysrKzIyMjIyODg4ODg4ODg4OP/bAEMBCQkJDg0OGQ0NGTsoISg7Ozs7Ozs7',
  'Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O//dAAQAD//aAAwD',
  'AQACEQMRAD8Ap6R8Mde0/VrS/mntSlvPHKwVnyQjAnGUHPFew61rFvoemy6pdq7RQ7dwQAsd',
  'zBRjJA6n1rJ1PxLph065Gl39vJd+U/kLHIju0m07Aq5O4lsYGDmuArecrajkkh+r6vb/ABKt',
  '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',
  '7tXOduOo61VjKSP/2Q==',
];

Uint8List _png(Uint8List rgb, int width, int height) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw
      ..addByte(y.isEven ? 0 : 2) // none and "up" filters
      ..add(
        y.isEven
            ? Uint8List.sublistView(rgb, y * width * 3, (y + 1) * width * 3)
            : Uint8List.fromList([
                for (var i = 0; i < width * 3; i++)
                  (rgb[y * width * 3 + i] - rgb[(y - 1) * width * 3 + i]) &
                      0xFF,
              ]),
      );
  }
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add([...type.codeUnits, ...data])
      ..add([0, 0, 0, 0]); // CRC is not checked by the probe
  }

  chunk(
    'IHDR',
    (ByteData(13)
          ..setUint32(0, width)
          ..setUint32(4, height)
          ..setUint8(8, 8)
          ..setUint8(9, 2))
        .buffer
        .asUint8List(),
  );
  chunk('IDAT', ZLibCodec().encode(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

Uint8List _bmp(Uint8List rgb, int width, int height, {int bpp = 24}) {
  final stride = ((width * bpp + 31) ~/ 32) * 4;
  final data = ByteData(54 + stride * height)
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, -height, Endian.little) // top-down
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, bpp, Endian.little);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final source = (y * width + x) * 3;
      final target = 54 + y * stride + x * (bpp ~/ 8);
      data
        ..setUint8(target, rgb[source + 2])
        ..setUint8(target + 1, rgb[source + 1])
        ..setUint8(target + 2, rgb[source]);
    }
  }
  return data.buffer.asUint8List();
}

/// A busy, colourful background like a real window.
Uint8List _background(int width, int height, {int seed = 1}) {
  final random = math.Random(seed);
  final rgb = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 3;
      final ink = ((x ~/ 6) + (y ~/ 4)) % 3 == 0;
      rgb[i] = ink ? 20 : 240 - random.nextInt(40);
      rgb[i + 1] = ink ? 20 : 235 - random.nextInt(40);
      rgb[i + 2] = ink ? 40 : 250 - random.nextInt(20);
    }
  }
  return rgb;
}

void main() {
  test('reads the counter from a scaled, compressed snapshot', () {
    final jpeg = base64Decode(_jpegFixture.join());
    final matches = findFrameCounters(decodeLuma(jpeg));
    expect(matches, hasLength(1));
    expect(matches.single.value, 0xA5C3);
    expect(matches.single.cell, closeTo(8, 0.5));
  });

  test('reads PNG and BMP at any position and cell size', () {
    for (final (value, cell, left, top) in [
      (0, 16, 16, 16),
      (0xFFFF, 16, 40, 70),
      (0x1234, 5, 3, 9),
      (0x8001, 32, 64, 32),
    ]) {
      const width = 900;
      const height = 300;
      final rgb = _background(width, height, seed: value);
      drawFrameCounter(rgb, width, value, left: left, top: top, cell: cell);
      for (final bytes in [
        _png(rgb, width, height),
        _bmp(rgb, width, height),
        _bmp(rgb, width, height, bpp: 32),
      ]) {
        final matches = findFrameCounters(decodeLuma(bytes));
        expect(matches.map((m) => m.value), [value], reason: 'cell $cell');
        expect(matches.single.x, left + cell);
        expect(matches.single.y, top + cell);
      }
    }
  });

  test('finds every counter, and none in ordinary content', () {
    const width = 1200;
    const height = 400;
    final rgb = _background(width, height);
    expect(findFrameCounters(decodeLuma(_png(rgb, width, height))), isEmpty);
    drawFrameCounter(rgb, width, 7, left: 20, top: 20);
    drawFrameCounter(rgb, width, 9000, left: 600, top: 250, cell: 12);
    final values = findFrameCounters(
      decodeLuma(_png(rgb, width, height)),
    ).map((m) => m.value);
    expect(values, [7, 9000]);
  });

  test('says which images it cannot read', () {
    expect(
      () => decodeLuma(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xC2, 0, 2])),
      throwsFormatException,
    );
    expect(
      () => decodeLuma(Uint8List.fromList(utf8.encode('GIF89a......'))),
      throwsFormatException,
    );
  });
}
