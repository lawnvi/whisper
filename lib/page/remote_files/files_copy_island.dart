import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../helper/transfer_notification_aggregator.dart';
import '../../l10n/app_localizations.dart';
import '../../remote_files/fs_copies.dart';
import '../window_stream/flow_space_theme.dart';

// ------------------------------------------------------------ wording

/// "ChatGPT.dmg", or "3 个项目".
String copyTitle(AppLocalizations l10n, FileCopyBatch batch) =>
    batch.names.length == 1
    ? batch.names.single
    : l10n.remoteFilesCopyItems(batch.names.length);

/// "拷贝到 一加 的“下载”".
String copyRoute(AppLocalizations l10n, FileCopyBatch batch) => batch.upload
    ? l10n.remoteFilesCopyToDevice(batch.deviceName, batch.folder)
    : l10n.remoteFilesCopyFromDevice(batch.deviceName, batch.folder);

String copyDuration(AppLocalizations l10n, Duration left) {
  final seconds = left.inSeconds;
  if (seconds < 60) {
    return l10n.remoteFilesSeconds(math.max(1, seconds));
  }
  if (seconds < 3600) {
    return l10n.remoteFilesMinutes((seconds / 60).ceil());
  }
  return l10n.remoteFilesHours((seconds / 3600).ceil());
}

String copySize(int bytes) => formatBytesForNotification(bytes);

/// "312.4 MB / 654.7 MB" (or just the size once it is all there).
String copyBytes(FileCopyBatch batch) {
  final total = batch.totalBytes;
  if (total <= 0) {
    return '';
  }
  if (batch.phase == FileCopyPhase.done) {
    return copySize(total);
  }
  final done = copySize(batch.doneBytes);
  final all = copySize(total);
  // One unit when both share it: "200.3 / 624.3 MB".
  final unit = all.substring(all.lastIndexOf(' '));
  if (done.endsWith(unit)) {
    return '${done.substring(0, done.length - unit.length)} / $all';
  }
  return '$done / $all';
}

/// Speed and time left while it moves, else where it stands.
String copyStatus(AppLocalizations l10n, FileCopyBatch batch) {
  switch (batch.phase) {
    case FileCopyPhase.starting:
      return l10n.remoteFilesCopyStarting;
    case FileCopyPhase.running:
      final left = batch.remaining;
      return [
        if (batch.speed >= 1) '${copySize(batch.speed.round())}/s',
        if (left != null) l10n.remoteFilesCopyLeft(copyDuration(l10n, left)),
      ].join(' · ');
    case FileCopyPhase.waiting:
      return l10n.remoteFilesCopyWaiting(batch.deviceName);
    case FileCopyPhase.paused:
      return l10n.remoteFilesCopyPaused;
    case FileCopyPhase.failed:
      return l10n.remoteFilesCopyFailedShort;
    case FileCopyPhase.canceled:
      return l10n.remoteFilesCopyCanceledShort;
    case FileCopyPhase.done:
      return l10n.remoteFilesCopyDoneShort;
  }
}

/// "2/5 项", or how many files of the folders have gone.
String? copyCount(AppLocalizations l10n, FileCopyBatch batch) {
  if (batch.itemsTotal > 1) {
    return l10n.remoteFilesCopyItemsDone(batch.itemsDone, batch.itemsTotal);
  }
  final files = batch.filesDone;
  if (files != null && files > 0 && batch.phase != FileCopyPhase.done) {
    return l10n.remoteFilesCopyFilesMoved(files);
  }
  return null;
}

Color copyTint(FileCopyPhase phase) => switch (phase) {
  FileCopyPhase.starting || FileCopyPhase.running => const Color(0xFF0A84FF),
  FileCopyPhase.waiting || FileCopyPhase.paused => FlowSpaceTokens.paused,
  FileCopyPhase.failed => FlowSpaceTokens.failed,
  FileCopyPhase.canceled => const Color(0xFF8E8E93),
  FileCopyPhase.done => FlowSpaceTokens.live,
};

