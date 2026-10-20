import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/page/window_stream/android_service/android_service_controller.dart';
import 'package:whisper/page/window_stream/android_service/android_service_page.dart';
import 'package:whisper/theme/app_theme.dart';

/// Renders the phone's window flow service page in each state to PNG files
/// for a look by eye:
///   SERVICE_PREVIEW_DIR=/some/dir flutter test test/android_service_preview_test.dart
/// Skipped otherwise.
void main() {
  final out = Platform.environment['SERVICE_PREVIEW_DIR'];

  testWidgets('service page previews', skip: out == null, (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final cases = <String, _Fake>{
      'setup': _Fake(AndroidWindowServiceState.needsSetup, selfStart: true),
      'stopped': _Fake(AndroidWindowServiceState.stopped, selfStart: true),
      'running': _Fake(AndroidWindowServiceState.running, selfStart: true),
      'computer': _Fake(AndroidWindowServiceState.needsSetup),
    };
    Widget page(String name) => name == 'settings'
        ? SettingsScreen(
            presentationLoader: () async => _settings,
            changeDirectory: () async => null,
            openDirectory: (_) async {},
            updateNickname: (_) async {},
            updateServerPort: (_) async {},
            autoCheckForUpdates: false,
          )
        : AndroidWindowServicePage(controller: cases[name]);
    for (final dark in [false, true]) {
      for (final name in ['settings', ...cases.keys]) {
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: AppTheme.lightTheme,
              darkTheme: AppTheme.darkTheme,
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              home: page(name),
            ),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        final file = '$name${dark ? '-dark' : ''}.png';
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('$out/$file').writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
    }
  });
}

const _settings = SettingsPresentation(
  device: DeviceData(
    id: 0,
    uid: 'local-device',
    name: '一加 8',
    host: '192.168.1.5',
    port: 10002,
    platform: 'android',
    isServer: true,
    online: true,
    clipboard: true,
    auth: false,
    lastTime: 0,
  ),
  saveDirectoryPath: '/storage/emulated/0/Download/Whisper',
  version: '0.0.58',
  closeToTray: false,
  copyVerificationCode: true,
  listenAndroidNotifications: true,
  ignoreAndroidNotifications: false,
  autoConnect: true,
  launchAtStartup: false,
  androidBackgroundKeepAlive: true,
  audioSharePlaybackGain: 1.0,
  remoteInputScrollMultiplier: 1.0,
  themeMode: ThemeMode.system,
  isAndroid: true,
  isDesktop: false,
  isMobile: true,
  notificationAppCount: 2,
);

class _Fake extends AndroidWindowServiceController {
  _Fake(this._state, {bool selfStart = false}) : _selfStart = selfStart;

  final AndroidWindowServiceState _state;
  final bool _selfStart;

  @override
  AndroidWindowServiceState get state => _state;

  @override
  bool get canSelfStart => _selfStart;

  @override
  bool get autoStart => true;

  @override
  Future<void> init() async {}
}

Future<void> _loadFonts() async {
  Future<ByteData> read(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  const text = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
  for (final family in [
    'Roboto',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
  ]) {
    await (FontLoader(family)..addFont(read(text))).load();
  }
  final home = Platform.environment['HOME'];
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
        read(
          '$home/.pub-cache/hosted/pub.dev/cupertino_icons-1.0.9/assets/'
          'CupertinoIcons.ttf',
        ),
      ))
      .load();
  await (FontLoader('MaterialIcons')..addFont(
        read(
          '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
        ),
      ))
      .load();
}

String _flutterRoot() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) return root;
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.path != dir.parent.path) {
    if (File('${dir.path}/bin/flutter').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return '';
}
