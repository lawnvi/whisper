import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/page/remote_files/files_share_sheet.dart';
import 'package:whisper/page/remote_files/files_shares.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/share_links/share_names.dart';
import 'package:whisper/share_links/share_server.dart';
import 'package:whisper/theme/app_theme.dart';

class _MemoryPreferences implements ShareLinkPreferences {
  final values = <String, Object>{};

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<int?> getInt(String key) async => values[key] as int?;

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> setBool(String key, bool value) async => values[key] = value;

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

/// Pretends to listen, so widget tests need no sockets.
class _FakeServer extends ShareServer {
  _FakeServer(ShareServerSource source) : super(source: source);

  int? _port;

  @override
  bool get isRunning => _port != null;

  @override
  int? get port => _port;

  @override
  Future<int> start(List<int> ports) async => _port = ports.first;

  @override
  Future<void> stop() async => _port = null;
}

/// Made and loaded on the real event loop: futures the store keeps would
/// otherwise belong to the test's fake-time zone and never run.
Future<ShareLinkStore> _ready(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final store = _store();
      await store.initialize();
      return store;
    }))!;

ShareLinkStore _store() => ShareLinkStore(
  preferences: _MemoryPreferences(),
  server: _FakeServer.new,
  addresses: () async => ['192.168.31.230', '10.8.0.12'],
  deviceName: () async => 'MacBook',
  clock: () => DateTime(2026, 10, 17, 10, 24),
);

Widget _app({
  required Widget child,
  Locale locale = const Locale('zh'),
  bool dark = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.lightTheme,
  darkTheme: AppTheme.darkTheme,
  themeMode: dark ? ThemeMode.dark : ThemeMode.light,
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  late Directory temp;
  late String photo;
  late String folder;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('share_ui_');
    photo = p.join(temp.path, 'IMG_0042.jpg');
    folder = p.join(temp.path, '旅行');
    await File(photo).writeAsBytes(List.filled(2048, 1));
    await Directory(folder).create();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  testWidgets(
    'with no links the list says how to make one',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final store = await _ready(tester);
      await tester.pumpWidget(
        _app(
          child: Scaffold(body: FilesSharesList(store: store, grouped: true)),
        ),
      );
      await tester.pump();
      final text = lookupAppLocalizations(const Locale('zh'));
      expect(find.text(text.shareLinksEmpty), findsOneWidget);
      expect(find.text(text.shareLinksEmptyDetailPhone), findsOneWidget);
      expect(find.text(text.shareLinksServiceIdle), findsOneWidget);
    },
  );

  // Renders the sheet and the list to PNG files for a look by eye:
  //   SHARE_PREVIEW_DIR=/some/dir flutter test test/share_links_ui_test.dart
  final out = Platform.environment['SHARE_PREVIEW_DIR'];
  for (final (name, size, dark, locale) in [
    ('phone_zh_light', const Size(390, 844), false, const Locale('zh')),
    ('phone_zh_dark', const Size(390, 844), true, const Locale('zh')),
    ('wide_en_light', const Size(1100, 760), false, const Locale('en')),
    ('wide_es_dark', const Size(1100, 760), true, const Locale('es')),
  ]) {
    testWidgets(
      'preview $name',
      skip: out == null,
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        await tester.runAsync(_loadFonts);
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final store = await _ready(tester);
        await tester.runAsync(() async {
          final a = await store.create(paths: [photo], route: 'k7qm');
          await store.create(paths: [folder, photo], password: 'pw');
          await store.create(paths: [folder], route: 'trip-2026');
          store.linkVisited(a, counted: true);
          store.linkDownloaded(a);
          store.linkServed(a, 734003200);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        final boundary = GlobalKey();
        BuildContext? home;
        final phone = size.width < 700;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: _app(
              locale: locale,
              dark: dark,
              child: Builder(
                builder: (context) {
                  home = context;
                  return Scaffold(
                    backgroundColor: phone ? context.wc.canvas : null,
                    body: SafeArea(
                      child: FilesSharesList(store: store, grouped: phone),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pumpAndSettle();
        await _save(tester, boundary, '$out/list_$name.png');

        // The sheet, before and after making a link.
        final sources = [
          ShareSource(absolutePath: photo, name: 'IMG_0042.jpg', isDir: false),
          ShareSource(absolutePath: folder, name: '旅行', isDir: true),
          ShareSource(absolutePath: photo, name: '报告 2026.pdf', isDir: false),
          ShareSource(absolutePath: folder, name: 'Música', isDir: true),
        ];
        showShareLinkSheet(home!, store: store, items: sources);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(CupertinoTextField).last, 'secret');
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await _save(tester, boundary, '$out/sheet_create_$name.png');
        await tester.runAsync(() async {
          await tester.tap(
            find.text(lookupAppLocalizations(locale).shareLinkCreate),
          );
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        });
        await tester.pumpAndSettle();
        await _save(tester, boundary, '$out/sheet_result_$name.png');
        Navigator.of(home!).pop();
        await tester.pumpAndSettle();

        showShareLinkDetails(home!, store.links.last, store: store);
        await tester.pumpAndSettle();
        await _save(tester, boundary, '$out/sheet_details_$name.png');
        Navigator.of(home!).pop();
        await tester.pumpAndSettle();

        await tester.runAsync(() => store.setServiceOn(false));
        showShareLinkDetails(home!, store.links.last, store: store);
        await tester.pumpAndSettle();
        await _save(tester, boundary, '$out/sheet_details_off_$name.png');
      },
    );
  }
}

Future<void> _save(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> _loadFonts() async {
  Future<ByteData> read(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  const text = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
  for (final family in [
    'Roboto',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
    'Menlo',
  ]) {
    final loader = FontLoader(family)
      ..addFont(
        read(family == 'Menlo' ? '/System/Library/Fonts/SFNSMono.ttf' : text),
      );
    await loader.load();
  }
  final home = Platform.environment['HOME'];
  final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
    ..addFont(
      read(
        '$home/.pub-cache/hosted/pub.dev/cupertino_icons-1.0.9/assets/'
        'CupertinoIcons.ttf',
      ),
    );
  await icons.load();
}
