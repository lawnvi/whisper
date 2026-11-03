// Realistic device pictures, the main source of texture in the new UI. The
// geometry follows art() in docs/design/whisper-ui-language.html.

import 'package:flutter/widgets.dart';

/// What a device looks like. Comes from its platform, see [deviceKindFor].
enum DeviceKind {
  desktop,
  laptop,
  phone,
  tablet;

  /// Measured by its height, and with nothing to take a keyboard over: a phone
  /// or a tablet cannot be controlled.
  bool get handheld => this == phone || this == tablet;
}

/// How present a device is. Connected and unpaired devices use [normal].
enum DeviceArtState {
  normal,

  /// Paired and nearby, but not connected: a little faded.
  nearby,

  /// Gone: grey and half transparent.
  offline,
}

/// A gradient from top left to bottom right. The only source of per-device
/// color in the interface (DESIGN.md「设备是实物」).
@immutable
class DeviceWallpaper {
  const DeviceWallpaper(this.from, this.to);

  final Color from, to;

  /// This device.
  static const self = DeviceWallpaper(Color(0xFF5B8CFF), Color(0xFF8F7BFF));

  /// Devices that have not been paired.
  static const unpaired = DeviceWallpaper(Color(0xFFC3CBD6), Color(0xFF9AA6B8));

  /// Paired devices, handed out in pairing order and then repeating.
  static const paired = [
    DeviceWallpaper(Color(0xFF2A93FF), Color(0xFF3CC4E8)),
    DeviceWallpaper(Color(0xFF6F86FF), Color(0xFFA78BFA)),
    DeviceWallpaper(Color(0xFF22AECB), Color(0xFF5BD3C6)),
    DeviceWallpaper(Color(0xFF7F7BFF), Color(0xFFC58AF0)),
  ];

  /// The wallpaper of the device paired [order]th, counted from zero.
  factory DeviceWallpaper.forPairingOrder(int order) =>
      paired[order % paired.length];

  LinearGradient get gradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [from, to],
  );
}

/// Same split as `platformIcon`, which knows these spellings. An Android tablet
/// and an Android phone share a platform, so [tablet] is what it said about
/// itself (`DeviceFormFactors`). A foldable draws as a phone. Nothing says
/// whether a Windows or Linux machine is a laptop, so they draw as desktops.
DeviceKind deviceKindFor(
  String platform, {
  String name = '',
  bool tablet = false,
}) {
  // A platform says a Mac or a PC, not which: the name usually does.
  final lower = name.toLowerCase();
  final os = platform.trim().toLowerCase();
  if (os == 'macos' || os == 'windows' || os == 'linux') {
    if (RegExp(
      r'imac|mac ?mini|mac ?studio|mac ?pro|desktop',
    ).hasMatch(lower)) {
      return DeviceKind.desktop;
    }
    if (RegExp(
      r'macbook|thinkpad|laptop|notebook|book|surface|xps|笔记本',
    ).hasMatch(lower)) {
      return DeviceKind.laptop;
    }
  }
  switch (platform.trim().toLowerCase()) {
    case 'ipad':
      return DeviceKind.tablet;
    case 'android':
    case 'ios':
    case 'iphone':
      return tablet ? DeviceKind.tablet : DeviceKind.phone;
    case 'mac':
    case 'macos':
    case 'darwin':
      return DeviceKind.laptop;
    default:
      return DeviceKind.desktop;
  }
}

/// The aspect of each picture, width over height.
double _aspect(DeviceKind kind) => switch (kind) {
  DeviceKind.desktop => 100 / 86,
  DeviceKind.laptop => 100 / 66,
  DeviceKind.phone => 56 / 100,
  DeviceKind.tablet => 76 / 100,
};

/// A realistic device. For handhelds [size] is the height, for computers the width,
/// which is how the prototype and `surfaces.md` measure them.
class DeviceArt extends StatelessWidget {
  const DeviceArt({
    super.key,
    required this.kind,
    required this.wallpaper,
    required this.size,
    this.state = DeviceArtState.normal,
  });

  final DeviceKind kind;
  final DeviceWallpaper wallpaper;
  final double size;
  final DeviceArtState state;

  // CSS filter: saturate(.7) and grayscale(1), for sRGB luminance.
  static List<double> _saturate(double s) {
    const r = .2126, g = .7152, b = .0722;
    final i = 1 - s;
    return [
      i * r + s, i * g, i * b, 0, 0, //
      i * r, i * g + s, i * b, 0, 0, //
      i * r, i * g, i * b + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  @override
  Widget build(BuildContext context) {
    final aspect = _aspect(kind);
    final art = kind.handheld
        ? Size(size * aspect, size)
        : Size(size, size / aspect);
    final (double sat, double opacity) = switch (state) {
      DeviceArtState.normal => (1, 1),
      DeviceArtState.nearby => (.7, .72),
      DeviceArtState.offline => (0, .5),
    };
    final painted = RepaintBoundary(
      child: CustomPaint(
        size: art,
        isComplex: false,
        painter: _DeviceArtPainter(kind, wallpaper),
      ),
    );
    if (state == DeviceArtState.normal) return painted;
    return Opacity(
      opacity: opacity,
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix(_saturate(sat)),
        child: painted,
      ),
    );
  }
}

class _DeviceArtPainter extends CustomPainter {
  const _DeviceArtPainter(this.kind, this.wallpaper);

  final DeviceKind kind;
  final DeviceWallpaper wallpaper;

