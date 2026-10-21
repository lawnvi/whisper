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

  /// The island drawn over other apps while Whisper is in the background:
  /// whether this phone needs it (one that shows live updates as its own
  /// island does not) and whether Whisper may draw over other apps.
  static Future<({bool needed, bool allowed})> islandOverlay() async {
    if (!Platform.isAndroid) {
      return (needed: false, allowed: false);
    }
    final state = await _channel.invokeMapMethod<String, Object?>(
      'islandOverlay',
    );
    return (
      needed: state?['needed'] == true,
      allowed: state?['allowed'] == true,
    );
  }

  /// Opens the system page where the user lets Whisper draw over other
  /// apps (only they can).
  static Future<bool> requestIslandOverlay() async {
    if (!Platform.isAndroid) {
      return false;
    }
    return await _channel.invokeMethod<bool>('requestIslandOverlay') ?? false;
  }
}
