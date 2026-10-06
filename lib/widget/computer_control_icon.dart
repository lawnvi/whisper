import 'package:flutter/material.dart';

/// A screen and pointer, drawn on the same 24px grid as the app's outline icons.
class ComputerControlIcon extends StatelessWidget {
  const ComputerControlIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    return SizedBox.square(
      dimension: theme.size ?? 24,
      child: CustomPaint(
        painter: _ComputerControlPainter(
          (theme.color ?? Theme.of(context).colorScheme.onSurface).withValues(
            alpha: theme.opacity ?? 1,
          ),
        ),
      ),
    );
  }
}

class _ComputerControlPainter extends CustomPainter {
  const _ComputerControlPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(10, 17)
        ..lineTo(4, 17)
        ..quadraticBezierTo(2, 17, 2, 15)
        ..lineTo(2, 5)
        ..quadraticBezierTo(2, 3, 4, 3)
        ..lineTo(20, 3)
        ..quadraticBezierTo(22, 3, 22, 5)
        ..lineTo(22, 10),
      pen,
    );
    canvas.drawLine(const Offset(9, 17), const Offset(9, 21), pen);
    canvas.drawLine(const Offset(6, 21), const Offset(12, 21), pen);
    canvas.drawPath(
      Path()
        ..moveTo(14, 10)
        ..lineTo(22, 15)
        ..lineTo(18, 16)
        ..lineTo(16, 20)
        ..close(),
      pen,
    );
  }

  @override
  bool shouldRepaint(_ComputerControlPainter oldDelegate) =>
      oldDelegate.color != color;
}
