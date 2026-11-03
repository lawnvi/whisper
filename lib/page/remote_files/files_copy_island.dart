import 'package:whisper/theme/radix_colors.dart';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

/// "拷贝到 一加 的“下载”"; "从 一加 拷贝到“访达”" for a copy dragged or
/// pasted out of the app.
String copyRoute(AppLocalizations l10n, FileCopyBatch batch) {
  final outside = switch (batch.target) {
    FilesOutside.fileManager => systemFileManagerName(l10n),
    _ => null,
  };
  if (outside != null) {
    return l10n.remoteFilesCopyFromDevice(batch.deviceName, outside);
  }
  return batch.upload
      ? l10n.remoteFilesCopyToDevice(batch.deviceName, batch.folder)
      : l10n.remoteFilesCopyFromDevice(batch.deviceName, batch.folder);
}

/// What this system calls its file manager.
String systemFileManagerName(AppLocalizations l10n) =>
    switch (defaultTargetPlatform) {
      TargetPlatform.macOS => l10n.remoteFilesFinder,
      TargetPlatform.windows => l10n.remoteFilesExplorer,
      _ => l10n.remoteFilesFileManager,
    };

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
  FileCopyPhase.starting || FileCopyPhase.running => Radix.blue9,
  FileCopyPhase.waiting || FileCopyPhase.paused => FlowSpaceTokens.paused,
  FileCopyPhase.failed => FlowSpaceTokens.failed,
  FileCopyPhase.canceled => Radix.slateDark10,
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
    this.track = Radix.whiteA4,
    this.tint,
  });

  final FileCopyBatch batch;
  final double size;
  final Color track;

  /// The colour for this phase; the island keeps [copyTint].
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final phase = batch.phase;
    final tint = this.tint ?? copyTint(phase);
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
    this.tint,
  });

  final FileCopyBatch batch;
  final Color track;
  final double height;
  final Color? tint;

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
              tint: tint ?? copyTint(phase),
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
