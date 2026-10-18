import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'flow_space_theme.dart';

/// An app icon in the Flow Space: the real icon when the source provides
/// one, otherwise a monogram on the app's colour. Always a continuous-corner
/// square so mixed sources line up.
class FlowAppIcon extends StatelessWidget {
  const FlowAppIcon({
    super.key,
    required this.label,
    required this.hue,
    this.icon,
    this.size = 56,
    this.onColor = false,
  });

  final String label;
  final Uint8List? icon;
  final Color hue;
  final double size;

  /// Drawn on top of a coloured surface: use a white glass plate.
  final bool onColor;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.225;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    final image = icon;
    if (image != null) {
      return SizedBox.square(
        dimension: size,
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: Image.memory(image, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      );
    }
    final monogram = label.isEmpty
        ? '?'
        : String.fromCharCode(label.runes.first).toUpperCase();
    final hsl = HSLColor.fromColor(hue);
    final top = hsl
        .withLightness((hsl.lightness + 0.1).clamp(0.0, 1.0))
        .toColor();
    final bottom = hsl
        .withLightness((hsl.lightness - 0.12).clamp(0.0, 1.0))
        .toColor();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        shape: shape,
        gradient: onColor
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [top, bottom],
              ),
        color: onColor ? Colors.white.withValues(alpha: 0.22) : null,
      ),
      child: Text(
        monogram,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.46,
          fontWeight: FontWeight.w600,
          height: 1,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
}

/// Stable colour for an app without an icon, so its monogram and recents
/// card keep the same hue everywhere.
Color flowAppHue(String appId, Brightness brightness) =>
    FlowSpaceTokens.deviceHue('app:$appId', brightness);
