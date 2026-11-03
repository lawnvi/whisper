// docs/design/surfaces.md「设置」: the table of rows per platform, the panel, the
// phone's page, inline editing.
//
// To look at it next to the reference images, which is what decides whether it
// is right:
//   WHISPER_SETTINGS_SHOTS=/some/folder flutter test test/new_settings_test.dart \
//       --plain-name shots

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/app_update.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/macos_permissions.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';
import 'package:whisper/helper/windows_input_service.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/settings/settings_controls.dart';
import 'package:whisper/new_ui/settings/whisper_settings.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/theme/whisper_window.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/window_stream/linux/gnome_shell_helper.dart';

import 'support/golden_support.dart';

enum _Os { macos, windows, gnome, kde, android, ios }

final _home = Platform.environment['HOME'] ?? '/home/nobody';

const _macChannel = MethodChannel('test/settings/mac');
const _winChannel = MethodChannel('test/settings/win');

class _Backend extends ScreenshotBackend {
  ScreenshotShortcut? last;
  bool refuse = false;

  @override
  Future<bool> captureRegion() async => false;

  @override
  Future<String?> setShortcut(
    ScreenshotShortcut? shortcut,
    String description,
  ) async {
    if (refuse) throw PlatformException(code: 'taken');
    last = shortcut;
    return null;
  }

  @override
  Future<void> close() async {}
}

class _Gnome extends GnomeShellHelperController {
  _Gnome(this._on, this._fake) : super(isLinux: true);

  final bool _on;
  final GnomeShellHelperState _fake;

  @override
  bool get supported => _on;
  @override
  bool get checked => true;
  @override
  GnomeShellHelperState get state =>
      _on ? _fake : GnomeShellHelperState.unsupported;
  @override
  Future<void> refresh() async {}
}

class _Links extends ShareLinkStore {
  @override
  Future<void> initialize() async {}
  @override
  int get enabledCount => 2;
  @override
  bool get serviceOn => true;
}

class _Updates implements AppUpdateManager {
  _Updates(this.result);

  AppUpdateCheckResult result;
  Completer<void>? gate;
  int checks = 0;

