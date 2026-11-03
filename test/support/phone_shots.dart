import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart' show debugDisableShadows;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_support.dart';

/// The inside of the phone in docs/design/reference/phone-*.jpg, at 1x: under
/// its status bar of 44 the pictures and these pages line up pixel for pixel.
const phoneScreen = Size(380, 780);
const phoneReference = Rect.fromLTWH(400, 26, 380, 780);
const phoneStatusBar = 44.0;

final _shotKey = GlobalKey();

bool get phoneRendering =>
    (Platform.environment['WHISPER_RENDER_DIR'] ?? '').isNotEmpty;

/// [loadGoldenFonts], and something monospaced for the family the codes ask for.
Future<void> loadPhoneFonts() async {
  await loadGoldenFonts();
  const mono = '/System/Library/Fonts/SFNSMono.ttf';
  final fallback = File('assets/fonts/NotoSansSC-Compact.ttf');
  final bytes = File(mono).existsSync()
      ? File(mono).readAsBytesSync()
      : fallback.readAsBytesSync();
  final loader = FontLoader('monospace')
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// A phone's screen: its size, status bar and text scale, undone at the end.
Future<void> pumpPhone(
  WidgetTester tester,
  Widget page, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('zh'),
  Size size = phoneScreen,
  double textScale = 1,
  bool settleIt = true,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.padding = const FakeViewPadding(top: phoneStatusBar * 2);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: goldenApp(page, brightness: brightness, locale: locale),
    ),
  );
  if (settleIt) await phoneSettle(tester);
}

/// Lets springs land. Not `pumpAndSettle`: the scan line never does.
Future<void> phoneSettle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }
}

/// With WHISPER_RENDER_DIR set, writes the screen, and beside the reference when
/// given one. Never compared, and nothing lands in the repo.
Future<void> phoneShot(
  WidgetTester tester,
  String name, {
  String? reference,
}) async {
  if (!phoneRendering || !kDebugMode) return;
  final dir = Platform.environment['WHISPER_RENDER_DIR']!;
  final boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    Directory(dir).createSync(recursive: true);
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    if (reference == null) return;
    final bytes = File('docs/design/reference/$reference').readAsBytesSync();
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final w = phoneReference.width * 2, h = phoneReference.height * 2;
    canvas.drawImageRect(
      frame.image,
      phoneReference,
      Rect.fromLTWH(0, 0, w, h),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(w + 16, 0, image.width.toDouble(), image.height.toDouble()),
      Paint(),
    );
    final both = await recorder.endRecording().toImage(
      (w + 16 + image.width).round(),
      h.round(),
    );
    final out = await both.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name-vs.png').writeAsBytesSync(out!.buffer.asUint8List());
  });
}

/// Runs [body] with real shadows when rendering: flutter_test paints them without
/// their blur. Put back before the end of the test body, which checks.
Future<void> withPhoneShadows(Future<void> Function() body) async {
  if (phoneRendering) debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = true;
  }
}

/// Every combination the phone's pages must lay out in without overflowing.
final phoneMatrix = [
  for (final locale in const [Locale('zh'), Locale('en'), Locale('es')])
    for (final (size, scale) in const [
      (Size(360, 720), 1.0),
      (Size(360, 720), 2.0),
      (phoneScreen, 1.0),
    ])
      for (final brightness in Brightness.values)
        (locale, size, scale, brightness),
];
