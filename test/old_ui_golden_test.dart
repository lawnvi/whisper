// The pages as they are before the redesign. They pin the old UI so that the
// migration can prove it did not move: see docs/design/migration.md step 0.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/page/conversation.dart';
import 'package:whisper/page/deviceList.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/state/chat_session_list.dart';

import 'support/golden_support.dart';

const _self = DeviceData(
  id: 1,
  uid: 'self',
  name: 'Studio Mac',
  host: '192.168.31.8',
  port: 10002,
  platform: 'macos',
  isServer: true,
  online: true,
  clipboard: true,
  auth: false,
  lastTime: 0,
);

final _imac = DeviceData(
  id: 2,
  uid: 'imac',
  name: 'iMac',
  host: '192.168.31.20',
  port: 10002,
  platform: 'macos',
  isServer: true,
  online: true,
  clipboard: true,
  auth: true,
  lastTime: _t0,
);

final _phone = DeviceData(
  id: 3,
  uid: 'mi',
  name: 'Xiaomi 16',
  host: '192.168.31.109',
  port: 10002,
  platform: 'android',
  isServer: true,
  online: true,
  clipboard: false,
  auth: true,
  lastTime: _t0,
);

final _gone = DeviceData(
  id: 4,
  uid: 'tp',
  name: 'ThinkPad X1 Carbon 办公笔记本',
  host: '192.168.31.41',
  port: 10002,
  platform: 'windows',
  isServer: true,
  online: false,
  clipboard: false,
  auth: true,
  lastTime: _t0,
);

// Long ago, so no date reads "today", and in local time, so the images hold in
// any time zone.
final _t0 = DateTime(2020, 1, 1, 9).millisecondsSinceEpoch ~/ 1000;

MessageData _text(int id, String sender, String receiver, String content) =>
    MessageData(
      id: id,
      deviceId: null,
      sender: sender,
      receiver: receiver,
      name: '',
      clipboard: false,
      size: 0,
      type: MessageEnum.Text,
      content: content,
      message: '',
      timestamp: _t0 + id * 60,
      uuid: 'uuid-$id',
      acked: true,
      path: '',
      md5: '',
      fileTimestamp: 0,
    );

final List<ChatSessionItem> _sessions = [
  ChatSessionItem(
    device: _imac,
    latestMessage: _text(9, 'imac', 'self', '不急'),
    preview: '不急',
    lastTimestamp: _t0,
    isConnected: true,
    isNearby: true,
    hasHistory: true,
    avatarLabel: 'iM',
  ),
  ChatSessionItem(
    device: _phone,
    latestMessage: null,
    preview: '附近可连接',
    lastTimestamp: _t0,
    isConnected: false,
    isNearby: true,
    hasHistory: false,
    avatarLabel: 'Xi',
  ),
  ChatSessionItem(
    device: _gone,
    latestMessage: null,
    preview: '还没有消息',
    lastTimestamp: _t0,
    isConnected: false,
    isNearby: false,
    hasHistory: false,
    avatarLabel: 'Th',
  ),
];

const _settings = SettingsPresentation(
  device: _self,
  saveDirectoryPath: '/Users/tester/Downloads/Whisper',
  version: '0.0.58',
  closeToTray: true,
  copyVerificationCode: true,
  listenAndroidNotifications: true,
  ignoreAndroidNotifications: false,
  autoConnect: true,
  launchAtStartup: false,
  androidBackgroundKeepAlive: true,
  audioSharePlaybackGain: 1.0,
  remoteInputScrollMultiplier: 1.0,
  themeMode: ThemeMode.light,
);

const _phoneSettings = SettingsPresentation(
  device: _self,
  saveDirectoryPath: '/storage/emulated/0/Download',
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
  themeMode: ThemeMode.light,
  isAndroid: true,
  isDesktop: false,
  isMobile: true,
  notificationAppCount: 2,
);

Widget _settingsPage(SettingsPresentation presentation) => SettingsScreen(
  presentationLoader: () async => presentation,
  changeDirectory: () async => '/tmp/Whisper',
  openDirectory: (_) async {},
  updateNickname: (_) async {},
  updateServerPort: (_) async {},
  autoCheckForUpdates: false,
);

