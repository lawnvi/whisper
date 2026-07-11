import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/connection_request_notification_dismissal.dart';
import 'package:whisper/helper/notification_l10n.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/pairing_request.dart';

const String pairingApproveNotificationAction = 'whisper.pairing.approve';
const String pairingRejectNotificationAction = 'whisper.pairing.reject';
const String pairingCancelNotificationAction = 'whisper.pairing.cancel';
const String pairingViewNotificationAction = 'whisper.pairing.view';

const String _pairingActionPortName = 'whisper.pairing.notification.actions';

List<String> pairingNotificationActionIds(PairingRequest request) {
  if (request.isInitiator) {
    return const <String>[pairingCancelNotificationAction];
  }
  if (request.reason == PairingReason.identityChanged) {
    return const <String>[
      pairingRejectNotificationAction,
      pairingViewNotificationAction,
    ];
  }
  return const <String>[
    pairingRejectNotificationAction,
    pairingApproveNotificationAction,
  ];
}

bool? pairingNotificationDecisionForAction(String actionId) =>
    switch (actionId) {
      pairingApproveNotificationAction => true,
      pairingRejectNotificationAction ||
      pairingCancelNotificationAction =>
        false,
      _ => null,
    };

String formatPairingNotificationCode(String code) =>
    code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

bool pairingNotificationUsesIncomingCallStyle(PairingRequest request) =>
    !request.isInitiator && request.reason != PairingReason.identityChanged;

final class ConnectionRequestNotificationActionRouter {
  final Map<String, _PendingPairingNotification> _pendingByToken =
      <String, _PendingPairingNotification>{};
  final Map<String, Set<String>> _tokensByPeer = <String, Set<String>>{};

  Set<int> register({
    required String token,
    required String peerId,
    required int notificationId,
    required Set<String> allowedActionIds,
    required void Function(bool) resolve,
  }) {
    removeToken(token);
    final replacedNotificationIds = removePeer(peerId);
    _pendingByToken[token] = _PendingPairingNotification(
      peerId: peerId,
      notificationId: notificationId,
      allowedActionIds: allowedActionIds,
      resolve: resolve,
    );
    _tokensByPeer.putIfAbsent(peerId, () => <String>{}).add(token);
    return replacedNotificationIds;
  }

  bool dispatch({
    required int? notificationId,
    required String actionId,
    required String token,
  }) {
    final pending = _pendingByToken[token];
    if (pending == null ||
        notificationId != pending.notificationId ||
        !pending.allowedActionIds.contains(actionId)) {
      return false;
    }
    final decision = pairingNotificationDecisionForAction(actionId);
    if (decision == null) {
      return false;
    }
    removeToken(token);
    pending.resolve(decision);
    return true;
  }

  bool removeToken(String token) {
    final pending = _pendingByToken.remove(token);
    if (pending == null) {
      return false;
    }
    final tokens = _tokensByPeer[pending.peerId];
    tokens?.remove(token);
    if (tokens?.isEmpty ?? false) {
      _tokensByPeer.remove(pending.peerId);
    }
    return true;
  }

  Set<int> removePeer(String peerId) {
    final tokens = _tokensByPeer.remove(peerId);
    if (tokens == null) {
      return const <int>{};
    }
    final notificationIds = <int>{};
    for (final token in tokens) {
      final pending = _pendingByToken.remove(token);
      if (pending != null) {
        notificationIds.add(pending.notificationId);
      }
    }
    return notificationIds;
  }
}

@pragma('vm:entry-point')
void connectionRequestNotificationTapBackground(
  NotificationResponse response,
) {
  IsolateNameServer.lookupPortByName(_pairingActionPortName)?.send(
    <Object?>[response.id, response.actionId, response.payload],
  );
}

/// Shows a background-only pairing alert whose actions remain bound to the
/// exact in-memory handshake that created it.
class ConnectionRequestNotifier {
  static final ConnectionRequestNotifier _instance =
      ConnectionRequestNotifier._internal();

  factory ConnectionRequestNotifier() => _instance;

  ConnectionRequestNotifier._internal();

  static const String channelId = 'whisper.connect_request';
  static const List<String> _obsoleteChannelIds = <String>[
    'whisper.connect_request.alerts.v2',
    'whisper.connect_request.calls',
  ];
  static const MethodChannel _nativeChannel =
      MethodChannel('com.vireen.whisper/connection_request_notifications');
  static const Uuid _uuid = Uuid();

  final ConnectionRequestNotificationDismissal _dismissal =
      ConnectionRequestNotificationDismissal();
  final ConnectionRequestNotificationActionRouter _actionRouter =
      ConnectionRequestNotificationActionRouter();
  FlutterLocalNotificationsPlugin? _plugin;
  ReceivePort? _actionPort;

