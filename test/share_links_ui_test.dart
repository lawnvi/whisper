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
    'the sheet makes a link and shows it',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = await _ready(tester);
      ShareLink? result;
      var closed = false;
      await tester.pumpWidget(
        _app(
          child: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showShareLinkSheet(
                    context,
                    store: store,
                    items: [
                      ShareSource(
                        absolutePath: photo,
                        name: 'IMG_0042.jpg',
                        isDir: false,
                      ),
                      ShareSource(
                        absolutePath: folder,
                        name: '旅行',
                        isDir: true,
                      ),
                    ],
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final text = lookupAppLocalizations(const Locale('zh'));
      expect(find.text(text.shareLinkCreateTitle), findsOneWidget);
      expect(find.text('IMG_0042.jpg'), findsOneWidget);
      expect(find.text('旅行'), findsOneWidget);

      // A reserved word is refused as it is typed.
      final route = find.byType(CupertinoTextField).first;
      await tester.enterText(route, 'zip');
      await tester.pump();
      expect(find.text(text.shareLinkRouteReserved), findsOneWidget);

      // Capitals become lowercase, anything else is not taken at all.
      await tester.enterText(route, 'My Trip!');
      await tester.pump();
      final field = tester.widget<CupertinoTextField>(route);
      expect(field.controller!.text, 'mytrip');
      expect(find.text(text.shareLinkRouteReserved), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(find.text(text.shareLinkCreate));
        // Until the server is up, the last step of making a link.
        for (var i = 0; i < 60 && !store.serverState.isRunning; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(store.links.single.route, 'mytrip');
      expect(store.links.single.name, isEmpty);
      expect(
        shareLinkTitle(text, store.links.single),
        text.shareLinkDefaultName(2),
      );
      expect(find.text(text.shareLinkReady), findsOneWidget);
      expect(
        find.textContaining('http://192.168.31.230:10003/', findRichText: true),
        findsOneWidget,
      );

      // The second address is one tap away.
      await tester.tap(find.text('10.8.0.12'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('http://10.8.0.12:10003/', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.text(text.shareLinkCopy));
      await tester.pump();
      expect(find.text(text.shareLinkCopied), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      await tester.tap(find.text(text.remoteFilesDone));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result?.route, 'mytrip');
    },
  );

  testWidgets(
    'the list shows the server and each link',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = await _ready(tester);
      late ShareLink link;
      await tester.runAsync(() async {
        link = await store.create(paths: [photo], route: 'photo');
        await store.create(paths: [folder], route: 'trip', password: 'pw');
      });
      await tester.pumpWidget(
        _app(
          locale: const Locale('en'),
          child: Scaffold(body: FilesSharesList(store: store)),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      final text = lookupAppLocalizations(const Locale('en'));
      expect(find.text(text.shareLinksService), findsOneWidget);
      expect(find.text(text.shareLinksServiceRunning('10003')), findsOneWidget);
      // One address row per address, as in iOS Settings.
      expect(find.text(text.shareLinkAddress), findsNWidgets(2));
      expect(find.text('192.168.31.230:10003'), findsOneWidget);
      expect(find.text('10.8.0.12:10003'), findsOneWidget);
      expect(find.text('IMG_0042.jpg'), findsOneWidget);
      expect(find.text('旅行'), findsOneWidget);
      expect(find.text('/photo'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.lock_fill), findsOneWidget);
      // Rows end in a dot, a word and a chevron; the only switch is the
      // server's.
      expect(find.text(text.shareLinkStatusOn), findsNWidgets(2));
      expect(find.byIcon(CupertinoIcons.chevron_forward), findsNWidgets(2));
      expect(find.byType(CupertinoSwitch), findsOneWidget);

      // A row opens the link's page, where it can be turned off.
      await tester.tap(find.text('IMG_0042.jpg'));
      await tester.pumpAndSettle();
      expect(find.text(text.shareLinkAllowAccess), findsOneWidget);
      expect(find.text(text.shareLinkVisitsLabel), findsOneWidget);
      final allow = find.ancestor(
        of: find.text(text.shareLinkAllowAccess),
        matching: find.byType(Row),
      );
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(
            of: allow.first,
            matching: find.byType(CupertinoSwitch),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(store.linkById(link.id)!.enabled, isFalse);
      await tester.tap(find.text(text.remoteFilesDone));
      await tester.pumpAndSettle();
      expect(find.text(text.shareLinkStatusOff), findsOneWidget);

      // A right-click has the quick actions; deleting asks first.
      await tester.tap(find.text('IMG_0042.jpg'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text(text.shareLinkCopy), findsOneWidget);
      expect(find.text(text.shareLinkTurnOn), findsOneWidget);
      await tester.tap(find.text(text.shareLinkDelete));
      await tester.pumpAndSettle();
      expect(find.text(text.shareLinkDeleteTitle), findsOneWidget);
      await tester.tap(find.text(text.delete).last);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(store.links.length, 1);

      // The whole server off.
      await tester.runAsync(() async {
        await store.setServiceOn(false);
      });
      await tester.pump();
      expect(find.text(text.shareLinksServiceOff), findsOneWidget);
      expect(find.text(text.shareLinkAddress), findsNothing);
    },
  );

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
                    backgroundColor: phone
                        ? context.whisperPalette.surfaceCanvas
                        : null,
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
