import 'package:flutter/material.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/widget/app_dialogs.dart' as app_dialogs;

/// Asks whether to release a failing connection and disconnects only the
/// affected peer (never all connected devices).
///
/// When the error carries no [peerId], only shows an error toast instead of
/// guessing a peer to disconnect.
Future<void> confirmReleasePeerConnection(
  BuildContext context, {
  String? peerId,
  String? cancelButtonText,
}) async {
  final l10n = AppLocalizations.of(context);
  final target = peerId ?? '';
  if (target.isEmpty) {
    showAppToast(
      l10n?.connectFailed ?? 'Connection Failed',
      tone: AppToastTone.error,
    );
    return;
  }
  final confirmed = await app_dialogs.confirmAction(
    context,
    title: l10n?.timeoutTitle ?? '是否释放连接',
    description: l10n?.connectFailed ?? 'Connection Failed',
    confirmButtonText: l10n?.disconnect ?? '断开',
    cancelButtonText: cancelButtonText ?? l10n?.cancel ?? '取消',
  );
  if (confirmed) {
    await WsSvrManager().disconnectPeer(target);
  }
}
