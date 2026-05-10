import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('websocket manager can request an immediate peer profile refresh', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('_profileRefreshRequestMessage'));
    expect(
        source, contains('Future<PeerProfile?> requestRemoteProfileRefresh'));
    expect(source, contains('_remoteProfileRevision'));
    expect(source, contains('_remoteProfileRefreshWaiters'));
    expect(source, contains('_heartBeat(profileRefreshRequest: true)'));
    expect(source, contains('_completeRemoteProfileRefreshWaiters()'));

    final heartbeatCase = RegExp(
      r'case MessageEnum\.Heartbeat:[\s\S]*?case MessageEnum\.FileSignal:',
    ).firstMatch(source)!.group(0)!;
    expect(
        heartbeatCase, contains('_refreshRemoteProfileFromHeartbeat(message)'));
    expect(heartbeatCase,
        contains('message.message == _profileRefreshRequestMessage'));
    expect(heartbeatCase, contains('unawaited(_heartBeat())'));
  });
}
