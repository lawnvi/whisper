// What the device list does, seen from the outside. These replace tests that
// read deviceList.dart as text and pinned private method names.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations_en.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/page/deviceList.dart';
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

ChatSessionItem _session(String uid, String name) => ChatSessionItem(
  device: DeviceData(
    id: 2,
    uid: uid,
    name: name,
    host: '192.168.31.20',
    port: 10002,
    platform: 'macos',
    isServer: true,
    online: true,
    clipboard: false,
    auth: true,
    lastTime: 0,
  ),
  latestMessage: null,
  preview: 'preview of $name',
  lastTimestamp: 0,
  isConnected: true,
  isNearby: true,
  hasHistory: false,
  avatarLabel: name.substring(0, 1),
);

final _l10n = AppLocalizationsEn();

void main() {
  tearDown(() => debugIsDesktopOverride = null);

  Future<void> pumpList(
    WidgetTester t, {
    required bool desktop,
    Size? window,
  }) async {
    setGoldenWindow(
      t,
      window ?? (desktop ? goldenDesktopWindow : goldenPhoneWindow),
    );
    debugIsDesktopOverride = desktop;
    await t.pumpWidget(
      goldenApp(
        DeviceListScreen(
          debugPreview: DeviceListPreview(
            device: _self,
            sessions: [_session('imac', 'iMac'), _session('mi', 'Xiaomi 16')],
          ),
        ),
        locale: const Locale('en'),
      ),
    );
    await t.pumpAndSettle();
  }

  group('desktop sidebar', () {
    testWidgets('lists every device with its latest activity', (t) async {
      await pumpList(t, desktop: true);
      expect(find.text('iMac'), findsOneWidget);
      expect(find.text('Xiaomi 16'), findsOneWidget);
      expect(find.text('preview of iMac'), findsOneWidget);
      expect(find.text(_l10n.selectConversationPlaceholder), findsOneWidget);
    });

    testWidgets('connecting and settings are always one click away', (t) async {
      await pumpList(t, desktop: true);
      expect(find.byTooltip(_l10n.connectDeviceTitle), findsOneWidget);
      expect(find.byTooltip(_l10n.setting), findsOneWidget);
    });

    testWidgets('sound and keyboard sharing stay out until asked for', (
      t,
    ) async {
      await pumpList(t, desktop: true);
      expect(find.byTooltip(_l10n.remoteInputWorkspaceTooltip), findsNothing);
      expect(find.byTooltip(_l10n.audioGroupShareStart), findsNothing);

      await t.tap(find.byTooltip(_l10n.toolbarMoreTools));
      await t.pumpAndSettle();

      expect(find.byTooltip(_l10n.remoteInputWorkspaceTooltip), findsOneWidget);
      expect(find.byTooltip(_l10n.audioGroupShareStart), findsOneWidget);
      expect(find.byTooltip(_l10n.toolbarFewerTools), findsOneWidget);

      await t.tap(find.byTooltip(_l10n.toolbarFewerTools));
      await t.pumpAndSettle();
      expect(find.byTooltip(_l10n.remoteInputWorkspaceTooltip), findsNothing);
    });

    testWidgets('search narrows the list as you type', (t) async {
      await pumpList(t, desktop: true);
      await t.tap(find.byTooltip(_l10n.searchChats));
      await t.pumpAndSettle();
      await t.enterText(find.byType(CupertinoTextField), 'xiaomi');
      await t.pumpAndSettle();
      expect(find.text('iMac'), findsNothing);
      expect(find.text('Xiaomi 16'), findsWidgets);

      await t.enterText(find.byType(CupertinoTextField), '');
      await t.pumpAndSettle();
      expect(find.text('iMac'), findsOneWidget);
    });
  });

  group('phone', () {
    testWidgets('shows this device, its address and the list', (t) async {
      await pumpList(t, desktop: false);
      expect(find.text('Studio Mac'), findsOneWidget);
      expect(find.text('192.168.31.8:10002'), findsOneWidget);
      expect(find.text('iMac'), findsOneWidget);
      expect(find.text('Xiaomi 16'), findsOneWidget);
    });

    testWidgets('connecting is one tap away, tools are not in the way', (
      t,
    ) async {
      await pumpList(t, desktop: false);
      expect(find.byTooltip(_l10n.connectDeviceTitle), findsOneWidget);
      expect(find.byTooltip(_l10n.toolbarMoreTools), findsNothing);
      expect(find.byTooltip(_l10n.remoteInputWorkspaceTooltip), findsNothing);
    });
  });
}
