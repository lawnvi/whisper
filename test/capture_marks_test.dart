import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/capture/capture_marks.dart';

/// Black and white stripes one pixel wide: the kind of detail text is made of.
Future<ui.Image> _stripes(int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFFFFFFF), BlendMode.src);
  final black = Paint()..color = const Color(0xFF000000);
  for (var x = 0; x < size; x += 2) {
    canvas.drawRect(Rect.fromLTWH(x.toDouble(), 0, 1, size.toDouble()), black);
  }
  return recorder.endRecording().toImage(size, size);
}

int _red(ByteData rgba, int size, int x, int y) =>
    rgba.getUint8((y * size + x) * 4);

void main() {
  // What a mosaic hides must not be in the picture that leaves: no original pixel
  // under it, and no resampling of what is not under it.
  test('a mosaic leaves nothing of what is under it', () async {
    const size = 64;
    final image = await _stripes(size);
    final picture = await CapturePicture.of(image, block: 8);
    final flat = await flattenCapture(picture, const [
      CaptureMosaic([Offset(0, 16), Offset(64, 16)], width: 16),
    ]);
    final rgba = (await flat.toByteData())!;

    expect(flat.width, size);
    expect(flat.height, size);
    // Under it, neighbours in a block have the same colour: the stripes are gone.
    for (var x = 8; x < 56; x++) {
      if (x % 8 == 7) continue;
      expect(_red(rgba, size, x, 16), _red(rgba, size, x + 1, 16));
    }
    // Elsewhere, the picture is what it was, pixel by pixel.
    for (var x = 0; x < size - 1; x++) {
      expect(_red(rgba, size, x, 56), x.isEven ? 0 : 255);
    }
  });
}
