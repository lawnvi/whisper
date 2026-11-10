import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
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

  /// `.fcard`: paper, a name on one line, then size and progress. The sheet stays
  /// the same whatever happens to the transfer; only the words say so.
  Widget _buildNew(BuildContext context) {
    final c = context.wc;
    final touch = !isDesktop();
    final type = WhisperType(touch: touch);
    final second = TextStyle(
      fontSize: type.note,
      color: c.ink2Glass,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final skippedLabel = this.skippedLabel;
    // A warning colours only its small icon: amber words look dirty.
    Widget warned(String text, {bool warn = true}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (warn) ...[
          WhisperIcon(WhisperGlyph.warn, size: 12, color: c.warn),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(text, overflow: TextOverflow.ellipsis, style: second),
        ),
      ],
    );
    Widget iconAction(WhisperGlyph glyph, String label, VoidCallback onTap) =>
        Pressable(
          onTap: onTap,
          radius: WhisperRadius.xs,
          label: label,
          child: SizedBox.square(
            dimension: touch ? 48 : 28,
            child: Center(
              child: WhisperIcon(glyph, size: 14, color: c.ink2Glass),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.bubble,
        borderRadius: BorderRadius.circular(WhisperRadius.bubble),
      ),
      child: Row(
        children: [
          isFolder
              ? const WhisperFolderArt(size: 30)
              : const WhisperDocArt(size: 30),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: type.body,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
                WhisperAnimatedSwitcher(
                  value: statusKey,
                  alignment: Alignment.centerLeft,
                  child: active
                      ? _animatedProgress(
                          context,
                          (context, value) =>
                              Text(statusText(value), style: second),
                        )
                      : warned(statusText(null), warn: failed),
                ),
                if (active) ...[
                  const SizedBox(height: 6),
                  WhisperProgressBar(
                    value: verifying ? 1 : progress.clamp(0, 1),
                  ),
                ],
                if (skippedLabel != null)
                  Pressable(
                    key: skippedKey,
                    onTap: onShowSkipped,
                    radius: WhisperRadius.xs,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: warned(skippedLabel),
                    ),
                  ),
              ],
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 11),
            iconAction(WhisperGlyph.flip, retryTooltip, onRetry!),
          ],
          if (onCancel != null) ...[
            const SizedBox(width: 11),
            iconAction(WhisperGlyph.x, cancelTooltip, onCancel!),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildNew(context);
  }
}
