import 'dart:io';

import 'package:flutter/services.dart';

class AndroidPrivacyPermission {
  AndroidPrivacyPermission._();

  static const MethodChannel _channel = MethodChannel(
    'whisper/android_privacy_permissions',
  );

  static Future<bool> requestNotificationListener() async {
    if (!Platform.isAndroid) {
      return true;
    }
    return await _channel.invokeMethod<bool>('requestNotificationListener') ??
        false;
  }

  static Future<bool> rebindNotificationListener() async {
    if (!Platform.isAndroid) {
      return true;
    }
    return await _channel.invokeMethod<bool>('rebindNotificationListener') ??
        false;
  }

  static Future<bool> requestInstalledApps() async {
    if (!Platform.isAndroid) {
      return true;
    }
    return await _channel.invokeMethod<bool>('requestInstalledApps') ?? false;
  }
}
