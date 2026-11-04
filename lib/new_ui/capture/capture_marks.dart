import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// What a picture is marked up with. Everything is in the picture's own pixels,
/// so what is drawn does not depend on how large it is on screen.
sealed class CaptureMark {
  const CaptureMark();

  void paint(Canvas canvas, CapturePicture picture);
}

/// The picture and its pixelated copy.
class CapturePicture {
  const CapturePicture(this.image, this.pixelated, this.block);

  final ui.Image image;

  /// How many of the picture's pixels a mosaic block is wide.
  final int block;

  /// The whole picture at a block's worth of detail. The mosaic is this drawn
  /// large, so what is under it is not in the result at all, not even faintly.
  final ui.Image pixelated;

  Rect get bounds =>
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

  static Future<CapturePicture> of(ui.Image image, {required int block}) async {
    final width = math.max(1, (image.width / block).ceil());
    final height = math.max(1, (image.height / block).ceil());
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final small = await picture.toImage(width, height);
    picture.dispose();
    return CapturePicture(image, small, block);
  }

  void dispose() {
    image.dispose();
    pixelated.dispose();
  }
}

enum CaptureShapeKind { rect, ellipse, arrow }

class CaptureShape extends CaptureMark {
  const CaptureShape(
    this.kind,
    this.from,
    this.to, {
    required this.color,
    required this.width,
  });

  final CaptureShapeKind kind;
  final Offset from, to;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, CapturePicture picture) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (kind) {
      case CaptureShapeKind.rect:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromPoints(from, to),
            Radius.circular(width),
          ),
          stroke,
        );
      case CaptureShapeKind.ellipse:
        canvas.drawOval(Rect.fromPoints(from, to), stroke);
      case CaptureShapeKind.arrow:
        _paintArrow(canvas, stroke);
    }
  }

  void _paintArrow(Canvas canvas, Paint stroke) {
    final line = to - from;
    final length = line.distance;
    if (length < 1) return;
    final along = line / length;
    final across = Offset(-along.dy, along.dx);
    final head = math.min(length, width * 4.5);
    final base = to - along * head;
    // The line stops inside the head, or its round end shows past the point.
    canvas.drawLine(from, base + along * (head * .25), stroke);
    final half = head * .58;
    canvas.drawPath(
      Path()
        ..moveTo(to.dx, to.dy)
        ..lineTo(base.dx + across.dx * half, base.dy + across.dy * half)
        ..lineTo(base.dx - across.dx * half, base.dy - across.dy * half)
        ..close(),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }
}

/// A smooth line through the points of a stroke.
Path capturePathThrough(List<Offset> points) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.dx, points.first.dy);
  if (points.length == 1) {
    path.lineTo(points.first.dx + .01, points.first.dy);
    return path;
  }
  for (var i = 1; i < points.length - 1; i++) {
    final middle = (points[i] + points[i + 1]) / 2;
    path.quadraticBezierTo(points[i].dx, points[i].dy, middle.dx, middle.dy);
  }
  path.lineTo(points.last.dx, points.last.dy);
  return path;
}

class CapturePen extends CaptureMark {
  const CapturePen(this.points, {required this.color, required this.width});

  final List<Offset> points;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, CapturePicture picture) => canvas.drawPath(
    capturePathThrough(points),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );
}

class CaptureMosaic extends CaptureMark {
  const CaptureMosaic(this.points, {required this.width});

  final List<Offset> points;
  final double width;

  @override
  void paint(Canvas canvas, CapturePicture picture) {
    final bounds = picture.bounds;
    final block = picture.block.toDouble();
    canvas.saveLayer(bounds, Paint());
    canvas.drawPath(
      capturePathThrough(points),
      Paint()
        ..color = const Color(0xFF000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        // A soft edge would let a little of what is under it through.
        ..isAntiAlias = false,
    );
    canvas.drawImageRect(
      picture.pixelated,
      Rect.fromLTWH(
        0,
        0,
        picture.pixelated.width.toDouble(),
        picture.pixelated.height.toDouble(),
      ),
      // Whole blocks, also where the last column is cut off by the picture.
      Rect.fromLTWH(
        0,
        0,
        picture.pixelated.width * block,
        picture.pixelated.height * block,
      ),
      Paint()
        ..blendMode = BlendMode.srcIn
        ..filterQuality = FilterQuality.none,
    );
    canvas.restore();
  }
}

class CaptureText extends CaptureMark {
  const CaptureText(this.position, this.text, {required this.style});

  final Offset position;
  final String text;

  /// The app's own font: a painter on its own would pick another, and what was
  /// written would change on the way out.
  final TextStyle style;

  @override
  void paint(Canvas canvas, CapturePicture picture) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0, picture.bounds.width - position.dx));
    painter.paint(canvas, position);
    painter.dispose();
  }
}

/// The picture with its marks, or the part of it at [crop], without resampling
/// a pixel.
Future<ui.Image> flattenCapture(
  CapturePicture picture,
  List<CaptureMark> marks, {
  Rect? crop,
}) async {
  final area = crop ?? picture.bounds;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & area.size);
  canvas.translate(-area.left, -area.top);
  paintCapture(canvas, picture, marks);
  final recorded = recorder.endRecording();
  final image = await recorded.toImage(area.width.round(), area.height.round());
  recorded.dispose();
  return image;
}

void paintCapture(
  Canvas canvas,
  CapturePicture picture,
  List<CaptureMark> marks, {
  FilterQuality quality = FilterQuality.none,
}) {
  canvas.save();
  canvas.clipRect(picture.bounds);
  canvas.drawImage(
    picture.image,
    Offset.zero,
    Paint()..filterQuality = quality,
  );
  for (final mark in marks) {
    mark.paint(canvas, picture);
  }
  canvas.restore();
}
