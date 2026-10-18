import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../page/window_stream/flow_space_theme.dart';

/// The island's colours: it is black in light and dark alike.
abstract final class IslandColors {
  static const white = Colors.white;
  static final dim = Colors.white.withValues(alpha: 0.62);
  static final faint = Colors.white.withValues(alpha: 0.14);
  static final hairline = Colors.white.withValues(alpha: 0.1);
  static const blue = Color(0xFF0A84FF);
  static const live = FlowSpaceTokens.live;
  static const paused = FlowSpaceTokens.paused;
  static const failed = FlowSpaceTokens.failed;
  static const gray = Color(0xFF8E8E93);
  static const tile = Color(0xFF2C2C2E);
}

abstract final class IslandText {
  static const compactTitle = TextStyle(
    color: IslandColors.white,
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );

  static TextStyle compactFigure(Color color) => TextStyle(
    color: color,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static const title = TextStyle(
    color: IslandColors.white,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  static final subtitle = TextStyle(color: IslandColors.dim, fontSize: 12.5);

  static final figures = TextStyle(
    color: IslandColors.dim,
    fontSize: 12,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static const rowTitle = TextStyle(
    color: IslandColors.white,
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );

  static final rowStatus = TextStyle(
    color: IslandColors.dim,
    fontSize: 12,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// A ring that fills as something goes, with what it is doing inside.
/// Without a [value] it turns (unless motion is reduced).
class IslandRing extends StatelessWidget {
  const IslandRing({
    super.key,
    required this.value,
    required this.tint,
    required this.icon,
    this.size = 20,
    this.full = false,
  });

  /// 0–1, or null while it is not known yet.
  final double? value;
  final Color tint;
  final IconData icon;
  final double size;

  /// Drawn closed (done, failed, stopped).
  final bool full;

  @override
  Widget build(BuildContext context) {
    final known = value;
    final ring = known == null && !full
        ? _Spinner(size: size, tint: tint)
        : TweenAnimationBuilder<double>(
            tween: Tween(end: full ? 1 : known!.clamp(0.0, 1.0)),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => CustomPaint(
              size: Size.square(size),
              painter: IslandRingPainter(
                value: value,
                tint: tint,
                track: IslandColors.faint,
              ),
            ),
          );
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(child: ring),
          AnimatedSwitcher(
            duration: FlowSpaceTokens.quickDuration,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Icon(
              icon,
              key: ValueKey(icon),
              size: size * 0.5,
              color: tint,
            ),
          ),
        ],
      ),
    );
  }
}

class IslandRingPainter extends CustomPainter {
  IslandRingPainter({
    required this.value,
    required this.tint,
    required this.track,
    this.start = -math.pi / 2,
  });

  final double value;
  final Color tint;
  final Color track;
  final double start;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.12;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    final sweep = math.pi * 2 * value;
    if (sweep > 0) {
      canvas.drawArc(rect, start, sweep, false, paint..color = tint);
    }
  }

  @override
  bool shouldRepaint(IslandRingPainter old) =>
      old.value != value ||
      old.tint != tint ||
      old.track != track ||
      old.start != start;
}

class _Spinner extends StatefulWidget {
  const _Spinner({required this.size, required this.tint});

  final double size;
  final Color tint;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (flowReduceMotion(context)) {
      _turn.stop();
    } else if (!_turn.isAnimating) {
      unawaited(_turn.repeat());
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _turn,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: IslandRingPainter(
          value: 0.25,
          tint: widget.tint,
          track: IslandColors.faint,
          start: -math.pi / 2 + _turn.value * math.pi * 2,
        ),
      ),
    );
  }
}

/// A thin bar that fills smoothly.
class IslandBar extends StatelessWidget {
  const IslandBar({
    super.key,
    required this.value,
    required this.tint,
    this.height = 6,
  });

  final double value;
  final Color tint;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => CustomPaint(
            painter: _BarPainter(
              value: value,
              tint: tint,
              track: IslandColors.faint,
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
    final width = math.max(size.height, size.width * value);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & Size(width, size.height), radius),
      Paint()..color = tint,
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.value != value || old.tint != tint || old.track != track;
}

/// Bars that dance while sound plays (still when motion is reduced or the
/// sound is paused).
class IslandEqualizer extends StatefulWidget {
  const IslandEqualizer({
    super.key,
    required this.playing,
    this.tint = IslandColors.live,
    this.width = 18,
    this.height = 14,
  });

  final bool playing;
  final Color tint;
  final double width;
  final double height;

  @override
  State<IslandEqualizer> createState() => _IslandEqualizerState();
}

class _IslandEqualizerState extends State<IslandEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(IslandEqualizer old) {
    super.didUpdateWidget(old);
    _update();
  }

