import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/app_update.dart';
import 'package:whisper/helper/macos_permissions.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/settings/settings_controls.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/remote_files/mount/remote_mounts.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';
import 'package:whisper/widget/glass_dialog.dart';

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

SettingsSwitchRow _switchRow(WidgetTester tester) => tester.widget(
  find.byWidgetPredicate(
    (w) => w is SettingsSwitchRow && w.title == 'Forward Android Notifications',
  ),
);

Finder _settingRow(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(Semantics)).first;

Widget _host({
  Widget? home,
  Locale locale = const Locale('en'),
  double textScale = 1,
  TargetPlatform? platform,
  SettingsPresentation presentation = _presentation,
  SettingsPresentationLoader? loader,
  Future<void> Function(bool enabled)? updateNotificationForwarding,
  Future<void> Function(bool enabled)? writeNotificationForwarding,
  Future<bool> Function()? readNotificationForwarding,
  Future<void> Function(bool enabled)? syncNotificationForwardingListener,
  Future<void> Function()? refreshNotificationRegistry,
  Future<void> Function()? openNotificationApps,
  void Function(String message)? showMessage,
  AppUpdateManager? updateManager,
  Future<void> Function()? exitForUpdate,
  bool autoCheckForUpdates = true,
}) {
  return MaterialApp(
    theme: platform == null
        ? AppTheme.lightTheme
        : AppTheme.lightTheme.copyWith(platform: platform),
    locale: locale,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
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
    home:
        home ??
        SettingsScreen(
          presentationLoader: loader ?? () async => presentation,
          changeDirectory: () async => '/tmp/Whisper',
          openDirectory: (_) async {},
          updateNickname: (_) async {},
          updateServerPort: (_) async {},
          updateNotificationForwarding: updateNotificationForwarding,
          writeNotificationForwarding: writeNotificationForwarding,
          readNotificationForwarding: readNotificationForwarding,
          syncNotificationForwardingListener:
              syncNotificationForwardingListener,
          refreshNotificationRegistry: refreshNotificationRegistry,
          openNotificationApps: openNotificationApps,
          showMessage: showMessage,
          updateManager: updateManager,
          exitForUpdate: exitForUpdate,
          autoCheckForUpdates: autoCheckForUpdates,
        ),
  );
}

Widget _settingsNavigationHome() => Builder(
  builder: (context) => Scaffold(
    body: TextButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            presentationLoader: () async => _presentation,
            autoCheckForUpdates: false,
          ),
        ),
      ),
      child: const Text('open settings'),
    ),
  ),
);

