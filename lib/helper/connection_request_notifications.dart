import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:whisper/helper/connection_request_notification_dismissal.dart';
import 'package:whisper/helper/notification_l10n.dart';

/// Shows a background-only pairing alert. Trust decisions always stay in the
/// in-app dialog where both devices can display and compare the signed code.
class ConnectionRequestNotifier {
  static final ConnectionRequestNotifier _instance =
      ConnectionRequestNotifier._internal();

  factory ConnectionRequestNotifier() => _instance;

  ConnectionRequestNotifier._internal();

  static const String channelId = 'whisper.connect_request';

  final ConnectionRequestNotificationDismissal _dismissal =
      ConnectionRequestNotificationDismissal();
  FlutterLocalNotificationsPlugin? _plugin;

  static int notificationIdForPeer(String peerId) =>
      20000 + (peerId.hashCode.abs() % 1000);

  Future<void> initialize(FlutterLocalNotificationsPlugin plugin) async {
    if (Platform.isAndroid) {
      _plugin = plugin;
    }
  }

  Future<void> maybeShowForPairing({required String peerId}) async {
    final plugin = _plugin;
    if (!Platform.isAndroid || plugin == null || peerId.isEmpty) {
      return;
    }
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    _dismissal.cancelPending(peerId);
    final l10n = resolveNotificationL10n();
    await plugin.show(
      notificationIdForPeer(peerId),
      l10n.connectRequest,
      l10n.pairingNotificationBody,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          l10n.connectRequest,
          channelDescription: l10n.connectRequest,
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          autoCancel: true,
          onlyAlertOnce: true,
        ),
      ),
      payload: peerId,
    );
  }

  /// A normal notification tap only opens/focuses the app. It cannot resolve
  /// the pending pairing decision.
  void handleNotificationResponse(NotificationResponse response) {}

  Future<void> dismissForPeer(
    String peerId, {
    int graceMillis = 0,
  }) async {
    if (graceMillis > 0) {
      _dismissal.schedule(
        peerId,
        graceMillis: graceMillis,
        onDismiss: () {
          final cancellation = _plugin?.cancel(notificationIdForPeer(peerId));
          if (cancellation != null) {
            unawaited(cancellation.catchError((_) {}));
          }
        },
      );
      return;
    }
    _dismissal.cancelPending(peerId);
    await _plugin?.cancel(notificationIdForPeer(peerId));
  }
}
