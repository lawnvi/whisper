import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('background pairing notification only opens the in-app comparison', () {
    final notifier = File('lib/helper/connection_request_notifications.dart')
        .readAsStringSync();
    final helper = File('lib/helper/notification.dart').readAsStringSync();
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    // notifier 核心要素
    expect(notifier, contains("'whisper.connect_request'"));
    expect(notifier, contains('maybeShowForPairing'));
    expect(notifier, contains('AppLifecycleState.resumed'));
    expect(notifier, contains('onlyAlertOnce: true'));
    expect(notifier, contains('pairingNotificationBody'));
    expect(notifier, isNot(contains('AndroidNotificationAction')));
    expect(notifier, isNot(contains('acceptActionId')));
    expect(notifier, isNot(contains('rejectActionId')));
    expect(notifier, isNot(contains('pairingCode')));
    expect(notifier, isNot(contains('host')));

    // A default notification tap launches/focuses the app; it never resolves
    // the guarded approval callback.
    expect(helper, contains('onDidReceiveNotificationResponse'));

    expect(manager, contains('session.guardApprovalCallback('));
    expect(manager, contains('event.onPairing('));
    expect(manager, contains('maybeShowForPairing'));
    expect(
      manager,
      matches(RegExp(
          r'_releaseIncomingAuthForSink[\s\S]{0,400}dismissForPeer\([^;]+graceMillis:\s*3000')),
    );

    // main.dart 初始化
    expect(main, contains('ConnectionRequestNotifier().initialize'));
  });
}
