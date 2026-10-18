import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/phone_trust.dart';

void main() {
  test('reads the identity a phone reports over adb', () {
    final identity = PhoneTrust.parse(
      'Result: Bundle[{identityKey=AbC-_1x, '
      'peerId=1b2c3d4e-0000-4000-8000-123456789abc, version=1}]\n',
    );
    expect(identity?.peerId, '1b2c3d4e-0000-4000-8000-123456789abc');
    expect(identity?.identityKey, 'AbC-_1x');
    // Whisper never opened since install, an old Whisper, or none at all.
    expect(
      PhoneTrust.parse('Result: Bundle[{identityKey=, peerId=, version=1}]'),
      isNull,
    );
    expect(PhoneTrust.parse('Error: Unknown authority'), isNull);
    expect(PhoneTrust.parse(''), isNull);
  });

  test('only paired, trusted phones become sources', () {
    final coordinator = File(
      'lib/window_stream/window_stream_coordinator.dart',
    ).readAsStringSync();
    final create = coordinator.substring(
      coordinator.indexOf('Future<void> _createSource('),
      coordinator.indexOf('PhoneTrustCheck trustCheck'),
    );
    final check = create.indexOf('await trustCheck(adb, device.serial)');
    expect(check, isNot(-1));
    // The check comes before anything is pushed to or started on the phone.
    expect(check, lessThan(create.indexOf('AndroidDeviceProps.read(')));
    expect(check, lessThan(create.indexOf('_launchAndroidSource(')));
    final trust = File(
      'lib/window_stream/android/phone_trust.dart',
    ).readAsStringSync();
    expect(trust, contains('device.auth &&'));
    expect(trust, contains('device.identityPublicKey == identity.identityKey'));
  });

  test('the phone answers adb and root only, and can stop streaming', () {
    final provider = File(
      'android/app/src/main/kotlin/com/vireen/whisper/WindowStreamProvider.kt',
    ).readAsStringSync();
    expect(provider, contains('caller != ROOT_UID && caller != SHELL_UID'));
    expect(provider, contains('const val SHELL_UID = 2000'));
    expect(provider, contains('setRequestPromotedOngoing(true)'));
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      manifest,
      contains('android:authorities="com.vireen.whisper.window_stream"'),
    );
    expect(
      manifest,
      contains(
        'android:name=".WindowStreamStopReceiver" android:exported="false"',
      ),
    );
    final agent = File(
      'android_agent/src/com/vireen/whisper/agent/PhoneApp.java',
    ).readAsStringSync();
    expect(agent, contains('AUTHORITY = "${PhoneTrust.authority}"'));
    final server = File(
      'android_agent/src/com/vireen/whisper/agent/AgentServer.java',
    ).readAsStringSync();
    expect(server, contains('phoneApp.takeStopRequest()'));
    for (final lang in ['values', 'values-zh', 'values-es']) {
      final strings = File(
        'android/app/src/main/res/$lang/strings.xml',
      ).readAsStringSync();
      expect(strings, contains('window_stream_stop_action'), reason: lang);
    }
  });

  test('Flow opens from a device\'s page, focused on that device', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    // A row on the device's page (the … in its conversation), not an icon
    // in the conversation's header or on the home screen.
    expect(
      conversation,
      contains('builder: (_) => FlowSpacePage(focusPeerId: device.uid)'),
    );
    expect(conversation, isNot(contains('icon: const ComputerControlIcon()')));
    final settings = File('lib/page/settings.dart').readAsStringSync();
    expect(settings, contains('class DeviceFeature {'));
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    expect(deviceList, isNot(contains('const FlowSpacePage()')));
    final coordinator = File(
      'lib/window_stream/window_stream_coordinator.dart',
    ).readAsStringSync();
    // adb phones are matched to their Whisper peer by the id they report.
    expect(coordinator, contains('WindowSource? sourceForPeer(String peerId)'));
    expect(coordinator, contains('peerId: trust.peerId'));
  });

  test('a sent window arrives as a banner the user opens', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(
      main,
      contains('IslandHost(navigatorKey: appNavigatorKey, child: shell)'),
    );
    final banner = File(
      'lib/page/window_stream/flow_offer_banner.dart',
    ).readAsStringSync();
    expect(banner, contains('_viewer.offers.addListener(_onOffers)'));
    // Away from the app: a notification instead, the banner waits.
    expect(banner, contains('NotificationHelper().showNotification('));
    expect(
      banner,
      contains('openFlowWindow(navigator, offer.source, offer.target)'),
    );
    final page = File(
      'lib/page/window_stream/flow_space_page.dart',
    ).readAsStringSync();
    // Desktop: the two directions are separate modes, and sending flies.
    expect(page, contains('enum _FlowMode { open, send }'));
    expect(page, contains('WindowStreamHost.shared.offer(peerId, window)'));
    expect(page, contains('await flowFlyWindow('));
    final capture = File(
      'packages/window_stream_native/macos/Classes/WindowCapture.swift',
    ).readAsStringSync();
    // Minimized or off-desktop windows render nothing until brought back.
    expect(
      capture,
      contains('WindowInjector.reveal(pid: pid, frame: window.frame)'),
    );
  });

  test(
    'a phone frozen by a leftover page is reported, fixed only on consent',
    () {
      final server = File(
        'android_agent/src/com/vireen/whisper/agent/AgentServer.java',
      ).readAsStringSync();
      // Checked when a desktop connects and after every window closes.
      expect(server, contains('scheduleTouchCheck(1000)'));
      expect(server, contains('scheduleTouchCheck(1500)'));
      expect(server, contains('broadcast("touchBlocked", payload)'));
      final session = File(
        'android_agent/src/com/vireen/whisper/agent/ControlSession.java',
      ).readAsStringSync();
      expect(
        session,
        contains('TouchGuard.removeTask(params.getInt("taskId"))'),
      );
      final alert = File(
        'lib/page/window_stream/phone_touch_alert.dart',
      ).readAsStringSync();
      expect(alert, contains('.repairTouch(app.taskId)'));
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('PhoneTouchAlertHost(child: shell)'));
    },
  );
}