  @override
  Future<AppUpdateCheckResult> checkForUpdate({
    required String currentVersion,
    bool force = false,
  }) async {
    checks += 1;
    await gate?.future;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _upToDate = AppUpdateCheckResult(
  status: AppUpdateStatus.upToDate,
  currentVersion: '0.0.58',
);

final _available = AppUpdateCheckResult(
  status: AppUpdateStatus.updateAvailable,
  currentVersion: '0.0.58',
  release: AppUpdateRelease(
    version: '0.0.59',
    tagName: 'dev-v0.0.59',
    channel: AppUpdateChannel.preview,
    releaseUrl: Uri.parse('https://example.com/release'),
    notes: '',
    publishedAt: DateTime.utc(2026, 11, 2),
    asset: null,
  ),
);

/// Everything the screen would otherwise ask this machine.
class _World {
  _World(this.os, {this.name = 'xiaoxin 的 MacBook Air 13 英寸'});

  final _Os os;
  final String name;
  final saved = <String, Object>{};
  final said = <String>[];
  final backend = _Backend();
  late final screenshot = DesktopScreenshotController(
    backend: backend,
    macOS: os == _Os.macos,
    windows: os == _Os.windows,
    load: () async => null,
    save: (_) async {},
  );
  late final windows = WindowsInputServiceController(
    channel: _winChannel,
    supported: os == _Os.windows,
    pollInterval: Duration.zero,
    pollAttempts: 1,
  );
  late final mac = MacPermissions(channel: _macChannel);
  late final gnome = _Gnome(
    os == _Os.gnome,
    GnomeShellHelperState.notInstalled,
  );
  final links = _Links();
  bool? macAudioKnown;
  String? languageCode;
  bool listenAndroid = true;
  AppUpdateManager? updates;
  bool autoCheck = false;
  ThemeMode themeMode = ThemeMode.system;

  bool get desktop => os != _Os.android && os != _Os.ios;

  SettingsPresentation get presentation => SettingsPresentation(
    device: DeviceData(
      id: 1,
      uid: 'self',
      name: name,
      host: '192.168.31.8',
      port: 10002,
      platform: switch (os) {
        _Os.macos => 'macos',
        _Os.windows => 'windows',
        _Os.gnome || _Os.kde => 'linux',
        _Os.android => 'android',
        _Os.ios => 'ios',
      },
      isServer: true,
      online: true,
      clipboard: true,
      auth: false,
      lastTime: 0,
    ),
    saveDirectoryPath: desktop
        ? '$_home/Downloads/Whisper'
        : '/storage/emulated/0/Download/Whisper',
    version: '0.0.58',
    closeToTray: true,
    copyVerificationCode: true,
    listenAndroidNotifications: listenAndroid,
    ignoreAndroidNotifications: false,
    autoConnect: true,
    launchAtStartup: true,
    androidBackgroundKeepAlive: true,
    audioSharePlaybackGain: 1.0,
    remoteInputScrollMultiplier: 1.0,
    themeMode: themeMode,
    clipboardAutoSync: true,
    isAndroid: os == _Os.android,
    isDesktop: desktop,
    isMobile: !desktop,
    notificationAppCount: 3,
    isMacOS: os == _Os.macos,
    languageCode: languageCode,
  );

  SettingsScreen screen(SettingsLayout layout) => SettingsScreen(
    layout: layout,
    presentationLoader: () async => presentation,
    changeDirectory: () async => '/tmp/picked',
    openDirectory: (path) async => saved['opened'] = path,
    updateNickname: (name) async => saved['nickname'] = name,
    updateServerPort: (port) async => saved['port'] = port,
    updateNotificationForwarding: (_) async {},
    showMessage: said.add,
    autoCheckForUpdates: autoCheck,
    updateManager: updates,
    windowsInputService: windows,
    macPermissions: mac,
    gnomeHelper: gnome,
    screenshotController: screenshot,
    shareLinks: links,
    readIslandOverlay: () async => (needed: true, allowed: true),
    openPairing: () => saved['pairing'] = true,
    openShareLinks: () => saved['links'] = true,
  );
}

Future<void> _mockChannels(WidgetTester t, _World world) async {
  final messenger = t.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_macChannel, (call) async {
    return <String, Object?>{
      'accessibility': true,
      'screenRecording': true,
      'audioCapture': 'denied',
    };
  });
  messenger.setMockMethodCallHandler(_winChannel, (call) async {
    if (call.method == 'getElevatedInputAllowed') return false;
    if (call.method == 'getInputServiceState') return 'notInstalled';
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(_macChannel, null);
    messenger.setMockMethodCallHandler(_winChannel, null);
  });
}

final _boundary = GlobalKey();

/// Pumps a window with one button that opens the settings, and opens them.
Future<void> _open(
  WidgetTester t,
  _World world, {
  Brightness brightness = Brightness.light,
  Size window = const Size(1128, 690),
  double textScale = 1,
  double dpr = 1,
  double statusBar = 0,
  Locale locale = const Locale('zh'),
  Widget? behind,
}) async {
  t.view.physicalSize = window * dpr;
  t.view.devicePixelRatio = dpr;
  t.view.padding = FakeViewPadding(top: statusBar * dpr);
  addTearDown(t.view.reset);
  await _mockChannels(t, world);
  await world.screenshot.initialize('Whisper');
  await t.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            backgroundColor: context.wc.content,
            body: Stack(
              fit: StackFit.expand,
              children: [
                ?behind,
                Align(
                  alignment: Alignment.topLeft,
                  child: GestureDetector(
                    key: const ValueKey('open'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => unawaited(
                      showWhisperSettings(
                        context,
                        exitForUpdate: () async {},
                        openPairing: () {},
                        openShareLinks: () {},
                        screen: world.screen,
                      ),
                    ),
                    child: const SizedBox.square(dimension: 8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const ValueKey('open')), warnIfMissed: false);
  await t.pumpAndSettle();
}

AppLocalizations _zh() => lookupAppLocalizations(const Locale('zh'));

/// The rows on screen, top to bottom.
List<String> _rows(WidgetTester t) {
  final found = <(double, String)>[];
  for (final e in find.byType(SettingsRowTitle).evaluate()) {
    final title = (e.widget as SettingsRowTitle).title;
    found.add((t.getTopLeft(find.byWidget(e.widget).first).dy, title));
  }
  for (final e in find.byType(SettingsSliderRow).evaluate()) {
    final row = e.widget as SettingsSliderRow;
    if (found.any((f) => f.$2 == row.title)) continue;
    found.add((t.getTopLeft(find.byWidget(row).first).dy, row.title));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final f in found) f.$2];
}

Future<void> _section(WidgetTester t, String title) async {
  final item = find.ancestor(
    of: find.text(title, skipOffstage: false),
    matching: find.byType(SettingsNavItem, skipOffstage: false),
  );
  await t.ensureVisible(item);
  await t.pumpAndSettle();
  await t.tap(item);
  await t.pumpAndSettle();
}

const _macRows = ['辅助功能', '屏幕与系统录音', '仅系统录音'];

Map<String, List<String>> _panelTable(_Os os) => {
  '通用': ['昵称', '外观', '语言', '文件保存到'],
  '连接': ['服务端口', '自动连接互信设备', '接收电视投屏'],
  '系统': [
    '开机自启动',
    '关闭时隐藏到托盘',
    '启用截图快捷键',
    '截图快捷键',
    if (os == _Os.windows) '锁屏与 UAC 时接收键鼠',
    if (os == _Os.gnome) '窗口流转组件',
  ],
  '共享与权限': [
    if (os == _Os.macos) ..._macRows,
    '允许查看和操作本机窗口',
    '允许访问剪贴板',
    '自动同步剪贴板',
    '播放别处声音的增益',
    '键鼠共享滚轮速度',
  ],
  '通知': ['忽略安卓通知', '验证码写入剪贴板'],
  '关于': ['版本', '关于 Whisper'],
};

void main() {
  setUpAll(loadGoldenFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('every row of the table, in both themes', () {
    for (final brightness in Brightness.values) {
      for (final os in [_Os.macos, _Os.windows, _Os.gnome, _Os.kde]) {
        testWidgets('${os.name} panel, ${brightness.name}', (t) async {
          await _open(t, _World(os), brightness: brightness);
          final table = _panelTable(os);
          expect([
            for (final e in find.byType(SettingsNavItem).evaluate())
              (e.widget as SettingsNavItem).title,
          ], table.keys.toList());
          for (final entry in table.entries) {
            await _section(t, entry.key);
            expect(_rows(t), entry.value, reason: entry.key);
          }
        });
      }

      testWidgets('android page, ${brightness.name}', (t) async {
        await _open(
          t,
          _World(_Os.android),
          brightness: brightness,
          window: const Size(390, 2400),
        );
        expect(find.text('二维码和地址'), findsOneWidget);
        expect(_rows(t), [
          '共享链接',
          '昵称',
          '外观',
          '语言',
          '文件保存到',
          '播放别处声音的增益',
          '服务端口',
          '自动连接互信设备',
          '后台保持连接',
          '后台灵动岛',
          '电池优化白名单',
          '窗口流转服务',
          '允许访问剪贴板',
          '自动同步剪贴板',
          '推送安卓通知',
          '通知应用',
          '忽略安卓通知',
          '验证码写入剪贴板',
          '版本',
          '关于 Whisper',
        ]);
        expect(find.text('通用'), findsOneWidget);
        expect(find.text('连接'), findsOneWidget);
        expect(find.text('剪贴板和通知'), findsOneWidget);
      });

      testWidgets('ios page, ${brightness.name}', (t) async {
        await _open(
          t,
          _World(_Os.ios),
          brightness: brightness,
          window: const Size(390, 2400),
        );
        expect(_rows(t), [
          '昵称',
          '外观',
          '语言',
          '文件保存到',
          '播放别处声音的增益',
          '服务端口',
          '自动连接互信设备',
          '允许访问剪贴板',
          '自动同步剪贴板',
          '忽略安卓通知',
          '验证码写入剪贴板',
          '版本',
          '关于 Whisper',
        ]);
      });
    }

    testWidgets('an android tablet in the panel has the android rows', (
      t,
    ) async {
      await _open(t, _World(_Os.android), window: const Size(900, 700));
      await _section(t, '连接');
      expect(_rows(t), [
        '服务端口',
        '自动连接互信设备',
        '后台保持连接',
        '后台灵动岛',
        '电池优化白名单',
        '窗口流转服务',
      ]);
      expect(find.widgetWithText(SettingsNavItem, '系统'), findsNothing);
      await _section(t, '通知');
      expect(_rows(t), ['忽略安卓通知', '验证码写入剪贴板', '推送安卓通知', '通知应用']);
    });

    testWidgets('通知应用 only while pushing notifications', (t) async {
      await _open(
        t,
        _World(_Os.android)..listenAndroid = false,
        window: const Size(390, 2400),
      );
      expect(find.text('通知应用'), findsNothing);
      await t.tap(find.text('推送安卓通知'));
      await t.pumpAndSettle();
      expect(find.text('通知应用'), findsOneWidget);
    });

    testWidgets('截图快捷键 only while enabled', (t) async {
      await _open(t, _World(_Os.macos));
      await _section(t, '系统');
      expect(find.text('截图快捷键'), findsOneWidget);
      await t.tap(find.text('启用截图快捷键'));
      await t.pumpAndSettle();
      expect(find.text('截图快捷键'), findsNothing);
    });

    testWidgets('a permission macOS does not report has no row', (t) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _macChannel,
        (call) async => <String, Object?>{
          'accessibility': false,
          'screenRecording': true,
        },
      );
      await t.runAsync(world.mac.refresh);
      await _section(t, '共享与权限');
      await t.pumpAndSettle();
      expect(find.text('仅系统录音'), findsNothing);
      expect(find.text('未允许'), findsOneWidget);
      expect(find.text('已允许'), findsOneWidget);
    });
  });

  group('sizes', () {
    testWidgets('the panel is 780 × 560 with a 224 list and 44 rows', (
      t,
    ) async {
      await _open(t, _World(_Os.macos));
      final body = find.byType(SettingsNavItem).first;
      expect(t.getSize(body).height, 38);
      final tile = t.getSize(find.byType(SettingsTile).first);
      expect(tile, const Size(22, 22));
      expect(
        t.getSize(find.byType(SettingsRowTitle).first).height,
        lessThan(44),
      );
      final row = t.getSize(find.byType(SettingsRowFrame).first);
      expect(row.height, 44);
      final panel = find.byType(ClipPath).first;
      expect(t.getSize(panel), const Size(780, 560));
      expect(t.getSize(find.byType(LiquidSegmented<ThemeMode>)).height, 26);
    });

    testWidgets('at the smallest window it fits, with margins', (t) async {
      for (final brightness in Brightness.values) {
        await _open(
          t,
          _World(_Os.windows),
          brightness: brightness,
          window: const Size(720, 480),
        );
        // Above and below stay free for the window's buttons and the island.
        expect(
          t.getSize(find.byType(ClipPath).first),
          Size(688, 480 - WhisperWindow.sheetGap),
        );
        for (final section in _panelTable(_Os.windows).keys) {
          await _section(t, section);
          expect(t.takeException(), isNull);
        }
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('phone rows are at least 48, and every target too', (t) async {
      await _open(t, _World(_Os.android), window: const Size(390, 2400));
      for (final e in find.byType(SettingsRowFrame).evaluate()) {
        expect(
          t.getSize(find.byWidget(e.widget).first).height,
          greaterThanOrEqualTo(48),
        );
      }
      expect(t.getSize(find.byType(LiquidSegmented<ThemeMode>)).height, 34);
      expect(t.getSize(find.byType(Slider)).height, 48);
    });
  });

  group('text at 200%', () {
    for (final locale in AppLocalizations.supportedLocales) {
      testWidgets('720 × 480 panel, ${locale.languageCode}', (t) async {
        await _open(
          t,
          _World(_Os.windows),
          window: const Size(720, 480),
          textScale: 2,
          locale: locale,
        );
        final l10n = lookupAppLocalizations(locale);
        for (final section in [
          l10n.shellSettingsGeneral,
          l10n.shellSettingsConnection,
          l10n.shellSettingsSystem,
          l10n.shellSettingsSharing,
          l10n.shellSettingsNotifications,
          l10n.shellSettingsAbout,
        ]) {
          await _section(t, section);
          expect(t.takeException(), isNull, reason: section);
        }
      });

      testWidgets('phone page, ${locale.languageCode}', (t) async {
        await _open(
          t,
          _World(_Os.android),
          window: const Size(360, 3600),
          textScale: 2,
          locale: locale,
        );
        expect(t.takeException(), isNull);
      });
    }
  });

  group('inline editing', () {
    Finder field(String title) => find.descendant(
      of: find.widgetWithText(SettingsFieldRow, title),
      matching: find.byType(TextField),
    );

    String text(WidgetTester t, String title) =>
        t.widget<TextField>(field(title)).controller!.text;

    testWidgets('a nickname commits on Enter', (t) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      await t.tap(field('昵称'));
      await t.enterText(field('昵称'), '  书房  ');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(world.saved['nickname'], '书房');
    });

    testWidgets('losing focus commits', (t) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      await t.tap(field('昵称'));
      await t.enterText(field('昵称'), '书房');
      FocusManager.instance.primaryFocus!.unfocus();
      await t.pumpAndSettle();
      expect(world.saved['nickname'], '书房');
    });

    testWidgets('Esc restores and leaves the panel open', (t) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      final before = text(t, '昵称');
      await t.tap(field('昵称'));
      await t.enterText(field('昵称'), '不要了');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(text(t, '昵称'), before);
      expect(world.saved.containsKey('nickname'), isFalse);
      expect(find.byType(SettingsNavItem), findsWidgets);
    });

    testWidgets('an empty nickname is restored and says why', (t) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      final before = text(t, '昵称');
      await t.tap(field('昵称'));
      await t.enterText(field('昵称'), '   ');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(text(t, '昵称'), before);
      expect(world.saved.containsKey('nickname'), isFalse);
      expect(world.said, [_zh().validationNicknameRequired]);
    });

    testWidgets('a port saves through the same path as the dialog', (t) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      await _section(t, '连接');
      await t.tap(field('服务端口'));
      await t.enterText(field('服务端口'), '10123');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(world.saved['port'], 10123);
    });

    for (final bad in ['0', '65536', '']) {
      testWidgets('port "$bad" is restored and says why', (t) async {
        final world = _World(_Os.macos);
        await _open(t, world);
        await _section(t, '连接');
        await t.tap(field('服务端口'));
        await t.enterText(field('服务端口'), bad);
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pumpAndSettle();
        expect(text(t, '服务端口'), '10002');
        expect(world.saved.containsKey('port'), isFalse);
        expect(world.said, [_zh().manualConnectPortInvalid]);
      });
    }

    testWidgets('the port field takes digits only', (t) async {
      await _open(t, _World(_Os.macos));
      await _section(t, '连接');
      await t.tap(field('服务端口'));
      await t.enterText(field('服务端口'), '1a2b3');
      expect(text(t, '服务端口'), '123');
    });
  });

  group('controls', () {
    testWidgets('Esc closes the panel, and so do the X and the scrim', (
      t,
    ) async {
      await _open(t, _World(_Os.macos));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(SettingsNavItem), findsNothing);

      await t.tap(find.byKey(const ValueKey('open')), warnIfMissed: false);
      await t.pumpAndSettle();
      await t.tap(find.byType(SettingsCloseButton));
      await t.pumpAndSettle();
      expect(find.byType(SettingsNavItem), findsNothing);

      await t.tap(find.byKey(const ValueKey('open')), warnIfMissed: false);
      await t.pumpAndSettle();
      await t.tapAt(const Offset(4, 300));
      await t.pumpAndSettle();
      expect(find.byType(SettingsNavItem), findsNothing);
    });

    testWidgets('it opens once, however many times it is asked', (t) async {
      await _open(t, _World(_Os.macos));
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('the language menu has the four choices, follow system first', (
      t,
    ) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      expect(
        find.widgetWithText(SettingsPopupButton<String?>, '跟随系统'),
        findsOneWidget,
      );
      await t.tap(find.byType(SettingsPopupButton<String?>));
      await t.pumpAndSettle();
      expect(find.text('跟随系统'), findsNWidgets(2));
      expect(find.text('简体中文'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Español'), findsOneWidget);

      await t.tap(find.text('English'));
      await t.pumpAndSettle();
      expect(await t.runAsync(LocalSetting().pickedLocalization), 'en');

      await t.tap(find.byType(SettingsPopupButton<String?>));
      await t.pumpAndSettle();
      await t.tap(find.text('跟随系统').last);
      await t.pumpAndSettle();
      expect(await t.runAsync(LocalSetting().pickedLocalization), isNull);
      // Nothing that reads the language gets told something odd.
      expect(
        AppLocalizations.supportedLocales.map((l) => l.languageCode),
        contains(await t.runAsync(LocalSetting().localization)),
      );
    });

    testWidgets('a stored code the app does not have reads as following', (
      t,
    ) async {
      SharedPreferences.setMockInitialValues({'_localization': 'fr'});
      expect(await LocalSetting().pickedLocalization(), isNull);
    });

    testWidgets('appearance: the bands above and below a segment count', (
      t,
    ) async {
      await _open(t, _World(_Os.android), window: const Size(390, 2400));
      final segmented = find.byType(LiquidSegmented<ThemeMode>);
      final dark = t.getCenter(find.text('深色'));
      await t.tapAt(Offset(dark.dx, t.getRect(segmented).bottom + 5));
      await t.pumpAndSettle();
      expect(
        t.widget<LiquidSegmented<ThemeMode>>(segmented).selected,
        ThemeMode.dark,
      );
    });

    testWidgets('the page slider answers 8 above and below what it shows', (
      t,
    ) async {
      final world = _World(_Os.android);
      await _open(t, world, window: const Size(390, 2400));
      final slider = find.byType(Slider);
      final row = t.getRect(find.byType(SettingsSliderRow));
      expect(row.height, lessThan(100));
      final rect = t.getRect(slider);
      await t.tapAt(Offset(rect.center.dx, rect.top + 2));
      await t.pumpAndSettle();
      expect(t.widget<Slider>(slider).value, greaterThan(1.5));
    });

    testWidgets('a slider moves as it is dragged and saves when let go', (
      t,
    ) async {
      await _open(t, _World(_Os.macos));
      await _section(t, '共享与权限');
      final slider = find.byType(Slider).first;
      await t.drag(slider, const Offset(100, 0));
      await t.pumpAndSettle();
      expect(t.widget<Slider>(slider).value, greaterThan(1));
      final prefs = await t.runAsync(SharedPreferences.getInstance);
      expect(
        prefs!.getKeys().any((key) => key.toLowerCase().contains('gain')),
        isTrue,
      );
    });

    testWidgets('recording a shortcut: Esc gives up, a combination is set', (
      t,
    ) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      await _section(t, '系统');
      final button = find.byType(SettingsShortcutButton);
      expect(
        find.descendant(of: button, matching: find.text('⌥⌘S')),
        findsOneWidget,
      );

      await t.tap(button);
      await t.pump();
      expect(find.text('按下快捷键…'), findsOneWidget);
      expect(world.screenshot.shortcutsPaused, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('按下快捷键…'), findsNothing);
      expect(world.screenshot.shortcutsPaused, isFalse);
      // Esc went to the recorder, not to the panel.
      expect(find.byType(SettingsNavItem), findsWidgets);

      await t.tap(button);
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyK);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      expect(world.backend.last?.key, 'K');
      expect(world.backend.last?.control, isTrue);
    });

    testWidgets('a shortcut the system refuses says so', (t) async {
      final world = _World(_Os.windows);
      await _open(t, world);
      await _section(t, '系统');
      world.backend.refuse = true;
      await t.tap(find.byType(SettingsShortcutButton));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyK);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      expect(world.said, [_zh().screenshotShortcutFailed]);
    });

    testWidgets('the Windows service row names the state and its one action', (
      t,
    ) async {
      final world = _World(_Os.windows);
      await _open(t, world);
      await t.runAsync(world.windows.refresh);
      await _section(t, '系统');
      expect(find.text('未安装'), findsOneWidget);
      expect(find.widgetWithText(SettingsButton, '安装'), findsOneWidget);
      expect(find.text(_zh().windowsLockScreenInputHint), findsOneWidget);

      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _winChannel,
        (call) async => switch (call.method) {
          'getElevatedInputAllowed' => false,
          'getInputServiceState' => 'running',
          _ => null,
        },
      );
      await t.runAsync(world.windows.refresh);
      await t.pumpAndSettle();
      expect(find.text('运行中'), findsOneWidget);
      expect(find.widgetWithText(SettingsButton, '卸载'), findsOneWidget);
      // Whether it reaches UAC prompts: a setting the old page has too.
      expect(
        find.descendant(
          of: find.byType(SettingsServiceRow),
          matching: find.byType(WhisperSwitch),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the GNOME row names the state and its one action', (t) async {
      await _open(t, _World(_Os.gnome));
      await _section(t, '系统');
      expect(find.text('未安装'), findsOneWidget);
      expect(find.widgetWithText(SettingsButton, '安装'), findsOneWidget);
    });

    testWidgets('a whole switch row flips', (t) async {
      await _open(t, _World(_Os.macos));
      await _section(t, '通知');
      final row = find.widgetWithText(SettingsSwitchRow, '忽略安卓通知');
      expect(t.widget<SettingsSwitchRow>(row).value, isFalse);
      await t.tap(find.text('忽略安卓通知'));
      await t.pumpAndSettle();
      expect(t.widget<SettingsSwitchRow>(row).value, isTrue);
    });

    testWidgets('the file row: 更改… picks, the path opens', (t) async {
      final world = _World(_Os.macos);
      await _open(t, world);
      await t.tap(find.byType(SettingsPathText));
      await t.pumpAndSettle();
      expect(world.saved['opened'], '$_home/Downloads/Whisper');
      await t.tap(find.text('更改…'));
      await t.pumpAndSettle();
      expect(find.textContaining('/tmp/picked'), findsOneWidget);
    });

    testWidgets('the phone file row is one target', (t) async {
      final world = _World(_Os.android);
      await _open(t, world, window: const Size(390, 2400));
      expect(find.text('下载 / Whisper'), findsOneWidget);
      await t.tap(find.text('文件保存到'));
      await t.pumpAndSettle();
      expect(find.text('tmp / picked'), findsOneWidget);
    });

    testWidgets('the top of the phone page goes where it says', (t) async {
      final world = _World(_Os.android);
      await _open(t, world, window: const Size(390, 2400));
      await t.tap(find.text('二维码和地址'));
      await t.pump();
      expect(world.saved['pairing'], isTrue);
      await t.tap(find.text('共享链接'));
      await t.pump();
      expect(world.saved['links'], isTrue);
      expect(find.text('2 个开启中'), findsOneWidget);
    });
  });

  group('the version row', () {
    testWidgets('before an answer it only says the version', (t) async {
      await _open(t, _World(_Os.macos));
      await _section(t, '关于');
      expect(find.text('0.0.58'), findsOneWidget);
    });

    testWidgets('tapping asks; then up to date, or a new one in accent', (
      t,
    ) async {
      final updates = _Updates(_upToDate)..gate = Completer<void>();
      final world = _World(_Os.macos)..updates = updates;
      await _open(t, world);
      await _section(t, '关于');
      await t.tap(find.text('版本'));
      await t.pump();
      expect(find.text('正在检查…'), findsOneWidget);
      // Nothing to press while it is asking.
      await t.tap(find.text('版本'));
      await t.pump();
      expect(updates.checks, 1);
      updates.gate!.complete();
      await t.pumpAndSettle();
      expect(find.text('0.0.58 · 已是最新'), findsOneWidget);

      updates
        ..gate = null
        ..result = _available;
      await t.tap(find.text('版本'));
      await t.pumpAndSettle();
      final text = t.widget<Text>(find.text('有新版本 0.0.59'));
      expect(text.style!.color, WhisperColors.light.accent);
    });

    testWidgets('the about panel has what the spec lists', (t) async {
      await _open(t, _World(_Os.macos));
      await _section(t, '关于');
      await t.tap(find.text('关于 Whisper'));
      await t.pumpAndSettle();
      expect(find.text('Whisper'), findsOneWidget);
      expect(find.text(_zh().aboutWhisperDescription), findsOneWidget);
      expect(find.text('版本 0.0.58'), findsOneWidget);
      expect(find.text(_zh().officialWebsite), findsOneWidget);
      expect(find.text(_zh().sourceCode), findsOneWidget);
    });
  });

  test('the new files have no raw values', () {
    final raw = RegExp(
      r'\bColor\(\s*0x[0-9a-fA-F]+\s*\)|\bfontSize:\s*[\d.]+|'
      r'\bDuration\(\s*milliseconds:|\bBorderRadius\.circular\(\s*[\d.]+\s*\)|'
      r'\bCurves\.',
    );
    for (final path in [
      'lib/new_ui/settings/settings_controls.dart',
      'lib/new_ui/settings/settings_layout.dart',
      'lib/new_ui/settings/whisper_settings.dart',
    ]) {
      final code = File(path).readAsStringSync().replaceAll(
        RegExp(r'(^|\s)//.*$', multiLine: true),
        '',
      );
      expect(
        raw.allMatches(code).map((m) => m.group(0)),
        isEmpty,
        reason: path,
      );
    }
  });

  group('shots', () {
    final dir = Platform.environment['WHISPER_SETTINGS_SHOTS'];
    if (dir == null) return;

    // flutter_test turns shadow blur off, for stable goldens. Here it is the
    // point.
    void shadowed(String name, Future<void> Function(WidgetTester t) body) =>
        testWidgets(name, (t) async {
          debugDisableShadows = false;
          try {
            await body(t);
          } finally {
            debugDisableShadows = true;
          }
        });

    Future<ui.Image> capture(WidgetTester t, double pixelRatio) async {
      final box =
          _boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      return (await t.runAsync(() => box.toImage(pixelRatio: pixelRatio)))!;
    }

    Future<void> save(WidgetTester t, String name, ui.Image image) async {
      await t.runAsync(() async {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    Future<void> shot(
      WidgetTester t,
      String name, {
      double pixelRatio = 1,
    }) async {
      await save(t, name, await capture(t, pixelRatio));
    }

    /// The reference on the left, this on the right, both cropped to the panel.
    Future<void> compare(
      WidgetTester t,
      String name,
      String reference,
      Rect referenceRect,
      Rect mineRect,
    ) async {
      final mine = await capture(t, 1);
      final image = (await t.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          File('docs/design/reference/$reference').readAsBytesSync(),
        );
        final ref = (await codec.getNextFrame()).image;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final w = referenceRect.width;
        final h = referenceRect.height;
        canvas.drawRect(
          Rect.fromLTWH(0, 0, 2 * w + 16, h),
          Paint()..color = const Color(0xFF808080),
        );
        canvas.drawImageRect(
          ref,
          referenceRect,
          Rect.fromLTWH(0, 0, w, h),
          Paint(),
        );
        canvas.drawImageRect(
          mine,
          mineRect,
          Rect.fromLTWH(w + 16, 0, w, h),
          Paint(),
        );
        return recorder.endRecording().toImage((2 * w + 16).toInt(), h.toInt());
      }))!;
      await save(t, name, image);
    }

    Widget behind() => Builder(
      builder: (context) {
        // Roughly what is behind the panel in the references, so the scrim and
        // the shadow have something to read against.
        final c = context.wc;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 252, child: ColoredBox(color: c.sidebarSolid)),
            Expanded(child: ColoredBox(color: c.content)),
          ],
        );
      },
    );

