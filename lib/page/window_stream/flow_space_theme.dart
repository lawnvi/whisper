import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/radix_colors.dart';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../theme/app_theme.dart';

/// Design tokens of the Flow Space (see the window-stream design doc,
/// "流转空间：设计语言"). Shared by the desktop, tablet and phone layouts.
abstract final class FlowSpaceTokens {
  static const double cardRadius = 24;
  static const double tileRadius = 20;
  static const double chipRadius = 14;
  static const double capsuleRadius = 999;

  static const double gutter = 24;
  static const double compactGutter = 16;

  /// Device hues.
  static const List<Color> deviceHues = [
    Radix.blue9,
    Radix.indigo9,
    Radix.cyan9,
    Radix.green9,
    Radix.orange9,
    Radix.pink9,
    Radix.purple9,
    Radix.teal9,
  ];

  static Color deviceHue(String deviceId, Brightness brightness) {
    var hash = 0;
    for (final unit in deviceId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return deviceHues[hash % deviceHues.length];
  }

  static const Color live = Radix.green9;
  static const Color paused = Radix.amber9;
  static const Color reconnecting = Radix.blue9;
  static const Color failed = Radix.red9;

  /// Main motion spring (≈ SwiftUI `.spring(response: 0.42, dampingFraction: 0.82)`).
  static const SpringDescription spring = SpringDescription(
    mass: 1,
    stiffness: 224,
    damping: 24.6,
  );

  /// Stiffer spring for scale and hover feedback.
  static const SpringDescription snappySpring = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 34,
  );

  static const Duration springDuration = Duration(milliseconds: 520);
  static const Duration quickDuration = Duration(milliseconds: 260);
  static const Duration staggerStep = Duration(milliseconds: 40);

  static ShapeBorder card([double radius = cardRadius]) =>
      RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));
}

/// A [Curve] that follows a damped spring's step response, so implicit
/// animations (AnimatedPositioned, TweenAnimationBuilder…) move like springs.
/// Ends exactly at 1 after the given duration.
class SpringCurve extends Curve {
  const SpringCurve([this.spring = FlowSpaceTokens.spring, this.settle = 0.52]);

  final SpringDescription spring;

  /// Seconds covered by t ∈ [0, 1].
  final double settle;

  @override
  double transformInternal(double t) {
    final time = t * settle;
    final omega = math.sqrt(spring.stiffness / spring.mass);
    final zeta =
        spring.damping / (2 * math.sqrt(spring.stiffness * spring.mass));
    double value;
    if (zeta < 1) {
      final omegaD = omega * math.sqrt(1 - zeta * zeta);
      value =
          1 -
          math.exp(-zeta * omega * time) *
              (math.cos(omegaD * time) +
                  (zeta * omega / omegaD) * math.sin(omegaD * time));
    } else {
      value = 1 - math.exp(-omega * time) * (1 + omega * time);
    }
    // Blend into exactly 1 over the last 10% so the curve ends at rest.
    if (t > 0.9) {
      final blend = (t - 0.9) / 0.1;
      value = value * (1 - blend) + blend;
    }
    return value;
  }
}

/// Colours of the space, derived from the app theme so light and dark modes
/// follow the rest of Whisper.
class FlowSpaceColors {
  FlowSpaceColors.of(BuildContext context)
    : brightness = Theme.of(context).brightness,
      _c = context.wc,
      scheme = Theme.of(context).colorScheme;

  final Brightness brightness;
  final WhisperColors _c;
  final ColorScheme scheme;

  bool get dark => brightness == Brightness.dark;

  /// Whisper's own page background, so Flow reads as part of the app.
  Color get canvas => _c.canvas;
  Color get raised => _c.raised;
  Color get raisedSecondary => _c.bubble;
  Color get hairline => _c.sep;
  Color get label => _c.ink;
  Color get secondaryLabel => _c.ink2;
  Color get tertiaryLabel => _c.ink3;
  Color get glassTint => _c.panelTint;

  List<BoxShadow> get cardShadow => dark
      ? const [
          BoxShadow(
            color: Radix.blackA6,
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
          BoxShadow(color: Radix.blackA4, blurRadius: 4, offset: Offset(0, 1)),
        ]
      : const [
          BoxShadow(
            color: Radix.blackA2,
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
          BoxShadow(color: Radix.blackA1, blurRadius: 3, offset: Offset(0, 1)),
        ];

  List<BoxShadow> liftedShadow(Color hue) => [
    BoxShadow(
      color: hue.withValues(alpha: dark ? 0.28 : 0.18),
      blurRadius: 32,
      offset: const Offset(0, 16),
    ),
    ...cardShadow,
  ];
}

/// Frosted material for floating surfaces (menus, control capsules, paused
/// overlays). The space's flat surfaces stay opaque.
///
/// Blurring what is behind is redone every frame anything under it moves.
/// Windows and Linux GPUs pay for that in dropped frames (cards animating
/// with glass on them stuttered), so there the material is a denser tint
/// without the blur.
class FlowGlass extends StatelessWidget {
  const FlowGlass({
    super.key,
    required this.child,
    this.radius = FlowSpaceTokens.cardRadius,
    this.padding,
    this.tint,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    final color = tint ?? colors.glassTint;
    final surface = DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: colors.hairline),
        ),
        color: flowGlassBlurs
            ? color
            : color.withValues(alpha: math.min(1, color.a + 0.25)),
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: flowGlassBlurs
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: surface,
            )
          : surface,
    );
  }
}

/// Whether [FlowGlass] blurs what is behind it (see there).
bool get flowGlassBlurs => !(Platform.isWindows || Platform.isLinux);

/// Whether motion should collapse to fades.
bool flowReduceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);
