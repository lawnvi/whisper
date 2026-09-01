import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop tray uses dedicated high-contrast assets', () async {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(source, contains("'assets/tray_icon.ico'"));
    expect(source, contains("'assets/tray_icon.png'"));
    expect(source, contains('isTemplate: Platform.isMacOS'));
    expect(source, contains('iconSize: 18'));
    expect(pubspec, contains('- assets/tray_icon.png'));
    expect(pubspec, contains('- assets/tray_icon.ico'));

    final tray = await _decodePng('assets/tray_icon.png');
    expect(tray.width, 256);
    expect(tray.height, 256);
    final pixels = await tray.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(pixels, isNotNull);
    expect(_alphaAt(pixels!, tray.width, 0, 0), 0);
    expect(_alphaAt(pixels, tray.width, 128, 28), greaterThan(200));
    expect(_alphaAt(pixels, tray.width, 86, 128), lessThan(32));
    tray.dispose();

    expect(_icoImageCount('assets/tray_icon.ico'), 8);
  });

  test('full application logo keeps a transparent edge', () async {
    final logo = await _decodePng('assets/app_icon_round.png');
    expect(logo.width, 180);
    expect(logo.height, 180);
    final pixels = await logo.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(pixels, isNotNull);
    expect(_alphaAt(pixels!, logo.width, 0, 0), 0);
    expect(_alphaAt(pixels, logo.width, 90, 90), greaterThan(240));
    logo.dispose();
  });
}

Future<ui.Image> _decodePng(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

int _alphaAt(ByteData pixels, int width, int x, int y) {
  return pixels.getUint8((y * width + x) * 4 + 3);
}

int _icoImageCount(String path) {
  final bytes = File(path).readAsBytesSync();
  expect(bytes.sublist(0, 4), <int>[0, 0, 1, 0]);
  return bytes[4] | (bytes[5] << 8);
}
