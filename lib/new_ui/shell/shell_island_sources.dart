import 'package:whisper/theme/radix_colors.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/new_ui/shell/shell_island.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/new_ui/paste_island/paste_island_app.dart';
import 'package:whisper/remote_files/fs_copies.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';
import 'package:whisper/widget/island/island_home.dart';

bool _momentsAdded = false;

/// What the redesigned island shows besides what the old one did: transfers,
/// requests and short notes. Desktop and touch share them, as surfaces.md
/// 「手机」says. Once, whichever host comes first.
void installShellIslandSources(IslandCenter center) {
  if (_momentsAdded) return;
  _momentsAdded = true;
  center
    ..addSource(TransferIslandSource.shared)
    ..addSource(RequestIslandSource.shared)
    ..addSource(StatusIslandSource.shared)
    ..addSource(NoteIslandSource.shared);
}

/// surfaces.md「灵动岛」: what is moving between devices right now. A file sent
/// from a conversation also shows there, so it comes in without opening.
class TransferIslandSource extends IslandListSource {
  TransferIslandSource._();

  static final shared = TransferIslandSource._();

  final Map<String, DateTime> _since = {};

  void update(TransferSnapshot snapshot) {
    final id = 'transfer:${snapshot.transferId}';
    if (FileCopies.shared.holds(snapshot.transferId) ||
        (pasteIslandSupported &&
            WsSvrManager().carriesRemoteClipboardTransfer(
              snapshot.transferId,
            ))) {
      remove(id);
      return;
    }
    // Waiting for its device to come back: the file card says so. The island is
    // for what is moving now, not a number that stays at 1% all day.
    if (snapshot.state == FileTransferState.waitingReconnect ||
        snapshot.state == FileTransferState.paused) {
      remove(id);
      return;
    }
    final name = snapshot.finalPath.split(RegExp(r'[/\\]')).last;
    final status = switch (snapshot.state) {
      FileTransferState.queued ||
      FileTransferState.negotiating ||
      FileTransferState.transferring ||
      FileTransferState.verifying => IslandStatus.live,
      FileTransferState.waitingReconnect ||
      FileTransferState.paused => IslandStatus.paused,
      FileTransferState.completed => IslandStatus.done,
      FileTransferState.failed => IslandStatus.failed,
      FileTransferState.canceled => IslandStatus.ended,
    };
    put(
      IslandActivity(
        id: id,
        kind: IslandKind.copy,
        status: status,
        since: _since.putIfAbsent(id, DateTime.now),
        arrival: IslandArrival.quiet,
        // A quick one is over at once and never flashes up.
        showAfter: const Duration(milliseconds: 800),
        home: snapshot.messageUuid.isEmpty
            ? null
            : IslandHomes.message(snapshot.messageUuid),
        presenter: _TransferPresenter(
          name: name,
          status: status,
          progress: snapshot.size > 0
              ? (snapshot.committedBytes / snapshot.size).clamp(0, 1)
              : null,
          transferId: snapshot.transferId,
        ),
      ),
    );
  }

  @override
  void retired(String id) {
    _since.remove(id);
    remove(id);
    super.retired(id);
  }
}

class _TransferPresenter extends IslandPresenter with MomentViews {
  const _TransferPresenter({
    required this.name,
    required this.status,
    required this.progress,
    required this.transferId,
  });

  final String name;
  final IslandStatus status;
  final double? progress;
  final String transferId;

  String get _percent =>
      progress == null ? '' : '${(progress! * 100).floor()}%';

  Widget get _leading => status == IslandStatus.done
      ? const WhisperIcon(
          WhisperGlyph.check,
          size: 16,
          weight: 2.4,
          color: Colors.white,
        )
      : status == IslandStatus.failed
      ? const WhisperIcon(WhisperGlyph.warn, size: 16, color: Radix.amber9)
      : SizedBox.square(
          dimension: 20,
          child: CustomPaint(painter: IslandRingPainter(progress ?? 0)),
        );

  @override
  IslandMoment moment(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final running = !status.finished;
    return IslandMoment(
      leading: _leading,
      title: name,
      value: running && _percent.isNotEmpty ? _percent : null,
      detail: running ? _percent : l10n.shellIslandFinished,
      stopLabel: l10n.cancel,
      onStop: running
          ? () => unawaited(WsSvrManager().cancelTransfer(transferId))
          : null,
    );
  }

