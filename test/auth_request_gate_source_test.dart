import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('socket auth flow gates duplicate incoming and outgoing requests', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source,
        contains("import 'package:whisper/socket/auth_request_gate.dart';"));
    expect(source, contains('final AuthRequestGate _authRequestGate'));
    expect(
      source,
      contains('Future<ConnectionAttemptResult> connectToServer('),
    );
    expect(source, contains('ConnectionAttemptRequest request'));
    expect(source, contains('tryClaimOutgoing'));
    expect(source, contains('releaseOutgoing'));
    expect(source, contains('tryClaimIncoming'));
    expect(source, contains('releaseIncoming'));
  });

  test('device connection entry points pass peer ids into socket auth', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(deviceList, contains('expectedPeerId: peerId ??'));
    expect(conversation, contains('expectedPeerId: device.uid'));
  });
}
