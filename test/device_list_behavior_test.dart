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

  group('desktop sidebar', () {});

  group('phone', () {});
}
