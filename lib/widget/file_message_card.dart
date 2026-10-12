import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/subtle_motion.dart';

/// The card a conversation shows for a file or a folder that is not
/// previewed as media: what it is, how its transfer stands, and the actions
/// that apply.
class FileMessageCard extends StatelessWidget {
  const FileMessageCard({
    super.key,
    required this.name,
    required this.isFolder,
    required this.failed,
    required this.active,
    required this.verifying,
    required this.progress,
    required this.statusKey,
    required this.statusText,
    required this.cardColor,
    required this.borderColor,
    required this.animationDuration,
    required this.retryTooltip,
    required this.cancelTooltip,
    this.skippedLabel,
    this.onShowSkipped,
    this.onRetry,
    this.onCancel,
  });

  static const skippedKey = ValueKey('file-message-card-skipped');

  final String name;
  final bool isFolder;
  final bool failed;

  /// A transfer is under way, so progress stands in for the icon.
  final bool active;
  final bool verifying;
  final double progress;

  /// Changes whenever the status line should cross-fade to a new text.
  final Object statusKey;

  /// The status line; called with the animated progress while [active].
  final String Function(double? progress) statusText;
  final Color cardColor;
  final Color borderColor;
  final Duration animationDuration;
  final String retryTooltip;
  final String cancelTooltip;

  /// For a folder some of whose entries were left out: how many, as text.
  final String? skippedLabel;
  final VoidCallback? onShowSkipped;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  Widget _animatedProgress(
    BuildContext context,
    Widget Function(BuildContext context, double value) builder,
  ) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: progress.clamp(0, 1).toDouble()),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : animationDuration,
      curve: Curves.easeOutCubic,
      builder: (context, animatedValue, child) {
        return builder(context, animatedValue.clamp(0, 1).toDouble());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final statusStyle = TextStyle(
      color: colorScheme.onSurfaceVariant,
      fontSize: 12,
    );
    final skippedLabel = this.skippedLabel;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 40,
              child: WhisperAnimatedSwitcher(
                value: failed
                    ? 'failed'
                    : active
                    ? (verifying ? 'verifying' : 'progress')
                    : 'file',
                child: failed
                    ? const Icon(
                        Icons.error_outline_rounded,
                        color: Colors.redAccent,
                        size: 24,
                      )
                    : active
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: verifying
                            ? CircularProgressIndicator(
                                value: null,
                                strokeWidth: 2.4,
                                color: colorScheme.primary,
                                backgroundColor: colorScheme.primary.withValues(
                                  alpha: 0.18,
                                ),
                              )
                            : _animatedProgress(
                                context,
                                (context, value) => CircularProgressIndicator(
                                  value: value,
                                  strokeWidth: 2.4,
                                  color: colorScheme.primary,
                                  backgroundColor: colorScheme.primary
                                      .withValues(alpha: 0.18),
                                ),
                              ),
                      )
                    : Icon(
                        isFolder
                            ? Icons.folder_rounded
                            : Icons.insert_drive_file,
                        color: colorScheme.primary.withValues(alpha: 0.86),
                        size: 34,
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    softWrap: true,
                  ),
                  const SizedBox(height: 4),
                  WhisperAnimatedSwitcher(
                    value: statusKey,
                    alignment: Alignment.centerLeft,
                    child: active
                        ? _animatedProgress(
                            context,
                            (context, value) =>
                                Text(statusText(value), style: statusStyle),
                          )
                        : Text(statusText(null), style: statusStyle),
                  ),
                  if (skippedLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: InkWell(
                        key: skippedKey,
                        borderRadius: BorderRadius.circular(6),
                        onTap: onShowSkipped,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                skippedLabel,
                                overflow: TextOverflow.ellipsis,
                                style: statusStyle.copyWith(
                                  color: palette.warning,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: palette.warning,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (onRetry != null)
              IconButton(
                tooltip: retryTooltip,
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            if (onCancel != null)
              IconButton(
                tooltip: cancelTooltip,
                onPressed: onCancel,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}
