import 'package:whisper/helper/helper.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../remote_files/fs_copies.dart';
import 'files_copy_island.dart';
import 'package:whisper/widget/island/island_home.dart';

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

  /// Inset groups on the page, as everywhere else.
  Widget _buildNew(
    BuildContext context,
    AppLocalizations l10n,
    List<FileCopyBatch> active,
    List<FileCopyBatch> finished,
  ) {
    final c = context.wc;
    final touch = !isDesktop();
    final type = WhisperType(touch: touch);
    if (active.isEmpty && finished.isEmpty) {
      return Center(
        child: Text(
          l10n.remoteFilesTransfersEmpty,
          style: TextStyle(fontSize: type.body, color: c.ink2),
        ),
      );
    }
    Widget rows(List<FileCopyBatch> batches) => ShellGroup(
      children: [
        for (final batch in batches)
          _CopyRow(
            key: ObjectKey(batch),
            batch: batch,
            copies: copies,
            onReveal: onReveal,
          ),
      ],
    );
    return ListView(
      padding: EdgeInsets.fromLTRB(grouped ? 16 : 20, 6, grouped ? 16 : 20, 28),
      children: [
        if (active.isNotEmpty) ...[
          ShellGroupLabel(l10n.remoteFilesTransfersActive, touch: touch),
          rows(active),
          const SizedBox(height: 18),
        ],
        if (finished.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: ShellGroupLabel(
                  l10n.remoteFilesTransfersRecent,
                  touch: touch,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ShellButton(
                  label: l10n.remoteFilesTransfersClear,
                  kind: ShellButtonKind.quiet,
                  touch: touch,
                  onTap: copies.clearFinished,
                ),
              ),
            ],
          ),
          rows(finished),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return IslandHome(
      home: IslandHomes.transfers,
      child: ListenableBuilder(
        listenable: copies,
        builder: (context, _) {
          final l10n = AppLocalizations.of(context)!;
          final active = copies.active.toList();
          final finished = copies.batches.where((b) => b.finished).toList();
          return _buildNew(context, l10n, active, finished);
        },
      ),
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

  /// A row of the group: the ring, what and where, the figures. Blue only while
  /// it moves; the rest of the states use the status colours.
  Widget _buildNew(BuildContext context, AppLocalizations l10n) {
    final c = context.wc;
    final touch = !isDesktop();
    final type = WhisperType(touch: touch);
    final phase = batch.phase;
    final tint = switch (phase) {
      FileCopyPhase.starting || FileCopyPhase.running => c.accent,
      FileCopyPhase.waiting || FileCopyPhase.paused => c.warn,
      FileCopyPhase.failed => c.bad,
      FileCopyPhase.canceled => c.ink3,
      FileCopyPhase.done => c.ok,
    };
    final when = batch.ended ?? batch.started;
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(when));
    final bytes = copyBytes(batch);
    final details = [
      ?copyCount(l10n, batch),
      if (bytes.isNotEmpty) bytes,
      if (batch.finished) time,
    ].join(' · ');
    final figures = TextStyle(
      fontSize: type.note,
      height: 1.3,
      color: c.ink2,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget action(WhisperGlyph glyph, String label, VoidCallback onTap) =>
        ShellIconButton(
          glyph: glyph,
          label: label,
          touch: touch,
          color: c.ink2,
          onTap: onTap,
        );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: touch ? 48 : 40),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          children: [
            CopyRing(
              batch: batch,
              size: 22,
              tint: tint,
              track: tint.withValues(alpha: .22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    copyTitle(l10n, batch),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.body,
                      height: 1.3,
                      color: c.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    copyRoute(l10n, batch),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.note,
                      height: 1.3,
                      color: c.ink2,
                    ),
                  ),
                  if (!batch.finished) ...[
                    const SizedBox(height: 6),
                    CopyBar(batch: batch, track: c.fill, height: 3, tint: tint),
                  ],
                  const SizedBox(height: 4),
                  CopyFigures(
                    left: details,
                    right: copyStatus(l10n, batch),
                    leftStyle: figures,
                    rightStyle: figures.copyWith(
                      color: phase == FileCopyPhase.running ? c.ink2 : tint,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (batch.canResume &&
                (phase == FileCopyPhase.paused ||
                    phase == FileCopyPhase.failed))
              action(
                WhisperGlyph.play,
                phase == FileCopyPhase.failed
                    ? l10n.remoteFilesCopyRetry
                    : l10n.remoteFilesCopyResume,
                () => unawaited(copies.resume(batch)),
              ),
            if (!batch.finished)
              action(
                WhisperGlyph.x,
                l10n.remoteFilesCopyStop,
                () => unawaited(copies.stop(batch)),
              ),
            if (phase == FileCopyPhase.done &&
                onReveal != null &&
                batch.target is! FilesOutside)
              action(
                WhisperGlyph.folder,
                l10n.remoteFilesCopyReveal,
                () => onReveal!(batch),
              ),
            if (batch.finished)
              action(
                WhisperGlyph.x,
                l10n.remoteFilesCopyRemove,
                () => copies.remove(batch),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _buildNew(context, l10n);
  }
}
