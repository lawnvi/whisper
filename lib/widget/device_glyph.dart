import 'package:flutter/cupertino.dart';

/// A tablet among Cupertino's thin device glyphs: there is no tablet of the
/// phone's weight, so its plain rounded rectangle, stood upright by
/// [DeviceGlyph].
const IconData tabletGlyph = CupertinoIcons.rectangle;

/// An [Icon] for a device glyph; [tabletGlyph] is drawn upright.
class DeviceGlyph extends StatelessWidget {
  const DeviceGlyph(this.icon, {super.key, this.size, this.color});

  final IconData icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(icon, size: size, color: color);
    return icon == tabletGlyph
        ? RotatedBox(quarterTurns: 1, child: glyph)
        : glyph;
  }
}
