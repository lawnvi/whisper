import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_reading.dart';

void main() {
  test('socket manager exposes connected audio group sink devices for UI', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('List<DeviceData> connectedAudioGroupSinkDevices'));
    expect(source, contains('supportsAudioGroupSinkFor(peerId)'));
    expect(source, contains('preferredPeerId'));
  });
}
