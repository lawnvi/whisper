import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/connection_request_notifications.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/pairing_request.dart';

PairingRequest _request({
  required PairingReason reason,
  required PairingPromptMode mode,
}) {
  return PairingRequest(
    device: DeviceData(
      id: 1,
      uid: 'peer-a',
      name: 'Desk Mac',
      host: '192.168.1.10',
      port: 10002,
      platform: 'macos',
      isServer: false,
      online: false,
      clipboard: false,
      auth: false,
      lastTime: 0,
    ),
    pairingCode: '123456',
    reason: reason,
    mode: mode,
  );
}

void main() {
  test('background pairing notification exposes guarded code actions', () {
    final notifier = File(
      'lib/helper/connection_request_notifications.dart',
    ).readAsStringSync();
    final helper = File('lib/helper/notification.dart').readAsStringSync();
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final native = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'ConnectionRequestNotificationPlugin.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final removedPairingService = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'PairingConnectionService.kt',
    );
    final removedSystemCallHelper = File(
      'lib/helper/android_system_call_integration.dart',
    );
    final removedManagedService = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'WhisperConnectionService.kt',
    );
    final nativeZhStrings = File(
      'android/app/src/main/res/values-zh/strings.xml',
    ).readAsStringSync();
    final settings = File('lib/page/settings.dart').readAsStringSync();

    // notifier 核心要素
    expect(notifier, contains("'whisper.incoming_connection.v3'"));
    expect(notifier, contains('maybeShowForPairing'));
    expect(notifier, contains('AppLifecycleState.resumed'));
    expect(notifier, contains('onlyAlertOnce: true'));
    expect(notifier, contains('pairingNotificationBody'));
    expect(notifier, contains('AndroidNotificationAction'));
    expect(notifier, contains('pairingApproveNotificationAction'));
    expect(notifier, contains('pairingRejectNotificationAction'));
    expect(notifier, contains('request.pairingCode'));
    expect(notifier, contains('NotificationVisibility.public'));
    expect(notifier, contains('createNotificationChannel'));
    expect(notifier, contains('importance: Importance.max'));
    expect(notifier, contains('enableVibration: true'));
    expect(notifier, contains("'version': 1, 'token': token"));
    final payloadBuilder = RegExp(
      r'final payload = jsonEncode\(([\s\S]*?)\);',
    ).firstMatch(notifier)!.group(1)!;
    expect(payloadBuilder, isNot(contains("'peerId'")));
    expect(payloadBuilder, isNot(contains("'pairingCode'")));

    // Android 16 rejects unbound CallStyle notifications. Whisper uses a
    // standard high-priority event card instead of entering phone call state.
    expect(native, contains('NotificationCompat.BigTextStyle()'));
    expect(native, contains('.setLargeIcon(deviceAvatar(platform))'));
    expect(native, contains('connection_alert_accept_action'));
    expect(native, contains('connection_alert_reject_action'));
    expect(native, contains('NotificationCompat.CATEGORY_EVENT'));
    expect(native, isNot(contains('NotificationCompat.CallStyle')));
    expect(native, contains('NotificationCompat.PRIORITY_MAX'));
    expect(native, contains('R.drawable.ic_stat_whisper'));
    expect(native, isNot(contains('areNotificationsEnabled')));
    expect(native, contains('ActionBroadcastReceiver.ACTION_TAPPED'));
    expect(native, contains('"notificationId"'));
    expect(native, contains('"actionId"'));
    expect(native, contains('"payload"'));
    expect(native, isNot(contains('setFullScreenIntent')));
    expect(native, contains('NotificationCompat.VISIBILITY_PUBLIC'));
    expect(native, contains('Notification.VISIBILITY_PUBLIC'));
    expect(native, contains('NotificationManagerCompat.from(context).notify'));
    expect(native, contains('wakeScreenForAlert()'));
    expect(native, contains('PowerManager.ACQUIRE_CAUSES_WAKEUP'));
    expect(native, contains('wakeLock.acquire(SCREEN_WAKE_MILLIS)'));
    expect(native, isNot(contains('addNewIncomingCall')));
    expect(native, isNot(contains('telecom.registerPhoneAccount')));
    expect(native, contains('removeObsoletePhoneAccounts'));
    expect(native, contains('unregisterPhoneAccount'));
    expect(native, contains('whisper_pairing_alerts_v2'));
    expect(notifier, contains("'answerShowsUserInterface': true"));
    expect(native, contains('CHANNEL_ID = "whisper.incoming_connection.v3"'));
    expect(notifier, contains('deleteNotificationChannel(obsoleteChannelId)'));
    expect(notifier, contains("'whisper.incoming_connection.v2'"));
    expect(notifier, contains("'whisper.incoming_connection.v1'"));
    expect(notifier, contains("'whisper.connect_request'"));
    expect(notifier, contains("'whisper.connect_request.alerts.v2'"));
    expect(notifier, contains("'whisper.connect_request.calls'"));
    expect(notifier, contains("icon: 'ic_stat_whisper'"));
    expect(
      activity,
      contains(
        'flutterEngine.plugins.add(ConnectionRequestNotificationPlugin())',
      ),
    );
    expect(manifest, isNot(contains('android.permission.MANAGE_OWN_CALLS')));
    expect(
      manifest,
      isNot(contains('android.permission.USE_FULL_SCREEN_INTENT')),
    );
    expect(manifest, isNot(contains('android:showWhenLocked="true"')));
    expect(manifest, isNot(contains('android:turnScreenOn="true"')));
    expect(
      manifest,
      isNot(contains('android.permission.BIND_TELECOM_CONNECTION_SERVICE')),
    );
    expect(manifest, isNot(contains('android.telecom.ConnectionService')));
    expect(notifier, contains("'dismissConnectionAlert'"));
    expect(nativeZhStrings, contains('>数字一致</string>'));
    expect(nativeZhStrings, isNot(contains('系统来电')));
    expect(removedSystemCallHelper.existsSync(), isFalse);
    expect(removedManagedService.existsSync(), isFalse);
    expect(removedPairingService.existsSync(), isFalse);
    expect(settings, isNot(contains('androidSystemCallAlerts')));

    // Foreground and background actions converge on the main-isolate router.
    expect(helper, contains('onDidReceiveNotificationResponse'));
    expect(helper, contains('onDidReceiveBackgroundNotificationResponse'));
    expect(notifier, contains('IsolateNameServer.lookupPortByName'));

    expect(manager, contains('session.guardApprovalCallback('));
    expect(manager, contains('PairingPresentationBinding('));
    expect(manager, contains('cancellation: presentation.cancellation'));
    expect(manager, contains('request: request'));
    expect(manager, contains('resolve: presentation.resolve'));
    expect(manager, contains('event.onPairing('));
    expect(manager, contains('maybeShowForPairing'));
    expect(
      manager,
      matches(
        RegExp(
          r'_releaseIncomingAuthForSink[\s\S]{0,400}dismissForPeer\([^;]+graceMillis:\s*3000',
        ),
      ),
    );

    // main.dart 初始化
    expect(main, contains('ConnectionRequestNotifier().initialize'));
  });

  test('new and legacy responder requests allow code-confirmed approval', () {
    for (final reason in <PairingReason>[
      PairingReason.newDevice,
      PairingReason.legacyTrustWithoutPin,
    ]) {
      expect(
        pairingNotificationActionIds(
          _request(reason: reason, mode: PairingPromptMode.responder),
        ),
        <String>[
          pairingRejectNotificationAction,
          pairingApproveNotificationAction,
        ],
      );
      expect(
        pairingNotificationUsesProminentAlert(
          _request(reason: reason, mode: PairingPromptMode.responder),
        ),
        isTrue,
      );
    }
  });

  test('identity changes require opening details before approval', () {
    final request = _request(
      reason: PairingReason.identityChanged,
      mode: PairingPromptMode.responder,
    );
    expect(pairingNotificationActionIds(request), <String>[
      pairingRejectNotificationAction,
      pairingViewNotificationAction,
    ]);
    expect(pairingNotificationUsesProminentAlert(request), isFalse);
  });

  test('initiator can cancel but cannot approve from its notification', () {
    final request = _request(
      reason: PairingReason.newDevice,
      mode: PairingPromptMode.initiator,
    );
    expect(pairingNotificationActionIds(request), <String>[
      pairingCancelNotificationAction,
    ]);
    expect(pairingNotificationUsesProminentAlert(request), isFalse);
  });

  test('notification decisions and code formatting are deterministic', () {
    expect(
      pairingNotificationDecisionForAction(pairingApproveNotificationAction),
      isTrue,
    );
    expect(
      pairingNotificationDecisionForAction(pairingRejectNotificationAction),
      isFalse,
    );
    expect(
      pairingNotificationDecisionForAction(pairingCancelNotificationAction),
      isFalse,
    );
    expect(
      pairingNotificationDecisionForAction(pairingViewNotificationAction),
      isNull,
    );
    expect(formatPairingNotificationCode('123456'), '123 456');
  });

  test('action router rejects stale, mismatched, and duplicate responses', () {
    final router = ConnectionRequestNotificationActionRouter();
    final decisions = <bool>[];
    router.register(
      token: 'current-token',
      peerId: 'peer-a',
      notificationId: 42,
      allowedActionIds: const <String>{
        pairingRejectNotificationAction,
        pairingApproveNotificationAction,
      },
      resolve: decisions.add,
    );

    expect(
      router.dispatch(
        notificationId: 41,
        actionId: pairingApproveNotificationAction,
        token: 'current-token',
      ),
      isFalse,
    );
    expect(
      router.dispatch(
        notificationId: 42,
        actionId: pairingCancelNotificationAction,
        token: 'current-token',
      ),
      isFalse,
    );
    expect(
      router.dispatch(
        notificationId: 42,
        actionId: pairingApproveNotificationAction,
        token: 'stale-token',
      ),
      isFalse,
    );
    expect(decisions, isEmpty);

    expect(
      router.dispatch(
        notificationId: 42,
        actionId: pairingApproveNotificationAction,
        token: 'current-token',
      ),
      isTrue,
    );
    expect(decisions, <bool>[true]);
    expect(
      router.dispatch(
        notificationId: 42,
        actionId: pairingRejectNotificationAction,
        token: 'current-token',
      ),
      isFalse,
    );
    expect(decisions, <bool>[true]);
  });

  test('registering a replacement invalidates the old token for one peer', () {
    final router = ConnectionRequestNotificationActionRouter();
    final decisions = <bool>[];
    router.register(
      token: 'old-token',
      peerId: 'peer-a',
      notificationId: 10,
      allowedActionIds: const <String>{pairingApproveNotificationAction},
      resolve: decisions.add,
    );
    router.register(
      token: 'new-token',
      peerId: 'peer-a',
      notificationId: 11,
      allowedActionIds: const <String>{pairingApproveNotificationAction},
      resolve: decisions.add,
    );

    expect(
      router.dispatch(
        notificationId: 10,
        actionId: pairingApproveNotificationAction,
        token: 'old-token',
      ),
      isFalse,
    );
    expect(
      router.dispatch(
        notificationId: 11,
        actionId: pairingApproveNotificationAction,
        token: 'new-token',
      ),
      isTrue,
    );
    expect(decisions, <bool>[true]);
  });
}
