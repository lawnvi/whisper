// Realistic device pictures, the main source of texture in the interface. The
// geometry follows art() in docs/design/whisper-ui-language.html.

import 'package:flutter/widgets.dart';
import 'package:whisper/theme/radix_colors.dart';
import 'package:whisper/theme/whisper_icons.dart';

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

/// Which system a computer runs. No vendor's logo: Apple and Microsoft do not allow
/// it, so a Mac is silver with a menu bar and a Dock, Windows is graphite with a
/// taskbar, and Linux has the penguin, which is free to use.
enum DeviceOs { mac, windows, linux, other }

DeviceOs deviceOsFor(String platform) =>
    switch (platform.trim().toLowerCase()) {
      'mac' || 'macos' || 'darwin' => DeviceOs.mac,
      'windows' || 'win32' => DeviceOs.windows,
      'linux' => DeviceOs.linux,
      _ => DeviceOs.other,
    };

/// The system's name, to say in words what the picture only suggests.
String? deviceSystemName(String platform) =>
    switch (platform.trim().toLowerCase()) {
      'mac' || 'macos' || 'darwin' => 'macOS',
      'windows' || 'win32' => 'Windows',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' || 'iphone' => 'iOS',
      'ipad' => 'iPadOS',
      _ => null,
    };

/// How present a device is. Connected and unpaired devices use [normal].
enum DeviceArtState {
  normal,

  /// Paired and nearby, but not connected: only just faded. It is there, and
  /// must not be mistaken for [offline], which has no colour at all.
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
  static const self = DeviceWallpaper(Radix.indigo9, Radix.violet9);

  /// Devices that have not been paired. Paler than a paired one's, but a colour:
  /// grey is for what is gone.
  static const unpaired = DeviceWallpaper(Radix.blue7, Radix.blue8);

