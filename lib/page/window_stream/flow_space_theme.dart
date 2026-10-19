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

  /// Device hues: Apple system colours, light and dark variants.
  static const List<(Color light, Color dark)> deviceHues = [
    (Color(0xFF007AFF), Color(0xFF0A84FF)), // blue
    (Color(0xFF5856D6), Color(0xFF5E5CE6)), // indigo
    (Color(0xFF30B0C7), Color(0xFF40C8E0)), // teal
    (Color(0xFF34C759), Color(0xFF30D158)), // green
    (Color(0xFFFF9500), Color(0xFFFF9F0A)), // orange
    (Color(0xFFFF2D55), Color(0xFFFF375F)), // pink
    (Color(0xFFAF52DE), Color(0xFFBF5AF2)), // purple
    (Color(0xFF00C7BE), Color(0xFF63E6E2)), // mint
  ];

  static Color deviceHue(String deviceId, Brightness brightness) {
    var hash = 0;
    for (final unit in deviceId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final pair = deviceHues[hash % deviceHues.length];
    return brightness == Brightness.dark ? pair.$2 : pair.$1;
  }

  static const Color live = Color(0xFF34C759);
  static const Color paused = Color(0xFFFF9F0A);
  static const Color reconnecting = Color(0xFF0A84FF);
  static const Color failed = Color(0xFFFF453A);

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
      palette = context.whisperPalette,
      scheme = Theme.of(context).colorScheme;

  final Brightness brightness;
  final WhisperPalette palette;
  final ColorScheme scheme;

  bool get dark => brightness == Brightness.dark;

  /// Whisper's own page background, so Flow reads as part of the app.
  Color get canvas => palette.surfaceCanvas;
  Color get raised => dark ? const Color(0xFF1C1C1E) : Colors.white;
  Color get raisedSecondary =>
      dark ? const Color(0xFF2C2C2E) : const Color(0xFFF7F7FA);
  Color get hairline => dark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);
  Color get label => dark ? Colors.white : const Color(0xFF1C1C1E);
  Color get secondaryLabel =>
      dark ? const Color(0x99EBEBF5) : const Color(0x993C3C43);
  Color get tertiaryLabel =>
      dark ? const Color(0x4DEBEBF5) : const Color(0x4D3C3C43);
  Color get glassTint =>
      dark ? const Color(0xB31C1C1E) : const Color(0xB3FFFFFF);

  List<BoxShadow> get cardShadow => dark
      ? const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
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
