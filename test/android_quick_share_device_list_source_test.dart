import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device list wires Android quick share to connected peers only', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains("helper/android_quick_share.dart"));
    expect(source, contains('AndroidQuickShare.shared'));
    expect(source, contains('_loadPendingAndroidQuickShare'));
    expect(source, contains('popUntil((route) => route.isFirst)'));
    expect(source, contains('_handleQuickShareDeviceSelection'));
    expect(source, contains('_sendPendingQuickShareTo'));
    expect(source, contains('socketManager.isConnectedTo'));
    expect(source, contains('socketManager.selectPeer'));
    expect(source, contains('socketManager.sendFile'));
    expect(source, contains('pendingFilePaths'));
  });
}
