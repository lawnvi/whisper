import 'package:flutter/material.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// `.vf`: a dark square with a picture from the camera on it, four marks at 18%
/// and a line going up and down between them.
class PhoneViewfinder extends StatelessWidget {
  const PhoneViewfinder({super.key, this.camera, this.denied});

  final Widget? camera, denied;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final denied = this.denied;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WhisperRadius.l),
        boxShadow: WhisperShadow.e1(brightness),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WhisperRadius.l),
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-.4, -.6),
                    radius: 1.2,
                    stops: [0, .7],
                    colors: [WhisperViewfinder.glow, WhisperViewfinder.base],
                    transform: _FlatterGlow(),
                  ),
                ),
              ),
              ?camera,
              IgnorePointer(child: CustomPaint(painter: const _Marks())),
              if (denied == null) _ScanLine(side: box.maxWidth),
              if (denied != null) Center(child: denied),
            ],
          ),
        ),
      ),
    );
  }
}

/// `radial-gradient(120% 90% at 30% 20%, …)`: wider than it is tall.
class _FlatterGlow extends GradientTransform {
  const _FlatterGlow();

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final center = const Alignment(-.4, -.6).withinRect(bounds);
    return Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(1, .75, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }
}

/// `.ln`: 22% to 78%, there and back.
class _ScanLine extends StatefulWidget {
  const _ScanLine({required this.side});

  final double side;

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    duration: WhisperLoops.scan,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _run.stop();
      _run.value = .5;
    } else if (!_run.isAnimating) {
      _run.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _run,
    builder: (context, child) {
      final t = Curves.easeInOut.transform(_run.value);
      return Positioned(
        left: widget.side * .2,
        right: widget.side * .2,
        top: widget.side * (.22 + .56 * t),
        height: 2,
        child: child!,
      );
    },
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: WhisperViewfinder.line,
          borderRadius: BorderRadius.circular(WhisperRadius.thumbBar),
        ),
      ),
    ),
  );
}

/// Four corners, 30 each, a stroke of 3 with an outer radius of 12.
class _Marks extends CustomPainter {
  const _Marks();

  @override
  void paint(Canvas canvas, Size size) {
    const box = 30.0, stroke = 3.0;
    final inset = size.width * .18;
    const radius = WhisperRadius.viewfinderMark - stroke / 2;
    final paint = Paint()
      ..color = WhisperViewfinder.mark
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final corner = Path()
      ..moveTo(stroke / 2, box)
      ..lineTo(stroke / 2, stroke / 2 + radius)
      ..arcToPoint(
        const Offset(stroke / 2 + radius, stroke / 2),
        radius: const Radius.circular(radius),
      )
      ..lineTo(box, stroke / 2);
    for (final (flipX, flipY) in const [
      (false, false),
      (true, false),
      (false, true),
      (true, true),
    ]) {
      canvas.save();
      canvas.translate(
        flipX ? size.width - inset : inset,
        flipY ? size.height - inset : inset,
      );
      canvas.scale(flipX ? -1 : 1, flipY ? -1 : 1);
      canvas.drawPath(corner, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Marks old) => false;
}
