import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../page/remote_files/files_copy_island.dart';
import '../../../remote_files/fs_copies.dart';
import '../island_activity.dart';
import '../island_views.dart';

/// Where the file manager can show more about a copy, while it is open:
/// the list of transfers and the folder a finished copy went to. The page
/// that is on screen registers itself; without one these buttons are not
/// offered.
abstract final class IslandCopyHooks {
  static final _stack = <_CopyHooks>[];

  /// Registers the page's handlers; call the returned function when it goes.
  static VoidCallback attach({
    VoidCallback? showAll,
    void Function(FileCopyBatch batch)? reveal,
  }) {
    final hooks = _CopyHooks(showAll, reveal);
    _stack.add(hooks);
    return () => _stack.remove(hooks);
  }

  static VoidCallback? get showAll =>
      _stack.isEmpty ? null : _stack.last.showAll;

  static void Function(FileCopyBatch batch)? get reveal =>
      _stack.isEmpty ? null : _stack.last.reveal;
}

class _CopyHooks {
  const _CopyHooks(this.showAll, this.reveal);

  final VoidCallback? showAll;
  final void Function(FileCopyBatch batch)? reveal;
}

IslandStatus islandStatusOfCopy(FileCopyPhase phase) => switch (phase) {
  FileCopyPhase.starting || FileCopyPhase.running => IslandStatus.live,
  // A reconnect pauses copies too: worth a look either way.
  FileCopyPhase.waiting || FileCopyPhase.paused => IslandStatus.waiting,
  FileCopyPhase.failed => IslandStatus.failed,
  FileCopyPhase.canceled => IslandStatus.ended,
  FileCopyPhase.done => IslandStatus.done,
};

/// Copies made in the file manager, one activity per paste.
class CopyIslandSource extends ChangeNotifier implements IslandSource {
  CopyIslandSource(this.copies) {
    copies.addListener(_onCopies);
    copies.spotlight.addListener(_onSpotlight);
  }

  final FileCopies copies;
  final _spotlights = StreamController<String>.broadcast();
  Timer? _throttle;
  final _phases = <String, FileCopyPhase>{};
  bool _disposed = false;

  static String idOf(FileCopyBatch batch) => 'copy:${batch.id}';

  @override
  List<IslandActivity> get activities => [
    for (final batch in copies.batches)
      IslandActivity(
        id: idOf(batch),
        kind: IslandKind.copy,
        status: islandStatusOfCopy(batch.phase),
        since: batch.started,
        presenter: CopyPresenter(batch: batch, copies: copies),
      ),
  ];

