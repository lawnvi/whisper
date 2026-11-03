import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
// The channel context super_native_extensions talks through (a mock in tests).
// ignore: depend_on_referenced_packages
import 'package:irondash_message_channel/irondash_message_channel.dart'
    show MockMessageChannelContext, MockMethodChannel;
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:super_native_extensions/src/native/context.dart'
    show superNativeExtensionsContext;
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';

/// Goldens compare pixels, and text renders differently per OS and per Flutter
/// version, so they only run where they were made. CI on Linux skips them.
/// To remake them: `flutter test --update-goldens <file>`.
final Object? goldenSkip = Platform.isMacOS
    ? null
    : 'Goldens are made on macOS. Text renders differently elsewhere.';

const _families = [
  // What text resolves to in the app's themes without a family of their own.
  'Roboto',
  '.AppleSystemUIFont',
  '.SF UI Text',
  '.SF UI Display',
  'CupertinoSystemText',
  'CupertinoSystemDisplay',
  'Noto Sans SC',
];

/// flutter_test paints every glyph as a black box unless real fonts are loaded.
/// Uses the Noto font the repository already bundles for Windows, under the
/// family names the themes ask for, so widgets and themes stay untouched.
Future<void> loadGoldenFonts() async {
  final text = File('assets/fonts/NotoSansSC-Compact.ttf').readAsBytesSync();
  for (final family in _families) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(text)));
    await loader.load();
  }
  // The icon fonts, wherever Flutter's asset bundle put them.
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json'))
          as List<dynamic>;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final family = entry['family'] as String;
    if (_families.contains(family)) continue;
    final loader = FontLoader(family);
    for (final font in (entry['fonts'] as List<dynamic>)) {
      final asset = (font as Map<String, dynamic>)['asset'] as String;
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }
}

/// Pages that accept dropped files find no native side in tests and carry on.
void stubSystemDragAndDrop(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('dev.irondash.engine_context'),
    (call) async => 1,
  );
  final native = superNativeExtensionsContext as MockMessageChannelContext;
  for (final channel in ['DragManager', 'DropManager']) {
    native.registerMockMethodCallHandler(channel, (call) async => null);
  }
}

/// Sizes the test's window, undone when the test ends.
void setGoldenWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

const goldenDesktopWindow = Size(1144, 720);
const goldenPhoneWindow = Size(390, 780);

/// The app's real themes and localizations around one page.
Widget goldenApp(
  Widget home, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('zh'),
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.lightTheme,
  darkTheme: AppTheme.darkTheme,
  themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
  locale: locale,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);
