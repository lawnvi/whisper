import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/windows_system_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop tray uses dedicated high-contrast assets', () async {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    final windowsTheme = File(
      'lib/helper/windows_system_theme.dart',
    ).readAsStringSync();
    expect(windowsTheme, contains("'assets/tray_icon.ico'"));
    expect(source, contains("'assets/tray_icon.png'"));
    expect(source, contains('isTemplate: Platform.isMacOS'));
    expect(source, contains('iconSize: 18'));
    expect(pubspec, contains('- assets/tray_icon.png'));
    expect(pubspec, contains('- assets/tray_icon.ico'));

    final tray = await _decodePng('assets/tray_icon.png');
    expect(tray.width, 256);
    expect(tray.height, 256);
    final pixels = await tray.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    expect(pixels, isNotNull);
    expect(_alphaAt(pixels!, tray.width, 0, 0), 0);
    expect(_alphaAt(pixels, tray.width, 128, 28), greaterThan(200));
    expect(_alphaAt(pixels, tray.width, 86, 128), lessThan(32));
    for (var offset = 0; offset < pixels.lengthInBytes; offset += 4) {
      if (pixels.getUint8(offset + 3) > 0) {
        expect(pixels.getUint8(offset), 255);
        expect(pixels.getUint8(offset + 1), 255);
        expect(pixels.getUint8(offset + 2), 255);
      }
    }
    tray.dispose();

    expect(_icoImageCount('assets/tray_icon.ico'), 8);
  });

  test('Windows has a dark tray icon for a light taskbar', () async {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    // The tray icon is white and vanishes on the light taskbar of Windows.
    // Which taskbar there is comes from Windows' own mode, not from the
    // app's theme.
    expect(
      windowsTrayIconAsset(taskbarIsLight: true),
      'assets/tray_icon_on_light.ico',
    );
    expect(windowsTrayIconAsset(taskbarIsLight: false), 'assets/tray_icon.ico');
    expect(windowsTrayIconAsset(taskbarIsLight: null), 'assets/tray_icon.ico');
    expect(pubspec, contains('- assets/tray_icon_on_light.ico'));
    expect(source, contains('await _windowsTrayIcon.start();'));
    expect(source, contains('_windowsTrayIcon.stop();'));

    // The same shapes as the white icon, frame for frame, in a dark colour.
    final white = _icoFrames('assets/tray_icon.ico');
    final dark = _icoFrames('assets/tray_icon_on_light.ico');
    expect(dark, hasLength(white.length));
    for (var frame = 0; frame < white.length; frame += 1) {
      final whiteImage = await _decodePngBytes(white[frame]);
      final darkImage = await _decodePngBytes(dark[frame]);
      expect(darkImage.width, whiteImage.width);
      final whitePixels = (await whiteImage.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!;
      final darkPixels = (await darkImage.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!;
      for (var offset = 0; offset < darkPixels.lengthInBytes; offset += 4) {
        final alpha = darkPixels.getUint8(offset + 3);
        expect(alpha, whitePixels.getUint8(offset + 3));
        // Nearly transparent pixels lose their exact colour in decoding.
        if (alpha >= 128) {
          expect(darkPixels.getUint8(offset), lessThan(48));
          expect(darkPixels.getUint8(offset + 1), lessThan(48));
          expect(darkPixels.getUint8(offset + 2), lessThan(48));
        }
      }
      whiteImage.dispose();
      darkImage.dispose();
    }
  });

  test('the Windows tray icon follows the taskbar as it really is', () async {
    const settle = Duration(milliseconds: 150);
    bool? light = true;
    final shown = <String>[];
    final watch = WindowsTrayIconWatch(
      apply: (asset) async => shown.add(asset),
      taskbarIsLight: () => light,
      interval: const Duration(milliseconds: 20),
    );
    addTearDown(watch.stop);
    await watch.start();
    expect(shown, <String>['assets/tray_icon_on_light.ico']);

    // Windows announces a switch before it has written its own mode down.
    // Reading at that moment gives the old answer; the icon has to come
    // right once the setting has caught up, with nothing more announced.
    light = false;
    await Future<void>.delayed(settle);
    expect(shown, <String>[
      'assets/tray_icon_on_light.ico',
      'assets/tray_icon.ico',
    ]);

    light = true;
    await Future<void>.delayed(settle);
    expect(shown.last, 'assets/tray_icon_on_light.ico');

    // Nothing is set again while the taskbar stays as it is, and nothing
    // at all once the tray is gone.
    await Future<void>.delayed(settle);
    expect(shown, hasLength(3));
    watch.stop();
    light = false;
    await Future<void>.delayed(settle);
    expect(shown, hasLength(3));
  });

  test('a tray icon that could not be set is tried again', () async {
    var attempts = 0;
    final watch = WindowsTrayIconWatch(
      apply: (asset) async {
        attempts += 1;
        if (attempts == 1) throw StateError('tray not ready');
      },
      taskbarIsLight: () => true,
      interval: const Duration(milliseconds: 20),
    );
    addTearDown(watch.stop);
    await watch.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(attempts, 2);
  });

  test('full application logo keeps a transparent edge', () async {
    final logo = await _decodePng('assets/app_icon_round.png');
    expect(logo.width, 180);
    expect(logo.height, 180);
    final pixels = await logo.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    expect(pixels, isNotNull);
    expect(_alphaAt(pixels!, logo.width, 0, 0), 0);
    expect(_alphaAt(pixels, logo.width, 90, 90), greaterThan(240));
    logo.dispose();
  });
}

Future<ui.Image> _decodePng(String path) =>
    _decodePngBytes(File(path).readAsBytesSync());

Future<ui.Image> _decodePngBytes(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

/// The images inside an icon file, each of which is a PNG here.
List<Uint8List> _icoFrames(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final count = data.getUint16(4, Endian.little);
  return <Uint8List>[
    for (var index = 0; index < count; index += 1)
      Uint8List.sublistView(
        bytes,
        data.getUint32(6 + 16 * index + 12, Endian.little),
        data.getUint32(6 + 16 * index + 12, Endian.little) +
            data.getUint32(6 + 16 * index + 8, Endian.little),
      ),
  ];
}

int _alphaAt(ByteData pixels, int width, int x, int y) {
  return pixels.getUint8((y * width + x) * 4 + 3);
}

int _icoImageCount(String path) {
  final bytes = File(path).readAsBytesSync();
  expect(bytes.sublist(0, 4), <int>[0, 0, 1, 0]);
  return bytes[4] | (bytes[5] << 8);
}