  void _onCopies() {
    // Every transfer update lands here; what changes a phase goes out at
    // once, progress at most a few times a second.
    var phaseChanged = false;
    final seen = <String>{};
    for (final batch in copies.batches) {
      seen.add(batch.id);
      if (_phases[batch.id] != batch.phase) {
        _phases[batch.id] = batch.phase;
        phaseChanged = true;
      }
    }
    if (_phases.length != seen.length) {
      _phases.removeWhere((id, _) => !seen.contains(id));
      phaseChanged = true;
    }
    if (phaseChanged) {
      _throttle?.cancel();
      _throttle = null;
      notifyListeners();
      return;
    }
    _throttle ??= Timer(const Duration(milliseconds: 200), () {
      _throttle = null;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  void _onSpotlight() {
    final batch = copies.spotlit;
    if (batch != null) {
      _spotlights.add(idOf(batch));
    }
  }

  @override
  Stream<String> get spotlights => _spotlights.stream;

  @override
  void retired(String id) {}

  @override
  void dismissed(IslandActivity activity) {}

  @override
  void expired(IslandActivity activity) {}

  @override
  void dispose() {
    _disposed = true;
    _throttle?.cancel();
    copies.removeListener(_onCopies);
    copies.spotlight.removeListener(_onSpotlight);
    unawaited(_spotlights.close());
    super.dispose();
  }
}

/// A copy on the island, drawn like the file manager's own island.
class CopyPresenter extends IslandPresenter {
  const CopyPresenter({required this.batch, required this.copies});

  final FileCopyBatch batch;
  final FileCopies copies;

  String _trailing(AppLocalizations l10n) => switch (batch.phase) {
    FileCopyPhase.running when batch.totalBytes > 0 =>
      '${(batch.fraction * 100).floor()}%',
    FileCopyPhase.running || FileCopyPhase.starting => '',
    FileCopyPhase.waiting => l10n.remoteFilesCopyPaused,
    _ => copyStatus(l10n, batch),
  };

  @override
  Widget compact(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final phase = batch.phase;
    final trailing = _trailing(l10n);
    return IslandCompactLine(
      leading: CopyRing(batch: batch, size: 20, track: IslandColors.faint),
      title: copyTitle(l10n, batch),
      trailing: trailing.isEmpty
          ? null
          : Text(
              trailing,
              style: IslandText.compactFigure(
                phase == FileCopyPhase.running
                    ? IslandColors.dim
                    : copyTint(phase),
              ),
            ),
    );
  }

  @override
  Widget glyph(BuildContext context, double size) =>
      CopyRing(batch: batch, size: size, track: IslandColors.faint);

  @override
  Widget featured(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    final phase = batch.phase;
    final count = copyCount(l10n, batch);
    final status = copyStatus(l10n, batch);
    final bytes = copyBytes(batch);
    final left = [?count, if (bytes.isNotEmpty) bytes].join(' · ');
    final showAll = IslandCopyHooks.showAll;
    final action = _action(l10n, controls);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IslandHead(
            leading: IslandTile(
              tint: copyTint(phase),
              child: CopyRing(
                batch: batch,
                size: 24,
                track: IslandColors.faint,
              ),
            ),
            title: copyTitle(l10n, batch),
            subtitle: copyRoute(l10n, batch),
            trailing: [?action],
          ),
          const SizedBox(height: 14),
          CopyBar(batch: batch, track: IslandColors.faint),
          const SizedBox(height: 8),
          SizedBox(
            height: 16 * MediaQuery.textScalerOf(context).scale(12) / 12,
            child: CopyFigures(
              left: left,
              right: status,
              leftStyle: IslandText.figures,
              rightStyle: IslandText.figures.copyWith(
                color: phase == FileCopyPhase.running
                    ? IslandColors.dim
                    : copyTint(phase),
                fontWeight: phase == FileCopyPhase.running
                    ? FontWeight.w400
                    : FontWeight.w600,
              ),
            ),
          ),
          if (showAll != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  controls.collapse();
                  showAll();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.remoteFilesCopyShowAll,
                        style: const TextStyle(
                          color: IslandColors.blue,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(
                        CupertinoIcons.chevron_right,
                        size: 11,
                        color: IslandColors.blue,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Stop while it moves or waits; carry on or try again once stopped;
  /// show where it went once there (when the file manager is open).
  Widget? _action(AppLocalizations l10n, IslandControls controls) {
    final phase = batch.phase;
    if (batch.canResume &&
        (phase == FileCopyPhase.paused ||
            phase == FileCopyPhase.failed ||
            phase == FileCopyPhase.waiting)) {
      return IslandRoundButton(
        icon: CupertinoIcons.arrow_clockwise,
        label: phase == FileCopyPhase.failed
            ? l10n.remoteFilesCopyRetry
            : l10n.remoteFilesCopyResume,
        tint: copyTint(phase),
        onPressed: () => unawaited(copies.resume(batch)),
      );
    }
    if (!batch.finished) {
      return IslandRoundButton(
        icon: CupertinoIcons.xmark,
        label: l10n.remoteFilesCopyStop,
        onPressed: () => unawaited(copies.stop(batch)),
      );
    }
    final reveal = IslandCopyHooks.reveal;
    if (phase == FileCopyPhase.done &&
        reveal != null &&
        batch.target is! FilesOutside) {
      return IslandRoundButton(
        icon: CupertinoIcons.folder,
        label: l10n.remoteFilesCopyReveal,
        onPressed: () {
          controls.collapse();
          reveal(batch);
        },
      );
    }
    return null;
  }

  @override
  Widget row(BuildContext context, IslandControls controls) {
    final l10n = AppLocalizations.of(context)!;
    final phase = batch.phase;
    return IslandRowLine(
      leading: CopyRing(batch: batch, size: 18, track: IslandColors.faint),
      title: copyTitle(l10n, batch),
      status: phase == FileCopyPhase.running && batch.totalBytes > 0
          ? '${(batch.fraction * 100).floor()}%'
          : copyStatus(l10n, batch),
      statusColor: phase == FileCopyPhase.running ? null : copyTint(phase),
      onTap: () => controls.feature(CopyIslandSource.idOf(batch)),
      trailing: _rowAction(l10n),
    );
  }

  Widget? _rowAction(AppLocalizations l10n) {
    final phase = batch.phase;
    if (batch.canResume &&
        (phase == FileCopyPhase.paused ||
            phase == FileCopyPhase.failed ||
            phase == FileCopyPhase.waiting)) {
      return IslandRoundButton(
        icon: CupertinoIcons.arrow_clockwise,
        size: 28,
        label: phase == FileCopyPhase.failed
            ? l10n.remoteFilesCopyRetry
            : l10n.remoteFilesCopyResume,
        tint: copyTint(phase),
        onPressed: () => unawaited(copies.resume(batch)),
      );
    }
    if (!batch.finished) {
      return IslandRoundButton(
        icon: CupertinoIcons.xmark,
        size: 28,
        label: l10n.remoteFilesCopyStop,
        onPressed: () => unawaited(copies.stop(batch)),
      );
    }
    return null;
  }

  @override
  String describe(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [
      copyTitle(l10n, batch),
      copyRoute(l10n, batch),
      if (batch.phase == FileCopyPhase.running && batch.totalBytes > 0)
        '${(batch.fraction * 100).floor()}%'
      else
        copyStatus(l10n, batch),
    ].where((part) => part.isNotEmpty).join(', ');
  }
}
