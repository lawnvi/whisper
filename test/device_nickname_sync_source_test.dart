import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Bonjour broadcast advertises the configured local nickname', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains("'name': device?.name ?? await deviceName()"));
    expect(source, isNot(contains("'name': await deviceName()")));
    expect(source, contains('localProfileUpdate'));
    expect(source, contains('device!.name != temp.name'));
  });

  test('nickname changes are pushed to connected peers immediately', () {
    final settingsSource = File('lib/page/settings.dart').readAsStringSync();
    final socketSource = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(settingsSource, contains('broadcastLocalProfileUpdate'));
    expect(
      socketSource,
      contains('Future<void> broadcastLocalProfileUpdate() async'),
    );
    expect(socketSource, contains('for (final peerId in connectedPeerIds)'));
    expect(socketSource, contains('await _heartBeat(peerId: peerId)'));
  });

  test(
      'heartbeat profile updates are persisted and refresh visible device names',
      () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(
      source,
      contains(
        'Future<void> _refreshRemoteProfileFromHeartbeat',
      ),
    );
    expect(source, contains('await _database.upsertDevice(profile.device)'));
    expect(source, contains('ConnectionCoordinator().markConnected'));
    expect(source, contains('profileDeviceChanged'));
    expect(source, contains('_dispatchToAll((event) => event.onConnect())'));
  });
}
