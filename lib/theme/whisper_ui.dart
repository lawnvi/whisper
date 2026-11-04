// The design language in code: tokens, springs and the shared controls.
// Rules live in DESIGN.md; recipes and their history in docs/design/flutter.md.
// New UI uses these. Old pages keep their own tokens until they are rebuilt.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui'
    show DisplayFeature, DisplayFeatureState, DisplayFeatureType, ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:whisper/theme/radix_colors.dart';

export 'package:whisper/theme/radix_colors.dart';

/// All colors of the design language. Values come from DESIGN.md.
@immutable
class WhisperColors extends ThemeExtension<WhisperColors> {
  const WhisperColors({
    required this.canvas,
    required this.content,
    required this.group,
    required this.raised,
    required this.bubble,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.ink2Glass,
    required this.accent,
    required this.accentText,
    required this.onAccent,
    required this.tint,
    required this.tintHover,
    required this.tintActive,
    required this.onTint,
    required this.tintSelection,
    required this.ok,
    required this.okSolid,
    required this.warn,
    required this.warnSolid,
    required this.bad,
    required this.badSolid,
    required this.sep,
    required this.sidebarEdge,
    required this.border,
    required this.fill,
    required this.fill2,
    required this.selected,
    required this.sidebarSolid,
    required this.sidebarSelected,
    required this.sidebarVeil,
    required this.scrim,
    required this.deviceName,
    required this.deviceMuted,
    required this.deviceOn,
    required this.deviceNear,
    required this.deviceOff,
    required this.deviceOffDot,
    required this.deviceSelected,
  });

  static const light = WhisperColors(
    canvas: Radix.slate2,
    content: Radix.white,
    group: Radix.white,
    raised: Radix.white,
    bubble: Radix.slate3,
    ink: Radix.slate12,
    ink2: Radix.slate11,
    ink3: Radix.slate10,
    ink2Glass: Radix.slateA11,
    accent: Radix.blue9,
    accentText: Radix.blue11,
    onAccent: Radix.white,
    tint: Radix.blue3,
    tintHover: Radix.blue4,
    tintActive: Radix.blue5,
    onTint: Radix.blue12,
    tintSelection: Radix.blue7,
    ok: Radix.green11,
    okSolid: Radix.green9,
    warn: Radix.amber11,
    warnSolid: Radix.amber9,
    bad: Radix.red11,
    badSolid: Radix.red9,
    sep: Radix.slateA6,
    sidebarEdge: Radix.slateA3,
    border: Radix.slateA7,
    fill: Radix.slateA3,
    fill2: Radix.slateA4,
    selected: Radix.slateA5,
    sidebarSolid: Radix.white,
    sidebarSelected: Radix.whiteA8,
    sidebarVeil: Radix.white,
    scrim: Radix.blackA5,
    deviceName: Color(0xFF0F172A),
    deviceMuted: Color(0xFF64748B),
    deviceOn: Color(0xFF03A9F4),
    deviceNear: Color(0xFF4CAF50),
    deviceOff: Color(0xFFE0E0E0),
    deviceOffDot: Color(0xFF9E9E9E),
    deviceSelected: Color(0x142563EB),
  );

  static const dark = WhisperColors(
    canvas: Radix.slateDark1,
    content: Radix.slateDark2,
    group: Radix.slateDark2,
    raised: Radix.slateDark4,
    bubble: Radix.slateDark4,
    ink: Radix.slateDark12,
    ink2: Radix.slateDark11,
    ink3: Radix.slateDark10,
    ink2Glass: Radix.slateDarkA11,
    accent: Radix.blueDark9,
    accentText: Radix.blueDark11,
    onAccent: Radix.white,
    tint: Radix.blueDark3,
    tintHover: Radix.blueDark4,
    tintActive: Radix.blueDark5,
    onTint: Radix.blueDark12,
    tintSelection: Radix.blueDark7,
    ok: Radix.greenDark11,
    okSolid: Radix.greenDark9,
    warn: Radix.amberDark11,
    warnSolid: Radix.amberDark9,
    bad: Radix.redDark11,
    badSolid: Radix.redDark9,
    sep: Radix.slateDarkA6,
    sidebarEdge: Radix.slateDarkA3,
    border: Radix.slateDarkA7,
    fill: Radix.slateDarkA3,
    fill2: Radix.slateDarkA4,
    selected: Radix.slateDarkA5,
    sidebarSolid: Radix.slateDark2,
    sidebarSelected: Radix.whiteA3,
    sidebarVeil: Radix.whiteA0,
    scrim: Radix.blackA7,
    deviceName: Color(0xFFE2E8F0),
    deviceMuted: Color(0xFF8A8F98),
    deviceOn: Color(0xFF03A9F4),
    deviceNear: Color(0xFF4CAF50),
    deviceOff: Color(0xFF616161),
    deviceOffDot: Color(0xFF9E9E9E),
    deviceSelected: Radix.whiteA2,
  );

  final Color canvas, content, group, raised, bubble;
  final Color ink, ink2, ink3, ink2Glass;

  /// A solid fill, and what is written in the accent colour.
  final Color accent, accentText, onAccent;

  /// The accent as a background: at rest, hovered, pressed or selected, and the
  /// text on them. Own messages are [tintHover] with [onTint].
  final Color tint, tintHover, tintActive, onTint;

  /// Selected text on [tintHover]: the theme's selection is the same blue, and
  /// could not be seen there.
  final Color tintSelection;

  /// Text and icons. The solid ones are fills; on [warnSolid] write in `ink`.
  final Color ok, warn, bad;
  final Color okSolid, warnSolid, badSolid;
  final Color sep, border, fill, fill2, selected;

  /// Between the sidebar and the content: the two are told apart by what they
  /// are, the line only has to say where one ends.
  final Color sidebarEdge;

  /// The sidebar where the system gives no material: Linux and Windows 10.
  final Color sidebarSolid;

  /// The raised selection behind the current sidebar row.
  final Color sidebarSelected;

  /// Over the macOS material, which goes grey on a dark wallpaper.
  final Color sidebarVeil;

  /// The device list keeps the colours it had before the redesign: the user
  /// looked at both. Not Radix, and only here. See decisions.md.
  final Color deviceName, deviceMuted, deviceOn, deviceNear;
  final Color deviceOff, deviceOffDot, deviceSelected;

  /// `panel`'s tint, for what draws its own blur: the file menu.
  Color get panelTint => this == WhisperColors.dark
      ? const Color(0xB8212225)
      : const Color(0xBDF9F9FB);

  /// `control` without its blur: for blocks on glass that is blurred already.
  Color get controlTint =>
      this == WhisperColors.dark ? const Color(0xAD2E3135) : Radix.whiteA9;

  /// Behind a panel.
  final Color scrim;

