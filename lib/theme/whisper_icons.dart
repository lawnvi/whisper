import 'package:whisper/theme/radix_colors.dart';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The interface's line icons, drawn from the same paths as the prototype
/// (docs/design/whisper-ui-language.html). Material's icons have another weight
/// and proportion, and next to these they read as a different product.
enum WhisperGlyph {
  chat,
  folder,
  apps,
  speaker,
  keyboard,
  clip,
  drive,
  link,
  power,
  search,
  info,
  back,
  right,
  plus,
  x,
  check,
  out,
  pause,
  play,
  bolt,
  flip,
  up,
  doc,
  ask,
  gear,
  more,
  copy,
  qr,
  trash,
  lock,
  camera,
  warn,
  updown,
  window,
  globe,
  cast,
  phone,
  bell,
  sliders,
  plane,
  star,
  eye,
  eyeOff,
  markRect,
  markEllipse,
  markArrow,
  markPen,
  markText,
  markMosaic,
  undo,
  redo,
  download,
}

const Map<WhisperGlyph, String> _paths = {
  WhisperGlyph.chat:
      'M4 5.5A2.5 2.5 0 0 1 6.5 3h7A2.5 2.5 0 0 1 16 5.5v6a2.5 2.5 0 0 1-2.5 2.5H9l-3.5 3v-3A2.5 2.5 0 0 1 4 11.5z',
  WhisperGlyph.folder:
      'M3 6a1.5 1.5 0 0 1 1.5-1.5h3.2l1.8 2h6A1.5 1.5 0 0 1 17 8v6.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 3 14.5z',
  WhisperGlyph.apps: 'M4 4h5v5H4zM11 4h5v5h-5zM4 11h5v5H4zM11 11h5v5h-5z',
  WhisperGlyph.speaker:
      'M4 8v4h2.5L10 15V5L6.5 8zM13 7.5a3.5 3.5 0 0 1 0 5M15 5.5a6.3 6.3 0 0 1 0 9',
  WhisperGlyph.keyboard:
      'M3 6h14a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1zM5.5 9h.01M8.5 9h.01M11.5 9h.01M14.5 9h.01M6.5 11.5h7',
  WhisperGlyph.markRect: 'M4.5 5h11a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z',
  WhisperGlyph.markEllipse: 'M10 4c4.2 0 7 2.6 7 6s-2.8 6-7 6-7-2.6-7-6 2.8-6 7-6z',
  WhisperGlyph.markArrow: 'M4.5 15.5 15.5 4.5M8.5 4.5h7v7',
  WhisperGlyph.markPen:
      'M4 16l.8-3.4L13.2 4.2a1.4 1.4 0 0 1 2 0l.6.6a1.4 1.4 0 0 1 0 2L7.4 15.2zM11.6 5.8l2.6 2.6',
  WhisperGlyph.markText: 'M4.5 6.5v-2h11v2M10 4.5v11M7.5 15.5h5',
  WhisperGlyph.markMosaic:
      'M3.5 3.5h4.3v4.3H3.5zM12.2 3.5h4.3v4.3h-4.3zM7.8 7.8h4.4v4.4H7.8zM3.5 12.2h4.3v4.3H3.5zM12.2 12.2h4.3v4.3h-4.3z',
  WhisperGlyph.undo: 'M7.5 4.5 4 8l3.5 3.5M4 8h8a4 4 0 0 1 0 8H9.5',
  WhisperGlyph.redo: 'M12.5 4.5 16 8l-3.5 3.5M16 8H8a4 4 0 0 0 0 8h2.5',
  WhisperGlyph.download: 'M10 3.5v9.5M6 9.5l4 4 4-4M4 16.5h12',
  WhisperGlyph.clip:
      'M7 4.5H5.5A1.5 1.5 0 0 0 4 6v10a1.5 1.5 0 0 0 1.5 1.5h9A1.5 1.5 0 0 0 16 16V6a1.5 1.5 0 0 0-1.5-1.5H13M7.5 3h5v3h-5z',
  WhisperGlyph.drive:
      'M3.5 11.5 5.5 4.5h9l2 7M3.5 11.5h13v3.5a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1zM13.5 14h.01',
  WhisperGlyph.link:
      'M8.5 11.5a3 3 0 0 0 4.2 0l2.3-2.3a3 3 0 0 0-4.2-4.2l-.8.8M11.5 8.5a3 3 0 0 0-4.2 0L5 10.8A3 3 0 0 0 9.2 15l.8-.8',
  WhisperGlyph.power: 'M10 2.5v7M6.5 4.9a6.25 6.25 0 1 0 7 0',
  WhisperGlyph.search: 'M9 15A6 6 0 1 0 9 3a6 6 0 0 0 0 12zM13.5 13.5 17 17',
  WhisperGlyph.info:
      'M10 17.5a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15zM10 9.5v4M10 6.5h.01',
  WhisperGlyph.back: 'M12.5 4 6.5 10l6 6',
  WhisperGlyph.right: 'M7.5 4l6 6-6 6',
  WhisperGlyph.plus: 'M10 4v12M4 10h12',
  WhisperGlyph.x: 'M5 5l10 10M15 5 5 15',
  WhisperGlyph.check: 'M4 10.5l4 4 8-9',
  WhisperGlyph.eye:
      'M2.6 10c1.7-3.1 4.2-4.7 7.4-4.7s5.7 1.6 7.4 4.7c-1.7 3.1-4.2 4.7-7.4 4.7S4.3 13.1 2.6 10zM10 12a2 2 0 1 0 0-4 2 2 0 0 0 0 4z',
  WhisperGlyph.eyeOff:
      'M2.8 8.2c1.8 2.7 4.2 4.1 7.2 4.1s5.4-1.4 7.2-4.1M10 12.3v2.6M5.9 11.2l-1.4 2.1M14.1 11.2l1.4 2.1',
  WhisperGlyph.star:
      'M10 2.8l2.2 4.6 5 .7-3.6 3.5.9 5L10 14.2l-4.5 2.4.9-5-3.6-3.5 5-.7z',
  WhisperGlyph.out: 'M10 13V4M6 7.5l4-4 4 4M4 16.5h12',
  WhisperGlyph.pause: 'M7 5v10M13 5v10',
  WhisperGlyph.play: 'M7 4.5v11l9-5.5z',
  WhisperGlyph.bolt: 'M11 2.5 4.5 11.5H10L9 17.5l6.5-9H10z',
  WhisperGlyph.flip:
      'M4 8a6.5 6.5 0 0 1 11-2.5L16.5 7M16.5 3v4h-4M16 12a6.5 6.5 0 0 1-11 2.5L3.5 13M3.5 17v-4h4',
  WhisperGlyph.up: 'M10 16V4M5 9l5-5 5 5',
  WhisperGlyph.doc: 'M6 3h5l4 4v10H6zM11 3v4h4',
  WhisperGlyph.ask:
      'M10 17.5a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15zM8 8a2 2 0 1 1 3 1.7c-.7.4-1 .8-1 1.6M10 14h.01',
  WhisperGlyph.more: 'M4.5 10h.01M10 10h.01M15.5 10h.01',
  WhisperGlyph.copy: 'M7 7h9v10H7zM13 7V3H4v10h3',
  WhisperGlyph.qr:
      'M3.5 3.5h5v5h-5zM11.5 3.5h5v5h-5zM3.5 11.5h5v5h-5zM11.5 11.5h2v2h-2zM15 15h1.5v1.5H15z',
  WhisperGlyph.trash: 'M4 6h12M8 6V3.5h4V6M6 6l.7 11h6.6L14 6',
  WhisperGlyph.lock: 'M5.5 9h9v8h-9zM7 9V6.5a3 3 0 0 1 6 0V9',
  WhisperGlyph.camera:
      'M3 7h3l1.5-2.5h5L14 7h3v9.5H3zM10 14a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z',
  WhisperGlyph.warn: 'M10 3.5 18 16.5H2zM10 8.5v4M10 14.5h.01',
  WhisperGlyph.updown: 'M6.5 8 10 4.5 13.5 8M6.5 12 10 15.5 13.5 12',
  WhisperGlyph.window: 'M3 4.5h14v11H3zM3 8h14',
  WhisperGlyph.globe:
      'M10 17.5a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15zM2.5 10h15M10 2.5c2.2 2 3 4.7 3 7.5s-.8 5.5-3 7.5c-2.2-2-3-4.7-3-7.5s.8-5.5 3-7.5z',
  WhisperGlyph.cast:
      'M3 14a3 3 0 0 1 3 3M3 10.5A6.5 6.5 0 0 1 9.5 17M3 5h14v12h-4',
  WhisperGlyph.phone:
      'M7 2.5h6a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1v-13a1 1 0 0 1 1-1zM9 15h2',
  WhisperGlyph.bell: 'M5 13.5V9a5 5 0 0 1 10 0v4.5l1.5 2h-13zM8.5 17.5h3',
  WhisperGlyph.sliders: 'M4 6h7M15 6h1M4 14h1M9 14h7M11 4v4h4V4zM5 12v4h4v-4z',
  WhisperGlyph.plane: 'M3 10l14-6-5 13-2.5-5.5z',
};