  static int notificationIdForToken(String token) {
    var hash = 0x811C9DC5;
    for (final byte in utf8.encode(token)) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
    return 20000 + (hash & 0x3FFFFFFF);
  }

  Future<void> initialize(FlutterLocalNotificationsPlugin plugin) async {
    if (Platform.isAndroid) {
      _plugin = plugin;
      final l10n = resolveNotificationL10n();
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final obsoleteChannelId in _obsoleteChannelIds) {
        await android?.deleteNotificationChannel(obsoleteChannelId);
      }
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          channelId,
          l10n.connectRequest,
          description: l10n.connectRequest,
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
      try {
        final active = await plugin.getActiveNotifications();
        for (final notification in active) {
          if (notification.channelId == channelId && notification.id != null) {
            await plugin.cancel(notification.id!);
          }
        }
      } on Object {
        // Stale cleanup is best-effort and must not block app startup.
      }
      if (_actionPort == null) {
        final port = ReceivePort();
        IsolateNameServer.removePortNameMapping(_pairingActionPortName);
        if (IsolateNameServer.registerPortWithName(
          port.sendPort,
          _pairingActionPortName,
        )) {
          _actionPort = port;
          port.listen(_handleBackgroundActionMessage);
        } else {
          port.close();
        }
      }
    }
  }

  Future<void> maybeShowForPairing({
    required PairingRequest request,
    required void Function(bool) resolve,
  }) async {
    final plugin = _plugin;
    final peerId = request.device.uid;
    if (!Platform.isAndroid || plugin == null || peerId.isEmpty) {
      return;
    }
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    _dismissal.cancelPending(peerId);

    final l10n = resolveNotificationL10n();
    final code = formatPairingNotificationCode(request.pairingCode);
    final title = switch (request.reason) {
      PairingReason.newDevice => l10n.pairingNewDeviceTitle,
      PairingReason.identityChanged => l10n.pairingIdentityChangedTitle,
      PairingReason.legacyTrustWithoutPin => l10n.pairingLegacyTrustTitle,
    };
    final body = request.isInitiator
        ? l10n.pairingInitiatorNotificationBody(request.device.name, code)
        : request.reason == PairingReason.identityChanged
            ? l10n.pairingIdentityChangedNotificationBody(
                request.device.name,
                code,
              )
            : l10n.pairingNotificationBody(request.device.name, code);
    final fallbackTitle =
        request.isInitiator || request.reason == PairingReason.identityChanged
            ? title
            : request.device.name;
    final fallbackBody =
        !request.isInitiator && request.reason != PairingReason.identityChanged
            ? l10n.pairingCodeSemantics(code)
            : body;
    final actionIds = pairingNotificationActionIds(request);
    final token = _uuid.v4();
    final notificationId = notificationIdForToken(token);
    final payload = jsonEncode(<String, Object>{'version': 1, 'token': token});
    final replacedDuringRegistration = _actionRouter.register(
      token: token,
      peerId: peerId,
      notificationId: notificationId,
      allowedActionIds: actionIds.toSet(),
      resolve: resolve,
    );
    for (final replacedId in replacedDuringRegistration) {
      await plugin.cancel(replacedId);
    }
    var requestCancelled = false;
    final cancellation = request.cancellation;
    if (cancellation != null) {
      unawaited(cancellation.whenComplete(() {
        requestCancelled = true;
        final notificationCancellation = _actionRouter.removeToken(token)
            ? _plugin?.cancel(notificationId)
            : null;
        if (notificationCancellation != null) {
          unawaited(notificationCancellation.catchError((_) {}));
        }
      }));
    }

    try {
      final useIncomingCallStyle =
          pairingNotificationUsesIncomingCallStyle(request);
      final shownAsIncomingCall = useIncomingCallStyle &&
          await _showIncomingCallStyle(
            notificationId: notificationId,
            request: request,
            title: title,
            body: body,
            formattedCode: code,
            payload: payload,
            l10n: l10n,
          );
      if (!shownAsIncomingCall) {
        await plugin.show(
          notificationId,
          fallbackTitle,
          fallbackBody,
          NotificationDetails(
            android: AndroidNotificationDetails(
              channelId,
              l10n.connectRequest,
              channelDescription: l10n.connectRequest,
              icon: 'ic_stat_whisper',
              importance: Importance.max,
              priority: Priority.max,
              category: request.isInitiator
                  ? AndroidNotificationCategory.status
                  : AndroidNotificationCategory.call,
              autoCancel: false,
              ongoing: true,
              onlyAlertOnce: true,
              visibility: NotificationVisibility.private,
              timeoutAfter: 30000,
              styleInformation: BigTextStyleInformation(fallbackBody),
              actions: actionIds
                  .map(
                    (actionId) => _androidAction(
                      actionId,
                      l10n: l10n,
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          payload: payload,
        );
      }
      if (requestCancelled) {
        await plugin.cancel(notificationId);
      }
    } on Object {
      _actionRouter.removeToken(token);
      rethrow;
    }
  }

  Future<bool> _showIncomingCallStyle({
    required int notificationId,
    required PairingRequest request,
    required String title,
    required String body,
    required String formattedCode,
    required String payload,
    required AppLocalizations l10n,
  }) async {
    try {
      return await _nativeChannel.invokeMethod<bool>(
            'showIncoming',
            <String, Object>{
              'notificationId': notificationId,
              'peerId': request.device.uid,
              'deviceName': request.device.name,
              'pairingCode': formattedCode,
              'verificationText': l10n.pairingCodeSemantics(formattedCode),
              'title': title,
              'body': body,
              'payload': payload,
              'rejectActionId': pairingRejectNotificationAction,
              'answerActionId': pairingApproveNotificationAction,
              'answerShowsUserInterface': false,
              'channelName': l10n.connectRequest,
              'channelDescription': l10n.connectRequest,
            },
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  AndroidNotificationAction _androidAction(
    String actionId, {
    required AppLocalizations l10n,
  }) {
    return switch (actionId) {
      pairingApproveNotificationAction => AndroidNotificationAction(
          actionId,
          l10n.pairingApprove,
          titleColor: const Color(0xFF16A34A),
        ),
      pairingRejectNotificationAction => AndroidNotificationAction(
          actionId,
          l10n.pairingReject,
          titleColor: const Color(0xFFDC2626),
        ),
      pairingCancelNotificationAction => AndroidNotificationAction(
          actionId,
          l10n.cancel,
          titleColor: const Color(0xFFDC2626),
        ),
      pairingViewNotificationAction => AndroidNotificationAction(
          actionId,
          l10n.pairingViewDetails,
          showsUserInterface: true,
          cancelNotification: false,
        ),
      _ => throw StateError('Unsupported pairing notification action'),
    };
  }

  void handleNotificationResponse(NotificationResponse response) {
    _handleAction(response.id, response.actionId, response.payload);
  }

  void _handleBackgroundActionMessage(dynamic message) {
    if (message is! List || message.length != 3) {
      return;
    }
    final notificationId = message[0];
    final actionId = message[1];
    final payload = message[2];
    if ((notificationId != null && notificationId is! int) ||
        (actionId != null && actionId is! String) ||
        (payload != null && payload is! String)) {
      return;
    }
    _handleAction(
      notificationId as int?,
      actionId as String?,
      payload as String?,
    );
  }

  void _handleAction(
    int? notificationId,
    String? actionId,
    String? payload,
  ) {
    if (actionId == null ||
        actionId.isEmpty ||
        actionId == pairingViewNotificationAction) {
      return;
    }
    final token = _tokenFromPayload(payload);
    if (token == null) {
      return;
    }
    final handled = _actionRouter.dispatch(
      notificationId: notificationId,
      actionId: actionId,
      token: token,
    );
    if (!handled) {
      return;
    }
    final cancellation = _plugin?.cancel(notificationId!);
    if (cancellation != null) {
      unawaited(cancellation.catchError((_) {}));
    }
  }

  String? _tokenFromPayload(String? payload) {
    if (payload == null || payload.length > 256) {
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        return null;
      }
      final token = decoded['token'];
      return token is String && token.length <= 64 ? token : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> dismissForPeer(
    String peerId, {
    int graceMillis = 0,
  }) async {
    final notificationIds = _actionRouter.removePeer(peerId);
    if (graceMillis > 0) {
      _dismissal.schedule(
        peerId,
        graceMillis: graceMillis,
        onDismiss: () {
          for (final notificationId in notificationIds) {
            final cancellation = _plugin?.cancel(notificationId);
            if (cancellation != null) {
              unawaited(cancellation.catchError((_) {}));
            }
          }
        },
      );
      return;
    }
    _dismissal.cancelPending(peerId);
    for (final notificationId in notificationIds) {
      await _plugin?.cancel(notificationId);
    }
  }
}

final class _PendingPairingNotification {
  const _PendingPairingNotification({
    required this.peerId,
    required this.notificationId,
    required this.allowedActionIds,
    required this.resolve,
  });

  final String peerId;
  final int notificationId;
  final Set<String> allowedActionIds;
  final void Function(bool) resolve;
}