  static const _metal = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFEEEEF2), Color(0xFFB9B9C1)],
  );
  static const _bezel = Color(0xFF1B1B1E);
  static const _phoneBody = Color(0xFF2B2B2E);
  static const _phoneEdge = Color(0xFF6A6A70);
  static const _phoneIsland = Color(0xFF000000);
  static const _monitorFoot = Color(0xFFA9A9B2);
  static const _laptopNotch = Color(0xFF9A9AA3);

  @override
  void paint(Canvas canvas, Size size) {
    switch (kind) {
      case DeviceKind.desktop:
        _desktop(canvas, size);
      case DeviceKind.laptop:
        _laptop(canvas, size);
      case DeviceKind.phone:
        _phone(canvas, size);
      case DeviceKind.tablet:
        _tablet(canvas, size);
    }
  }

  /// A rounded rectangle in viewBox units, as an SVG `rect`.
  static RRect _r(double x, double y, double w, double h, double r) =>
      RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r));

  // SVG gradients with objectBoundingBox units stretch over each shape, so
  // every shader takes the bounds of the shape it fills.
  Paint _wall(Rect bounds) =>
      Paint()..shader = wallpaper.gradient.createShader(bounds);
  Paint _metalOver(Rect bounds) =>
      Paint()..shader = _metal.createShader(bounds);

  void _desktop(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 86);
    final stand = Path()
      ..moveTo(40, 66)
      ..lineTo(60, 66)
      ..lineTo(62.5, 79)
      ..lineTo(37.5, 79)
      ..close();
    canvas.drawPath(stand, _metalOver(stand.getBounds()));
    canvas.drawRRect(_r(31, 78, 38, 3, 1.5), Paint()..color = _monitorFoot);
    final chin = _r(2, 2, 96, 66, 5);
    canvas.drawRRect(chin, _metalOver(chin.outerRect));
    canvas.drawRRect(_r(2, 2, 96, 55, 5), Paint()..color = _bezel);
    final screen = _r(4.5, 4.5, 91, 50, 2.5);
    canvas.drawRRect(screen, _wall(screen.outerRect));
    canvas.restore();
  }

  void _laptop(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 66);
    canvas.drawRRect(_r(13, 2, 74, 51, 4), Paint()..color = _bezel);
    final screen = _r(15.5, 4.5, 69, 46, 2);
    canvas.drawRRect(screen, _wall(screen.outerRect));
    // M3 54h94l-3 6a3 3 0 0 1-2.7 2H8.7A3 3 0 0 1 6 60z
    final base = Path()
      ..moveTo(3, 54)
      ..lineTo(97, 54)
      ..lineTo(94, 60)
      ..arcToPoint(const Offset(91.3, 62), radius: const Radius.circular(3))
      ..lineTo(8.7, 62)
      ..arcToPoint(const Offset(6, 60), radius: const Radius.circular(3))
      ..close();
    canvas.drawPath(base, _metalOver(base.getBounds()));
    canvas.drawRRect(_r(42, 54, 16, 2.5, 1.25), Paint()..color = _laptopNotch);
    canvas.restore();
  }

  void _phone(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 56, size.height / 100);
    canvas.drawRRect(_r(1, 1, 54, 98, 11), Paint()..color = _phoneBody);
    canvas.drawRRect(
      _r(2, 2, 52, 96, 10),
      Paint()
        ..color = _phoneEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
    final screen = _r(4, 4, 48, 92, 8);
    canvas.drawRRect(screen, _wall(screen.outerRect));
    canvas.drawRRect(_r(20, 8, 16, 4.5, 2.25), Paint()..color = _phoneIsland);
    canvas.restore();
  }

  void _tablet(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 76, size.height / 100);
    canvas.drawRRect(_r(1, 1, 74, 98, 7), Paint()..color = _phoneBody);
    canvas.drawRRect(
      _r(2, 2, 72, 96, 6),
      Paint()
        ..color = _phoneEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
    final screen = _r(4.5, 4.5, 67, 91, 3.5);
    canvas.drawRRect(screen, _wall(screen.outerRect));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DeviceArtPainter old) =>
      old.kind != kind || old.wallpaper != wallpaper;
}

/// A one-color line icon of a device, for the device picker. [size] is the
/// square it sits in; the stroke scales with it, 2 in a viewBox of 32.
class DeviceGlyph extends StatelessWidget {
  const DeviceGlyph({
    super.key,
    required this.kind,
    required this.color,
    this.size = 20,
  });

  final DeviceKind kind;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _DeviceGlyphPainter(kind, color),
  );
}

class _DeviceGlyphPainter extends CustomPainter {
  const _DeviceGlyphPainter(this.kind, this.color);

  final DeviceKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    RRect r(double x, double y, double w, double h, double c) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(c));
    switch (kind) {
      case DeviceKind.phone:
        canvas.drawRRect(r(11, 3, 10, 26, 2.5), p);
        canvas.drawLine(const Offset(14.5, 5.8), const Offset(17.5, 5.8), p);
      case DeviceKind.tablet:
        canvas.drawRRect(r(7, 3, 18, 26, 2.5), p);
      case DeviceKind.desktop:
        canvas.drawRRect(r(3, 5, 26, 17, 2.5), p);
        canvas.drawLine(const Offset(13, 22), const Offset(12.2, 26.5), p);
        canvas.drawLine(const Offset(19, 22), const Offset(19.8, 26.5), p);
        canvas.drawLine(const Offset(10, 26.5), const Offset(22, 26.5), p);
      case DeviceKind.laptop:
        canvas.drawRRect(r(6.5, 7, 19, 14, 2), p);
        canvas.drawLine(const Offset(3, 24.5), const Offset(29, 24.5), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DeviceGlyphPainter old) =>
      old.kind != kind || old.color != color;
}
