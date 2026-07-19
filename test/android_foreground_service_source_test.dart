import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'foreground keep-alive notification opens the app and shows progress',
    () {
      final service = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'KeepAliveForegroundService.kt',
      ).readAsStringSync();
      final plugin = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'BackgroundKeepAlivePlugin.kt',
      ).readAsStringSync();
      final dartHelper = File(
        'lib/helper/android_background.dart',
      ).readAsStringSync();
      final unified = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'UnifiedForegroundNotification.kt',
      ).readAsStringSync();

      expect(unified, contains('PendingIntent.getActivity'));
      expect(unified, contains('getLaunchIntentForPackage'));
      expect(unified, contains('.setContentIntent('));
      expect(unified, contains('.setProgress(100, state.progress'));
      expect(service, contains('EXTRA_PROGRESS'));
      expect(service, contains('EXTRA_INDETERMINATE_PROGRESS'));
      expect(
        service,
        matches(
          RegExp(
            r'override fun onCreate\(\)[\s\S]*'
            r'startForeground\([\s\S]*'
            r'NOTIFICATION_ID,[\s\S]*'
            r'UnifiedForegroundNotification\.bootstrap\(',
          ),
        ),
      );

      expect(plugin, contains('call.argument<Int>("progress")'));
      expect(
        plugin,
        contains('call.argument<Boolean>("indeterminateProgress")'),
      );
      expect(dartHelper, contains('class AndroidKeepAliveNotification'));
      expect(dartHelper, contains("'progress': _clampedProgress"));
      expect(dartHelper, contains("'indeterminateProgress':"));
    },
  );

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
    final onCreate = section(
      'override fun onCreate()',
      'override fun onStartCommand',
    );
    expect(
      onCreate,
      contains('PREF_CHANNEL_NAME'),
      reason: 'onCreate 需读回持久化的渠道名',
    );
    expect(onCreate, contains('PREF_CHANNEL_DESCRIPTION'));
    final onStart = section(
      'override fun onStartCommand',
      'override fun onDestroy',
    );
    expect(
      onStart,
      contains('putString(PREF_CHANNEL_NAME'),
      reason: 'onStartCommand 收到本地化文案时需持久化',
    );
  });

  test('foreground service types match their Android workloads', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
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

  test('keep-alive service owns CPU and Wi-Fi locks for its lifetime', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'KeepAliveForegroundService.kt',
    ).readAsStringSync();

    expect(manifest, contains('android.permission.WAKE_LOCK'));
    expect(manifest, contains('android.permission.CHANGE_WIFI_STATE'));
    expect(service, contains('PowerManager.PARTIAL_WAKE_LOCK'));
    expect(service, contains('WifiManager.WIFI_MODE_FULL_HIGH_PERF'));
    expect(service, contains('setReferenceCounted(false)'));

    final onStart = service.indexOf('override fun onStartCommand');
    final acquire = service.indexOf('acquireResourceLocks()', onStart);
    final onDestroy = service.indexOf('override fun onDestroy');
    final release = service.indexOf('releaseResourceLocks()', onDestroy);
    final stopForeground = service.indexOf(
      'stopForeground(STOP_FOREGROUND_DETACH)',
      onDestroy,
    );
    expect(acquire, greaterThan(onStart), reason: '服务实际启动后才可持锁，重复启动必须幂等');
    expect(release, greaterThan(onDestroy));
    expect(release, lessThan(stopForeground), reason: '服务销毁时应先释放系统资源，再退出前台状态');

    expect(
      service,
      matches(
        RegExp(r'if \(wakeLock\?\.isHeld != true\)[\s\S]*lock\.acquire\(\)'),
      ),
      reason: '重复 startKeepAlive 不应重复持有 WakeLock',
    );
    expect(
      service,
      matches(
        RegExp(r'if \(wifiLock\?\.isHeld != true\)[\s\S]*lock\.acquire\(\)'),
      ),
      reason: '重复 startKeepAlive 不应重复持有 WifiLock',
    );
    expect(service, contains('catch (_: RuntimeException)'));
    expect(service, contains('heldWifiLock.release()'));
    expect(service, contains('heldWakeLock.release()'));
  });

  test('foreground workloads share one notification record and renderer', () {
    final unified = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'UnifiedForegroundNotification.kt',
    ).readAsStringSync();
    final keepAlive = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'KeepAliveForegroundService.kt',
    ).readAsStringSync();
    final transfer = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'TransferForegroundService.kt',
    ).readAsStringSync();
    final media = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'MediaPlaybackService.kt',
    ).readAsStringSync();

    expect(unified, contains('const val NOTIFICATION_ID = 10021'));
    expect(unified, contains('const val CHANNEL_ID = "whisper.keep_alive"'));
    for (final service in <String>[keepAlive, transfer, media]) {
      expect(
        service,
        contains('UnifiedForegroundNotification.NOTIFICATION_ID'),
        reason: '所有前台服务必须复用同一条系统通知',
      );
    }

    final transferPriority = unified.indexOf('transfer?.let');
    final mediaPriority = unified.indexOf('media?.let');
    final keepAlivePriority = unified.indexOf('keepAlive?.let');
    expect(transferPriority, greaterThanOrEqualTo(0));
    expect(mediaPriority, greaterThan(transferPriority));
    expect(keepAlivePriority, greaterThan(mediaPriority));
    expect(unified, contains('fun finishTransfer'));
    expect(unified, contains('transfer = null'));
  });

  test(
    'stopping foreground services reject direct commands until restarted',
    () {
      final keepAlive = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'KeepAliveForegroundService.kt',
      ).readAsStringSync();
      final keepAlivePlugin = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'BackgroundKeepAlivePlugin.kt',
      ).readAsStringSync();
      final transfer = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'TransferForegroundService.kt',
      ).readAsStringSync();
      final transferPlugin = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'TransferNotificationPlugin.kt',
      ).readAsStringSync();
      final media = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'MediaPlaybackService.kt',
      ).readAsStringSync();
      final audioPlugin = File(
        'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt',
      ).readAsStringSync();

      for (final service in <String>[keepAlive, transfer, media]) {
        expect(service, contains('private var acceptsDirectCommands = true'));
        expect(service, contains('private fun beginStopping()'));
        expect(
          service,
          matches(
            RegExp(
              r'private fun deliverCommand\(intent: Intent\): Boolean[\s\S]*?'
              r'if \(!acceptsDirectCommands\)[\s\S]*?return false',
            ),
          ),
          reason: 'stopSelf/stopService 到 onDestroy 之间不得把新命令交给旧实例',
        );
        expect(
          service,
          matches(
            RegExp(
              r'private fun acceptSystemCommand\(intent: Intent\?\)[\s\S]*?'
              r'acceptsDirectCommands = true',
            ),
          ),
          reason: '系统重新启动服务后必须重新开放命令处理',
        );
      }

      expect(
        keepAlivePlugin,
        contains('KeepAliveForegroundService.prepareToStop()'),
      );
      expect(
        transferPlugin.indexOf('TransferForegroundService.deliverToRunning'),
        lessThan(
          transferPlugin.indexOf('context.startForegroundService(intent)'),
        ),
      );
      expect(
        audioPlugin.indexOf('MediaPlaybackService.deliverToRunning'),
        lessThan(
          audioPlugin.indexOf('appContext.startForegroundService(intent)'),
        ),
      );
    },
  );

  test('LAN server owns Android keep alive before the first pairing', () {
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final notificationPermission = deviceList.indexOf(
      'Permission.notification.isDenied',
    );
    final storagePermission = deviceList.indexOf(
      'Permission.manageExternalStorage.isDenied',
    );

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

  test(
    'notification listener service is declared for Android settings grant',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final strings = File(
        'android/app/src/main/res/values/strings.xml',
      ).readAsStringSync();

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
    },
  );
}