  @override
  WhisperColors copyWith({Color? accent}) => WhisperColors(
    canvas: canvas,
    content: content,
    group: group,
    raised: raised,
    bubble: bubble,
    ink: ink,
    ink2: ink2,
    ink3: ink3,
    ink2Glass: ink2Glass,
    accent: accent ?? this.accent,
    accentText: accentText,
    onAccent: onAccent,
    tint: tint,
    tintHover: tintHover,
    tintActive: tintActive,
    onTint: onTint,
    tintSelection: tintSelection,
    ok: ok,
    okSolid: okSolid,
    warn: warn,
    warnSolid: warnSolid,
    bad: bad,
    badSolid: badSolid,
    sep: sep,
    sidebarEdge: sidebarEdge,
    border: border,
    fill: fill,
    fill2: fill2,
    selected: selected,
    sidebarSolid: sidebarSolid,
    sidebarSelected: sidebarSelected,
    sidebarVeil: sidebarVeil,
    deviceName: deviceName,
    deviceMuted: deviceMuted,
    deviceOn: deviceOn,
    deviceNear: deviceNear,
    deviceOff: deviceOff,
    deviceOffDot: deviceOffDot,
    deviceSelected: deviceSelected,
    scrim: scrim,
  );

  @override
  WhisperColors lerp(WhisperColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return WhisperColors(
      canvas: l(canvas, other.canvas),
      content: l(content, other.content),
      group: l(group, other.group),
      raised: l(raised, other.raised),
      bubble: l(bubble, other.bubble),
      ink: l(ink, other.ink),
      ink2: l(ink2, other.ink2),
      ink3: l(ink3, other.ink3),
      ink2Glass: l(ink2Glass, other.ink2Glass),
      accent: l(accent, other.accent),
      accentText: l(accentText, other.accentText),
      onAccent: l(onAccent, other.onAccent),
      tint: l(tint, other.tint),
      tintHover: l(tintHover, other.tintHover),
      tintActive: l(tintActive, other.tintActive),
      onTint: l(onTint, other.onTint),
      tintSelection: l(tintSelection, other.tintSelection),
      ok: l(ok, other.ok),
      okSolid: l(okSolid, other.okSolid),
      warn: l(warn, other.warn),
      warnSolid: l(warnSolid, other.warnSolid),
      bad: l(bad, other.bad),
      badSolid: l(badSolid, other.badSolid),
      sep: l(sep, other.sep),
      sidebarEdge: l(sidebarEdge, other.sidebarEdge),
      border: l(border, other.border),
      fill: l(fill, other.fill),
      fill2: l(fill2, other.fill2),
      selected: l(selected, other.selected),
      sidebarSolid: l(sidebarSolid, other.sidebarSolid),
      sidebarSelected: l(sidebarSelected, other.sidebarSelected),
      sidebarVeil: l(sidebarVeil, other.sidebarVeil),
      deviceName: l(deviceName, other.deviceName),
      deviceMuted: l(deviceMuted, other.deviceMuted),
      deviceOn: l(deviceOn, other.deviceOn),
      deviceNear: l(deviceNear, other.deviceNear),
      deviceOff: l(deviceOff, other.deviceOff),
      deviceOffDot: l(deviceOffDot, other.deviceOffDot),
      deviceSelected: l(deviceSelected, other.deviceSelected),
      scrim: l(scrim, other.scrim),
    );
  }
}

extension WhisperTheme on BuildContext {
  /// A bare theme (a small window of its own, a dialog in a test) still gets the
  /// colours of its brightness rather than a crash.
  WhisperColors get wc {
    final theme = Theme.of(this);
    return theme.extension<WhisperColors>() ??
        (theme.brightness == Brightness.dark
            ? WhisperColors.dark
            : WhisperColors.light);
  }
}

/// The coloured tiles of the settings sections, the one place the interface
/// colours an icon for its own sake (DESIGN.md「色彩」). The same in both themes;
/// 连接 uses `accent`, the one blue.
abstract final class WhisperSettingsIcons {
  static const general = Radix.slate9;
  static const system = Radix.slate11;
  static const sharing = Radix.crimson9;
  static const notifications = Radix.orange9;
  static const about = Radix.slate9;

  /// The hairline along the top of a tile.
  static const highlight = Radix.whiteA5;
}

abstract final class WhisperRadius {
  static const xs = 6.0,
      s = 10.0,
      m = 14.0,
      l = 20.0,
          /// A row in a menu: the menu's [m] less its padding of 5, so the corners
          /// run parallel.
          menuRow =
          9.0,
      bubble = 18.0,
      composer = 26.0,
      tray = 24.0,
      appIcon = 12.0,
      thumbBar = 3.0,
      capsule = 999.0,
      sheetTop = 30.0,
      sheetBottom = 46.0,
      viewfinderMark = 12.0;
}

/// Six roles, two densities. Touch is used in the compact size class.
class WhisperType {
  const WhisperType({required this.touch});

  final bool touch;

  double get large => touch ? 32 : 26;
  double get title => touch ? 22 : 20;
  double get head => touch ? 17 : 15;
  double get body => touch ? 16 : 14;
  double get note => touch ? 14 : 12;
  double get tiny => touch ? 12 : 11;
}

abstract final class WhisperSizes {
  /// The letter on an app without an icon of its own.
  static const appIconLetter = 21.0;

  /// Addresses and fingerprints: `code` in the prototype.
  static const code = 12.0;

  /// The six digits two devices compare.
  static const pairCode = 30.0;
}

/// Addresses, fingerprints and the digits to compare, whose characters must not
/// be mistaken for one another. `--mono` in the prototype.
abstract final class WhisperMono {
  static const family = 'monospace';
  static const fallback = ['Menlo', 'Consolas', 'Roboto Mono'];
}

/// The camera's frame on the phone's connect page and the code it looks for.
/// They are about a camera and a printed code, so both themes are the same.
abstract final class WhisperViewfinder {
  /// The gradient behind the camera until it has a picture.
  static const glow = Radix.slateDark7;
  static const base = Radix.slateDark1;
  static const mark = Radix.whiteA11;
  static const line = Radix.whiteA9;
  static const hint = Radix.whiteA11;

  /// The dark modules of a QR code, always on white.
  static const qrInk = Radix.black;
}

/// A box shadow as CSS draws it, only outside the box. Flutter paints a
/// `BoxShadow` under the box too, and under a translucent fill that reads as a
/// grey fill: use this under `sidebarSelected` and the like.
class WhisperOutsideShadow extends CustomPainter {
  const WhisperOutsideShadow({required this.shadows, required this.radius});

