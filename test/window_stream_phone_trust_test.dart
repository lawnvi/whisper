import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/phone_trust.dart';

import 'support/source_reading.dart';

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
    final deviceList = deviceListSource();
    expect(deviceList, isNot(contains('const FlowSpacePage()')));
    final coordinator = File(
      'lib/window_stream/window_stream_coordinator.dart',
    ).readAsStringSync();
    // adb phones are matched to their Whisper peer by the id they report.
    expect(coordinator, contains('WindowSource? sourceForPeer(String peerId)'));
    expect(coordinator, contains('peerId: trust.peerId'));
  });

}