Future<void> _pumpAt(
  WidgetTester tester, {
  required double width,
  double height = 900,
  double textScale = 1,
  Locale locale = const Locale('en'),
  TargetPlatform? platform,
  SettingsPresentation presentation = _presentation,
  SettingsPresentationLoader? loader,
  Future<void> Function(bool enabled)? updateNotificationForwarding,
  Future<void> Function(bool enabled)? writeNotificationForwarding,
  Future<bool> Function()? readNotificationForwarding,
  Future<void> Function(bool enabled)? syncNotificationForwardingListener,
  Future<void> Function()? refreshNotificationRegistry,
  Future<void> Function()? openNotificationApps,
  void Function(String message)? showMessage,
  AppUpdateManager? updateManager,
  Future<void> Function()? exitForUpdate,
  bool autoCheckForUpdates = true,
}) async {
  tester.view
    ..physicalSize = Size(width, height)
    ..devicePixelRatio = 1;
  await tester.pumpWidget(
    _host(
      locale: locale,
      textScale: textScale,
      platform: platform,
      presentation: presentation,
      loader: loader,
      updateNotificationForwarding: updateNotificationForwarding,
      writeNotificationForwarding: writeNotificationForwarding,
      readNotificationForwarding: readNotificationForwarding,
      syncNotificationForwardingListener: syncNotificationForwardingListener,
      refreshNotificationRegistry: refreshNotificationRegistry,
      openNotificationApps: openNotificationApps,
      showMessage: showMessage,
      updateManager: updateManager,
      exitForUpdate: exitForUpdate,
      autoCheckForUpdates: autoCheckForUpdates,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('closing settings during the opening slide cancels its wait', (
    tester,
  ) async {
    await tester.pumpWidget(_host(home: _settingsNavigationHome()));
    await tester.tap(find.text('open settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  testWidgets(
    'settings remain usable at supported widths and 200 percent text',
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
    },
  );

  testWidgets('disconnected client delete awaits confirmation and callback', (
    tester,
  ) async {
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
    expect(find.byType(WhisperGlassDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(WhisperDialogButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(deleted, <String>['android-peer']);
  });

  testWidgets('connected client offers history search without delete', (
    tester,
  ) async {
    var searched = false;
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
          onSearchHistory: () => searched = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete Device'), findsNothing);
    await tester.tap(find.text('Search chat history'));
    expect(searched, isTrue);
  });

  testWidgets('device page takes back always allowing file browsing', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'remote_files.always_allowed': <String>['android-peer', 'other-peer'],
    });
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

    expect(find.text('Always Allow Browsing My Files'), findsOneWidget);
    final filesSwitch = find.descendant(
      of: find.ancestor(
        of: find.text('Always Allow Browsing My Files'),
        matching: find.byType(Row),
      ),
      matching: find.byType(CupertinoSwitch),
    );
    expect(tester.widget<CupertinoSwitch>(filesSwitch).value, isTrue);

    await tester.tap(filesSwitch);
    await tester.pumpAndSettle();

    expect(tester.widget<CupertinoSwitch>(filesSwitch).value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('remote_files.always_allowed'), <String>[
      'other-peer',
    ]);
  });

  testWidgets('a computer can keep another device mounted from its page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const peer = DeviceData(
      id: 10,
      uid: 'mount-peer',
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

    // Only where this system mounts (the tests run on a desktop).
    expect(
      find.text('Mount on this computer'),
      RemoteMounts.supported ? findsOneWidget : findsNothing,
    );
    if (RemoteMounts.supported) {
      final mountSwitch = find.descendant(
        of: find.ancestor(
          of: find.text('Mount on this computer'),
          matching: find.byType(Row),
        ),
        matching: find.byType(CupertinoSwitch),
      );
      expect(tester.widget<CupertinoSwitch>(mountSwitch).value, isFalse);
    }
    final source = File('lib/page/settings.dart').readAsStringSync();
    expect(source, contains('RemoteMounts.shared.setWanted('));
    expect(source, contains('listenable: RemoteMounts.shared'));
  });

  testWidgets('notification forwarding serializes rapid keyboard activation', (
    tester,
  ) async {
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
      find.text('Forward Android Notifications'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final forwarding = _settingRow('Forward Android Notifications');
    await tester.tap(forwarding);
    await tester.tap(forwarding);
    await tester.pump();

    expect(updates, <bool>[false]);
    expect(_switchRow(tester).onChanged, isNull);

    pending.complete();
    await tester.pumpAndSettle();
    expect(updates, <bool>[false]);
    expect(_switchRow(tester).value, isFalse);
    semantics.dispose();
  });

  testWidgets(
    'notification forwarding compensates persistence after refresh failure',
    (tester) async {
      var persisted = true;
      var refreshes = 0;
      final writes = <bool>[];
      final listenerStates = <bool>[];
      final messages = <String>[];
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
        showMessage: messages.add,
      );
      await tester.scrollUntilVisible(
        find.text('Forward Android Notifications'),
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
      expect(messages, <String>[
        'Notification forwarding could not be updated',
      ]);
    },
  );

  testWidgets('notification forwarding rolls back and reports update failure', (
    tester,
  ) async {
    final messages = <String>[];
    await _pumpAt(
      tester,
      width: 760,
      presentation: _androidPresentation,
      updateNotificationForwarding: (_) async {
        throw StateError('persistence failed');
      },
      showMessage: messages.add,
    );
    await tester.scrollUntilVisible(
      find.text('Forward Android Notifications'),
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
    expect(messages, <String>['Notification forwarding could not be updated']);
  });

  testWidgets(
    'notification forwarding stays off when listener access is denied',
    (tester) async {
      const disabled = SettingsPresentation(
        device: _device,
        saveDirectoryPath: '/storage/emulated/0/Download',
        version: '2.4.0',
        closeToTray: false,
        copyVerificationCode: true,
        listenAndroidNotifications: false,
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
      );
      final writes = <bool>[];
      final listenerStates = <bool>[];
      await _pumpAt(
        tester,
        width: 760,
        presentation: disabled,
        writeNotificationForwarding: (enabled) async => writes.add(enabled),
        readNotificationForwarding: () async => false,
        syncNotificationForwardingListener: (enabled) async {
          listenerStates.add(enabled);
          if (enabled) {
            throw StateError('permission denied');
          }
        },
        refreshNotificationRegistry: () async {},
      );
      await tester.scrollUntilVisible(
        find.text('Forward Android Notifications'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -160));
      await tester.pump();
      await tester.tap(_settingRow('Forward Android Notifications'));
      await tester.pumpAndSettle();

      expect(listenerStates, <bool>[true, false]);
      expect(writes, <bool>[false]);
      expect(_switchRow(tester).value, isFalse);
    },
  );

  testWidgets('latest retry ignores an older failure and hides retry at once', (
    tester,
  ) async {
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

    final retry = tester.widget<SettingsButton>(
      find.widgetWithText(SettingsButton, 'Retry'),
    );
    retry.onTap!();
    retry.onTap!();
    await tester.pump();

    expect(attempts, 3);
    expect(find.text('Retry'), findsNothing);
    latest.complete(_presentation);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsRow), findsWidgets);

    older.completeError(StateError('stale failure'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsRow), findsWidgets);
    expect(find.text('Settings could not be loaded'), findsNothing);
  });

  testWidgets('latest retry failure ignores an older successful load', (
    tester,
  ) async {
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

    final retry = tester.widget<SettingsButton>(
      find.widgetWithText(SettingsButton, 'Retry'),
    );
    retry.onTap!();
    retry.onTap!();
    await tester.pump();

    latest.completeError(StateError('latest failure'));
    await tester.pumpAndSettle();
    expect(find.text('Settings could not be loaded'), findsOneWidget);

    older.complete(_presentation);
    await tester.pumpAndSettle();
    expect(find.text('Settings could not be loaded'), findsOneWidget);
    expect(find.byType(SettingsRow), findsNothing);
  });
}
