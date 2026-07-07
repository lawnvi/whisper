import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:whisper/helper/connection_request_notification_dismissal.dart';
import 'package:whisper/helper/connection_request_registry.dart';
import 'package:whisper/helper/notification_l10n.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/socket/guarded_auth_callback.dart';

/// 后台 isolate 中的通知 action 回调:把决定送回主 isolate。
/// 主 isolate 端口不存在时进程已重启,pending 请求必然失效,
/// 原地把通知更新为"已过期"。
@pragma('vm:entry-point')
Future<void> connectionRequestNotificationBackgroundHandler(
    NotificationResponse response) async {
  final requestId = response.payload;
  if (requestId == null || requestId.isEmpty) {
    return;
  }
  final port =
      IsolateNameServer.lookupPortByName(ConnectionRequestNotifier.portName);
  if (port != null) {
    port.send(<String, Object?>{
      'requestId': requestId,
      'allow': response.actionId == ConnectionRequestNotifier.acceptActionId,
    });
    return;
  }
  await ConnectionRequestNotifier.showExpired(
    FlutterLocalNotificationsPlugin(),
    requestId,
  );
}

class ConnectionRequestNotifier {
  static final ConnectionRequestNotifier _instance =
      ConnectionRequestNotifier._internal();

  factory ConnectionRequestNotifier() => _instance;

  ConnectionRequestNotifier._internal();

  static const String portName = 'whisper.connect_request.port';
  static const String acceptActionId = 'whisper_connect_accept';
  static const String rejectActionId = 'whisper_connect_reject';
  static const String channelId = 'whisper.connect_request';

  final ConnectionRequestRegistry registry = ConnectionRequestRegistry();
  final ConnectionRequestNotificationDismissal _dismissal =
      ConnectionRequestNotificationDismissal();
  FlutterLocalNotificationsPlugin? _plugin;
  ReceivePort? _receivePort;

  static int notificationIdForPeer(String peerId) =>
      20000 + (peerId.hashCode.abs() % 1000);

  static String _peerIdOfRequest(String requestId) =>
      requestId.split('#').first;

  AppLocalizations get _l10n => resolveNotificationL10n();

  Future<void> initialize(FlutterLocalNotificationsPlugin plugin) async {
    if (!Platform.isAndroid) {
      return;
    }
    _plugin = plugin;
    IsolateNameServer.removePortNameMapping(portName);
    final port = ReceivePort();
    IsolateNameServer.registerPortWithName(port.sendPort, portName);
    port.listen((message) {
      if (message is Map) {
        _resolve(message['requestId'] as String? ?? '',
            message['allow'] as bool? ?? false);
      }
    });
    _receivePort = port;
  }

  /// app 非前台(Android)才发系统通知;前台仍走应用内弹窗。
  Future<void> maybeShowForAuthRequest({
    required String peerId,
    required String deviceName,
    required String host,
    required GuardedAuthCallback callback,
  }) async {
    final plugin = _plugin;
    if (!Platform.isAndroid || plugin == null || peerId.isEmpty) {
      return;
    }
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    _dismissal.cancelPending(peerId);
    final requestId = registry.register(peerId, callback);
    final l10n = _l10n;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        l10n.connectRequest,
        channelDescription: l10n.connectRequest,
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.call,
        autoCancel: false,
        ongoing: true,
        onlyAlertOnce: true,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            acceptActionId,
            l10n.allow,
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            rejectActionId,
            l10n.refuse,
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      ),
    );
    await plugin.show(
      notificationIdForPeer(peerId),
      l10n.connectRequest,
      l10n.connectRequestNotificationBody(deviceName, host),
      details,
      payload: requestId,
    );
  }

  /// 前台(主 isolate)action 响应入口。
  void handleNotificationResponse(NotificationResponse response) {
    final requestId = response.payload;
    if (requestId == null ||
        (response.actionId != acceptActionId &&
            response.actionId != rejectActionId)) {
      return;
    }
    _resolve(requestId, response.actionId == acceptActionId);
  }

  Future<void> dismissForPeer(
    String peerId, {
    int graceMillis = 0,
  }) async {
    if (graceMillis > 0) {
      _dismissal.schedule(
        peerId,
        graceMillis: graceMillis,
        onDismiss: () {
          registry.removeForPeer(peerId);
          unawaited(_plugin?.cancel(notificationIdForPeer(peerId)));
        },
      );
      return;
    }
    _dismissal.cancelPending(peerId);
    registry.removeForPeer(peerId);
    await _plugin?.cancel(notificationIdForPeer(peerId));
  }

  void _resolve(String requestId, bool allow) {
    if (requestId.isEmpty) {
      return;
    }
    final handled = registry.resolve(requestId, allow);
    if (!handled) {
      // 请求已在别处处理或已失效:原地转"已过期",不静默吞掉。
      final plugin = _plugin;
      if (plugin != null) {
        showExpired(plugin, requestId);
      }
      return;
    }
    final peerId = _peerIdOfRequest(requestId);
    _dismissal.cancelPending(peerId);
    _plugin?.cancel(notificationIdForPeer(peerId));
  }

  static Future<void> showExpired(
      FlutterLocalNotificationsPlugin plugin, String requestId) async {
    final l10n = resolveNotificationL10n();
    await plugin.show(
      notificationIdForPeer(_peerIdOfRequest(requestId)),
      l10n.connectRequest,
      l10n.connectRequestExpired,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          l10n.connectRequest,
          importance: Importance.low,
          priority: Priority.low,
          autoCancel: true,
        ),
      ),
    );
  }
}
