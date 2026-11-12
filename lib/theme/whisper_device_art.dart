// Realistic device pictures, the main source of texture in the interface. The
// geometry follows art() in docs/design/whisper-ui-language.html.

import 'dart:math' as math;

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

/// Which system a device runs. No vendor's logo: Apple and Microsoft do not
/// allow it, so a Mac is silver with a menu bar and a Dock, Windows is graphite
/// with a taskbar, an iPhone has the island at the top and the bar at the
/// bottom; Linux has the penguin and Android the robot's head, which are free
/// to use.
enum DeviceOs { mac, windows, linux, android, ios, other }

DeviceOs deviceOsFor(String platform) =>
    switch (platform.trim().toLowerCase()) {
      'mac' || 'macos' || 'darwin' => DeviceOs.mac,
      'windows' || 'win32' => DeviceOs.windows,
      'linux' => DeviceOs.linux,
      'android' => DeviceOs.android,
      'ios' || 'iphone' || 'ipad' => DeviceOs.ios,
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
/// itself (`DeviceFormFactors`). A foldable draws as a phone. A computer from
/// 0.0.61 says whether it is a laptop or a desktop ([formFactor]); for an
/// older one the name is the best guess, and a Windows or Linux machine
/// that says nothing draws as a desktop.
DeviceKind deviceKindFor(
  String platform, {
  String name = '',
  bool tablet = false,
  String formFactor = '',
}) {
  // A platform says a Mac or a PC, not which: the name usually does.
  final lower = name.toLowerCase();
  final os = platform.trim().toLowerCase();
  if (os == 'macos' || os == 'windows' || os == 'linux') {
    if (formFactor == 'laptop') return DeviceKind.laptop;
    if (formFactor == 'desktop') return DeviceKind.desktop;
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

/// Where the middle of a picture's screen is, for what stands on the screen.
/// The heights are those in the painter's viewBoxes.
Alignment deviceScreenCenter(DeviceKind kind, DeviceOs os) => switch (kind) {
  DeviceKind.laptop => const Alignment(0, 27.5 / 33 - 1),
  DeviceKind.desktop => Alignment(
    0,
    (os == DeviceOs.windows || os == DeviceOs.linux ? 35 : 29.5) / 43 - 1,
  ),
  DeviceKind.phone || DeviceKind.tablet => Alignment.center,
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
    this.bare = false,
  });

  /// Only the wallpaper on the screen, for something to stand on it.
  final bool bare;

  final DeviceKind kind;
  final DeviceWallpaper wallpaper;
  final double size;
  final DeviceArtState state;

  /// What the screen and the body say about the system: see [DeviceOs].
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
        painter: _DeviceArtPainter(kind, wallpaper, os, bare: bare),
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
  const _DeviceArtPainter(
    this.kind,
    this.wallpaper,
    this.os, {
    this.bare = false,
  });

  final DeviceKind kind;
  final DeviceWallpaper wallpaper;
  final DeviceOs os;
  final bool bare;

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
    if (bare) return;
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
      case DeviceOs.android || DeviceOs.ios || DeviceOs.other:
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

  /// An iPhone has the island and the bar under the apps; an Android phone,
  /// a little squarer, a punched-out camera and the robot on its screen.
  void _phone(Canvas canvas, Size size) {
    final android = os == DeviceOs.android;
    canvas.save();
    canvas.scale(size.width / 56, size.height / 100);
    final round = android ? 8.0 : 11.0;
    canvas.drawRRect(_r(1, 1, 54, 98, round), Paint()..color = _phoneBody);
    canvas.drawRRect(
      _r(2, 2, 52, 96, round - 1),
      Paint()
        ..color = _phoneEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
    final screen = _r(4, 4, 48, 92, round - 3);
    canvas.drawRRect(screen, _wall(screen.outerRect));
    if (android) {
      if (!bare) _robot(canvas, screen.outerRect.center, 30);
      canvas.drawCircle(
        const Offset(28, 9.5),
        2.1,
        Paint()..color = _phoneIsland,
      );
    } else {
      canvas.drawRRect(_r(20, 8, 16, 4.5, 2.25), Paint()..color = _phoneIsland);
      if (os == DeviceOs.ios && !bare) _homeBar(canvas, 28, 91.5, 16);
    }
    canvas.restore();
  }

  /// The line along the bottom of an iPhone's or an iPad's screen.
  void _homeBar(Canvas canvas, double center, double y, double width) =>
      canvas.drawRRect(
        _r(center - width / 2, y, width, 1.5, .75),
        Paint()..color = Radix.whiteA11,
      );

  /// Android's robot, its head only: green, two eyes, two feelers.
  void _robot(Canvas canvas, Offset center, double width) {
    canvas.save();
    canvas.translate(center.dx - width / 2, center.dy - width * .33);
    canvas.scale(width / 24);
    final green = Paint()..color = Radix.green9;
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(12, 15), radius: 10),
      math.pi,
      math.pi,
      true,
      green,
    );
    final feeler = Paint()
      ..color = Radix.green9
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(6.6, 7.6), const Offset(4.4, 3.8), feeler);
    canvas.drawLine(const Offset(17.4, 7.6), const Offset(19.6, 3.8), feeler);
    final eye = Paint()..color = Radix.white;
    canvas.drawCircle(const Offset(8, 10.8), 1.25, eye);
    canvas.drawCircle(const Offset(16, 10.8), 1.25, eye);
    canvas.restore();
  }

  /// An iPad has the bar along the bottom; an Android tablet the robot.
  /// Both have the camera in the bezel.
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
    if (os == DeviceOs.android || os == DeviceOs.ios) {
      canvas.drawCircle(
        const Offset(38, 2.9),
        .9,
        Paint()..color = _phoneIsland,
      );
    }
    if (!bare) {
      if (os == DeviceOs.android) _robot(canvas, screen.outerRect.center, 34);
      if (os == DeviceOs.ios) _homeBar(canvas, 38, 91.5, 20);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DeviceArtPainter old) =>
      old.kind != kind ||
      old.wallpaper != wallpaper ||
      old.os != os ||
      old.bare != bare;
}

