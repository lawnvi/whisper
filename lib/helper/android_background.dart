import 'dart:io';

import 'package:flutter/services.dart';
import 'package:whisper/helper/notification_l10n.dart';

const _androidBackgroundChannel =
    MethodChannel('com.vireen.whisper/android_background');

class AndroidKeepAliveNotification {
  const AndroidKeepAliveNotification({
    required this.title,
    required this.description,
    this.progress,
    this.indeterminateProgress = false,
  });

  final String title;
  final String description;
  final int? progress;
  final bool indeterminateProgress;

  Map<String, Object?> toChannelArguments() {
    final l10n = resolveNotificationL10n();
    return <String, Object?>{
      'title': title,
      'description': description,
      'progress': _clampedProgress,
      'indeterminateProgress': indeterminateProgress,
      'channelName': l10n.notificationChannelKeepAlive,
      'channelDescription': l10n.notificationChannelKeepAliveDesc,
    };
  }

  int? get _clampedProgress {
    final value = progress;
    if (value == null) {
      return null;
    }
    return value.clamp(0, 100).toInt();
  }
}

Future<void> startAndroidBackgroundKeepAlive({
  required String title,
  required String description,
  int? progress,
  bool indeterminateProgress = false,
}) async {
  if (!Platform.isAndroid) {
    return;
  }
  final notification = AndroidKeepAliveNotification(
    title: title,
    description: description,
    progress: progress,
    indeterminateProgress: indeterminateProgress,
  );
  await _androidBackgroundChannel.invokeMethod<void>(
    'startKeepAlive',
    notification.toChannelArguments(),
  );
}

Future<void> stopAndroidBackgroundKeepAlive() async {
  if (!Platform.isAndroid) {
    return;
  }
  await _androidBackgroundChannel.invokeMethod<void>('stopKeepAlive');
}

Future<void> openAndroidBatteryOptimizationSettings() async {
  if (!Platform.isAndroid) {
    return;
  }
  await _androidBackgroundChannel
      .invokeMethod<void>('openBatteryOptimizationSettings');
}