  final List<BoxShadow> shadows;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(200))
        ..addRRect(box),
    );
    for (final shadow in shadows) {
      canvas.drawRRect(
        box.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(WhisperOutsideShadow old) =>
      old.radius != radius || !listEquals(old.shadows, shadows);
}

abstract final class WhisperShadow {
  /// The selection behind a sidebar row: like a segmented control's thumb.
  static List<BoxShadow> sidebarSelected(Brightness b) => b == Brightness.light
      ? const [
          BoxShadow(color: Radix.blackA2, blurRadius: 3, offset: Offset(0, 1)),
          BoxShadow(color: Radix.blackA1, spreadRadius: .5),
        ]
      : const [
          BoxShadow(color: Radix.blackA5, blurRadius: 3, offset: Offset(0, 1)),
        ];

  /// An app's icon: 0 1px 3px.
  static const appIcon = [
    BoxShadow(color: Radix.blackA4, blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// The hairline along the top of an app's icon.
  static const appIconHighlight = Radix.whiteA6;

  /// The island: 0 4px 16px, and 0 16px 44px opened.
  static const islandClosed = [
    BoxShadow(color: Radix.blackA5, blurRadius: 16, offset: Offset(0, 4)),
  ];
  static const islandOpen = [
    BoxShadow(color: Radix.blackA6, blurRadius: 44, offset: Offset(0, 16)),
  ];

  /// A switch's knob.
  static const knob = [
    BoxShadow(color: Radix.blackA5, blurRadius: 3, offset: Offset(0, 1)),
    BoxShadow(color: Radix.blackA1, spreadRadius: .5),
  ];

  /// The hairline along the top of raised glass.
  static Color highlight(Brightness b) =>
      b == Brightness.light ? Radix.whiteA10 : Radix.whiteA3;

  static List<BoxShadow> e1(Brightness b) => b == Brightness.light
      ? const [
          BoxShadow(color: Radix.blackA1, blurRadius: 3, offset: Offset(0, 1)),
        ]
      : const [
          BoxShadow(color: Radix.blackA5, blurRadius: 2, offset: Offset(0, 1)),
          BoxShadow(color: Radix.whiteA1, spreadRadius: .5),
        ];

  static List<BoxShadow> e2(Brightness b) => b == Brightness.light
      ? const [
          BoxShadow(color: Radix.blackA3, blurRadius: 28, offset: Offset(0, 8)),
          BoxShadow(color: Radix.blackA2, blurRadius: 4, offset: Offset(0, 1)),
          BoxShadow(color: Radix.blackA2, spreadRadius: .5),
        ]
      : const [
          BoxShadow(color: Radix.blackA7, blurRadius: 28, offset: Offset(0, 8)),
          BoxShadow(color: Radix.blackA6, blurRadius: 4, offset: Offset(0, 1)),
          BoxShadow(color: Radix.whiteA2, spreadRadius: .5),
        ];

  static List<BoxShadow> e3(Brightness b) => b == Brightness.light
      ? const [
          BoxShadow(
            color: Radix.blackA5,
            blurRadius: 80,
            offset: Offset(0, 32),
          ),
          BoxShadow(color: Radix.blackA3, blurRadius: 24, offset: Offset(0, 8)),
          BoxShadow(color: Radix.blackA4, spreadRadius: .5),
        ]
      : const [
          BoxShadow(
            color: Radix.blackA8,
            blurRadius: 80,
            offset: Offset(0, 32),
          ),
          BoxShadow(color: Radix.blackA6, blurRadius: 24, offset: Offset(0, 8)),
          BoxShadow(color: Radix.whiteA3, spreadRadius: .5),
        ];
}

/// The screens in the keyboard and mouse arrangement. They are pictures of real
/// screens, so they look the same in both themes.
abstract final class WhisperScreens {
  static const pointerFill = Radix.black;
  static const pointerStroke = Radix.white;

  static const shadow = [
    BoxShadow(color: Radix.blackA2, blurRadius: 6, offset: Offset(0, 1)),
  ];

  /// While it is held.
  static const lifted = [
    BoxShadow(color: Radix.blackA5, blurRadius: 22, offset: Offset(0, 14)),
  ];

  static const pointerShadow = Shadow(
    color: Radix.blackA7,
    blurRadius: 2,
    offset: Offset(0, 1),
  );

  /// Inside the canvas the screens sit on.
  static const canvasInset = BoxShadow(
    color: Radix.blackA1,
    blurRadius: 3,
    offset: Offset(0, 1),
  );
}

/// The knob of a switch.
const List<BoxShadow> whisperKnobShadow = [
  BoxShadow(color: Radix.blackA5, blurRadius: 3, offset: Offset(0, 1)),
  BoxShadow(color: Radix.blackA1, spreadRadius: .5),
];

/// Signals that run on while something is happening. They are not transitions,
/// so they are the one thing with a period instead of a spring.
abstract final class WhisperLoops {
  static const wave = Duration(milliseconds: 1100);

  /// The line going down the viewfinder, one way.
  static const scan = Duration(milliseconds: 2400);

  /// How long a folder may take before its page comes up empty, to say so.
  static const slowLoad = Duration(milliseconds: 300);

  /// How long a button that just did its job says so.
  static const doneHold = Duration(milliseconds: 1400);
}

/// response is seconds; mass is 1.
SpringDescription whisperSpring(double response, double dampingRatio) {
  final k = math.pow(2 * math.pi / response, 2).toDouble();
  return SpringDescription(
    mass: 1,
    stiffness: k,
    damping: 2 * dampingRatio * math.sqrt(k),
  );
}

/// What a screenshot is marked up with (surfaces.md「截图标注」). Sizes are on
/// screen: the marks stay as heavy as they look, however large the picture is.
abstract final class WhisperCapture {
  static const colors = <Color>[
    Radix.red9,
    Radix.amber9,
    Radix.green9,
    Radix.blue9,
    Radix.black,
    Radix.white,
  ];
  static const strokes = <double>[2, 4, 7];
  static const fonts = <double>[14, 18, 26];
  static const mosaics = <double>[14, 24, 40];

  /// A mosaic block, in points of the screen it was taken on.
  static const block = 9.0;

  /// Around the selection, as on the overlay it takes over from.
  static const dim = Color(0x5C000000);
  static const selectionStroke = 2.0, handle = 3.5, handleStroke = 1.5;

  /// The selection's size in pixels, above its top left corner. The same on the
  /// overlays of each platform, which show it first.
  static const sizeLabelFill = Color(0xA6000000);
  static const sizeLabelHeight = 22.0,
      sizeLabelGap = 4.0,
      sizeLabelPadding = 8.0;
}

abstract final class WhisperSprings {
  static final follow = whisperSpring(.15, 1);
  static final snappy = whisperSpring(.28, .9);
  static final smooth = whisperSpring(.42, .86);
  static final expressive = whisperSpring(.5, .72);
  static final liquidLead = whisperSpring(.24, .8);
  static final liquidTrail = whisperSpring(.44, .9);
}

/// Animates a double toward [value] with a spring. Changing [value] mid-flight
/// keeps the current velocity, which a Curve-based animation cannot do. This
/// replaces AnimatedContainer, AnimatedPositioned and friends.
///
/// With reduced motion it jumps, unless [animateWhenReduced] is set for a value
/// that only drives opacity.
class SpringBuilder extends StatefulWidget {
  const SpringBuilder({
    super.key,
    required this.value,
    required this.builder,
    this.spring,
    this.child,
    this.from,
    this.animateWhenReduced = false,
  });

  final double value;

  /// Start here and animate to [value] on first build. Without it the first
  /// build sits at [value].
  final double? from;
  final SpringDescription? spring;
  final ValueWidgetBuilder<double> builder;
  final Widget? child;
  final bool animateWhenReduced;

  @override
  State<SpringBuilder> createState() => _SpringBuilderState();
}

class _SpringBuilderState extends State<SpringBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.from ?? widget.value,
  );
  bool _started = false;

  void _go() {
    if (!widget.animateWhenReduced && MediaQuery.disableAnimationsOf(context)) {
      _c.value = widget.value;
      return;
    }
    _c.animateWith(
      SpringSimulation(
        widget.spring ?? WhisperSprings.smooth,
        _c.value,
        widget.value,
        _c.velocity,
        snapToEnd: true,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.from != null && widget.from != widget.value) _go();
  }

  @override
  void didUpdateWidget(SpringBuilder old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) _go();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) => widget.builder(context, _c.value, child),
  );
}

