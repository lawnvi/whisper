import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connection request notification is wired end to end', () {
    final notifier = File('lib/helper/connection_request_notifications.dart')
        .readAsStringSync();
    final helper = File('lib/helper/notification.dart').readAsStringSync();
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    // notifier 核心要素
    expect(notifier, contains("'whisper.connect_request'"));
    expect(notifier, contains("@pragma('vm:entry-point')"));
    expect(notifier, contains('IsolateNameServer.registerPortWithName'));
    expect(notifier, contains('IsolateNameServer.lookupPortByName'));
    expect(notifier, contains("acceptActionId = 'whisper_connect_accept'"));
    expect(notifier, contains("rejectActionId = 'whisper_connect_reject'"));
    expect(notifier, contains('AppLifecycleState.resumed'));
    expect(notifier, contains('onlyAlertOnce: true'));

    // 前台/后台响应回调都接上了
    expect(helper, contains('onDidReceiveNotificationResponse'));
    expect(helper, contains('onDidReceiveBackgroundNotificationResponse:'));
    expect(helper, contains('connectionRequestNotificationBackgroundHandler'));

    // svrmanager:守卫回调 + 通知入口 + 断连清理
    expect(manager, contains('GuardedAuthCallback('));
    expect(manager, contains('maybeShowForAuthRequest'));
    expect(
      manager,
      matches(RegExp(
          r'_releaseIncomingAuthForSink[\s\S]{0,400}dismissForPeer\([^;]+graceMillis:\s*3000')),
    );

    // manifest 补了 action receiver
    expect(
      manifest,
      contains(
          'com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver'),
    );

    // main.dart 初始化
    expect(main, contains('ConnectionRequestNotifier().initialize'));
  });
}
