import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/server_start_failure.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_dialog.dart';

enum ServerStartRecovery { retry, settings }

Future<ServerStartRecovery?> showServerStartFailureDialog(
  BuildContext context, {
  required Object? error,
  required int port,
}) {
  return showWhisperDialog<ServerStartRecovery>(
    context,
    builder: (context) {
      final l10n = AppLocalizations.of(context)!;
      final theme = Theme.of(context);
      final palette = context.whisperPalette;
      final description = switch (classifyServerStartFailure(error)) {
        ServerStartFailure.addressInUse => l10n.serverPortInUse(port),
        ServerStartFailure.permissionDenied => l10n.serverPermissionDenied,
        ServerStartFailure.unavailable => l10n.serverUnavailableHelp,
      };
      return AlertDialog(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: palette.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        scrollable: true,
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 12),
        actionsOverflowButtonSpacing: 4,
        titleTextStyle: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: theme.textTheme.bodyMedium?.copyWith(
          color: palette.textMuted,
          height: 1.5,
        ),
        title: Text(l10n.startServerFailed),
        content: Text(description),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: palette.textMuted),
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, ServerStartRecovery.settings),
            child: Text(l10n.setting),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ServerStartRecovery.retry),
            child: Text(l10n.retry),
          ),
        ],
      );
    },
  );
}