/// Every tappable thing shrinks a little and springs back, and works from the
/// keyboard: Tab focuses, Enter or Space activates, focus draws a ring.
/// Use scale .97 for buttons and rows, .92 for round toggles, 1 for segments.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.scale = .97,
    this.radius = 8,
    this.selected,
    this.label,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale, radius;
  final bool? selected;

  /// Required when the child is only an icon.
  final String? label;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false, _focused = false;

  void _set(bool v) {
    if (widget.onTap != null && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: SystemMouseCursors.basic,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _set(true),
          onTapUp: (_) => _set(false),
          onTapCancel: () => _set(false),
          onTap: widget.onTap,
          child: SpringBuilder(
            value: _down ? widget.scale : 1,
            spring: WhisperSprings.snappy,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                border: _focused
                    ? Border.all(
                        color: context.wc.accent.withValues(alpha: .45),
                        width: 3,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      )
                    : null,
              ),
              child: widget.child,
            ),
            builder: (context, s, child) =>
                Transform.scale(scale: s, child: child),
          ),
        ),
      ),
    );
  }
}

/// The segmented control. The edge moving toward the target uses a fast
/// spring and the other edge a slow one, so the thumb stretches, thins and
/// settles. Use it for the tabs (对话 / 文件 / 应用), channels and appearance.
class LiquidSegmented<T> extends StatefulWidget {
  const LiquidSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.height = 30,
    this.padding = 2,
    this.fontSize = 12,
    this.expand = false,
    this.labelKeys,
    this.minSegmentWidth = 0,
    this.segmentPadding = 12,
    this.hitExtend = 0,
  });

  /// More to hit above and below than to look at, on touch: `.seg button::before`
  /// makes a pill of 36 a target of 48. The pill stays where it was.
  final double hitExtend;

  /// So that one-character labels (左, 右) are still comfortable targets.
  final double minSegmentWidth;

  /// Filled with a key per segment, for callers that need to find one.
  final Map<T, GlobalKey>? labelKeys;

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final double height, padding, fontSize;

  /// Each side of a label. Tabs have room; the small segments of settings do
  /// not.
  final double segmentPadding;

  /// Equal widths filling the parent, as on the phone's connect page.
  final bool expand;

  @override
  State<LiquidSegmented<T>> createState() => _LiquidSegmentedState<T>();
}

class _LiquidSegmentedState<T> extends State<LiquidSegmented<T>> {
  final Map<T, GlobalKey> _keys = {};
  final GlobalKey _stack = GlobalKey();
  Rect? _target;
  bool _right = true;

