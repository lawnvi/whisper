import 'package:flutter/material.dart';
import 'package:whisper/widget/glass_dialog.dart';

/// A group of rows on the settings pages that are not redesigned yet: the
/// device settings and the phone's window flow service.
class SettingsSectionSurface extends StatelessWidget {
  const SettingsSectionSurface({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return WhisperGlassSurface(
      borderRadius: BorderRadius.circular(14),
      showTopHighlight: false,
      showShadow: false,
      neutral: true,
      // These cards cover a solid page, so backdrop sampling adds no detail
      // and repaints every visible group throughout the iOS slide transition.
      blurBackground: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}
