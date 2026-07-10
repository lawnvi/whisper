import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';

enum FileDropFeedbackState { hidden, accepted, rejected }

Future<bool> sendDroppedFilesSequentially<T>(
  Iterable<T> files,
  Future<bool> Function(T file) send,
) async {
  for (final file in files) {
    if (!await send(file)) {
      return false;
    }
  }
  return true;
}

class FileDropFeedback extends StatelessWidget {
  static const overlayKey = ValueKey('file-drop-feedback-overlay');

  const FileDropFeedback({
    super.key,
    required this.state,
    required this.deviceName,
    required this.child,
    this.rejectedMessage,
  });

  final FileDropFeedbackState state;
  final String deviceName;
  final String? rejectedMessage;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (state != FileDropFeedbackState.hidden)
          Positioned.fill(child: _buildOverlay(context)),
      ],
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final accepted = state == FileDropFeedbackState.accepted;
    final message = accepted
        ? l10n.fileDropAccepted(deviceName)
        : (rejectedMessage ?? l10n.fileDropRejected);
    final accent = accepted ? colorScheme.primary : colorScheme.error;

    return IgnorePointer(
      child: Semantics(
        key: overlayKey,
        container: true,
        liveRegion: true,
        label: message,
        child: ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.surfaceElevated.withValues(alpha: 0.94),
              border: Border.all(color: accent, width: 2),
              borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      accepted
                          ? Icons.upload_file_outlined
                          : Icons.block_outlined,
                      color: accent,
                      size: 32,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        message,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: colorScheme.onSurface,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
