import 'package:flutter/material.dart';
import 'package:whisper/helper/folder_transfer_store.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_dialog.dart';

String folderSkipReasonLabel(AppLocalizations l10n, FolderSkipReason reason) =>
    switch (reason) {
      FolderSkipReason.symlink => l10n.folderSkipSymlink,
      FolderSkipReason.special => l10n.folderSkipSpecial,
      FolderSkipReason.invalidName => l10n.folderSkipInvalidName,
      FolderSkipReason.pathTooLong => l10n.folderSkipPathTooLong,
      FolderSkipReason.tooLarge => l10n.folderSkipTooLarge,
      FolderSkipReason.unreadable => l10n.folderSkipUnreadable,
      FolderSkipReason.sourceUnavailable => l10n.folderSkipSourceUnavailable,
      FolderSkipReason.writeFailed => l10n.folderSkipWriteFailed,
      FolderSkipReason.nameCollision => l10n.folderSkipNameCollision,
      FolderSkipReason.integrity => l10n.folderSkipIntegrity,
    };

/// Lists the entries of a folder transfer that did not make it across.
/// This device knows the names of the ones it left out or could not handle
/// itself; the rest of [skippedCount] is known to the other device.
Future<void> showFolderSkippedDialog(
  BuildContext context, {
  required String transferId,
  required int skippedCount,
  FolderTransferStore store = const FolderTransferStore(),
}) async {
  final entries = await store.readSkipped(transferId);
  if (!context.mounted) return;
  await showWhisperDialog<void>(
    context,
    builder: (dialogContext) =>
        FolderSkippedDialog(entries: entries, skippedCount: skippedCount),
  );
}

class FolderSkippedDialog extends StatelessWidget {
  const FolderSkippedDialog({
    super.key,
    required this.entries,
    required this.skippedCount,
  });

  final List<FolderSkippedEntry> entries;
  final int skippedCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    final elsewhere = skippedCount - entries.length;
    return WhisperAlertDialog(
      title: l10n.folderSkippedTitle,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.path,
                    textAlign: TextAlign.start,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    folderSkipReasonLabel(l10n, entry.reason),
                    textAlign: TextAlign.start,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          if (elsewhere > 0)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                l10n.folderSkippedMore(elsewhere),
                textAlign: entries.isEmpty ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
      actions: <Widget>[
        WhisperDialogButton(
          label: l10n.confirm,
          prominent: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