String _gearPath() {
  String pt(double r, double deg) {
    final a = deg * math.pi / 180;
    return '${(10 + r * math.cos(a)).toStringAsFixed(2)} '
        '${(10 + r * math.sin(a)).toStringAsFixed(2)}';
  }

  final d = StringBuffer();
  for (var i = 0; i < 8; i++) {
    final a = i * 45.0;
    d
      ..write(i == 0 ? 'M' : 'L')
      ..write(pt(6, a - 15))
      ..write('L${pt(8.2, a - 8)}L${pt(8.2, a + 8)}L${pt(6, a + 15)}');
  }
  d.write('zM12.5 10a2.5 2.5 0 1 1-5 0 2.5 2.5 0 1 1 5 0z');
  return d.toString();
}

final Map<String, Path> _parsed = {};

/// Enough of SVG's path syntax for the paths above.
Path whisperSvgPath(String d) => _parsed.putIfAbsent(d, () => _parse(d));

Path _parse(String d) {
  final tokens = RegExp(
    r'[MmLlHhVvCcSsQqAaZz]|-?\d*\.?\d+',
  ).allMatches(d).map((m) => m.group(0)!).toList();
  final path = Path();
  var i = 0;
  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  var lastCx = 0.0, lastCy = 0.0;
  var cmd = '';
  double n() => double.parse(tokens[i++]);
  bool isCommand(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
  while (i < tokens.length) {
    if (isCommand(tokens[i])) cmd = tokens[i++];
    final rel = cmd == cmd.toLowerCase();
    switch (cmd.toLowerCase()) {
      case 'm':
        final nx = n(), ny = n();
        x = rel ? x + nx : nx;
        y = rel ? y + ny : ny;
        path.moveTo(x, y);
        startX = x;
        startY = y;
        // Further pairs are lines.
        cmd = rel ? 'l' : 'L';
      case 'l':
        final nx = n(), ny = n();
        x = rel ? x + nx : nx;
        y = rel ? y + ny : ny;
        path.lineTo(x, y);
      case 'h':
        final nx = n();
        x = rel ? x + nx : nx;
        path.lineTo(x, y);
      case 'v':
        final ny = n();
        y = rel ? y + ny : ny;
        path.lineTo(x, y);
      case 'c':
        final x1 = n(), y1 = n(), x2 = n(), y2 = n(), ex = n(), ey = n();
        final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
        path.cubicTo(x1 + ox, y1 + oy, x2 + ox, y2 + oy, ex + ox, ey + oy);
        lastCx = x2 + ox;
        lastCy = y2 + oy;
        x = ex + ox;
        y = ey + oy;
      case 's':
        final x2 = n(), y2 = n(), ex = n(), ey = n();
        final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
        path.cubicTo(
          2 * x - lastCx,
          2 * y - lastCy,
          x2 + ox,
          y2 + oy,
          ex + ox,
          ey + oy,
        );
        lastCx = x2 + ox;
        lastCy = y2 + oy;
        x = ex + ox;
        y = ey + oy;
      case 'q':
        final x1 = n(), y1 = n(), ex = n(), ey = n();
        final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
        path.quadraticBezierTo(x1 + ox, y1 + oy, ex + ox, ey + oy);
        x = ex + ox;
        y = ey + oy;
      case 'a':
        final rx = n(), ry = n(), rot = n(), large = n(), sweep = n();
        final ex = n(), ey = n();
        final tx = rel ? x + ex : ex, ty = rel ? y + ey : ey;
        path.arcToPoint(
          Offset(tx, ty),
          radius: Radius.elliptical(rx, ry),
          rotation: rot,
          largeArc: large != 0,
          clockwise: sweep != 0,
        );
        x = tx;
        y = ty;
      case 'z':
        path.close();
        x = startX;
        y = startY;
      default:
        throw FormatException('Unsupported path command $cmd in $d');
    }
  }
  return path;
}

Path whisperGlyphPath(WhisperGlyph glyph) => whisperSvgPath(
  glyph == WhisperGlyph.gear ? _gearPathCached : _paths[glyph]!,
);

final String _gearPathCached = _gearPath();

/// Stroked in a 20-unit box, with round ends, like the prototype's `ic()`.
class WhisperIcon extends StatelessWidget {
  const WhisperIcon(
    this.glyph, {
    super.key,
    this.size = 16,
    this.weight = 1.6,
    this.color,
    this.filled = false,
  });

  final WhisperGlyph glyph;
  final double size, weight;

  /// The inside painted too, for a shape that shows it is on: the star.
  final bool filled;

  /// The surrounding icon colour when null.
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _StrokePainter(
        whisperGlyphPath(glyph),
        weight,
        color ?? IconTheme.of(context).color ?? Radix.black,
        filled: filled,
      ),
    ),
  );
}