/// A one-color line icon of a device: in the device list, white on the
/// round avatar, and in the device pickers. [size] is the square it sits
/// in; the stroke scales with it, 2 in a viewBox of 32.
///
/// Only the outline says what it is: a laptop, a monitor on its stand, a
/// phone or a tablet, the last two by their proportions alone. With [os],
/// the system's mark in the middle of the screen: an apple, the four panes
/// of Windows, a prompt for Linux, Android's robot.
class DeviceGlyph extends StatelessWidget {
  const DeviceGlyph({
    super.key,
    required this.kind,
    required this.color,
    this.size = 20,
    this.os = DeviceOs.other,
  });

  final DeviceKind kind;
  final Color color;
  final double size;
  final DeviceOs os;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _DeviceGlyphPainter(kind, color, os),
  );
}

class _DeviceGlyphPainter extends CustomPainter {
  const _DeviceGlyphPainter(this.kind, this.color, this.os);

  final DeviceKind kind;
  final Color color;
  final DeviceOs os;

  static RRect _r(double x, double y, double w, double h, double c) =>
      RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(c));

  Paint _stroke(double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    final line = _stroke(2);
    switch (kind) {
      case DeviceKind.laptop:
        canvas.drawRRect(_r(6, 7, 20, 14, 2), line);
        canvas.drawLine(const Offset(3, 24.5), const Offset(29, 24.5), line);
        _mark(canvas, const Offset(16, 14), 7.5);
      case DeviceKind.desktop:
        canvas.drawRRect(_r(3, 4.5, 26, 17.5, 2.5), line);
        canvas.drawLine(const Offset(16, 22), const Offset(16, 26.5), line);
        canvas.drawLine(const Offset(11, 26.5), const Offset(21, 26.5), line);
        _mark(canvas, const Offset(16, 13.25), 8.5);
      case DeviceKind.phone:
        canvas.drawRRect(_r(10, 4, 12, 24, 3), line);
        _mark(canvas, const Offset(16, 16), 7);
      case DeviceKind.tablet:
        canvas.drawRRect(_r(7, 5, 18, 22, 2.5), line);
        _mark(canvas, const Offset(16, 16), 8);
    }
    canvas.restore();
  }

  /// The system's mark, [side] across, centred on [c].
  void _mark(Canvas canvas, Offset c, double side) {
    final fill = Paint()..color = color;
    switch (os) {
      case DeviceOs.mac || DeviceOs.ios:
        // A little taller than the panes: it is rounder and looks smaller.
        final k = side * 1.15 / _appleHeight;
        canvas.save();
        canvas.translate(c.dx - 12 * k, c.dy - 12.4 * k);
        canvas.scale(k);
        canvas.drawPath(whisperSvgPath(_apple), fill);
        canvas.restore();
      case DeviceOs.windows:
        final gap = side * .1, pane = (side - gap) / 2;
        for (final (x, y) in const [(0, 0), (1, 0), (0, 1), (1, 1)]) {
          canvas.drawRect(
            Rect.fromLTWH(
              c.dx - side / 2 + x * (pane + gap),
              c.dy - side / 2 + y * (pane + gap),
              pane,
              pane,
            ),
            fill,
          );
        }
      case DeviceOs.linux:
        final prompt = _stroke(side * .2);
        final x = c.dx - side * .45, h = side * .32;
        canvas.drawPath(
          Path()
            ..moveTo(x, c.dy - h)
            ..lineTo(x + h, c.dy)
            ..lineTo(x, c.dy + h),
          prompt,
        );
        canvas.drawLine(
          Offset(c.dx + side * .05, c.dy + h),
          Offset(c.dx + side * .45, c.dy + h),
          prompt,
        );
      case DeviceOs.android:
        _robot(canvas, c, side * 1.15);
      case DeviceOs.other:
        break;
    }
  }

  /// Android's robot, its head: [width] across, centred on [c] with its
  /// feelers.
  void _robot(Canvas canvas, Offset c, double width) {
    final r = width / 2;
    final chin = c + Offset(0, r * .55);
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addArc(Rect.fromCircle(center: chin, radius: r), math.pi, math.pi)
        ..close()
        ..addOval(
          Rect.fromCircle(
            center: chin + Offset(-r * .42, -r * .45),
            radius: r * .13,
          ),
        )
        ..addOval(
          Rect.fromCircle(
            center: chin + Offset(r * .42, -r * .45),
            radius: r * .13,
          ),
        ),
      Paint()..color = color,
    );
    final feeler = _stroke(r * .2);
    for (final side in const [-1, 1]) {
      canvas.drawLine(
        chin + Offset(side * r * .5, -r * .86),
        chin + Offset(side * r * .78, -r * 1.25),
        feeler,
      );
    }
  }

  /// An apple with its leaf and the bite, in a box of 24, centred on
  /// (12, 12.4) and [_appleHeight] tall.
  static const _appleHeight = 20.0;
  static const _apple =
      'M12 7.6C13.3 7.6 14.5 6.6 16.2 6.6C17.6 6.6 18.9 7.3 19.8 8.5'
      'C17.6 9.8 17 13.6 20.4 15.3C19.6 17.7 18.2 20.4 16.6 21.6'
      'C15.6 22.4 14.8 22.2 13.8 21.8C12.9 21.4 11.9 21.3 10.9 21.7'
      'C9.8 22.1 8.9 22.4 7.9 21.6C5.6 19.8 3.6 15.6 3.9 12.1'
      'C4.1 9 6.2 6.8 8.6 6.7C10 6.6 11 7.6 12 7.6Z'
      'M12.1 6.2C12 4.3 13.6 2.6 15.6 2.4C15.8 4.4 14 6.2 12.1 6.2Z';

  @override
  bool shouldRepaint(_DeviceGlyphPainter old) =>
      old.kind != kind || old.color != color || old.os != os;
}
