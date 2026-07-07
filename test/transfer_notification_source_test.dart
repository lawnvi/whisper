import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native transfer notification supports live updates with fallback', () {
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'TransferNotificationPlugin.kt',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'TransferForegroundService.kt',
    ).readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final mainActivity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();

    // Android 16+ Live Updates 与降级链
    expect(service, contains('NotificationCompat.ProgressStyle'));
    expect(service, contains('setRequestPromotedOngoing'));
    expect(service, contains('canPostPromotedNotifications'));
    expect(service, contains('Build.VERSION.SDK_INT >= 36'));
    expect(service, contains('.setProgress(100,')); // 15- 降级
    expect(service, contains('setOnlyAlertOnce(true)'));
    expect(service, contains('STOP_FOREGROUND_DETACH'));

    // FGS 从后台启动失败的兜底
    expect(plugin, contains('ForegroundServiceStartNotAllowedException'));
    expect(plugin, contains("com.vireen.whisper/transfer_notifications"));

    expect(manifest, contains('TransferForegroundService'));
    expect(
        manifest, contains('android.permission.POST_PROMOTED_NOTIFICATIONS'));
    expect(gradle, contains('androidx.core:core:1.17.0'));
    expect(mainActivity, contains('TransferNotificationPlugin()'));
  });
}
