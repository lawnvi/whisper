import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'flow_space_theme.dart';

/// Flies a window's picture from [from] to [to] along an arc, shrinking
/// into the target, then completes. With reduced motion it only fades.
Future<void> flowFlyWindow(
  BuildContext context, {
  required Rect from,
  required Rect to,
  required Color hue,
  Uint8List? picture,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final done = Completer<void>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _FlyingWindow(
      from: from,
      to: to,
      hue: hue,
      picture: picture,
      reduceMotion: flowReduceMotion(context),
      onDone: () {
        entry.remove();
        if (!done.isCompleted) {
          done.complete();
        }
      },
    ),
  );
  overlay.insert(entry);
  return done.future;
}

class _FlyingWindow extends StatefulWidget {
  const _FlyingWindow({
    required this.from,
    required this.to,
    required this.hue,
    required this.picture,
    required this.reduceMotion,
    required this.onDone,
  });

  final Rect from;
  final Rect to;
  final Color hue;
  final Uint8List? picture;
  final bool reduceMotion;
  final VoidCallback onDone;

  @override
  State<_FlyingWindow> createState() => _FlyingWindowState();
}

class _FlyingWindowState extends State<_FlyingWindow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.reduceMotion ? 220 : 640),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = Curves.easeInOutCubic.transform(_controller.value);
          final from = widget.from;
          final to = widget.to;
          if (widget.reduceMotion) {
            return Positioned.fromRect(
              rect: from,
              child: Opacity(opacity: 1 - t, child: _card()),
            );
          }
          // Quadratic arc that rises above both ends before landing.
          final control = Offset(
            (from.center.dx + to.center.dx) / 2,
            (from.top < to.top ? from.top : to.top) - 90,
          );
          final a = Offset.lerp(from.center, control, t)!;
          final b = Offset.lerp(control, to.center, t)!;
          final center = Offset.lerp(a, b, t)!;
          final endScale = (to.height / from.height).clamp(0.12, 1.0) * 0.6;
          final scale = lerpDouble(1, endScale, t)!;
          final opacity = t < 0.8 ? 1.0 : 1 - (t - 0.8) / 0.2;
          return Positioned(
            left: center.dx - from.width / 2,
            top: center.dy - from.height / 2,
            width: from.width,
            height: from.height,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.scale(scale: scale, child: _card()),
            ),
          );
        },
      ),
    );
  }

  Widget _card() {
    final picture = widget.picture;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(FlowSpaceTokens.tileRadius),
        ),
        color: widget.hue,
        shadows: [
          BoxShadow(
            color: widget.hue.withValues(alpha: 0.35),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: picture == null
          ? const SizedBox.expand()
          : ClipPath(
              clipper: ShapeBorderClipper(
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(
                    FlowSpaceTokens.tileRadius,
                  ),
                ),
              ),
              child: Image.memory(picture, fit: BoxFit.cover),
            ),
    );
  }
}
