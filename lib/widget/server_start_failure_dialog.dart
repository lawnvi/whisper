import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/server_start_failure.dart';
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
      final description = switch (classifyServerStartFailure(error)) {
        ServerStartFailure.addressInUse => l10n.serverPortInUse(port),
        ServerStartFailure.permissionDenied => l10n.serverPermissionDenied,
        ServerStartFailure.unavailable => l10n.serverUnavailableHelp,
      };
      return WhisperGlassDialog(
        title: Text(
          l10n.startServerFailed,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: SingleChildScrollView(child: Text(description)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, ServerStartRecovery.settings),
            child: Text(l10n.setting),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ServerStartRecovery.retry),
            child: Text(l10n.retry),
          ),
        ],
      );
    },
  );
}
