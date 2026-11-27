import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/widget/app_dialogs.dart' as app_dialogs;

/// Asks whether to release a failing connection and disconnects only the
/// affected peer (never all connected devices).
Future<void> confirmReleasePeerConnection(
  BuildContext context, {
  String? peerId,
  String? fallbackPeerId,
  String? cancelButtonText,
}) async {
  final target = peerId?.isNotEmpty == true ? peerId! : (fallbackPeerId ?? '');
  final l10n = AppLocalizations.of(context);
  final confirmed = await app_dialogs.confirmAction(
    context,
    title: l10n?.timeoutTitle ?? '是否释放连接',
    description: l10n?.connectFailed ?? 'Connection Failed',
    confirmButtonText: l10n?.disconnect ?? '断开',
    cancelButtonText: cancelButtonText ?? l10n?.cancel ?? '取消',
  );
  if (confirmed && target.isNotEmpty) {
    await WsSvrManager().disconnectPeer(target);
  }
}
