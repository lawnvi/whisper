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

enum AndroidKeepAliveReason { lanServer, activeSession }

/// Merges independent keep-alive owners so a session disconnect cannot stop
/// the foreground service while the LAN server is still accepting peers.
class AndroidBackgroundKeepAliveCoordinator {
  AndroidBackgroundKeepAliveCoordinator({
    bool? isAndroid,
    Future<void> Function(AndroidKeepAliveNotification notification)? start,
    Future<void> Function()? stop,
  })  : _isAndroid = isAndroid ?? Platform.isAndroid,
        _start = start ?? _startKeepAliveNotification,
        _stop = stop ?? stopAndroidBackgroundKeepAlive;

  static final AndroidBackgroundKeepAliveCoordinator shared =
      AndroidBackgroundKeepAliveCoordinator();

  final bool _isAndroid;
  final Future<void> Function(AndroidKeepAliveNotification notification) _start;
  final Future<void> Function() _stop;
  final Set<AndroidKeepAliveReason> _activeReasons = <AndroidKeepAliveReason>{};
  Future<void> _operation = Future<void>.value();
  AndroidKeepAliveNotification? _notification;
  bool _enabled = false;

  bool get shouldRun => _enabled && _activeReasons.isNotEmpty;

  Future<void> setEnabled(
    bool enabled, {
    AndroidKeepAliveNotification? notification,
  }) {
    _enabled = enabled;
    if (notification != null) {
      _notification = notification;
    }
    return _synchronize();
  }

  Future<void> setReason(
    AndroidKeepAliveReason reason,
    bool active, {
    AndroidKeepAliveNotification? notification,
  }) {
    if (active) {
      _activeReasons.add(reason);
    } else {
      _activeReasons.remove(reason);
    }
    if (notification != null) {
      _notification = notification;
    }
    return _synchronize();
  }

  Future<void> _synchronize() {
    if (!_isAndroid) {
      return Future<void>.value();
    }
    _operation = _operation.catchError((_) {}).then((_) async {
      if (!shouldRun) {
        await _stop();
        return;
      }
      final notification = _notification ?? _defaultNotification();
      await _start(notification);
    });
    return _operation;
  }

  AndroidKeepAliveNotification _defaultNotification() {
    final l10n = resolveNotificationL10n();
    return AndroidKeepAliveNotification(
      title: l10n.androidBackgroundKeepAliveActiveTitle,
      description: l10n.androidBackgroundKeepAliveActiveDesc,
    );
  }
}

Future<void> _startKeepAliveNotification(
  AndroidKeepAliveNotification notification,
) {
  return startAndroidBackgroundKeepAlive(
    title: notification.title,
    description: notification.description,
    progress: notification.progress,
    indeterminateProgress: notification.indeterminateProgress,
  );
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
