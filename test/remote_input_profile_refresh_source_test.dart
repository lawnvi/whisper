import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('websocket manager can request an immediate peer profile refresh', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('_profileRefreshRequestMessage'));
    expect(
      source,
      contains('Future<PeerProfile?> requestRemoteProfileRefresh'),
    );
    expect(source, contains('_remoteProfileRefreshWaiters'));
    expect(source, contains('peerId: targetPeerId'));
    expect(source, contains('_completeRemoteProfileRefreshWaiters()'));

    final workspace = File(
      'lib/remote_input/remote_input_workspace_screen.dart',
    ).readAsStringSync();
    expect(
      workspace.indexOf('requestRemoteProfileRefresh(peerId: peerId)'),
      lessThan(
        workspace.indexOf('final self = await LocalSetting().instance()'),
      ),
    );
    expect(workspace, contains('requestRemoteProfileRefresh(peerId: peerId)'));

    final heartbeatCase = RegExp(
      r'case MessageEnum\.Heartbeat:[\s\S]*?case MessageEnum\.File:',
    ).firstMatch(source)!.group(0)!;
    expect(
      heartbeatCase,
      contains(
        RegExp(
          r'_refreshRemoteProfileFromHeartbeat\(\s*message,\s*'
          r'peerId:\s*incomingPeerId,\s*'
          r'requireCurrent:\s*requireCurrentBusiness,\s*\)',
        ),
      ),
    );
    expect(
      heartbeatCase,
      contains('message.message == _profileRefreshRequestMessage'),
    );
    expect(
      heartbeatCase,
      contains('unawaited(_heartBeat(peerId: incomingPeerId, sink: sink))'),
    );
  });
}