  void _update() {
    final moving = widget.playing && !flowReduceMotion(context);
    if (moving && !_beat.isAnimating) {
      unawaited(_beat.repeat());
    } else if (!moving && _beat.isAnimating) {
      _beat.stop();
    }
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _beat,
        builder: (context, _) => CustomPaint(
          size: Size(widget.width, widget.height),
          painter: _EqualizerPainter(
            t: _beat.value,
            playing: widget.playing,
            tint: widget.tint,
          ),
        ),
      ),
    );
  }
}

class _EqualizerPainter extends CustomPainter {
  _EqualizerPainter({
    required this.t,
    required this.playing,
    required this.tint,
  });

  final double t;
  final bool playing;
  final Color tint;

  static const _bars = 4;
  static const _rest = [0.45, 0.8, 0.6, 0.35];

  @override
  void paint(Canvas canvas, Size size) {
    final gap = size.width * 0.12;
    final bar = (size.width - gap * (_bars - 1)) / _bars;
    final paint = Paint()..color = playing ? tint : tint.withValues(alpha: 0.5);
    for (var i = 0; i < _bars; i++) {
      double level;
      if (playing) {
        // Two waves per bar at unrelated speeds: lively, never in step.
        final a = math.sin((t * 5 + i * 0.37) * math.pi * 2);
        final b = math.sin((t * 3 + i * 0.71) * math.pi * 2);
        level = 0.55 + 0.3 * a + 0.15 * b;
      } else {
        level = _rest[i] * 0.45;
      }
      final height = math.max(bar, size.height * level.clamp(0.18, 1.0));
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * (bar + gap), (size.height - height) / 2, bar, height),
        Radius.circular(bar / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_EqualizerPainter old) =>
      old.t != t || old.playing != playing || old.tint != tint;
}

/// The small island's usual line: something on the left, a title, and a
/// figure on the right.
class IslandCompactLine extends StatelessWidget {
  const IslandCompactLine({
    super.key,
    required this.leading,
    required this.title,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 0, 14, 0),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: IslandText.compactTitle,
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }
}

/// A tinted square with rounded corners for the card's leading picture.
class IslandTile extends StatelessWidget {
  const IslandTile({
    super.key,
    required this.tint,
    required this.child,
    this.size = 40,
  });

  final Color tint;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: tint.withValues(alpha: 0.2),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

/// The head of a featured activity: picture, title and subtitle, then its
/// buttons.
class IslandHead extends StatelessWidget {
  const IslandHead({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing = const [],
    this.subtitleColor,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Color? subtitleColor;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: IslandText.title,
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: subtitleColor == null
                        ? IslandText.subtitle
                        : IslandText.subtitle.copyWith(color: subtitleColor),
                  ),
                ],
              ],
            ),
          ),
          for (final button in trailing) ...[const SizedBox(width: 8), button],
        ],
      ),
    );
  }
}

/// One activity below the featured one: tap it to bring it to the top.
class IslandRowLine extends StatelessWidget {
  const IslandRowLine({
    super.key,
    required this.leading,
    required this.title,
    required this.status,
    required this.onTap,
    this.statusColor,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final String status;
  final Color? statusColor;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            SizedBox.square(dimension: 28, child: Center(child: leading)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: IslandText.rowTitle,
              ),
            ),
            if (status.isNotEmpty) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: statusColor == null
                      ? IslandText.rowStatus
                      : IslandText.rowStatus.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                ),
              ),
            ],
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      ),
    );
  }
}

/// A round button with an icon (the label is for screen readers).
class IslandRoundButton extends StatelessWidget {
  const IslandRoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tint,
    this.size = 32,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tint = this.tint;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: _Press(
        onPressed: onPressed,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: tint?.withValues(alpha: 0.22) ?? IslandColors.faint,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: size * 0.47,
            color: tint ?? IslandColors.white,
          ),
        ),
      ),
    );
  }
}

/// A capsule button with a label, for the card's main choices.
class IslandCapsuleButton extends StatelessWidget {
  const IslandCapsuleButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.background,
    this.foreground = IslandColors.white,
    this.height = 42,
  });

  final String label;
  final VoidCallback onPressed;
  final Color? background;
  final Color foreground;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: _Press(
        onPressed: onPressed,
        child: Container(
          constraints: BoxConstraints(minHeight: height),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: background ?? Colors.white.withValues(alpha: 0.15),
            shape: const StadiumBorder(),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Sinks a little under the finger, ticks when let go on it.
class _Press extends StatefulWidget {
  const _Press({required this.onPressed, required this.child});

  final VoidCallback onPressed;
  final Widget child;

  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
  bool _down = false;

  void _set(bool value) {
    if (_down != value) {
      setState(() => _down = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onPressed();
      },
      child: AnimatedScale(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        scale: _down ? 0.94 : 1,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: _down ? 0.72 : 1,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A small dark disc behind a row's or the circle's picture.
class IslandDisc extends StatelessWidget {
  const IslandDisc({super.key, required this.child, this.size = 28});

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: IslandColors.tile,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}