IconData copyIcon(FileCopyBatch batch) => switch (batch.phase) {
  FileCopyPhase.done => CupertinoIcons.checkmark_alt,
  FileCopyPhase.failed => CupertinoIcons.exclamationmark,
  FileCopyPhase.paused => CupertinoIcons.pause_fill,
  FileCopyPhase.waiting => CupertinoIcons.wifi_slash,
  FileCopyPhase.canceled => CupertinoIcons.xmark,
  _ => batch.upload ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down,
};

// ------------------------------------------------------------- pieces

/// Sizes and counts on the left, status on the right: the status takes
/// what it needs (up to most of the row), the rest is for the figures.
class CopyFigures extends StatelessWidget {
  const CopyFigures({
    super.key,
    required this.left,
    required this.right,
    required this.leftStyle,
    required this.rightStyle,
  });

  final String left;
  final String right;
  final TextStyle leftStyle;
  final TextStyle rightStyle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Text(
              left,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: leftStyle,
            ),
          ),
          if (right.isNotEmpty) ...[
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.62,
              ),
              child: Text(
                right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: rightStyle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A ring that fills as the copy goes, with what it is doing inside.
class CopyRing extends StatelessWidget {
  const CopyRing({
    super.key,
    required this.batch,
    this.size = 20,
    this.track = const Color(0x33FFFFFF),
  });

  final FileCopyBatch batch;
  final double size;
  final Color track;

  @override
  Widget build(BuildContext context) {
    final phase = batch.phase;
    final tint = copyTint(phase);
    final full =
        phase == FileCopyPhase.done ||
        phase == FileCopyPhase.failed ||
        phase == FileCopyPhase.canceled;
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: full ? 1 : batch.fraction),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => CustomPaint(
          painter: _RingPainter(
            value: value,
            tint: tint,
            track: track,
            spinning: phase == FileCopyPhase.starting,
          ),
          child: child,
        ),
        child: Center(
          child: AnimatedSwitcher(
            duration: FlowSpaceTokens.quickDuration,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Icon(
              copyIcon(batch),
              key: ValueKey(phase),
              size: size * 0.5,
              color: tint,
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.value,
    required this.tint,
    required this.track,
    required this.spinning,
  });

  final double value;
  final Color tint;
  final Color track;
  final bool spinning;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.12;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    final sweep = spinning ? math.pi * 0.5 : math.pi * 2 * value;
    if (sweep > 0) {
      canvas.drawArc(rect, -math.pi / 2, sweep, false, paint..color = tint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.tint != tint ||
      old.track != track ||
      old.spinning != spinning;
}

/// A thin bar that fills smoothly.
class CopyBar extends StatelessWidget {
  const CopyBar({
    super.key,
    required this.batch,
    required this.track,
    this.height = 6,
  });

  final FileCopyBatch batch;
  final Color track;
  final double height;

  @override
  Widget build(BuildContext context) {
    final phase = batch.phase;
    final value = phase == FileCopyPhase.done ? 1.0 : batch.fraction;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => CustomPaint(
            painter: _BarPainter(
              value: value,
              tint: copyTint(phase),
              track: track,
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.value, required this.tint, required this.track});

  final double value;
  final Color tint;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      Paint()..color = track,
    );
    if (value <= 0) {
      return;
    }
    final width = math.max(size.height, size.width * value.clamp(0.0, 1.0));
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & Size(width, size.height), radius),
      Paint()..color = tint,
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.value != value || old.tint != tint || old.track != track;
}

// ------------------------------------------------------------- island

/// Copies in flight, shown the way a phone shows a live activity: a black
/// island at the top. A new copy arrives as the small island and opens to
/// say what is going where, then settles back; trouble (the connection
/// gone, a failure) opens it again. Tap to open or close it, swipe it up
/// to put it away. Done, it shows a tick for a moment and leaves.
class FilesCopyIsland extends StatefulWidget {
  const FilesCopyIsland({
    super.key,
    required this.copies,
    required this.top,
    required this.onShowAll,
    this.onReveal,
    this.maxWidth = 400,
  });

  final FileCopies copies;

  /// Where the small island sits, from the top of the area it is in.
  final double top;
  final double maxWidth;
  final VoidCallback onShowAll;

  /// Shows where a finished copy went.
  final void Function(FileCopyBatch batch)? onReveal;

  @override
  State<FilesCopyIsland> createState() => _FilesCopyIslandState();
}

class _FilesCopyIslandState extends State<FilesCopyIsland>
    with TickerProviderStateMixin {
  /// Lively (ζ ≈ 0.7), like the window island.
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 290,
    damping: 24,
  );

  /// 0 gone, 1 the small island, 2 open. Made in [initState], so tearing
  /// down an island that never showed doesn't create one.
  late final AnimationController _stage;
  late final AnimationController _drag;

  FileCopyBatch? _batch;
  final _seen = <FileCopyBatch>{};
  final _phases = <FileCopyBatch, FileCopyPhase>{};
  Timer? _collapse;
  Timer? _leave;
  bool _hovering = false;
  double _rawDrag = 0;

  bool get _still => flowReduceMotion(context);

  @override
  void initState() {
    super.initState();
    _stage = AnimationController.unbounded(vsync: this);
    _drag = AnimationController.unbounded(vsync: this);
    _seen.addAll(widget.copies.batches);
    widget.copies.addListener(_onCopies);
    widget.copies.spotlight.addListener(_onSpotlight);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _onCopies();
      }
    });
  }

  @override
  void dispose() {
    widget.copies.removeListener(_onCopies);
    widget.copies.spotlight.removeListener(_onSpotlight);
    _collapse?.cancel();
    _leave?.cancel();
    _stage.dispose();
    _drag.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------- what shows

  void _onCopies() {
    final copies = widget.copies;
    FileCopyBatch? fresh;
    FileCopyBatch? trouble;
    var focusedChanged = false;
    for (final batch in copies.batches.reversed) {
      final phase = batch.phase;
      final was = _phases[batch];
      _phases[batch] = phase;
      if (_seen.add(batch)) {
        if (!batch.finished) {
          fresh = batch;
        }
        continue;
      }
      if (was == phase) {
        continue;
      }
      if (identical(batch, _batch)) {
        focusedChanged = true;
      }
      if (phase == FileCopyPhase.waiting ||
          phase == FileCopyPhase.paused ||
          phase == FileCopyPhase.failed) {
        trouble = batch;
      }
    }
    _phases.removeWhere((batch, _) => !copies.batches.contains(batch));
    final shown = _batch;
    if (shown != null && !copies.batches.contains(shown)) {
      _batch = null;
      _away();
    }
    if (fresh != null) {
      // A copy just made arrives and opens: the paste is seen to work.
      _focus(fresh, open: true);
    } else if (trouble != null) {
      // Trouble with any copy (the connection gone, a failure) is shown.
      HapticFeedback.mediumImpact();
      _focus(trouble, open: false);
      _open(for_: const Duration(seconds: 6));
    } else if (_batch == null) {
      final next = copies.active.firstOrNull;
      if (next != null) {
        _focus(next, open: false);
      }
    } else if (focusedChanged && _batch!.finished) {
      final next = copies.active.firstOrNull;
      if (next != null) {
        _focus(next, open: false);
      } else if (_batch!.phase != FileCopyPhase.failed) {
        if (_batch!.phase == FileCopyPhase.done) {
          HapticFeedback.lightImpact();
        }
        // The tick shows a moment, then it goes.
        _leave?.cancel();
        _leave = Timer(const Duration(milliseconds: 2600), () {
          if (mounted && !_hovering && _batch?.finished == true) {
            _away();
          }
        });
      }
    }
    setState(() {});
  }

  void _onSpotlight() {
    final batch = widget.copies.spotlit;
    if (batch != null) {
      _focus(batch, open: true);
      setState(() {});
    }
  }

  void _focus(FileCopyBatch batch, {required bool open}) {
    _batch = batch;
    _phases[batch] = batch.phase;
    _leave?.cancel();
    if (_stage.value < 0.5) {
      unawaited(_springTo(1));
    }
    if (open) {
      HapticFeedback.selectionClick();
      // The small island first, then it opens: reads as "something came".
      Timer(const Duration(milliseconds: 140), () {
        if (mounted && identical(_batch, batch)) {
          _open(for_: const Duration(milliseconds: 3800));
        }
      });
    }
  }

  void _open({Duration? for_}) {
    _collapse?.cancel();
    unawaited(_springTo(2));
    if (for_ != null) {
      _collapse = Timer(for_, _close);
    }
  }

  void _close() {
    if (!mounted || _hovering) {
      return;
    }
    _collapse?.cancel();
    if (_batch?.finished == true &&
        _batch?.phase != FileCopyPhase.failed &&
        widget.copies.active.isEmpty) {
      _away();
      return;
    }
    unawaited(_springTo(1));
  }

  void _away({double velocity = 0}) {
    _collapse?.cancel();
    _leave?.cancel();
    unawaited(
      _springTo(0, velocity: velocity).then((_) {
        if (mounted && _stage.value < 0.05) {
          setState(() => _batch = null);
        }
      }),
    );
  }

  Future<void> _springTo(double target, {double velocity = 0}) async {
    if (!mounted) {
      return;
    }
    if (_still) {
      await _stage
          .animateTo(
            target,
            duration: FlowSpaceTokens.quickDuration,
            curve: Curves.easeOut,
          )
          .orCancel
          .catchError((Object _) {});
      return;
    }
    await _stage
        .animateWith(SpringSimulation(_spring, _stage.value, target, velocity))
        .orCancel
        .catchError((Object _) {});
  }

  // ----------------------------------------------------------- gestures

  void _onTap() {
    if (_stage.value < 1.5) {
      HapticFeedback.lightImpact();
      _open(for_: const Duration(seconds: 8));
    } else {
      _close();
      unawaited(_springTo(_batch == null ? 0 : 1));
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _rawDrag += details.delta.dy;
    _drag.value = _rawDrag < 0
        ? _rawDrag * 0.6
        : 18 * (1 - math.exp(-_rawDrag / 60));
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_rawDrag < -20 || velocity < -400) {
      HapticFeedback.lightImpact();
      if (_stage.value > 1.5) {
        _collapse?.cancel();
        unawaited(_springTo(1, velocity: velocity / 400));
      } else {
        _away(velocity: velocity / 400);
      }
    } else if ((_rawDrag > 16 || velocity > 400) && _stage.value < 1.5) {
      HapticFeedback.lightImpact();
      _open(for_: const Duration(seconds: 8));
    }
    _rawDrag = 0;
    unawaited(
      _drag
          .animateWith(
            SpringSimulation(_spring, _drag.value, 0, velocity / 1000),
          )
          .orCancel
          .catchError((Object _) {}),
    );
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final batch = _batch;
    if (batch == null) {
      return const SizedBox.shrink();
    }
    final others = widget.copies.active
        .where((other) => !identical(other, batch))
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = constraints.maxWidth;
        final openWidth = math.min(area - 16, widget.maxWidth);
        const compactHeight = 36.0;
        final compactWidth = math.min(area - 32, 248.0);
        final shownOthers = math.min(others.length, 2);
        // Head, bar, numbers and the link below; a row per other copy.
        final openHeight =
            150.0 + (shownOthers == 0 ? 0 : 12.5 + shownOthers * 30.0);
        return AnimatedBuilder(
          animation: Listenable.merge([_stage, _drag]),
          builder: (context, _) {
            final s = math.max(0.0, _stage.value);
            final double width;
            final double height;
            final double radius;
            if (s <= 1) {
              width = ui.lerpDouble(compactWidth * 0.5, compactWidth, s)!;
              height = ui.lerpDouble(compactHeight * 0.75, compactHeight, s)!;
              radius = height / 2;
            } else {
              final t = s - 1;
              width = ui.lerpDouble(compactWidth, openWidth, t)!;
              height = ui.lerpDouble(compactHeight, openHeight, t)!;
              radius = ui.lerpDouble(compactHeight / 2, 30, t.clamp(0.0, 1.0))!;
            }
            final shown = (s * 2.5).clamp(0.0, 1.0);
            final compactContent = (1 - (s - 1).abs() * 2.6).clamp(0.0, 1.0);
            final openContent = ((s - 1.55) / 0.45).clamp(0.0, 1.0);
            final lift = (s - 1).clamp(0.0, 1.0);
            return Stack(
              children: [
                Positioned(
                  top: widget.top + _drag.value,
                  left: (area - width) / 2,
                  width: width,
                  height: math.max(height, 1),
                  child: Opacity(
                    opacity: shown,
                    child: MouseRegion(
                      onEnter: (_) {
                        _hovering = true;
                        _collapse?.cancel();
                      },
                      onExit: (_) {
                        _hovering = false;
                        if (_stage.value > 1.5) {
                          _collapse?.cancel();
                          _collapse = Timer(
                            const Duration(milliseconds: 1600),
                            _close,
                          );
                        }
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onTap,
                        onVerticalDragUpdate: _onDragUpdate,
                        onVerticalDragEnd: _onDragEnd,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: Colors.black,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(radius),
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.1),
                                width: 0.5,
                              ),
                            ),
                            shadows: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: 0.14 + 0.1 * lift,
                                ),
                                blurRadius: 10 + 18 * lift,
                                offset: Offset(0, 3 + 7 * lift),
                              ),
                            ],
                          ),
                          child: ClipRSuperellipse(
                            borderRadius: BorderRadius.circular(radius),
                            child: Stack(
                              children: [
                                if (compactContent > 0)
                                  Positioned.fill(
                                    child: Opacity(
                                      opacity: compactContent,
                                      child: _Compact(
                                        batch: batch,
                                        others: others.length,
                                      ),
                                    ),
                                  ),
                                if (openContent > 0)
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    width: openWidth,
                                    height: openHeight,
                                    child: Opacity(
                                      opacity: openContent,
                                      child: _Open(
                                        batch: batch,
                                        others: others,
                                        onShowAll: widget.onShowAll,
                                        onReveal: widget.onReveal,
                                        copies: widget.copies,
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
                ),
              ],
            );
          },
        );
      },
    );
  }
}

