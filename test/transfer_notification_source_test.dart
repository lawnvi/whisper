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
    expect(service, isNot(contains('setShortCriticalText')));
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

  test('service honors FGS start contract and keeps alive on status', () {
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'TransferNotificationPlugin.kt',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'TransferForegroundService.kt',
    ).readAsStringSync();

    String branch(String start, String end) {
      final s = service.indexOf(start);
      expect(s, greaterThanOrEqualTo(0), reason: '未找到分支: $start');
      final e = service.indexOf(end, s);
      expect(e, greaterThan(s), reason: '未找到分支终点: $end');
      return service.substring(s, e);
    }

    // 停滞/部分收尾走 COMMAND_STATUS:startForeground 更新文案,服务保活
    // (不 stopSelf),后台恢复时进度更新无需重新拉起 FGS。
    final status = branch('COMMAND_STATUS ->', 'COMMAND_TERMINAL ->');
    expect(status, contains('startForeground('));
    expect(status, isNot(contains('stopSelf()')),
        reason: '状态更新不得停止服务');

    // startForegroundService 契约:终态/取消命令冷启动服务时也必须先
    // startForeground 一次再退场,否则 Android P+ 抛 RemoteServiceException。
    final terminal = branch('COMMAND_TERMINAL ->', 'COMMAND_CANCEL ->');
    expect(terminal, contains('startForeground('),
        reason: '终态命令须先 startForeground 满足启动契约');
    final cancel = branch('COMMAND_CANCEL ->', 'return START_NOT_STICKY');
    expect(cancel, contains('startForeground('),
        reason: '取消命令须先 startForeground 满足启动契约');

    expect(plugin, contains('"showStatus"'));
    expect(plugin, contains('COMMAND_STATUS'));
  });
}