  @override
  Widget glyph(BuildContext context, double size) => _leading;

  @override
  String describe(BuildContext context) => '$name $_percent';
}

/// `ring()`: 20 across, 2.5 thick, white on a faint track.
class IslandRingPainter extends CustomPainter {
  const IslandRingPainter(this.value);

  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final scale = size.width / 20;
    final stroke = 2.5 * scale;
    final area = rect.deflate(stroke / 2 + .0);
    canvas.drawArc(
      area,
      0,
      6.2832,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = Radix.whiteA4,
    );
    if (value <= 0) return;
    canvas.drawArc(
      area,
      -1.5708,
      6.2832 * value.clamp(0, 1),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(IslandRingPainter old) => old.value != value;
}

/// What is simply going on: the network is gone, sound is going out, the pointer
/// is elsewhere. surfaces.md「灵动岛」: not 键鼠已就绪, which is a quiet state.
class StatusIslandSource extends IslandListSource {
  StatusIslandSource._();

  static final shared = StatusIslandSource._();

  final Map<String, DateTime> _since = {};

  /// Puts up exactly [moments], keeping when each one started.
  void show(Map<String, StatusMoment> moments) {
    final current = {for (final a in activities) a.id};
    if (current.length == moments.length &&
        current.containsAll(moments.keys) &&
        moments.entries.every((entry) {
          final shown = activities.firstWhere((a) => a.id == entry.key);
          return shown.presenter is StatusPresenter &&
              (shown.presenter as StatusPresenter).moment_ == entry.value;
        })) {
      return;
    }
    _since.removeWhere((id, _) => !moments.containsKey(id));
    activities = [
      for (final entry in moments.entries)
        IslandActivity(
          id: entry.key,
          kind: entry.value.warning ? IslandKind.request : IslandKind.audio,
          status: IslandStatus.live,
          arrival: IslandArrival.quiet,
          since: _since.putIfAbsent(entry.key, DateTime.now),
          home: entry.value.home,
          presenter: StatusPresenter(entry.value),
        ),
    ];
  }
}

@immutable
class StatusMoment {
  const StatusMoment({
    required this.glyph,
    required this.title,
    this.detail = '',
    this.warning = false,
    this.stopLabel = '',
    this.onStop,
    this.answers = const [],
    this.home,
  });

  /// See [IslandActivity.home].
  final String? home;
  final WhisperGlyph glyph;
  final String title, detail, stopLabel;
  final bool warning;
  final VoidCallback? onStop;
  final List<IslandAnswer> answers;

  @override
  bool operator ==(Object other) =>
      other is StatusMoment &&
      other.glyph == glyph &&
      other.title == title &&
      other.detail == detail &&
      other.warning == warning &&
      other.home == home;

  @override
  int get hashCode => Object.hash(glyph, title, detail, warning, home);
}

class StatusPresenter extends IslandPresenter with MomentViews {
  const StatusPresenter(this.moment_);

  final StatusMoment moment_;

  Widget get _leading => WhisperIcon(
    moment_.glyph,
    size: 16,
    color: moment_.warning ? Radix.amber9 : Colors.white,
  );

  @override
  IslandMoment moment(BuildContext context) => IslandMoment(
    leading: _leading,
    title: moment_.title,
    detail: moment_.detail,
    onStop: moment_.onStop,
    stopLabel: moment_.stopLabel,
    answers: moment_.answers,
  );

  @override
  Widget glyph(BuildContext context, double size) => _leading;

  @override
  String describe(BuildContext context) => moment_.title;
}

/// A result, for a moment: 已和 2698b 配对. surfaces.md「时刻」: where the app used
/// to raise a toast, the island says it, without covering the window.
class NoteIslandSource extends IslandListSource {
  NoteIslandSource._();

  static final shared = NoteIslandSource._();

  static const _shown = Duration(milliseconds: 2600);
  int _next = 0;

  void note(String text, {bool problem = false}) {
    final id = 'note:${_next++}';
    put(
      IslandActivity(
        id: id,
        kind: problem ? IslandKind.request : IslandKind.audio,
        status: IslandStatus.live,
        arrival: IslandArrival.quiet,
        since: DateTime.now(),
        presenter: StatusPresenter(
          StatusMoment(
            glyph: problem ? WhisperGlyph.warn : WhisperGlyph.check,
            warning: problem,
            title: text,
          ),
        ),
      ),
    );
    Timer(_shown, () => remove(id));
  }
}
