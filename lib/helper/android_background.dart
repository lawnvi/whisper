import 'dart:io';

import 'package:flutter/services.dart';

const _androidBackgroundChannel =
    MethodChannel('com.vireen.whisper/android_background');

Future<void> startAndroidBackgroundKeepAlive({
  required String title,
  required String description,
}) async {
  if (!Platform.isAndroid) {
    return;
  }
  await _androidBackgroundChannel.invokeMethod<void>('startKeepAlive', {
    'title': title,
    'description': description,
  });
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