  /// Paired devices, handed out in pairing order and then repeating.
  static const paired = [
    DeviceWallpaper(Radix.blue9, Radix.cyan9),
    DeviceWallpaper(Radix.iris9, Radix.violet9),
    DeviceWallpaper(Radix.cyan9, Radix.teal9),
    DeviceWallpaper(Radix.violet9, Radix.purple9),
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
    this.os = DeviceOs.other,
  });

  final DeviceKind kind;
  final DeviceWallpaper wallpaper;
  final double size;
  final DeviceArtState state;

  /// Only a computer shows it: a phone's screen is too narrow to say anything.
  final DeviceOs os;

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
      DeviceArtState.nearby => (.85, .9),
      DeviceArtState.offline => (0, .45),
    };
    final painted = RepaintBoundary(
      child: CustomPaint(
        size: art,
        isComplex: false,
        painter: _DeviceArtPainter(kind, wallpaper, os),
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
  const _DeviceArtPainter(this.kind, this.wallpaper, this.os);

  final DeviceKind kind;
  final DeviceWallpaper wallpaper;
  final DeviceOs os;

  bool get _graphite => os == DeviceOs.windows || os == DeviceOs.linux;

  static const _metal = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Radix.slate3, Radix.slate8],
  );
  static const _bezel = Radix.slate12;
  static const _phoneBody = Radix.slateDark4;
  static const _phoneEdge = Radix.slateDark9;
  static const _phoneIsland = Radix.black;
  static const _monitorFoot = Radix.slate8;
  static const _graphiteBody = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Radix.slate11, Radix.slateDark5],
  );
  static const _graphiteFoot = Radix.slate11;
  static const _graphiteNotch = Radix.slate9;
  static const _laptopNotch = Radix.slate9;

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
      Paint()
        ..shader = (_graphite ? _graphiteBody : _metal).createShader(bounds);

  /// What the system puts on the screen.
  void _system(Canvas canvas, RRect screen) {
    final s = screen.outerRect;
    canvas.save();
    canvas.clipRRect(screen);
    switch (os) {
      case DeviceOs.mac:
        canvas.drawRect(
          Rect.fromLTWH(s.left, s.top, s.width, s.height * .11),
          Paint()..color = Radix.whiteA8,
        );
        final w = s.width * .54, h = s.height * .17;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              s.center.dx - w / 2,
              s.bottom - h - s.height * .07,
              w,
              h,
            ),
            Radius.circular(h * .32),
          ),
          Paint()..color = Radix.whiteA9,
        );
      case DeviceOs.windows:
        final h = s.height * .18;
        canvas.drawRect(
          Rect.fromLTWH(s.left, s.bottom - h, s.width, h),
          Paint()..color = Radix.whiteA10,
        );
        final d = h * .52;
        for (var i = -1; i <= 1; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(s.center.dx + i * d * 1.6, s.bottom - h / 2),
                width: d,
                height: d,
              ),
              Radius.circular(d * .2),
            ),
            Paint()..color = Radix.slate11,
          );
        }
      case DeviceOs.linux:
        _penguin(canvas, s.center, s.height * .68);
      case DeviceOs.other:
        break;
    }
    canvas.restore();
  }

  void _penguin(Canvas canvas, Offset center, double side) {
    canvas.save();
    canvas.translate(center.dx - side / 2, center.dy - side / 2);
    canvas.scale(side / 24);
    canvas.drawPath(
      whisperSvgPath(_penguinBelly),
      Paint()..color = Radix.white,
    );
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addPath(whisperSvgPath(_penguinBody), Offset.zero)
        ..addPath(whisperSvgPath(_penguinBelly), Offset.zero),
      Paint()..color = Radix.slate12,
    );
    final amber = Paint()..color = Radix.amber9;
    canvas.drawPath(whisperSvgPath(_penguinBeak), amber);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(7.4, 21.6), width: 7.2, height: 3.4),
      amber,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: const Offset(16.6, 21.6),
        width: 7.2,
        height: 3.4,
      ),
      amber,
    );
    canvas.restore();
  }

  static const _penguinBody =
      'M12 .8C9 .8 7.4 3 7.4 5.8c0 1.5.3 2.5-.3 3.7C6.2 11.2 4.2 13.5 4.2 16.8'
      'c0 1.8.6 3.2 1.6 4.2h12.4c1-1 1.6-2.4 1.6-4.2 0-3.3-2-5.6-2.9-7.3'
      '-.6-1.2-.3-2.2-.3-3.7C16.6 3 15 .8 12 .8z';
  static const _penguinBelly =
      'M12 9.4c-2.3 0-3.9 3.2-3.9 6.3 0 2.5 1.7 4.4 3.9 4.4s3.9-1.9 3.9-4.4'
      'c0-3.1-1.6-6.3-3.9-6.3z';
  static const _penguinBeak = 'M10.2 6.6h3.6L12 8.6z';

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
    canvas.drawRRect(
      _r(31, 78, 38, 3, 1.5),
      Paint()..color = _graphite ? _graphiteFoot : _monitorFoot,
    );
    final chin = _r(2, 2, 96, 66, 5);
    canvas.drawRRect(chin, _metalOver(chin.outerRect));
    canvas.drawRRect(_r(2, 2, 96, 55, 5), Paint()..color = _bezel);
    // A PC monitor is the same all the way round; an iMac has its chin.
    if (_graphite) canvas.drawRRect(chin, Paint()..color = _bezel);
    final screen = _graphite
        ? _r(4.5, 4.5, 91, 61, 2.5)
        : _r(4.5, 4.5, 91, 50, 2.5);
    canvas.drawRRect(screen, _wall(screen.outerRect));
    _system(canvas, screen);
    canvas.restore();
  }

  void _laptop(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 66);
    canvas.drawRRect(_r(13, 2, 74, 51, 4), Paint()..color = _bezel);
    final screen = _r(15.5, 4.5, 69, 46, 2);
    canvas.drawRRect(screen, _wall(screen.outerRect));
    _system(canvas, screen);
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
    canvas.drawRRect(
      _r(42, 54, 16, 2.5, 1.25),
      Paint()..color = _graphite ? _graphiteNotch : _laptopNotch,
    );
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
      old.kind != kind || old.wallpaper != wallpaper || old.os != os;
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
