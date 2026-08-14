import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsAction, SemanticsFlag;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/app_update.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/theme/app_theme.dart';

const _device = DeviceData(
  id: 0,
  uid: 'local-device',
  name: 'Studio Mac',
  host: '192.168.1.5',
  port: 10002,
  platform: 'macos',
  isServer: true,
  online: true,
  clipboard: true,
  auth: false,
  lastTime: 0,
);

const _presentation = SettingsPresentation(
  device: _device,
  saveDirectoryPath:
      '/Users/tester/Documents/Whisper received files/Project archive',
  version: '2.4.0',
  closeToTray: true,
  copyVerificationCode: true,
  listenAndroidNotifications: true,
  ignoreAndroidNotifications: false,
  autoConnect: true,
  launchAtStartup: false,
  androidBackgroundKeepAlive: true,
  audioSharePlaybackGain: 1.0,
  remoteInputScrollMultiplier: 1.0,
  themeMode: ThemeMode.system,
);

const _androidPresentation = SettingsPresentation(
  device: _device,
  saveDirectoryPath: '/storage/emulated/0/Download',
  version: '2.4.0',
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

Finder _settingRow(String title) => find
    .ancestor(
      of: find.text(title),
      matching: find.byType(Semantics),
    )
    .first;

Widget _host({
  Locale locale = const Locale('en'),
  double textScale = 1,
  SettingsPresentation presentation = _presentation,
  SettingsPresentationLoader? loader,
  Future<void> Function(bool enabled)? updateNotificationForwarding,
  Future<void> Function(bool enabled)? writeNotificationForwarding,
  Future<bool> Function()? readNotificationForwarding,
  Future<void> Function(bool enabled)? syncNotificationForwardingListener,
  Future<void> Function()? refreshNotificationRegistry,
  Future<void> Function()? openNotificationApps,
  AppUpdateManager? updateManager,
  Future<void> Function()? exitForUpdate,
  bool autoCheckForUpdates = true,
}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    locale: locale,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: SettingsScreen(
      presentationLoader: loader ?? () async => presentation,
      changeDirectory: () async => '/tmp/Whisper',
      openDirectory: (_) async {},
      updateNickname: (_) async {},
      updateServerPort: (_) async {},
      updateNotificationForwarding: updateNotificationForwarding,
      writeNotificationForwarding: writeNotificationForwarding,
      readNotificationForwarding: readNotificationForwarding,
      syncNotificationForwardingListener: syncNotificationForwardingListener,
      refreshNotificationRegistry: refreshNotificationRegistry,
      openNotificationApps: openNotificationApps,
      updateManager: updateManager,
      exitForUpdate: exitForUpdate,
      autoCheckForUpdates: autoCheckForUpdates,
    ),
  );
}

class _FakeUpdateManager implements AppUpdateManager {
  _FakeUpdateManager({
    this.installDisposition = AppUpdateInstallDisposition.keepRunning,
    this.downloadGate,
  });

  static final _release = AppUpdateRelease(
    version: '2.5.0',
    tagName: 'dev-v2.5.0',
    channel: AppUpdateChannel.preview,
    releaseUrl:
        Uri.parse('https://github.com/lawnvi/whisper/releases/tag/dev-v2.5.0'),
    notes: 'Faster and more reliable updates.',
    publishedAt: DateTime.utc(2026, 8, 15),
    asset: AppUpdateAsset(
      name: 'whisper-2.5.0-macos-arm64.dmg',
      downloadUrl: Uri.parse(
        'https://github.com/lawnvi/whisper/releases/download/dev-v2.5.0/whisper-2.5.0-macos-arm64.dmg',
      ),
      size: 1024,
    ),
  );

  int checkCount = 0;
  int downloadCount = 0;
  int openInstallerCount = 0;
  final AppUpdateInstallDisposition installDisposition;
  final Completer<void>? downloadGate;

