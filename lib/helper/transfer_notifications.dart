import 'dart:io';

import 'package:flutter/services.dart';
import 'package:whisper/helper/notification_l10n.dart';
import 'package:whisper/helper/transfer_notification_aggregator.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/page/remote_files/files_copy_island.dart';
import 'package:whisper/remote_files/fs_copies.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/widget/island/transfer_names.dart';

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

  /// Copies made in the file manager: one paste is named by its files and
  /// where they go, not "N files" (and never by a staging path).
  FileCopies Function() copies = () => FileCopies.shared;

  /// File names as the conversation shows them, for a single transfer.
  TransferNames names = TransferNames.shared;

  /// The latest update of each transfer the notification follows.
  final _snapshots = <String, TransferSnapshot>{};

  AppLocalizations get _l10n => resolveNotificationL10n();

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
    final aggregator = _ensureAggregator();
    final before = aggregator.trackedIds;
    _snapshots[snapshot.transferId] = snapshot;
    final raw = aggregator.onSnapshot(snapshot);
    // The generation this update belongs to (all of it, also when this
    // update just closed it).
    final ids = {...before, ...aggregator.trackedIds};
    final command = raw == null ? null : _named(raw, ids, _l10n);
    _snapshots.removeWhere((id, _) => !aggregator.trackedIds.contains(id));
    if (command == null) {
      return;
    }
    final l10n = _l10n;
    switch (command.kind) {
      case TransferNotificationKind.progress:
        _channel.invokeMethod<void>('showProgress', <String, Object?>{
          'title': command.title,
          'text': command.text,
          'progress': command.progress,
          'channelName': l10n.notificationChannelTransfer,
          'channelDescription': l10n.notificationChannelTransferDesc,
        });
        break;
      case TransferNotificationKind.interrupted:
      case TransferNotificationKind.terminalPartial:
        // 停滞/部分收尾不是生命周期终结:更新文案但保留聚合器与前台
        // 服务(showStatus 不 stopSelf)。停服务只在整代终结时发生,
        // 否则后台恢复无法刷新通知,且已停服务再收终态命令会违反
        // startForegroundService 契约直接崩溃(R3)。
        _channel.invokeMethod<void>(
            'showStatus', _summaryArguments(command, l10n));
        break;
      case TransferNotificationKind.terminal:
        _channel.invokeMethod<void>(
            'showTerminal', _summaryArguments(command, l10n));
        _aggregator = null;
        break;
      case TransferNotificationKind.cancel:
        _channel.invokeMethod<void>('cancel');
        _aggregator = null;
        break;
    }
  }

  /// One paste in the file manager is named by its files and says where
  /// they go; a single file by its name; anything else stays "N files".
  TransferNotificationCommand _named(
    TransferNotificationCommand command,
    Set<String> ids,
    AppLocalizations l10n,
  ) {
    if (command.kind == TransferNotificationKind.cancel) {
      return command;
    }
    final batch = _batchOf(ids);
    if (batch != null) {
      var text = command.text;
      if (command.kind == TransferNotificationKind.progress) {
        text = [
          copyRoute(l10n, batch),
          '${command.progress}%',
          if (batch.speed >= 1) '${copySize(batch.speed.round())}/s',
        ].join(' · ');
      }
      return _retitled(command, copyTitle(l10n, batch), text);
    }
    if (ids.length == 1) {
      final snapshot = _snapshots[ids.single];
      final name = snapshot == null ? null : names.nameOf(snapshot);
      if (name != null) {
        return _retitled(command, name, command.text);
      }
    }
    return command;
  }

  FileCopyBatch? _batchOf(Set<String> ids) {
    FileCopyBatch? found;
    final batches = copies().batches;
    for (final id in ids) {
      FileCopyBatch? owner;
      for (final batch in batches) {
        if (batch.transfers.containsKey(id)) {
          owner = batch;
          break;
        }
      }
      if (owner == null || (found != null && !identical(found, owner))) {
        return null;
      }
      found = owner;
    }
    return found;
  }

  static TransferNotificationCommand _retitled(
    TransferNotificationCommand command,
    String title,
    String text,
  ) => TransferNotificationCommand(
    kind: command.kind,
    title: title,
    text: text,
    progress: command.progress,
    success: command.success,
  );

  Map<String, Object?> _summaryArguments(
      TransferNotificationCommand command, AppLocalizations l10n) {
    return <String, Object?>{
      'title': command.title,
      'text': command.text,
      'success': command.success,
      'channelName': l10n.notificationChannelTransfer,
      'channelDescription': l10n.notificationChannelTransferDesc,
    };
  }

  @override
  void onError(String message) {}

  @override
  void onNotice(String message) {}

  @override
  void onMessage(MessageData messageData) {}

  @override
  void onClose() {}

  @override
  void onConnect() {}

  @override
  void onPairing(
    PairingRequest request,
    void Function(bool) resolve,
  ) {}

  @override
  void afterAuth(bool allow, DeviceData? device) {}
}
