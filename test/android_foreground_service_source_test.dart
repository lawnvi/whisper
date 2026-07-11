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

  test('keep-alive channel l10n survives service creation ordering', () {
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

    // onCreate 先于任何 onStartCommand 调 ensureChannel;本地化渠道
    // 文案只活在 Intent extra 的话,首次创建会用英文
    // 缺省名 createNotificationChannel,把系统设置里已本地化的渠道名改回
    // 英文。文案必须持久化并在 onCreate 读回。
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

  test('foreground service types match their Android workloads', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest,
      contains('android:foregroundServiceType="dataSync"'),
      reason: '文件传输仍使用 dataSync',
    );
    expect(
      manifest,
      contains('android:foregroundServiceType="connectedDevice"'),
      reason: '局域网设备监听不应消耗 Android 15 dataSync 预算',
    );
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE'),
    );
    expect(manifest, contains('android:stopWithTask="true"'));

    final transferService = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'TransferForegroundService.kt',
    ).readAsStringSync();
    expect(
      transferService,
      contains('override fun onTimeout(startId: Int, fgsType: Int)'),
      reason: 'dataSync 文件传输服务仍需要 Android 15 超时兜底',
    );

    final keepAliveService = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'KeepAliveForegroundService.kt',
    ).readAsStringSync();
    expect(keepAliveService, contains('START_NOT_STICKY'));
  });

  test('LAN server owns Android keep alive before the first pairing', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final notificationPermission =
        deviceList.indexOf('Permission.notification.isDenied');
    final storagePermission =
        deviceList.indexOf('Permission.manageExternalStorage.isDenied');

    expect(deviceList, contains('AndroidKeepAliveReason.lanServer'));
    expect(
      deviceList,
      matches(
        RegExp(
          r'if \(result\.isSuccess\)[\s\S]{0,1800}?'
          r'AndroidKeepAliveReason\.lanServer,[\s\S]{0,100}?true',
        ),
      ),
    );
    expect(notificationPermission, greaterThanOrEqualTo(0));
    expect(notificationPermission, lessThan(storagePermission));
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
