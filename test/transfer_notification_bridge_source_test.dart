import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transfer notification bridge listens to socket events on android', () {
    final bridge =
        File('lib/helper/transfer_notifications.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(bridge, contains('implements ISocketEvent'));
    expect(bridge, contains('TransferNotificationAggregator'));
    expect(bridge, contains("'com.vireen.whisper/transfer_notifications'"));
    expect(bridge, contains('onTransferUpdated'));
    expect(bridge, contains('Platform.isAndroid'));
    expect(bridge, contains('lookupAppLocalizations'));
    expect(main, contains('TransferNotificationBridge().attach()'));
  });
}