  @override
  Future<AppUpdateCheckResult> checkForUpdate({
    required String currentVersion,
    bool force = false,
  }) async {
    checkCount += 1;
    return AppUpdateCheckResult(
      status: AppUpdateStatus.updateAvailable,
      currentVersion: currentVersion,
      release: _release,
    );
  }

  @override
  Future<AppUpdateDownload> downloadUpdate(
    AppUpdateRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    downloadCount += 1;
    onProgress?.call(0.5);
    await downloadGate?.future;
    onProgress?.call(1);
    return AppUpdateDownload(
      release: release,
      file: File('/tmp/whisper-test-update.dmg'),
    );
  }

  @override
  Future<AppUpdateInstallDisposition> openInstaller(
    AppUpdateDownload download,
  ) async {
    openInstallerCount += 1;
    return installDisposition;
  }
}

Future<void> _pumpAt(
  WidgetTester tester, {
  required double width,
  double height = 900,
  double textScale = 1,
  Locale locale = const Locale('en'),
  SettingsPresentation presentation = _presentation,
  SettingsPresentationLoader? loader,
  Future<void> Function(bool enabled)? updateNotificationForwarding,
  Future<void> Function(bool enabled)? writeNotificationForwarding,
  Future<bool> Function()? readNotificationForwarding,
  Future<void> Function(bool enabled)? syncNotificationForwardingListener,
  Future<void> Function()? refreshNotificationRegistry,
  Future<void> Function()? openNotificationApps,
  AppUpdateManager? updateManager,
  Future<void> Function()? exitForUpdate,
  bool autoCheckForUpdates = true,
}) async {
  tester.view
    ..physicalSize = Size(width, height)
    ..devicePixelRatio = 1;
  await tester.pumpWidget(_host(
    locale: locale,
    textScale: textScale,
    presentation: presentation,
    loader: loader,
    updateNotificationForwarding: updateNotificationForwarding,
    writeNotificationForwarding: writeNotificationForwarding,
    readNotificationForwarding: readNotificationForwarding,
    syncNotificationForwardingListener: syncNotificationForwardingListener,
    refreshNotificationRegistry: refreshNotificationRegistry,
    openNotificationApps: openNotificationApps,
    updateManager: updateManager,
    exitForUpdate: exitForUpdate,
    autoCheckForUpdates: autoCheckForUpdates,
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  testWidgets('uses the original rows in a centered 760 px settings column',
      (tester) async {
    await _pumpAt(tester, width: 1440);

    final list = find.byType(ListView).first;
    expect(tester.getSize(list).width, WhisperUi.settingsMaxWidth);
    expect(
      tester
          .widget<ConstrainedBox>(find
              .ancestor(
                of: list,
                matching: find.byType(ConstrainedBox),
              )
              .first)
          .constraints
          .maxWidth,
      WhisperUi.settingsMaxWidth,
    );
    expect(find.text('Device and appearance'), findsOneWidget);
    expect(
      find.text('Name, theme, and how this device appears nearby'),
      findsNothing,
    );
    for (final title in <String>['Theme Mode', 'Nickname', 'Server Port']) {
      expect(
          tester.getSize(_settingRow(title)).height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('section surfaces retain the original 14 radius card treatment',
      (tester) async {
    await _pumpAt(tester, width: 760);

    final surface = find.byType(SettingsSectionSurface).first;
    final card = tester.widget<Card>(
      find.descendant(of: surface, matching: find.byType(Card)).first,
    );
    final shape = card.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(14));
    expect(shape.side.style, BorderStyle.solid);
    expect(card.elevation, 0);

    final dividers = tester.widgetList<Divider>(
      find.descendant(of: surface, matching: find.byType(Divider)),
    );
    expect(dividers, isEmpty);
  });

  testWidgets('settings checks for updates and opens the verified installer',
      (tester) async {
    final manager = _FakeUpdateManager();
    await _pumpAt(
      tester,
      width: 720,
      height: 1500,
      updateManager: manager,
    );

    expect(manager.checkCount, 1);
    expect(find.text('Check for updates'), findsOneWidget);
    final versionLabel = find.text('Update available: 2.5.0');
    final updateBadge = find.byKey(
      const ValueKey<String>('update-available-badge'),
    );
    expect(versionLabel, findsOneWidget);
    expect(updateBadge, findsOneWidget);
    expect(
      tester.getTopLeft(updateBadge).dx - tester.getTopRight(versionLabel).dx,
      greaterThanOrEqualTo(4),
    );
    expect(find.byIcon(Icons.download_rounded), findsNothing);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(find.text('Version 2.5.0 is available'), findsWidgets);
    expect(find.textContaining('You have 2.4.0'), findsOneWidget);

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(manager.downloadCount, 1);
    expect(manager.openInstallerCount, 1);
  });

  testWidgets('update download uses a compact determinate progress ring',
      (tester) async {
    final gate = Completer<void>();
    final manager = _FakeUpdateManager(downloadGate: gate);
    await _pumpAt(
      tester,
      width: 720,
      height: 1500,
      updateManager: manager,
    );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final indicator = tester.widget<CircularProgressIndicator>(
      find.byKey(const ValueKey<String>('update-progress-indicator')),
    );
    expect(indicator.value, closeTo(0.5, 0.01));
    expect(indicator.strokeCap, StrokeCap.round);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('desktop update exits through the application shutdown callback',
      (tester) async {
    final manager = _FakeUpdateManager(
      installDisposition: AppUpdateInstallDisposition.exitApplication,
    );
    var exitCount = 0;
    await _pumpAt(
      tester,
      width: 720,
      height: 1500,
      updateManager: manager,
      exitForUpdate: () async {
        exitCount += 1;
      },
    );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(manager.openInstallerCount, 1);
    expect(exitCount, 1);
  });

  testWidgets('about row contains website and source links', (tester) async {
    await _pumpAt(tester, width: 720, height: 1500, autoCheckForUpdates: false);

    await tester.tap(find.text('About Whisper'));
    await tester.pumpAndSettle();

    expect(find.byType(AboutDialog), findsOneWidget);
    expect(find.text('Current version 2.4.0'), findsWidgets);
    expect(find.text('Official website'), findsOneWidget);
    expect(find.text('GitHub source code'), findsOneWidget);
  });

  testWidgets('mobile about dialog uses the compact responsive layout',
      (tester) async {
    await _pumpAt(
      tester,
      width: 390,
      height: 844,
      autoCheckForUpdates: false,
    );

    await tester.scrollUntilVisible(
      find.text('About Whisper'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('About Whisper'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('compact-about-dialog')),
      findsOneWidget,
    );
    expect(find.byType(AboutDialog), findsNothing);
    expect(find.text('Official website'), findsOneWidget);
    expect(find.text('GitHub source code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings remain usable at supported widths and 200 percent text',
      (tester) async {
    for (final width in <double>[390, 760, 1440]) {
      await _pumpAt(tester, width: width, textScale: 2);
      final exception = tester.takeException();
      expect(exception, isNull, reason: 'width $width');
      expect(
        tester.getSize(find.byType(ListView).first).width,
        lessThanOrEqualTo(WhisperUi.settingsMaxWidth),
      );
    }
  });

  testWidgets('section titles follow all supported locales without subtitles',
      (tester) async {
    const expectations = <(Locale, String, String)>[
      (Locale('zh'), '设备与外观', '名称、主题和本机在附近设备上的显示方式'),
      (
        Locale('en'),
        'Device and appearance',
        'Name, theme, and how this device appears nearby',
      ),
      (
        Locale('es'),
        'Dispositivo y apariencia',
        'Nombre, tema y visibilidad de este dispositivo en la red cercana',
      ),
    ];

    for (final entry in expectations) {
      await _pumpAt(tester, width: 760, locale: entry.$1);
      expect(find.text(entry.$2), findsOneWidget);
      expect(find.text(entry.$3), findsNothing);
    }
  });

  testWidgets('save directory retains tap and long press actions',
      (tester) async {
    await _pumpAt(tester, width: 760);
    await tester.scrollUntilVisible(
      find.text('Language and files'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.text(_presentation.saveDirectoryPath), findsOneWidget);
    expect(_settingRow('Save directory'), findsOneWidget);
  });

  testWidgets('switch row owns one merged toggled semantic action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpAt(tester, width: 760);

    final tile = _settingRow('Auto-connect mutually trusted devices');
    final node = tester.getSemantics(tile);
    expect(node.label, 'Auto-connect mutually trusted devices');
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isToggled), isTrue);
    expect(
      find.ancestor(
        of: find.descendant(of: tile, matching: find.byType(CupertinoSwitch)),
        matching: find.byType(ExcludeFocus),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    semantics.dispose();
  });

  testWidgets(
      'setting semantics include current values and preserve icon style',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpAt(tester, width: 760);

    for (final expectation in <(String, String)>[
      ('Theme Mode', 'Follow System'),
      ('Nickname', 'Studio Mac'),
      ('Server Port', 'Server Port 10002'),
    ]) {
      final tile = _settingRow(expectation.$1);
      expect(tester.getSemantics(tile).label, contains(expectation.$2));
    }
    final themeTile = _settingRow('Theme Mode');
    final leadingIcon = tester.widget<Icon>(
      find.descendant(of: themeTile, matching: find.byIcon(Icons.dark_mode)),
    );
    expect(
      leadingIcon.color,
      AppTheme.lightTheme.extension<WhisperPalette>()!.textMuted,
    );
    expect(leadingIcon.size, isNull);
    expect(tester.getSize(find.byIcon(Icons.dark_mode)), const Size(24, 24));

    await tester.scrollUntilVisible(
      find.text('Language and files'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(
      tester
          .getSemantics(
            _settingRow('Select Language'),
          )
          .label,
      contains('English'),
    );
    expect(
      tester.getSemantics(_settingRow('Check for updates')).label,
      contains('2.4.0'),
    );
    semantics.dispose();
  });

  testWidgets('Android forwarding and app navigation are separate actions',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final updates = <bool>[];
    var opens = 0;
    await _pumpAt(
      tester,
      width: 760,
      presentation: _androidPresentation,
      updateNotificationForwarding: (enabled) async => updates.add(enabled),
      openNotificationApps: () async => opens += 1,
    );
    await tester.scrollUntilVisible(
      find.text('Mobile integration'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final forwarding = _settingRow('Forward Android Notifications');
    var node = tester.getSemantics(forwarding);
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isToggled), isTrue);
    await tester.tap(forwarding);
    await tester.pump();
    expect(updates, <bool>[false]);
    expect(opens, 0);
    node = tester.getSemantics(forwarding);
    expect(node.hasFlag(SemanticsFlag.isToggled), isFalse);

    await tester.tap(forwarding);
    await tester.pump();
    expect(updates, <bool>[false, true]);
    expect(opens, 0);

    final apps = _settingRow('Notification apps');
    expect(
        tester.getSemantics(apps).label, contains('2 applications selected'));
    await tester.tap(apps);
    await tester.pump();
    expect(opens, 1);
    semantics.dispose();
  });

  testWidgets('notification forwarding serializes rapid keyboard activation',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final pending = Completer<void>();
    final updates = <bool>[];
    await _pumpAt(
      tester,
      width: 760,
      presentation: _androidPresentation,
      updateNotificationForwarding: (enabled) {
        updates.add(enabled);
        return pending.future;
      },
    );
    await tester.scrollUntilVisible(
      find.text('Mobile integration'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final forwarding = _settingRow('Forward Android Notifications');
    await tester.tap(forwarding);
    await tester.tap(forwarding);
    await tester.pump();

    expect(updates, <bool>[false]);
    expect(
      tester.getSemantics(forwarding).hasFlag(SemanticsFlag.isEnabled),
      isFalse,
    );
    expect(
      tester
          .widget<CupertinoSwitch>(
            find.descendant(
              of: forwarding,
              matching: find.byType(CupertinoSwitch),
            ),
          )
          .onChanged,
      isNull,
    );

    pending.complete();
    await tester.pumpAndSettle();
    expect(updates, <bool>[false]);
    expect(
      tester.getSemantics(forwarding).hasFlag(SemanticsFlag.isToggled),
      isFalse,
    );
    semantics.dispose();
  });

  testWidgets(
      'notification forwarding compensates persistence after refresh failure',
      (tester) async {
    var persisted = true;
    var refreshes = 0;
    final writes = <bool>[];
    final listenerStates = <bool>[];
    await _pumpAt(
      tester,
      width: 760,
      presentation: _androidPresentation,
      writeNotificationForwarding: (enabled) async {
        persisted = enabled;
        writes.add(enabled);
      },
      readNotificationForwarding: () async => persisted,
      syncNotificationForwardingListener: (enabled) async {
        listenerStates.add(enabled);
      },
      refreshNotificationRegistry: () async {
        refreshes += 1;
        if (refreshes == 1) {
          throw StateError('registry refresh failed');
        }
      },
    );
    await tester.scrollUntilVisible(
      find.text('Mobile integration'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final forwarding = _settingRow('Forward Android Notifications');
    await tester.tap(forwarding);
    await tester.pumpAndSettle();

    expect(writes, <bool>[false, true]);
    expect(listenerStates, <bool>[false, true]);
    expect(refreshes, 2);
    expect(persisted, isTrue);
    expect(
      tester.getSemantics(forwarding).hasFlag(SemanticsFlag.isToggled),
      isTrue,
    );
    expect(
      find.text('Notification forwarding could not be updated'),
      findsOneWidget,
    );
  });

  testWidgets('notification forwarding rolls back and reports update failure',
      (tester) async {
    await _pumpAt(
      tester,
      width: 760,
      presentation: _androidPresentation,
      updateNotificationForwarding: (_) async {
        throw StateError('persistence failed');
      },
    );
    await tester.scrollUntilVisible(
      find.text('Mobile integration'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final forwarding = _settingRow('Forward Android Notifications');
    await tester.tap(forwarding);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSemantics(forwarding).hasFlag(SemanticsFlag.isToggled),
      isTrue,
    );
    expect(
      tester.getSemantics(forwarding).hasFlag(SemanticsFlag.isEnabled),
      isTrue,
    );
    expect(
      find.text('Notification forwarding could not be updated'),
      findsOneWidget,
    );
  });

  testWidgets('notification app navigation explains its disabled state',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final disabled = SettingsPresentation(
      device: _androidPresentation.device,
      saveDirectoryPath: _androidPresentation.saveDirectoryPath,
      version: _androidPresentation.version,
      closeToTray: _androidPresentation.closeToTray,
      copyVerificationCode: _androidPresentation.copyVerificationCode,
      listenAndroidNotifications: false,
      ignoreAndroidNotifications:
          _androidPresentation.ignoreAndroidNotifications,
      autoConnect: _androidPresentation.autoConnect,
      launchAtStartup: _androidPresentation.launchAtStartup,
      androidBackgroundKeepAlive:
          _androidPresentation.androidBackgroundKeepAlive,
      audioSharePlaybackGain: _androidPresentation.audioSharePlaybackGain,
      remoteInputScrollMultiplier:
          _androidPresentation.remoteInputScrollMultiplier,
      themeMode: _androidPresentation.themeMode,
      isAndroid: true,
      isDesktop: false,
      isMobile: true,
      notificationAppCount: 2,
    );
    await _pumpAt(tester, width: 760, presentation: disabled);
    await tester.scrollUntilVisible(
      find.text('Mobile integration'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final apps = _settingRow('Notification apps');
    final node = tester.getSemantics(apps);
    expect(node.label,
        contains('Enable notification forwarding to choose applications'));
    expect(node.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    semantics.dispose();
  });

  testWidgets('settings loader failure can retry without platform services',
      (tester) async {
    var attempts = 0;
    await _pumpAt(
      tester,
      width: 760,
      loader: () async {
        attempts += 1;
        if (attempts == 1) {
          throw StateError('load failed');
        }
        return _presentation;
      },
    );

    expect(find.text('Settings could not be loaded'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Device and appearance'), findsOneWidget);
  });

  testWidgets('successful mutation refresh preserves list scroll',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      '_clipboard': true,
    });
    final pendingRefresh = Completer<SettingsPresentation>();
    var loads = 0;
    await _pumpAt(
      tester,
      width: 760,
      height: 500,
      loader: () {
        loads += 1;
        return loads == 1
            ? Future<SettingsPresentation>.value(_presentation)
            : pendingRefresh.future;
      },
    );

    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pump();
    final clipboard = _settingRow('Access Clipboard');
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final offset = scrollable.position.pixels;
    expect(offset, greaterThan(0));

    await tester.tap(clipboard);
    for (var index = 0; index < 5 && loads < 2; index += 1) {
      await tester.pump();
    }
    await tester.pump();

    expect(loads, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(clipboard, findsOneWidget);
    expect(scrollable.position.pixels, closeTo(offset, 0.1));

    pendingRefresh.complete(
      SettingsPresentation(
        device: _device.copyWith(clipboard: false),
        saveDirectoryPath: _presentation.saveDirectoryPath,
        version: _presentation.version,
        closeToTray: _presentation.closeToTray,
        copyVerificationCode: _presentation.copyVerificationCode,
        listenAndroidNotifications: _presentation.listenAndroidNotifications,
        ignoreAndroidNotifications: _presentation.ignoreAndroidNotifications,
        autoConnect: _presentation.autoConnect,
        launchAtStartup: _presentation.launchAtStartup,
        androidBackgroundKeepAlive: _presentation.androidBackgroundKeepAlive,
        audioSharePlaybackGain: _presentation.audioSharePlaybackGain,
        remoteInputScrollMultiplier: _presentation.remoteInputScrollMultiplier,
        themeMode: _presentation.themeMode,
      ),
    );
    await tester.pumpAndSettle();

    expect(clipboard, findsOneWidget);
    expect(scrollable.position.pixels, closeTo(offset, 0.1));
    expect(
      tester.getSemantics(clipboard).hasFlag(SemanticsFlag.isToggled),
      isFalse,
    );
  });

  testWidgets('latest retry ignores an older failure and hides retry at once',
      (tester) async {
    final older = Completer<SettingsPresentation>();
    final latest = Completer<SettingsPresentation>();
    var attempts = 0;
    await _pumpAt(
      tester,
      width: 760,
      loader: () {
        attempts += 1;
        if (attempts == 1) {
          return Future<SettingsPresentation>.error(
            StateError('initial failure'),
          );
        }
        return attempts == 2 ? older.future : latest.future;
      },
    );

    final retry = tester.widget<CupertinoButton>(
      find.widgetWithText(CupertinoButton, 'Retry'),
    );
    retry.onPressed!();
    retry.onPressed!();
    await tester.pump();

    expect(attempts, 3);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

    latest.complete(_presentation);
    await tester.pumpAndSettle();
    expect(find.text('Device and appearance'), findsOneWidget);

    older.completeError(StateError('stale failure'));
    await tester.pumpAndSettle();
    expect(find.text('Device and appearance'), findsOneWidget);
    expect(find.text('Settings could not be loaded'), findsNothing);
  });

  testWidgets('latest retry failure ignores an older successful load',
      (tester) async {
    final older = Completer<SettingsPresentation>();
    final latest = Completer<SettingsPresentation>();
    var attempts = 0;
    await _pumpAt(
      tester,
      width: 760,
      loader: () {
        attempts += 1;
        if (attempts == 1) {
          return Future<SettingsPresentation>.error(
            StateError('initial failure'),
          );
        }
        return attempts == 2 ? older.future : latest.future;
      },
    );

    final retry = tester.widget<CupertinoButton>(
      find.widgetWithText(CupertinoButton, 'Retry'),
    );
    retry.onPressed!();
    retry.onPressed!();
    await tester.pump();

    latest.completeError(StateError('latest failure'));
    await tester.pumpAndSettle();
    expect(find.text('Settings could not be loaded'), findsOneWidget);

    older.complete(_presentation);
    await tester.pumpAndSettle();
    expect(find.text('Settings could not be loaded'), findsOneWidget);
    expect(find.text('Device and appearance'), findsNothing);
  });

  testWidgets('nickname and port validation stays inline and accepts limits',
      (tester) async {
    await _pumpAt(tester, width: 760);

    await tester.tap(find.text('Nickname'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), '');
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Enter a nickname'), findsOneWidget);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);

    await tester.enterText(
      find.byType(CupertinoTextField),
      '${'a' * 64}\u{1F680}',
    );
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(
        find.text('Nickname must be 64 characters or fewer'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Server Port'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), '1000');
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Enter a port from 1001 to 65535'), findsWidgets);
  });

  testWidgets('disconnected client delete awaits confirmation and callback',
      (tester) async {
    const peer = DeviceData(
      id: 9,
      uid: 'android-peer',
      name: 'Pixel',
      host: '192.168.1.9',
      port: 10002,
      platform: 'android',
      isServer: false,
      online: false,
      clipboard: false,
      auth: true,
      lastTime: 0,
    );
    final deleted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ClientSettingsScreen(
          device: peer,
          deviceLoader: (_) async => peer,
          isConnected: false,
          deleteDevice: (uid) async => deleted.add(uid),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete Device'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete Device'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Pixel'), findsOneWidget);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Confirm'));
    await tester.pumpAndSettle();
    expect(deleted, <String>['android-peer']);
  });

  testWidgets('connected client does not expose delete action', (tester) async {
    const peer = DeviceData(
      id: 9,
      uid: 'android-peer',
      name: 'Pixel',
      host: '192.168.1.9',
      port: 10002,
      platform: 'android',
      isServer: false,
      online: true,
      clipboard: false,
      auth: true,
      lastTime: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ClientSettingsScreen(
          device: peer,
          deviceLoader: (_) async => peer,
          isConnected: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete Device'), findsNothing);
  });

  test('settings source keeps the original row styling and safe dialogs', () {
    final source = File('lib/page/settings.dart').readAsStringSync();

    expect(source, contains('onLongPress: _openSaveDirectory'));
    expect(source, contains("'SF Pro Display'"));
    expect(source, contains('BorderRadius.circular(14)'));
    expect(
      RegExp(r'AppLocalizations[^;\n]*\?\?').hasMatch(source),
      isFalse,
    );
    expect(source, contains('confirmAction('));
    expect(source, contains('isDestructive: true'));
    expect(source, contains('showValidatedInputDialog('));
  });

  test('obsolete automatic approval setting is absent from settings and l10n',
      () {
    final settings = File('lib/page/settings.dart').readAsStringSync();
    expect(settings, isNot(contains('trustNewDevice')));
    expect(settings, isNot(contains('updateNoAuth')));

    for (final path in <String>[
      'lib/l10n/app_zh.arb',
      'lib/l10n/app_en.arb',
      'lib/l10n/app_es.arb',
      'lib/l10n/app_localizations.dart',
      'lib/l10n/app_localizations_zh.dart',
      'lib/l10n/app_localizations_en.dart',
      'lib/l10n/app_localizations_es.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('trustNewDevice')),
        reason: path,
      );
    }
  });
}