const _white = Colors.white;
final _dim = Colors.white.withValues(alpha: 0.62);
final _faint = Colors.white.withValues(alpha: 0.14);

class _Compact extends StatelessWidget {
  const _Compact({required this.batch, required this.others});

  final FileCopyBatch batch;
  final int others;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final phase = batch.phase;
    final trailing = switch (phase) {
      FileCopyPhase.running when batch.totalBytes > 0 =>
        '${(batch.fraction * 100).floor()}%',
      FileCopyPhase.running || FileCopyPhase.starting => '',
      FileCopyPhase.waiting => l10n.remoteFilesCopyPaused,
      _ => copyStatus(l10n, batch),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 0, 14, 0),
      child: Row(
        children: [
          CopyRing(batch: batch, size: 20, track: _faint),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              copyTitle(l10n, batch),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              trailing,
              style: TextStyle(
                color: phase == FileCopyPhase.running ? _dim : copyTint(phase),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (others > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _faint,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '+$others',
                style: TextStyle(
                  color: _dim,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Open extends StatelessWidget {
  const _Open({
    required this.batch,
    required this.others,
    required this.onShowAll,
    required this.copies,
    this.onReveal,
  });

  final FileCopyBatch batch;
  final List<FileCopyBatch> others;
  final VoidCallback onShowAll;
  final void Function(FileCopyBatch batch)? onReveal;
  final FileCopies copies;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final phase = batch.phase;
    final count = copyCount(l10n, batch);
    final status = copyStatus(l10n, batch);
    final bytes = copyBytes(batch);
    final left = [?count, if (bytes.isNotEmpty) bytes].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: ShapeDecoration(
                    color: copyTint(phase).withValues(alpha: 0.2),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: CopyRing(batch: batch, size: 24, track: _faint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        copyTitle(l10n, batch),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        copyRoute(l10n, batch),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _dim, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _action(context, l10n) ?? const SizedBox.shrink(),
              ],
            ),
          ),
          const SizedBox(height: 14),
          CopyBar(batch: batch, track: _faint),
          const SizedBox(height: 8),
          SizedBox(
            height: 16,
            child: CopyFigures(
              left: left,
              right: status,
              leftStyle: TextStyle(
                color: _dim,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              rightStyle: TextStyle(
                color: phase == FileCopyPhase.running ? _dim : copyTint(phase),
                fontSize: 12,
                fontWeight: phase == FileCopyPhase.running
                    ? FontWeight.w400
                    : FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(height: 0.5, color: _faint),
            for (final other in others.take(2))
              SizedBox(
                height: 30,
                child: Row(
                  children: [
                    CopyRing(batch: other, size: 16, track: _faint),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        copyTitle(l10n, other),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _dim, fontSize: 12.5),
                      ),
                    ),
                    Text(
                      other.phase == FileCopyPhase.running
                          ? '${(other.fraction * 100).floor()}%'
                          : copyStatus(l10n, other),
                      style: TextStyle(
                        color: _dim,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const Spacer(),
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              onPressed: onShowAll,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    others.length > 2
                        ? l10n.remoteFilesCopyMore(others.length - 2)
                        : l10n.remoteFilesCopyShowAll,
                    style: const TextStyle(
                      color: Color(0xFF0A84FF),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    CupertinoIcons.chevron_right,
                    size: 11,
                    color: Color(0xFF0A84FF),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Stop while it moves or waits; carry on or try again once stopped;
  /// show where it went once there.
  Widget? _action(BuildContext context, AppLocalizations l10n) {
    final phase = batch.phase;
    if (batch.canResume &&
        (phase == FileCopyPhase.paused || phase == FileCopyPhase.failed)) {
      return _RoundButton(
        icon: CupertinoIcons.arrow_clockwise,
        label: phase == FileCopyPhase.failed
            ? l10n.remoteFilesCopyRetry
            : l10n.remoteFilesCopyResume,
        tint: copyTint(phase),
        onPressed: () => unawaited(copies.resume(batch)),
      );
    }
    if (!batch.finished) {
      return _RoundButton(
        icon: CupertinoIcons.xmark,
        label: l10n.remoteFilesCopyStop,
        onPressed: () => unawaited(copies.stop(batch)),
      );
    }
    if (phase == FileCopyPhase.done && onReveal != null) {
      return _RoundButton(
        icon: CupertinoIcons.folder,
        label: l10n.remoteFilesCopyReveal,
        onPressed: () => onReveal!(batch),
      );
    }
    return null;
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tint,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final tint = this.tint;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(32, 32),
          onPressed: () {
            HapticFeedback.selectionClick();
            onPressed();
          },
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: tint?.withValues(alpha: 0.22) ?? _faint,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 15, color: tint ?? _white),
          ),
        ),
      ),
    );
  }
}