  void _measure() {
    final box = _stack.currentContext?.findRenderObject() as RenderBox?;
    final seg =
        _keys[widget.selected]?.currentContext?.findRenderObject()
            as RenderBox?;
    if (box == null || seg == null) return;
    final rect = seg.localToGlobal(Offset.zero, ancestor: box) & seg.size;
    if (rect == _target) return;
    setState(() {
      _right = _target == null || rect.left >= _target!.left;
      _target = rect;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });
    final row = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (final e in widget.segments.entries)
          () {
            final cell = KeyedSubtree(
              key: _keys.putIfAbsent(
                e.key,
                () =>
                    widget.labelKeys?.putIfAbsent(e.key, GlobalKey.new) ??
                    GlobalKey(),
              ),
              child: Pressable(
                scale: 1,
                radius: widget.height / 2,
                selected: e.key == widget.selected,
                onTap: () => widget.onChanged(e.key),
                child: Container(
                  height:
                      widget.height - widget.padding * 2 + widget.hitExtend * 2,
                  constraints: BoxConstraints(minWidth: widget.minSegmentWidth),
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.segmentPadding,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    e.value,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: widget.fontSize,
                      fontWeight: FontWeight.w500,
                      color: c.ink,
                    ),
                  ),
                ),
              ),
            );
            return widget.expand ? Expanded(child: cell) : cell;
          }(),
      ],
    );
    final t = _target;
    final extend = widget.hitExtend;
    return Stack(
      children: [
        Positioned.fill(
          top: extend,
          bottom: extend,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: c.fill,
              shape: const StadiumBorder(),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.all(widget.padding),
          child: Stack(
            key: _stack,
            children: [
              if (t != null)
                SpringBuilder(
                  value: t.left,
                  spring: _right
                      ? WhisperSprings.liquidTrail
                      : WhisperSprings.liquidLead,
                  builder: (context, left, _) => SpringBuilder(
                    value: t.right,
                    spring: _right
                        ? WhisperSprings.liquidLead
                        : WhisperSprings.liquidTrail,
                    builder: (context, right, _) {
                      final width = math.max(0.0, right - left);
                      final stretch = math.max(
                        1.0,
                        width / math.max(1.0, t.width),
                      );
                      return Positioned(
                        left: left,
                        top: extend,
                        bottom: extend,
                        width: width,
                        child: Transform.scale(
                          scaleY: 1 / (1 + (stretch - 1) * .28),
                          child: DecoratedBox(
                            key: const ValueKey('liquid-thumb'),
                            decoration: ShapeDecoration(
                              color: c.raised,
                              shape: const StadiumBorder(),
                              shadows: const [
                                BoxShadow(
                                  color: Radix.blackA3,
                                  blurRadius: 2,
                                  offset: Offset(0, 1),
                                ),
                                BoxShadow(
                                  color: Radix.blackA1,
                                  spreadRadius: .5,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              row,
            ],
          ),
        ),
      ],
    );
  }
}

/// Content of the tabs. Each page has its own spring, so switching again
/// mid-flight keeps the speed, and the widget tree around a page never changes,
/// so its state survives.
///
/// A page is built the first time it is shown, not before: RemoteFilesPage
/// asks the other device for access as soon as it mounts.
class WhisperTabView extends StatefulWidget {
  const WhisperTabView({
    super.key,
    required this.index,
    required this.itemBuilder,
    required this.itemCount,
    this.contentKey,
    this.heavyPages = false,
    this.resetKey,
    this.keptPages = const {},
  });

  final int index, itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Building a page for the first time takes longer than a frame. With this,
  /// the old page leaves first and the new one is built while nothing is moving,
  /// then comes in.
  final bool heavyPages;

  /// When this changes the pages start over: those not on screen are built again
  /// only when they are next opened. Except [keptPages].
  final Object? resetKey;
  final Set<int> keptPages;

  /// What the pages are built from, when that is all they depend on. Switching
  /// tabs then leaves the pages alone instead of rebuilding every one of them.
  final Object? contentKey;

  @override
  State<WhisperTabView> createState() => _WhisperTabViewState();
}

class _WhisperTabViewState extends State<WhisperTabView> {
  late final int _first = widget.index;
  late final Set<int> _visited = {widget.index};
  late final Map<int, int> _entries = {widget.index: 0};

  /// Which side each page leaves to and comes from.
  final Map<int, double> _side = {};

  final Map<int, Widget> _built = {};
  Object? _builtFor;

  /// The time for the leaving page and the segment's thumb to get most of the
  /// way there.
  static const _firstBuildDelay = Duration(milliseconds: 170);
  late final Set<int> _ready = {widget.index};
  Timer? _readyTimer;

  void _makeReady() {
    _readyTimer?.cancel();
    if (_ready.contains(widget.index)) return;
    if (!widget.heavyPages) {
      _ready.add(widget.index);
      return;
    }
    _readyTimer = Timer(_firstBuildDelay, () {
      if (mounted) setState(() => _ready.add(widget.index));
    });
  }

  @override
  void dispose() {
    _readyTimer?.cancel();
    super.dispose();
  }

  Widget _page(BuildContext context, int i) {
    final key = widget.contentKey;
    if (key == null) return widget.itemBuilder(context, i);
    if (key != _builtFor) {
      _built.clear();
      _builtFor = key;
    }
    return _built[i] ??= widget.itemBuilder(context, i);
  }

  @override
  void didUpdateWidget(WhisperTabView old) {
    super.didUpdateWidget(old);
    if (widget.resetKey != old.resetKey) {
      _ready.retainWhere(
        (i) => i == widget.index || widget.keptPages.contains(i),
      );
    }
    if (widget.index == old.index) return;
    _visited.add(widget.index);
    _makeReady();
    _entries[widget.index] = (_entries[widget.index] ?? 0) + 1;
    for (final i in _visited) {
      if (i != widget.index) _side[i] = i < widget.index ? -1 : 1;
    }
    _side[widget.index] = widget.index > old.index ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final i in _visited.toList()..sort())
          KeyedSubtree(
            key: ValueKey(i),
            child: SpringBuilder(
              value: i == widget.index && _ready.contains(i) ? 1 : 0,
              from: i == _first ? null : 0,
              animateWhenReduced: true,
              // Its own layer: while it slides and fades, the page is not painted
              // again.
              child: RepaintBoundary(
                child: _TabEntry(
                  entry: _entries[i] ?? 0,
                  child: Builder(
                    builder: (context) => _ready.contains(i)
                        ? _page(context, i)
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
              builder: (context, raw, child) {
                final current = i == widget.index;
                final p = raw.clamp(0.0, 1.0);
                final side = _side[i] ?? 0;
                final motion = reduced ? 0.0 : 1.0;
                // Same widgets in every state: only the values change.
                return Offstage(
                  offstage: !current && p <= .001,
                  child: TickerMode(
                    enabled: current || p > .001,
                    child: IgnorePointer(
                      ignoring: !current,
                      child: Opacity(
                        opacity: p,
                        child: FractionalTranslation(
                          translation: Offset(side * .09 * (1 - p) * motion, 0),
                          child: WhisperGlassPause(
                            paused: p < .99,
                            child: child!,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _TabEntry extends InheritedWidget {
  const _TabEntry({required this.entry, required super.child});

  final int entry;

  @override
  bool updateShouldNotify(_TabEntry old) => entry != old.entry;
}

/// New rows and icons rise one after another each time the tab is entered.
/// Delay is 24 ms per index; animate at most 16 items.
class RiseIn extends StatefulWidget {
  const RiseIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<RiseIn> {
  bool _in = false;
  bool _jump = false;
  int? _entry;
  Timer? _t;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final entry =
        context.dependOnInheritedWidgetOfExactType<_TabEntry>()?.entry ?? 0;
    if (entry == _entry) return;
    _entry = entry;
    _t?.cancel();
    // Back to the start at once, without animating down.
    _jump = true;
    _in = false;
    _t = Timer(Duration(milliseconds: 24 * math.min(widget.index, 16)), () {
      if (mounted) {
        setState(() {
          _jump = false;
          _in = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SpringBuilder(
    key: ValueKey(_jump ? 'start-$_entry' : 'run-$_entry'),
    value: _in ? 1 : 0,
    child: widget.child,
    builder: (context, t, child) => _RiseFrame(t: t, child: child!),
  );
}

class _RiseFrame extends StatelessWidget {
  const _RiseFrame({required this.t, required this.child});

  final double t;
  final Widget child;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: t.clamp(0.0, 1.0),
    child: Transform.translate(
      offset: Offset(0, 12 * (1 - t)),
      child: Transform.scale(scale: .98 + .02 * t, child: child),
    ),
  );
}

/// Phone page stack: the new page pushes in from the right, the old one backs
/// off 26% to the left, driven by the smooth spring. Use for every phone page,
/// including the first: a route only backs off if it is a WhisperPageRoute too.
class WhisperPageRoute<T> extends PageRoute<T> {
  WhisperPageRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  bool get opaque => true;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 700);

  @override
  Simulation createSimulation({required bool forward}) => SpringSimulation(
    WhisperSprings.smooth,
    controller!.value,
    forward ? 1 : 0,
    controller!.velocity,
    snapToEnd: true,
  );

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(animation),
      child: SlideTransition(
        position: Tween(
          begin: Offset.zero,
          end: const Offset(-.26, 0),
        ).animate(secondaryAnimation),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Radix.blackA2,
                blurRadius: 32,
                offset: Offset(-12, 0),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// How a [WhisperModalRoute] comes in.
enum WhisperModalStyle {
  /// 弹层: fades in from .94, in the middle of the window.
  sheet,

  /// The touch version of a sheet: pushed up from the bottom.
  bottomSheet,

  /// A [bottomSheet] in the compact size class, a [sheet] beside a sidebar. It
  /// stays open through a fold and changes with the window.
  adaptive,

  /// 菜单: grows out of its button, from .92 and 6 higher.
  menu,
}

/// A panel over the window, driven by the smooth spring so it can be closed
/// mid-flight. [scrim] is what shows behind it: [WhisperColors.scrim] for a
/// panel, nothing for a menu.
class WhisperModalRoute<T> extends PopupRoute<T> {
  WhisperModalRoute({
    required this.builder,
    required this.barrierLabel,
    this.scrim,
    this.style = WhisperModalStyle.sheet,
    this.alignment = Alignment.center,
    super.settings,
  });

  final WidgetBuilder builder;
  final Color? scrim;
  final WhisperModalStyle style;

  /// Where a menu grows from, relative to itself.
  final Alignment alignment;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => scrim;
  @override
  bool get barrierDismissible => true;
  @override
  Curve get barrierCurve => Curves.linear;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 700);

  @override
  Simulation createSimulation({required bool forward}) => SpringSimulation(
    WhisperSprings.smooth,
    controller!.value,
    forward ? 1 : 0,
    controller!.velocity,
    snapToEnd: true,
  );

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value;
        final opacity = (t * 1.6).clamp(0.0, 1.0);
        final shown = style == WhisperModalStyle.adaptive
            ? (WhisperLayout.of(context).compact
                  ? WhisperModalStyle.bottomSheet
                  : WhisperModalStyle.sheet)
            : style;
        return switch (shown) {
          WhisperModalStyle.adaptive => child!,
          WhisperModalStyle.sheet => Opacity(
            opacity: opacity,
            child: Transform.scale(scale: .94 + .06 * t, child: child),
          ),
          WhisperModalStyle.bottomSheet => FractionalTranslation(
            translation: Offset(0, 1 - t),
            child: child,
          ),
          WhisperModalStyle.menu => Opacity(
            opacity: opacity,
            child: Transform.translate(
              offset: Offset(0, -6 * (1 - t)),
              child: Transform.scale(
                scale: .92 + .08 * t,
                alignment: alignment,
                child: child,
              ),
            ),
          ),
        };
      },
    );
  }
}

/// A switch: 38 × 22, thumb 18, which slides on the snappy spring and widens
/// to 22 under a finger. Same element in both states, so it can slide.
class WhisperSwitch extends StatefulWidget {
  const WhisperSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
  });

  final bool value;

  /// Null disables it.
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  State<WhisperSwitch> createState() => _WhisperSwitchState();
}

class _WhisperSwitchState extends State<WhisperSwitch> {
  static const _width = 38.0, _height = 22.0, _thumb = 18.0, _pressed = 22.0;
  static const _inset = 2.0;
  bool _down = false;

  void _set(bool down) {
    if (widget.onChanged != null && down != _down) {
      setState(() => _down = down);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final onChanged = widget.onChanged;
    return Semantics(
      toggled: widget.value,
      child: Opacity(
        opacity: onChanged == null ? .5 : 1,
        child: Listener(
          onPointerDown: (_) => _set(true),
          onPointerUp: (_) => _set(false),
          onPointerCancel: (_) => _set(false),
          child: Pressable(
            scale: 1,
            radius: _height / 2,
            label: widget.label,
            onTap: onChanged == null ? null : () => onChanged(!widget.value),
            child: SpringBuilder(
              value: widget.value ? 1 : 0,
              spring: WhisperSprings.snappy,
              builder: (context, on, _) => SpringBuilder(
                value: _down ? _pressed : _thumb,
                spring: WhisperSprings.snappy,
                builder: (context, thumb, _) {
                  final t = on.clamp(0.0, 1.0);
                  return SizedBox(
                    width: _width,
                    height: _height,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: Color.lerp(c.fill2, c.accent, t),
                        shape: const StadiumBorder(),
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            top: _inset,
                            bottom: _inset,
                            left: _inset + (_width - 2 * _inset - thumb) * on,
                            width: thumb,
                            child: DecoratedBox(
                              decoration: ShapeDecoration(
                                color: c.onAccent,
                                shape: const StadiumBorder(),
                                shadows: whisperKnobShadow,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Capsule thumb, 26 × 18 (30 × 18 on touch), grows while dragged.
class CapsuleThumbShape extends SliderComponentShape {
  const CapsuleThumbShape({this.width = 26, this.height = 18});

  final double width, height;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(width, height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final a = activationAnimation.value;
    final rect = Rect.fromCenter(
      center: center,
      width: width * (1 + .16 * a),
      height: height * (1 + .1 * a),
    );
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    final canvas = context.canvas;
    canvas.drawRRect(
      rr.shift(const Offset(0, 1)),
      Paint()
        ..color = Radix.blackA5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawRRect(rr.inflate(.5), Paint()..color = Radix.blackA2);
    canvas.drawRRect(rr, Paint()..color = Radix.white);
  }
}

/// One height on both sides of the thumb. The thumb stops at the ends of the
/// row, so the track runs half a thumb past where its centre can go.
class WhisperSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const WhisperSliderTrackShape({required this.thumbWidth});

  final double thumbWidth;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(rect.height / 2);
    final track = RRect.fromLTRBR(
      rect.left - thumbWidth / 2,
      rect.top,
      rect.right + thumbWidth / 2,
      rect.bottom,
      radius,
    );
    final canvas = context.canvas;
    canvas.drawRRect(track, Paint()..color = sliderTheme.inactiveTrackColor!);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(track.left, track.top, thumbCenter.dx, track.bottom),
    );
    canvas.drawRRect(track, Paint()..color = sliderTheme.activeTrackColor!);
    canvas.restore();
  }
}

/// The overlay is invisible: it only makes the hit area 48 on touch, 28 with a
/// pointer. Padding is horizontal so the track lines up with the row's text.
SliderThemeData whisperSliderTheme(BuildContext context, {bool touch = false}) {
  final c = context.wc;
  final thumb = touch ? 30.0 : 26.0;
  return SliderTheme.of(context).copyWith(
    trackHeight: 6,
    activeTrackColor: c.accent,
    inactiveTrackColor: c.fill2,
    thumbColor: Radix.white,
    overlayColor: Colors.transparent,
    thumbShape: CapsuleThumbShape(width: thumb),
    overlayShape: RoundSliderOverlayShape(overlayRadius: touch ? 24 : 14),
    trackShape: WhisperSliderTrackShape(thumbWidth: thumb),
    tickMarkShape: SliderTickMarkShape.noTickMark,
    showValueIndicator: ShowValueIndicator.never,
    padding: EdgeInsets.symmetric(horizontal: thumb / 2),
  );
}

/// Progress: a 4 high bar. The fill follows a spring, and a soft highlight
/// passes over it only while it is running, not when full or with reduced motion.
class WhisperProgressBar extends StatefulWidget {
  const WhisperProgressBar({super.key, required this.value});

  final double value;

  @override
  State<WhisperProgressBar> createState() => _WhisperProgressBarState();
}

class _WhisperProgressBarState extends State<WhisperProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  bool get _running => widget.value < 1;

  void _sync() {
    final run = _running && !MediaQuery.disableAnimationsOf(context);
    if (run && !_sheen.isAnimating) _sheen.repeat();
    if (!run && _sheen.isAnimating) _sheen.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(WhisperProgressBar old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: ColoredBox(
          color: c.fill2,
          child: SpringBuilder(
            value: widget.value.clamp(0.0, 1.0),
            builder: (context, v, _) => FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: v.clamp(0.0, 1.0),
              child: ColoredBox(
                color: c.accent,
                child: !_sheen.isAnimating
                    ? null
                    : AnimatedBuilder(
                        animation: _sheen,
                        builder: (context, _) => FractionalTranslation(
                          translation: Offset(-1 + 2 * _sheen.value, 0),
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Radix.whiteA0,
                                  Radix.whiteA7,
                                  Radix.whiteA0,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum GlassKind { sidebar, control, panel }

/// Glass under this does not blur for now: what it would blur is moving anyway,
/// and a page in motion cannot afford a backdrop filter on every frame.
class WhisperGlassPause extends InheritedWidget {
  const WhisperGlassPause({
    super.key,
    required this.paused,
    required super.child,
  });

  final bool paused;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WhisperGlassPause>()?.paused ??
      false;

  @override
  bool updateShouldNotify(WhisperGlassPause old) => paused != old.paused;
}

/// Glass inside the window shows the window's own content, so it blurs on every
/// platform (DESIGN.md「平台」). Set this false once, at startup, where the GPU
/// cannot keep up: glass then falls back to the opaque canvas.
bool whisperGlassBlurs = true;

/// A saturation matrix, as CSS `saturate()`.
List<double> _saturate(double s) {
  const r = .2126, g = .7152, b = .0722;
  final i = 1 - s;
  return [
    i * r + s,
    i * g,
    i * b,
    0,
    0,
    i * r,
    i * g + s,
    i * b,
    0,
    0,
    i * r,
    i * g,
    i * b + s,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];
}

class WhisperGlass extends StatelessWidget {
  const WhisperGlass({
    super.key,
    required this.kind,
    required this.child,
    this.shape = const RoundedSuperellipseBorder(),
    this.blur = true,
  });

  final GlassKind kind;
  final Widget child;
  final ShapeBorder shape;

  /// Off where only a plain surface is behind it, like the list inside the
  /// settings panel: there the tint is all there is to see, and a blur would
  /// only pull the scrim in over its edges.
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (tint, sigma, sat) = switch ((kind, dark)) {
      (GlassKind.sidebar, false) => (const Color(0xA8F0F0F3), 44.0, 1.8),
      (GlassKind.sidebar, true) => (const Color(0x9E212225), 44.0, 1.8),
      (GlassKind.control, false) => (Radix.whiteA9, 30.0, 1.8),
      (GlassKind.control, true) => (const Color(0xAD2E3135), 30.0, 1.8),
      (GlassKind.panel, false) => (const Color(0xBDF9F9FB), 44.0, 1.9),
      (GlassKind.panel, true) => (const Color(0xB8212225), 44.0, 1.9),
    };
    final blurs = whisperGlassBlurs;
    final paused = WhisperGlassPause.of(context);
    final surface = DecoratedBox(
      // No blur: fall back to the opaque canvas so text stays readable.
      decoration: ShapeDecoration(
        color: blurs || !blur ? tint : context.wc.canvas,
        shape: shape,
      ),
      child: child,
    );
    if (!blurs || !blur || paused) return surface;
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ImageFilter.compose(
          outer: ColorFilter.matrix(_saturate(sat)),
          inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        ),
        child: surface,
      ),
    );
  }
}

/// A message bubble hugs its text, also after wrapping. Without
/// TextWidthBasis.longestLine a wrapped Text fills the maximum width.
class WhisperBubble extends StatelessWidget {
  const WhisperBubble({
    super.key,
    required this.text,
    required this.mine,
    required this.touch,
  });

  final String text;
  final bool mine, touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final body = WhisperType(touch: touch).body;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (context, box) => ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: touch
                ? box.maxWidth * .8
                : math.min(box.maxWidth * .72, body * 30),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: mine ? c.tintHover : c.bubble,
              borderRadius: BorderRadius.circular(WhisperRadius.bubble),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              child: Text(
                text,
                textWidthBasis: TextWidthBasis.longestLine,
                style: TextStyle(
                  fontSize: body,
                  height: 1.45,
                  color: mine ? c.onTint : c.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum DevicePresence { connected, nearby, away }

/// The device list has one order: connected, then nearby, then away. A device
/// that gets better goes to the end of its new rank's rows, so it never pushes
/// down a connected row. One that gets worse goes to the start of its new rank's
/// rows, the shortest way down. Inside a rank nothing else moves.
class StableDeviceOrder {
  final List<String> _order = [];

  /// The rank each row is placed at.
  final Map<String, int> _placed = {};

  static int _rank(DevicePresence p) => switch (p) {
    DevicePresence.connected => 0,
    DevicePresence.nearby => 1,
    DevicePresence.away => 2,
  };

  void _place(String id, int rank, {required bool first}) {
    _order.remove(id);
    _placed[id] = rank;
    final at = _order.indexWhere((other) {
      final placed = _placed[other]!;
      return first ? placed >= rank : placed > rank;
    });
    _order.insert(at < 0 ? _order.length : at, id);
  }

  List<String> apply(Map<String, DevicePresence> devices) {
    _order.removeWhere((id) => !devices.containsKey(id));
    _placed.removeWhere((id, _) => !devices.containsKey(id));
    for (final r in [0, 1, 2]) {
      for (final id in devices.keys) {
        if (_rank(devices[id]!) != r) continue;
        final placed = _placed[id];
        if (placed == r) continue;
        _place(id, r, first: placed != null && r > placed);
      }
    }
    return List.unmodifiable(_order);
  }
}

enum WindowButton { minimize, maximize, close }

enum WindowButtonStyle { windows, gnome, kde }

/// Which buttons go on which side. macOS has none: AppKit draws its own.
@immutable
class WindowButtonLayout {
  const WindowButtonLayout({this.left = const [], this.right = const []});

  static const windows = WindowButtonLayout(
    right: [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
  );

  /// GTK's `gtk-decoration-layout`, like `:minimize,maximize,close` or
  /// `close,minimize,maximize:` or `appmenu:close`. Unknown names are skipped.
  factory WindowButtonLayout.parse(String value) {
    List<WindowButton> side(String names) => [
      for (final name in names.split(','))
        for (final button in WindowButton.values)
          if (button.name == name.trim()) button,
    ];
    final at = value.indexOf(':');
    return at < 0
        ? WindowButtonLayout(right: side(value))
        : WindowButtonLayout(
            left: side(value.substring(0, at)),
            right: side(value.substring(at + 1)),
          );
  }

  final List<WindowButton> left, right;
}

/// The window buttons Flutter draws once the system title bar is hidden.
/// Lay them over everything, scrims included, as the system's own would be.
class WindowButtons extends StatelessWidget {
  const WindowButtons({
    super.key,
    required this.buttons,
    required this.style,
    required this.maximized,
    required this.onPressed,
    required this.label,
  });

  final List<WindowButton> buttons;
  final WindowButtonStyle style;
  final bool maximized;
  final ValueChanged<WindowButton> onPressed;

  /// Localized name. `maximized` is passed so maximize can read 还原.
  final String Function(WindowButton button, bool maximized) label;

  /// How far a toolbar has to stay clear of the buttons.
  /// Where the buttons end, from the window's top.
  static double heightOf(WindowButtonStyle style) => switch (style) {
    WindowButtonStyle.windows => 32.0,
    WindowButtonStyle.gnome || WindowButtonStyle.kde => 38.0,
  };

  static double widthOf(WindowButtonStyle style, int count) {
    if (count == 0) return 0;
    return switch (style) {
      WindowButtonStyle.windows => 46.0 * count,
      WindowButtonStyle.gnome => 32.0 * count + 16,
      WindowButtonStyle.kde => 28.0 * count + 20,
    };
  }

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final button in buttons)
          _WindowButton(
            button: button,
            style: style,
            maximized: maximized,
            label: label(button, maximized),
            onPressed: () => onPressed(button),
          ),
      ],
    );
    // The pads keep the 24 circles on the toolbar's midline, 26 from the top.
    return switch (style) {
      WindowButtonStyle.windows => row,
      WindowButtonStyle.gnome => Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
        child: row,
      ),
      WindowButtonStyle.kde => Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
        child: row,
      ),
    };
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.button,
    required this.style,
    required this.maximized,
    required this.label,
    required this.onPressed,
  });

  final WindowButton button;
  final WindowButtonStyle style;
  final bool maximized;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final isClose = widget.button == WindowButton.close;
    final Color? fill;
    var ink = c.ink;
    switch (widget.style) {
      case WindowButtonStyle.windows:
        fill = !_hover
            ? null
            : isClose
            ? (_down ? const Color(0xFFB02A1C) : const Color(0xFFC42B1C))
            : (_down ? c.fill2 : c.fill);
        if (_hover && isClose) ink = Colors.white;
      case WindowButtonStyle.gnome:
        fill = _down ? c.ink3 : (_hover ? c.fill2 : c.fill);
      case WindowButtonStyle.kde:
        fill = !_hover ? null : (isClose ? const Color(0xFFDA4453) : c.fill2);
        if (_hover && isClose) ink = Colors.white;
    }
    final isWindows = widget.style == WindowButtonStyle.windows;
    // The system's buttons are not in the Tab order: Alt+Space, Alt+F4 and the
    // desktop's own shortcuts do that job.
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onPressed,
      child: Tooltip(
        message: widget.label,
        excludeFromSemantics: true,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() {
            _hover = false;
            _down = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapDown: (_) => setState(() => _down = true),
            onTapCancel: () => setState(() => _down = false),
            onTapUp: (_) => setState(() => _down = false),
            onTap: widget.onPressed,
            // On Linux the circle is 24 but the target is larger, like the
            // desktop's own buttons: 32 with a gap of 8, 28 with a gap of 4.
            child: SizedBox(
              width: isWindows
                  ? 46
                  : (widget.style == WindowButtonStyle.gnome ? 32 : 28),
              height: isWindows
                  ? 32
                  : (widget.style == WindowButtonStyle.gnome ? 32 : 28),
              child: Center(
                child: Container(
                  width: isWindows ? 46 : 24,
                  height: isWindows ? 32 : 24,
                  decoration: BoxDecoration(
                    color: fill,
                    shape: isWindows ? BoxShape.rectangle : BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: CustomPaint(
                    size: Size.square(isWindows ? 11 : 14),
                    painter: _WindowGlyph(
                      widget.button,
                      widget.style,
                      widget.maximized,
                      ink,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowGlyph extends CustomPainter {
  const _WindowGlyph(this.button, this.style, this.maximized, this.color);

  final WindowButton button;
  final WindowButtonStyle style;
  final bool maximized;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final windows = style == WindowButtonStyle.windows;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = windows ? 1 : 1.5;
    final path = Path();
    void line(double a, double b, double c, double d) => path
      ..moveTo(a, b)
      ..lineTo(c, d);
    void box(double l, double t, double w, double h, double r) =>
        path.addRRect(RRect.fromLTRBR(l, t, l + w, t + h, Radius.circular(r)));
    switch ((button, style)) {
      case (WindowButton.close, WindowButtonStyle.windows):
        line(1, 1, 10, 10);
        line(10, 1, 1, 10);
      case (WindowButton.close, _):
        line(3.5, 3.5, 10.5, 10.5);
        line(10.5, 3.5, 3.5, 10.5);
      case (WindowButton.minimize, WindowButtonStyle.windows):
        line(1, 5.5, 10, 5.5);
      case (WindowButton.minimize, WindowButtonStyle.gnome):
        line(3, 11, 11, 11);
      case (WindowButton.minimize, WindowButtonStyle.kde):
        line(3, 5.5, 7, 9.5);
        line(7, 9.5, 11, 5.5);
      case (WindowButton.maximize, WindowButtonStyle.windows):
        if (maximized) {
          box(1, 3, 7, 7, 1.2);
          path
            ..moveTo(3, 1)
            ..lineTo(9, 1)
            ..quadraticBezierTo(10, 1, 10, 2)
            ..lineTo(10, 8);
        } else {
          box(1, 1, 9, 9, 1.5);
        }
      case (WindowButton.maximize, WindowButtonStyle.gnome):
        if (maximized) {
          box(3, 5, 6, 6, 1);
          path
            ..moveTo(5.5, 3)
            ..lineTo(10, 3)
            ..quadraticBezierTo(11, 3, 11, 4)
            ..lineTo(11, 8.5);
        } else {
          box(3.5, 3.5, 7, 7, 1);
        }
      case (WindowButton.maximize, WindowButtonStyle.kde):
        if (maximized) {
          path
            ..moveTo(7, 2.5)
            ..lineTo(11.5, 7)
            ..lineTo(7, 11.5)
            ..lineTo(2.5, 7)
            ..close();
        } else {
          line(3, 9, 7, 5);
          line(7, 5, 11, 9);
        }
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_WindowGlyph old) =>
      old.button != button ||
      old.style != style ||
      old.maximized != maximized ||
      old.color != color;
}

// ---------------------------------------------------------------------- layout

enum WhisperSizeClass { compact, regular, expanded }

enum WhisperPosture { flat, book, tabletop }

/// The layout of the window right now. Everything here comes from the window
/// and how the device is held, never from which device it is: an iPad in Split
/// View is compact, a folded phone is compact, the same phone open is regular.
/// DESIGN.md「平板和折叠屏」.
@immutable
class WhisperLayout {
  const WhisperLayout({
    required this.sizeClass,
    required this.touch,
    required this.shortHeight,
    required this.posture,
    required this.sidebarWidth,
    this.foldX,
    this.foldY,
  });

  final WhisperSizeClass sizeClass;

  /// Density and hit targets. A phone, tablet or foldable is touch at any
  /// width; a desktop window is pointer at any width.
  final bool touch;

  /// Under 600 tall: a wide foldable on its side, or any window with the
  /// keyboard up. Sheets and the control page rearrange, nothing else does.
  final bool shortHeight;

  final WhisperPosture posture;

  /// 0 in the compact class, where there is no sidebar.
  final double sidebarWidth;

  /// Left edge of a half-opened vertical fold, in window coordinates.
  final double? foldX;

  /// Top edge of a half-opened horizontal fold, in window coordinates.
  final double? foldY;

  bool get compact => sizeClass == WhisperSizeClass.compact;
  bool get expanded => sizeClass == WhisperSizeClass.expanded;

  static const regularWidth = 600.0;
  static const expandedWidth = 1000.0;
  static const shortHeightLimit = 600.0;
  static const pointerSidebar = 252.0;
  static const touchSidebarMin = 240.0;
  static const touchSidebarMax = 300.0;

  /// For tests, and sample entries looking at the other density.
  @visibleForTesting
  static bool? debugTouchOverride;

  /// `Platform` and not `defaultTargetPlatform`, which says android in every
  /// `flutter test`: this agrees with `isDesktop()` on the host running it.
  static bool get touchPlatform =>
      debugTouchOverride ?? (Platform.isIOS || Platform.isAndroid);

  static WhisperLayout of(BuildContext context) => resolve(
    size: MediaQuery.sizeOf(context),
    touch: touchPlatform,
    features: MediaQuery.displayFeaturesOf(context),
  );

  static WhisperLayout resolve({
    required Size size,
    required bool touch,
    List<DisplayFeature> features = const [],
  }) {
    final sizeClass = size.width < regularWidth
        ? WhisperSizeClass.compact
        : size.width < expandedWidth
        ? WhisperSizeClass.regular
        : WhisperSizeClass.expanded;

    // A flat fold is just a screen. Only a half-opened one changes the layout,
    // and only one inside this window (not the other half of a split screen).
    var posture = WhisperPosture.flat;
    double? foldX, foldY;
    final window = Offset.zero & size;
    for (final f in features) {
      final isFold =
          f.type == DisplayFeatureType.fold ||
          f.type == DisplayFeatureType.hinge;
      if (!isFold || f.state != DisplayFeatureState.postureHalfOpened) continue;
      if (!window.overlaps(f.bounds.inflate(1))) continue;
      if (f.bounds.height >= f.bounds.width) {
        posture = WhisperPosture.book;
        foldX = f.bounds.left;
      } else {
        posture = WhisperPosture.tabletop;
        foldY = f.bounds.top;
      }
      break;
    }

    final double sidebarWidth;
    if (sizeClass == WhisperSizeClass.compact) {
      sidebarWidth = 0;
    } else if (posture == WhisperPosture.book) {
      sidebarWidth = foldX!;
    } else if (touch) {
      sidebarWidth = (size.width * .32).clamp(touchSidebarMin, touchSidebarMax);
    } else {
      sidebarWidth = pointerSidebar;
    }

    return WhisperLayout(
      sizeClass: sizeClass,
      touch: touch,
      shortHeight: size.height < shortHeightLimit,
      posture: posture,
      sidebarWidth: sidebarWidth,
      foldX: foldX,
      foldY: foldY,
    );
  }
}
