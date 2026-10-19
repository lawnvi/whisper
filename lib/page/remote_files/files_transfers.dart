import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../remote_files/fs_copies.dart';
import '../window_stream/flow_space_theme.dart';
import '../window_stream/flow_space_widgets.dart';
import 'files_copy_island.dart';

/// Every copy made in the file manager while the app runs: the ones under
/// way first, with how far they are and what can be done with them (stop,
/// carry on, try again), then the finished ones and how they ended.
class FilesTransfersList extends StatelessWidget {
  const FilesTransfersList({
    super.key,
    required this.copies,
    this.onReveal,
    this.grouped = false,
  });

  final FileCopies copies;
  final void Function(FileCopyBatch batch)? onReveal;

  /// Rows in rounded groups on a grey canvas (phones), else plain rows.
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: copies,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final active = copies.active.toList();
        final finished = copies.batches.where((b) => b.finished).toList();
        if (active.isEmpty && finished.isEmpty) {
          return FlowEmptyState(
            icon: CupertinoIcons.arrow_up_arrow_down,
            title: l10n.remoteFilesTransfersEmpty,
            detail: l10n.remoteFilesTransfersEmptyDetail,
          );
        }
        return ListView(
          padding: EdgeInsets.fromLTRB(
            grouped ? 16 : 24,
            grouped ? 8 : 16,
            grouped ? 16 : 24,
            32,
          ),
          children: [
            if (active.isNotEmpty) ...[
              _Header(title: l10n.remoteFilesTransfersActive),
              _Section(
                grouped: grouped,
                rows: [
                  for (final batch in active)
                    _CopyRow(
                      key: ObjectKey(batch),
                      batch: batch,
                      copies: copies,
                      onReveal: onReveal,
                    ),
                ],
              ),
              const SizedBox(height: 22),
            ],
            if (finished.isNotEmpty) ...[
              _Header(
                title: l10n.remoteFilesTransfersRecent,
                action: l10n.remoteFilesTransfersClear,
                onAction: copies.clearFinished,
              ),
              _Section(
                grouped: grouped,
                rows: [
                  for (final batch in finished)
                    _CopyRow(
                      key: ObjectKey(batch),
                      batch: batch,
                      copies: copies,
                      onReveal: onReveal,
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: colors.secondaryLabel,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (action != null)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 28),
              onPressed: onAction,
              child: Text(
                action!,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.rows, required this.grouped});

  final List<Widget> rows;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 64),
            child: Container(height: 0.5, color: colors.hairline),
          ),
        );
      }
      children.add(rows[i]);
    }
    final column = AnimatedSize(
      duration: FlowSpaceTokens.quickDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(children: children),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.raised,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(grouped ? 16 : 14),
          side: grouped
              ? BorderSide.none
              : BorderSide(color: colors.hairline, width: 0.5),
        ),
      ),
      child: column,
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({
    super.key,
    required this.batch,
    required this.copies,
    this.onReveal,
  });

  final FileCopyBatch batch;
  final FileCopies copies;
  final void Function(FileCopyBatch batch)? onReveal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FlowSpaceColors.of(context);
    final phase = batch.phase;
    final tint = copyTint(phase);
    final count = copyCount(l10n, batch);
    final bytes = copyBytes(batch);
    final when = batch.ended ?? batch.started;
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(when));
    final details = [
      ?count,
      if (bytes.isNotEmpty) bytes,
      if (batch.finished) time,
    ].join(' · ');
    final status = copyStatus(l10n, batch);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: ShapeDecoration(
              color: tint.withValues(alpha: colors.dark ? 0.22 : 0.12),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(11),
              ),
            ),
            alignment: Alignment.center,
            child: CopyRing(
              batch: batch,
              size: 22,
              track: tint.withValues(alpha: 0.22),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  copyTitle(l10n, batch),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.label,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  copyRoute(l10n, batch),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.secondaryLabel,
                    fontSize: 12.5,
                  ),
                ),
                if (!batch.finished) ...[
                  const SizedBox(height: 8),
                  CopyBar(batch: batch, track: colors.hairline, height: 4),
                ],
                const SizedBox(height: 6),
                CopyFigures(
                  left: details,
                  right: status,
                  leftStyle: TextStyle(
                    color: colors.tertiaryLabel,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  rightStyle: TextStyle(
                    color: phase == FileCopyPhase.running
                        ? colors.secondaryLabel
                        : tint,
                    fontSize: 12,
                    fontWeight: phase == FileCopyPhase.running
                        ? FontWeight.w400
                        : FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          ..._actions(l10n, colors),
        ],
      ),
    );
  }

  List<Widget> _actions(AppLocalizations l10n, FlowSpaceColors colors) {
    final phase = batch.phase;
    return [
      if (batch.canResume &&
          (phase == FileCopyPhase.paused || phase == FileCopyPhase.failed))
        _IconAction(
          icon: CupertinoIcons.arrow_clockwise,
          label: phase == FileCopyPhase.failed
              ? l10n.remoteFilesCopyRetry
              : l10n.remoteFilesCopyResume,
          color: copyTint(phase),
          onPressed: () => unawaited(copies.resume(batch)),
        ),
      if (!batch.finished)
        _IconAction(
          icon: CupertinoIcons.xmark_circle_fill,
          label: l10n.remoteFilesCopyStop,
          color: colors.tertiaryLabel,
          onPressed: () => unawaited(copies.stop(batch)),
        ),
      if (phase == FileCopyPhase.done &&
          onReveal != null &&
          batch.target is! FilesOutside)
        _IconAction(
          icon: CupertinoIcons.folder,
          label: l10n.remoteFilesCopyReveal,
          color: colors.secondaryLabel,
          onPressed: () => onReveal!(batch),
        ),
      if (batch.finished)
        _IconAction(
          icon: CupertinoIcons.xmark,
          label: l10n.remoteFilesCopyRemove,
          color: colors.tertiaryLabel,
          size: 14,
          onPressed: () => copies.remove(batch),
        ),
    ];
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.size = 20,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(36, 36),
          onPressed: () {
            HapticFeedback.selectionClick();
            onPressed();
          },
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}