class _StrokePainter extends CustomPainter {
  const _StrokePainter(
    this.path,
    this.weight,
    this.color, {
    this.filled = false,
  });

  final Path path;
  final double weight;
  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 20);
    if (filled) canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = weight
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_StrokePainter old) =>
      old.path != path ||
      old.weight != weight ||
      old.color != color ||
      old.filled != filled;
}

/// A sheet of white paper with a folded corner: every file, every kind.
class WhisperDocArt extends StatelessWidget {
  const WhisperDocArt({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CustomPaint(painter: _DocPainter()),
  );
}

class _DocPainter extends CustomPainter {
  const _DocPainter();

  static final _sheet = whisperSvgPath(
    'M5 2h7l4 4v11a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1z',
  );
  static final _fold = whisperSvgPath('M12 2v4h4');

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 20);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7
      ..strokeJoin = StrokeJoin.round
      ..color = Radix.blackA5;
    canvas
      ..drawPath(_sheet, Paint()..color = Radix.white)
      ..drawPath(_sheet, line)
      ..drawPath(_fold, Paint()..color = Radix.slate4)
      ..drawPath(_fold, line);
  }

  @override
  bool shouldRepaint(_DocPainter old) => false;
}

/// A blue folder, solid, like the system's.
class WhisperFolderArt extends StatelessWidget {
  const WhisperFolderArt({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CustomPaint(painter: _FolderPainter()),
  );
}

class _FolderPainter extends CustomPainter {
  const _FolderPainter();

  static final _back = whisperSvgPath(
    'M2 5.5A1.5 1.5 0 0 1 3.5 4h3.7l1.8 1.8h7.5A1.5 1.5 0 0 1 18 7.3V15a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 2 15z',
  );
  static final _front = whisperSvgPath(
    'M2 8.2a1.2 1.2 0 0 1 1.2-1.2h13.6A1.2 1.2 0 0 1 18 8.2V15a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 2 15z',
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 20);
    canvas
      ..drawPath(_back, Paint()..color = Radix.blue8)
      ..drawPath(_front, Paint()..color = Radix.blue7);
  }

  @override
  bool shouldRepaint(_FolderPainter old) => false;
}