    // Where the panel is in a 1128 × 690 window, and in the references.
    const mine = Rect.fromLTWH(174, 65, 780, 560);
    const ref = Rect.fromLTWH(200, 107, 780, 560);
    const refWin = Rect.fromLTWH(200, 83, 780, 560);
    const refGnome = Rect.fromLTWH(200, 109, 780, 560);

    for (final brightness in Brightness.values) {
      final b = brightness.name;
      shadowed('shots mac panel $b', (t) async {
        await _open(
          t,
          _World(_Os.macos),
          brightness: brightness,
          behind: behind(),
        );
        await compare(
          t,
          'compare-general-$b',
          'desktop-settings.jpg',
          ref,
          mine,
        );
        await shot(t, 'panel-general-$b', pixelRatio: 2);
        await t.tap(find.byType(SettingsPopupButton<String?>));
        await t.pumpAndSettle();
        await compare(
          t,
          'compare-language-$b',
          'desktop-settings-language.jpg',
          const Rect.fromLTWH(200, 107, 820, 560),
          const Rect.fromLTWH(174, 65, 820, 560),
        );
        await t.tapAt(const Offset(4, 300));
        await t.pumpAndSettle();
        await _section(t, '连接');
        await shot(t, 'panel-connection-$b', pixelRatio: 2);
        await _section(t, '共享与权限');
        await t.pumpAndSettle();
        await compare(
          t,
          'compare-sharing-$b',
          'desktop-settings-sharing.jpg',
          ref,
          mine,
        );
        await shot(t, 'panel-sharing-$b', pixelRatio: 2);
        await _section(t, '通知');
        await shot(t, 'panel-notifications-$b', pixelRatio: 2);
        await _section(t, '关于');
        await shot(t, 'panel-about-$b', pixelRatio: 2);
        await t.runAsync(
          () => precacheImage(
            const AssetImage('assets/app_icon_round.png'),
            t.element(find.byType(SettingsNavItem).first),
          ),
        );
        await t.tap(find.text('关于 Whisper'));
        await t.pumpAndSettle();
        await shot(t, 'panel-about-sheet-$b', pixelRatio: 2);
      });

      shadowed('shots windows and linux system $b', (t) async {
        await _open(
          t,
          _World(_Os.windows, name: 'xiaoxin 的 Surface Laptop 7'),
          brightness: brightness,
          behind: behind(),
        );
        await t.runAsync(_mockedWindowsRefresh(t));
        await _section(t, '系统');
        await compare(
          t,
          'compare-windows-$b',
          'windows-settings.jpg',
          refWin,
          mine,
        );
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();

        await _open(
          t,
          _World(_Os.gnome),
          brightness: brightness,
          behind: behind(),
        );
        await _section(t, '系统');
        await compare(
          t,
          'compare-gnome-$b',
          'gnome-settings.jpg',
          refGnome,
          mine,
        );
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();

        await _open(
          t,
          _World(_Os.kde),
          brightness: brightness,
          behind: behind(),
        );
        await _section(t, '系统');
        await compare(t, 'compare-kde-$b', 'kde-settings.jpg', refWin, mine);
      });

      shadowed('shots small and large $b', (t) async {
        await _open(
          t,
          _World(_Os.windows),
          brightness: brightness,
          window: const Size(720, 480),
          behind: behind(),
        );
        await _section(t, '共享与权限');
        await shot(t, 'min-window-$b', pixelRatio: 2);
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();

        await _open(
          t,
          _World(_Os.gnome),
          brightness: brightness,
          window: const Size(720, 480),
          textScale: 2,
          behind: behind(),
        );
        await _section(t, '系统');
        await shot(t, 'min-window-200-$b', pixelRatio: 2);
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();

        await _open(
          t,
          _World(_Os.android),
          brightness: brightness,
          window: const Size(390, 1500),
          textScale: 2,
        );
        await shot(t, 'phone-200-$b', pixelRatio: 2);
      });

      shadowed('shots states $b', (t) async {
        final world = _World(_Os.windows);
        await _open(t, world, brightness: brightness, behind: behind());
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _winChannel,
          (call) async => switch (call.method) {
            'getElevatedInputAllowed' => true,
            'getInputServiceState' => 'running',
            _ => null,
          },
        );
        await t.runAsync(world.windows.refresh);
        await _section(t, '系统');
        await t.pumpAndSettle();
        await t.tap(find.byType(SettingsShortcutButton));
        await t.pumpAndSettle();
        await shot(t, 'state-running-recording-$b', pixelRatio: 2);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        await _section(t, '通用');
        await t.tap(find.widgetWithText(SettingsFieldRow, '昵称'));
        await t.pumpAndSettle();
        await shot(t, 'state-field-focus-$b', pixelRatio: 2);
        FocusManager.instance.primaryFocus!.unfocus();
        await t.pumpAndSettle();
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();

        final updates = _Updates(_available);
        await _open(
          t,
          _World(_Os.macos)
            ..updates = updates
            ..autoCheck = true,
          brightness: brightness,
          behind: behind(),
        );
        await t.pumpAndSettle();
        await _section(t, '关于');
        await shot(t, 'state-update-available-$b', pixelRatio: 2);
      });

      shadowed('shots phone $b', (t) async {
        final world = _World(_Os.android, name: '这台手机')
          ..updates = _Updates(_upToDate)
          ..autoCheck = true
          ..languageCode = 'en'
          ..themeMode = ThemeMode.light;
        await _open(
          t,
          world,
          brightness: brightness,
          window: const Size(380, 780),
          statusBar: 44,
        );
        await t.pumpAndSettle();
        await compare(
          t,
          'compare-phone-$b',
          'phone-settings.jpg',
          const Rect.fromLTWH(400, 26, 380, 780),
          const Rect.fromLTWH(0, 0, 380, 780),
        );
        await shot(t, 'phone-top-$b', pixelRatio: 2);
        await t.drag(find.byType(ListView), const Offset(0, -2000));
        await t.pumpAndSettle();
        await compare(
          t,
          'compare-phone-bottom-$b',
          'phone-settings-bottom.jpg',
          const Rect.fromLTWH(400, 26, 380, 780),
          const Rect.fromLTWH(0, 0, 380, 780),
        );
        await shot(t, 'phone-bottom-$b', pixelRatio: 2);
      });
    }
  });
}

Future<void> Function() _mockedWindowsRefresh(WidgetTester t) => () async {};
