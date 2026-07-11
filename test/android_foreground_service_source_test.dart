import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('foreground keep-alive notification opens the app and shows progress',
      () {
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'KeepAliveForegroundService.kt',
    ).readAsStringSync();
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'BackgroundKeepAlivePlugin.kt',
    ).readAsStringSync();
    final dartHelper =
        File('lib/helper/android_background.dart').readAsStringSync();

    expect(service, contains('PendingIntent.getActivity'));
    expect(service, contains('packageManager.getLaunchIntentForPackage'));
    expect(service, contains('.setContentIntent('));
    expect(service, contains('.setProgress(100, progress'));
    expect(service, contains('EXTRA_PROGRESS'));
    expect(service, contains('EXTRA_INDETERMINATE_PROGRESS'));
    expect(
      service,
      matches(
        RegExp(
          r'override fun onCreate\(\)[\s\S]*'
          r'startForeground\([\s\S]*'
          r'NOTIFICATION_ID,[\s\S]*'
          r'buildNotification\(',
        ),
      ),
    );

    expect(plugin, contains('call.argument<Int>("progress")'));
    expect(plugin, contains('call.argument<Boolean>("indeterminateProgress")'));
    expect(dartHelper, contains('class AndroidKeepAliveNotification'));
    expect(dartHelper, contains("'progress': _clampedProgress"));
    expect(dartHelper, contains("'indeterminateProgress':"));
  });

  test('keep-alive channel l10n survives sticky restarts', () {
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'KeepAliveForegroundService.kt',
    ).readAsStringSync();

    String section(String startMarker, String endMarker) {
      final start = service.indexOf(startMarker);
      expect(start, greaterThanOrEqualTo(0), reason: '未找到: $startMarker');
      final end = service.indexOf(endMarker, start);
      expect(end, greaterThan(start), reason: '未找到终点: $endMarker');
      return service.substring(start, end);
    }

    // START_STICKY 空 intent 重建时 onCreate 先于任何 onStartCommand 调
    // ensureChannel;本地化渠道文案只活在 Intent extra 的话,重建会用英文
    // 缺省名 createNotificationChannel,把系统设置里已本地化的渠道名改回
    // 英文。文案必须持久化并在 onCreate 读回。
    expect(service, contains('START_STICKY'));
    final onCreate =
        section('override fun onCreate()', 'override fun onStartCommand');
    expect(onCreate, contains('PREF_CHANNEL_NAME'),
        reason: 'onCreate 需读回持久化的渠道名');
    expect(onCreate, contains('PREF_CHANNEL_DESCRIPTION'));
    final onStart =
        section('override fun onStartCommand', 'override fun onDestroy');
    expect(onStart, contains('putString(PREF_CHANNEL_NAME'),
        reason: 'onStartCommand 收到本地化文案时需持久化');
  });

  test('dataSync foreground services stop themselves on Android 15+ timeout',
      () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest,
      contains('android:foregroundServiceType="dataSync"'),
      reason: 'dataSync 前台服务受 Android 15+ 的 6 小时预算约束',
    );

    for (final path in <String>[
      'android/app/src/main/kotlin/com/vireen/whisper/'
          'TransferForegroundService.kt',
      'android/app/src/main/kotlin/com/vireen/whisper/'
          'KeepAliveForegroundService.kt',
    ]) {
      final service = File(path).readAsStringSync();
      // Android 15 起 dataSync FGS 预算耗尽会回调 onTimeout(int, int);
      // 不在回调里退出前台并停止服务,系统会抛
      // ForegroundServiceDidNotStopInTimeException 直接杀进程。
      expect(
        service,
        contains('override fun onTimeout(startId: Int, fgsType: Int)'),
        reason: '$path 缺少 dataSync onTimeout 兜底',
      );
      expect(
        service,
        matches(
          RegExp(
            r'override fun onTimeout\(startId: Int, fgsType: Int\)'
            r'[\s\S]{0,600}?stopForeground\(STOP_FOREGROUND_REMOVE\)'
            r'[\s\S]{0,300}?stopSelf\(\)',
          ),
        ),
        reason: '$path 的 onTimeout 必须 stopForeground(REMOVE) 后 stopSelf',
      );
    }
  });

  test('notification listener service is declared for Android settings grant',
      () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final strings =
        File('android/app/src/main/res/values/strings.xml').readAsStringSync();

    expect(
      manifest,
      contains(
        'android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"',
      ),
    );
    expect(manifest, contains('android:exported="false"'));
    expect(
      manifest,
      contains('android:label="@string/notification_listener_label"'),
    );
    expect(
      manifest,
      contains(
        'android:name="android.service.notification.default_filter_types"',
      ),
    );
    expect(strings, contains('<string name="notification_listener_label">'));
  });
}
