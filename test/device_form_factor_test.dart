import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/device_form_factor.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/page/remote_files/files_icons.dart';
import 'package:whisper/page/window_stream/flow_space_widgets.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/widget/device_glyph.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';

/// iPads and Android tablets say what they are, so they are not drawn as
/// phones; what they said is kept for when they are away.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a screen 600 dp across or more is a tablet', () {
    expect(formFactorForScreen(const Size(411, 914)), DeviceFormFactor.phone);
    expect(formFactorForScreen(const Size(599, 900)), DeviceFormFactor.phone);
    expect(formFactorForScreen(const Size(600, 960)), DeviceFormFactor.tablet);
    // Turned on its side: the shorter side still decides.
    expect(formFactorForScreen(const Size(1280, 800)), DeviceFormFactor.tablet);
  });

  test('what peers said is kept across restarts', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final first = DeviceFormFactors(preferences: preferences);
    await first.load();
    var changes = 0;
    first.addListener(() => changes++);
    await first.record('ipad', DeviceFormFactor.tablet);
    await first.record('pixel', DeviceFormFactor.phone);
    await first.record('ipad', DeviceFormFactor.tablet);
    await first.record('mac', '');
    await first.record('odd', 'watch');
    expect(changes, 2);
    expect(first.isTablet('ipad'), isTrue);
    expect(first.isTablet('pixel'), isFalse);
    expect(first.isTablet('unknown'), isFalse);

    final again = DeviceFormFactors(preferences: preferences);
    await again.load();
    expect(again.isTablet('ipad'), isTrue);
    expect(again.isTablet('pixel'), isFalse);
    // A tablet that turns out to be a phone (a fold closed) is redrawn.
    await again.record('ipad', DeviceFormFactor.phone);
    expect(again.isTablet('ipad'), isFalse);
  });

  test('tablets get a tablet, phones keep their mark', () {
    expect(platformIcon('ios'), Icons.apple_rounded);
    expect(platformIcon('ios', tablet: true), Icons.tablet_mac_rounded);
    expect(platformIcon('android'), Icons.android_rounded);
    expect(platformIcon('android', tablet: true), Icons.tablet_android_rounded);
    // A computer is what it is.
    expect(platformIcon('macos', tablet: true), Icons.laptop_mac_rounded);
    expect(platformLabel('ios', tablet: true), 'iPad');
    // Beside Cupertino's thin phone, a tablet of the same weight.
    expect(
      flowDeviceGlyph(WindowStreamPlatform.ios, tablet: true),
      tabletGlyph,
    );
    expect(fsDeviceIcon('android', tablet: true), tabletGlyph);
    expect(fsDeviceIcon('android'), CupertinoIcons.device_phone_portrait);
  });

  testWidgets('the tablet glyph stands upright, others as they are', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: [
            DeviceGlyph(tabletGlyph, size: 20),
            DeviceGlyph(CupertinoIcons.device_phone_portrait, size: 20),
          ],
        ),
      ),
    );
    expect(
      find.ancestor(
        of: find.byIcon(tabletGlyph),
        matching: find.byType(RotatedBox),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byIcon(CupertinoIcons.device_phone_portrait),
        matching: find.byType(RotatedBox),
      ),
      findsNothing,
    );
  });

  testWidgets('the shelf draws a tablet as one', (tester) async {
    Future<void> card(bool tablet) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: FlowDeviceCard(
            name: 'iPad',
            subtitle: '',
            platform: WindowStreamPlatform.ios,
            hue: Colors.blue,
            selected: false,
            tablet: tablet,
            onTap: () {},
          ),
        ),
      ),
    );
    await card(false);
    await card(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('profiles carry it, at the version agreed with each peer', () {
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    expect(manager, contains('formFactor: await _localFormFactor()'));
    expect(
      manager,
      contains('profile.toWireProfile().forProtocolVersion(agreed).toJson()'),
    );
    expect(
      manager,
      contains('DeviceFormFactors.shared.record(peerId, profile.formFactor)'),
    );
    // Profiles put together by hand keep it too: the one registered after
    // the handshake is, and a dialler may never get the peer's heartbeat.
    final copies = RegExp(
      r'PeerProfile\([^;]*?displayTopology: [^;]*?\)',
    ).allMatches(manager).map((m) => m.group(0)!).toList();
    expect(copies, isNotEmpty);
    for (final copy in copies) {
      expect(copy, contains('formFactor:'), reason: copy);
    }
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('unawaited(DeviceFormFactors.shared.load());'),
    );
  });
}