void main() {
  setUpAll(loadGoldenFonts);

  tearDown(() => debugIsDesktopOverride = null);

  Future<void> expectGolden(WidgetTester t, String name) async {
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/old_ui/$name.png'),
    );
  }

  group('settings', () {
    testWidgets('desktop', skip: goldenSkip != null, (t) async {
      setGoldenWindow(t, goldenDesktopWindow);
      await t.pumpWidget(goldenApp(_settingsPage(_settings)));
      await t.pumpAndSettle();
      await expectGolden(t, 'settings_desktop');
    });

    testWidgets('phone', skip: goldenSkip != null, (t) async {
      setGoldenWindow(t, goldenPhoneWindow);
      debugIsDesktopOverride = false;
      await t.pumpWidget(goldenApp(_settingsPage(_phoneSettings)));
      await t.pumpAndSettle();
      await expectGolden(t, 'settings_phone');
    });
  });

  group('device list', () {
    Widget screen({String? selected}) => DeviceListScreen(
      debugPreview: DeviceListPreview(
        device: _self,
        sessions: _sessions,
        selectedPeerId: selected,
      ),
    );

    testWidgets('desktop', skip: goldenSkip != null, (t) async {
      setGoldenWindow(t, goldenDesktopWindow);
      debugIsDesktopOverride = true;
      await t.pumpWidget(goldenApp(screen()));
      await t.pumpAndSettle();
      await expectGolden(t, 'device_list_desktop');
    });

    testWidgets('phone', skip: goldenSkip != null, (t) async {
      setGoldenWindow(t, goldenPhoneWindow);
      debugIsDesktopOverride = false;
      await t.pumpWidget(goldenApp(screen()));
      await t.pumpAndSettle();
      await expectGolden(t, 'device_list_phone');
    });
  });

  group('conversation', () {
    late LocalDatabase db;

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      SharedPreferences.setMockInitialValues({
        '_uuid': 'self',
        '_name': 'Studio Mac',
      });
      db = LocalDatabase.forTesting(NativeDatabase.memory());
      LocalDatabase.debugOverride = db;
    });

    tearDown(() async {
      LocalDatabase.debugOverride = null;
      await db.close();
    });

    Future<void> seed(WidgetTester t) => t.runAsync(() async {
      await db.upsertDevice(_imac);
      await db.insertMessage(_text(1, 'imac', 'self', '发版说明改好了，帮我看一眼。'));
      await db.insertMessage(_text(2, 'self', 'imac', '好'));
      await db.insertMessage(_text(3, 'imac', 'self', '不急'));
    });

    testWidgets('desktop', skip: goldenSkip != null, (t) async {
      setGoldenWindow(t, goldenDesktopWindow);
      debugIsDesktopOverride = true;
      stubSystemDragAndDrop(t);
      await seed(t);
      await t.pumpWidget(goldenApp(SendMessageScreen(device: _imac)));
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pumpAndSettle();
      await expectGolden(t, 'conversation_desktop');
    });

    testWidgets('phone', skip: goldenSkip != null, (t) async {
      setGoldenWindow(t, goldenPhoneWindow);
      debugIsDesktopOverride = false;
      await seed(t);
      await t.pumpWidget(goldenApp(SendMessageScreen(device: _imac)));
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pumpAndSettle();
      await expectGolden(t, 'conversation_phone');
    });

    // The composer only shows where sending is possible: on this device's own
    // conversation here, as nothing is connected.
    testWidgets('composer on desktop', skip: goldenSkip != null, (t) async {
      setGoldenWindow(t, goldenDesktopWindow);
      debugIsDesktopOverride = true;
      stubSystemDragAndDrop(t);
      await t.pumpWidget(goldenApp(const SendMessageScreen(device: _self)));
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pumpAndSettle();
      await expectGolden(t, 'conversation_composer_desktop');
    });

    testWidgets('composer on a phone', skip: goldenSkip != null, (t) async {
      setGoldenWindow(t, goldenPhoneWindow);
      debugIsDesktopOverride = false;
      await t.pumpWidget(goldenApp(const SendMessageScreen(device: _self)));
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pumpAndSettle();
      await expectGolden(t, 'conversation_composer_phone');
    });
  });
}
