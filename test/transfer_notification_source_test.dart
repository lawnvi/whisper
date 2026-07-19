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
    final unified = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'UnifiedForegroundNotification.kt',
    ).readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final mainActivity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();

    // Android 16+ Live Updates 与降级链
    expect(unified, contains('NotificationCompat.ProgressStyle'));
    expect(unified, contains('setRequestPromotedOngoing'));
    expect(unified, contains('canPostPromotedNotifications'));
    expect(unified, contains('Build.VERSION.SDK_INT >= 36'));
    expect(unified, contains('.setProgress(100,')); // 15- 降级
    expect(unified, isNot(contains('setShortCriticalText')));
    expect(unified, contains('setOnlyAlertOnce(true)'));
    expect(service, contains('STOP_FOREGROUND_DETACH'));

    // FGS 从后台启动失败的兜底
    expect(plugin, contains('ForegroundServiceStartNotAllowedException'));
    expect(plugin, contains("com.vireen.whisper/transfer_notifications"));
    expect(plugin, contains('TransferForegroundService.deliverToRunning'));

    expect(manifest, contains('TransferForegroundService'));
    expect(
      manifest,
      contains('android.permission.POST_PROMOTED_NOTIFICATIONS'),
    );
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
    expect(status, isNot(contains('stopSelf()')), reason: '状态更新不得停止服务');

    // startForegroundService 契约:终态/取消命令冷启动服务时也必须先
    // startForeground 一次再退场,否则 Android P+ 抛 RemoteServiceException。
    final terminal = branch('COMMAND_TERMINAL ->', 'COMMAND_CANCEL ->');
    expect(
      terminal,
      contains('startForeground('),
      reason: '终态命令须先 startForeground 满足启动契约',
    );
    expect(terminal, contains('beginStopping()'));
    expect(
      terminal.indexOf('beginStopping()'),
      lessThan(terminal.indexOf('stopSelf()')),
      reason: '请求停止前必须先关闭直投窗口',
    );
    final cancel = branch('COMMAND_CANCEL ->', '// Android 15+');
    expect(
      cancel,
      contains('startForeground('),
      reason: '取消命令须先 startForeground 满足启动契约',
    );
    expect(cancel, contains('beginStopping()'));
    expect(
      cancel.indexOf('beginStopping()'),
      lessThan(cancel.indexOf('stopSelf()')),
      reason: '取消停止前必须先关闭直投窗口',
    );

    expect(plugin, contains('"showStatus"'));
    expect(plugin, contains('COMMAND_STATUS'));
  });

  test(
    'terminal transfer state clears receiving text before service exits',
    () {
      final service = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'TransferForegroundService.kt',
      ).readAsStringSync();
      final unified = File(
        'android/app/src/main/kotlin/com/vireen/whisper/'
        'UnifiedForegroundNotification.kt',
      ).readAsStringSync();

      expect(service, contains('UnifiedForegroundNotification.finishTransfer'));
      final finish = unified.indexOf('fun finishTransfer');
      final clear = unified.indexOf('transfer = null', finish);
      final rebuild = unified.indexOf('buildCurrent(context)', finish);
      expect(clear, greaterThan(finish));
      expect(clear, lessThan(rebuild), reason: '完成时必须先移除传输状态，不能继续显示“接收中”');
    },
  );
}
