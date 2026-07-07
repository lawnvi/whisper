import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:whisper/helper/transfer_notification_aggregator.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/socket/svrmanager.dart';

/// 订阅 socket 传输事件,把聚合结果推给原生传输通知模块。
/// 仅 Android;进程级单例,应用启动时 attach 一次。
class TransferNotificationBridge implements ISocketEvent {
  static final TransferNotificationBridge _instance =
      TransferNotificationBridge._internal();

  factory TransferNotificationBridge() => _instance;

  TransferNotificationBridge._internal();

  static const MethodChannel _channel =
      MethodChannel('com.vireen.whisper/transfer_notifications');

  TransferNotificationAggregator? _aggregator;

  AppLocalizations get _l10n =>
      lookupAppLocalizations(PlatformDispatcher.instance.locale);

  void attach() {
    if (!Platform.isAndroid) {
      return;
    }
    WsSvrManager().registerEvent(this);
  }

  TransferNotificationAggregator _ensureAggregator() {
    final l10n = _l10n;
    return _aggregator ??= TransferNotificationAggregator(
      strings: TransferNotificationStrings(
        title: (count) => l10n.transferNotificationTitle(count),
        bodySending: (percent, speed, remaining) =>
            l10n.transferNotificationBodySending(percent, speed, remaining),
        bodyReceiving: (percent, speed, remaining) =>
            l10n.transferNotificationBodyReceiving(percent, speed, remaining),
        bodyMixed: (percent, speed, remaining) =>
            l10n.transferNotificationBodyMixed(percent, speed, remaining),
        completed: (count) => l10n.transferNotificationCompleted(count),
        interrupted: () => l10n.transferNotificationInterrupted,
      ),
    );
  }

  @override
  void onTransferUpdated(TransferSnapshot snapshot) {
    final command = _ensureAggregator().onSnapshot(snapshot);
    if (command == null) {
      return;
    }
    switch (command.kind) {
      case TransferNotificationKind.progress:
        _channel.invokeMethod<void>('showProgress', <String, Object?>{
          'title': command.title,
          'text': command.text,
          'progress': command.progress,
        });
        break;
      case TransferNotificationKind.terminal:
        _channel.invokeMethod<void>('showTerminal', <String, Object?>{
          'title': command.title,
          'text': command.text,
          'success': command.success,
        });
        _aggregator = null;
        break;
      case TransferNotificationKind.cancel:
        _channel.invokeMethod<void>('cancel');
        _aggregator = null;
        break;
    }
  }

  @override
  void onError(String message) {}

  @override
  void onNotice(String message) {}

  @override
  void onMessage(MessageData messageData) {}

  @override
  void onProgress(int size, length) {}

  @override
  void onClose() {}

  @override
  void onConnect() {}

  @override
  void onAuth(DeviceData? deviceData, bool asServer, String msg, var callback) {}

  @override
  void afterAuth(bool allow, DeviceData? device) {}
}
