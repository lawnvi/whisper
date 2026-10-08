import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/glass_dialog.dart';

/// Null cancels, true deletes received files, false keeps all files.
Future<bool?> showMessageDeletionDialog(
  BuildContext context, {
  required int count,
  required bool hasReceivedFiles,
}) {
  return showWhisperDialog<bool>(
    context,
    builder: (_) => _MessageDeletionDialog(
      count: count,
      hasReceivedFiles: hasReceivedFiles,
    ),
  );
}

class _MessageDeletionDialog extends StatefulWidget {
  const _MessageDeletionDialog({
    required this.count,
    required this.hasReceivedFiles,
  });

  final int count;
  final bool hasReceivedFiles;

  @override
  State<_MessageDeletionDialog> createState() => _MessageDeletionDialogState();
}

class _MessageDeletionDialogState extends State<_MessageDeletionDialog> {
  bool _keepFiles = false;
  bool _closing = false;

  void _close([bool? deleteFiles]) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(deleteFiles);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.whisperPalette;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: WhisperGlassDialog(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 620),
          title: Text(
            widget.count == 1
                ? l10n?.deleteMessageTitle ?? '删除消息'
                : l10n?.deleteSelectedMessagesTitle(widget.count) ??
                      '删除 ${widget.count} 条消息',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.hasReceivedFiles
                      ? l10n?.deleteReceivedFilesDesc ??
                            '同时删除接收的本地文件，发送的源文件会保留。'
                      : l10n?.deleteSelectedMessagesDesc ?? '将删除所选消息，无法撤销。',
                  style: TextStyle(color: palette.textMuted),
                ),
                if (widget.hasReceivedFiles) ...[
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    key: const ValueKey('keep-received-files'),
                    contentPadding: EdgeInsets.zero,
                    horizontalTitleGap: 0,
                    controlAffinity: ListTileControlAffinity.leading,
                    checkboxShape: const CircleBorder(),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    title: Text(l10n?.keepReceivedFiles ?? '保留接收的文件'),
                    value: _keepFiles,
                    onChanged: (value) => setState(() => _keepFiles = value!),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            WhisperDialogButton(onPressed: _close, label: l10n?.cancel ?? '取消'),
            WhisperDialogButton(
              key: const ValueKey('confirm-message-deletion'),
              onPressed: () => _close(widget.hasReceivedFiles && !_keepFiles),
              label: l10n?.delete ?? '删除',
              prominent: true,
              destructive: true,
            ),
          ],
        ),
      ),
    );
  }
}
