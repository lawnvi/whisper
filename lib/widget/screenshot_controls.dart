import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

class ScreenshotButton extends StatelessWidget {
  const ScreenshotButton({super.key, this.controller, this.capsule = false});

  final DesktopScreenshotController? controller;

  /// Inside the composer.
  final bool capsule;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller ?? DesktopScreenshotController.shared;
    if (capsule) {
      return AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Tooltip(
          message: _tooltip(context, controller) ?? '',
          child: Pressable(
            onTap: controller.capturing || controller.configuring
                ? null
                : () => unawaited(controller.capture()),
            radius: WhisperRadius.capsule,
            label: _tooltip(context, controller),
            child: SizedBox.square(
              dimension: 28,
              child: Center(
                child: WhisperIcon(
                  WhisperGlyph.camera,
                  size: 17,
                  color: context.wc.ink2Glass,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => IconButton(
        tooltip: _tooltip(context, controller),
        onPressed: controller.capturing || controller.configuring
            ? null
            : () => unawaited(controller.capture()),
        icon: const Icon(Icons.crop_free_rounded, size: 18),
        style: IconButton.styleFrom(
          foregroundColor: context.whisperPalette.textMuted,
          minimumSize: const Size(36, 36),
          padding: const EdgeInsets.all(8),
        ),
      ),
    );
  }

  /// The shortcut currently set, there to look up when forgotten.
  static String? _tooltip(
    BuildContext context,
    DesktopScreenshotController controller,
  ) {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return null;
    return controller.enabled && controller.registered
        ? l10n.screenshotButtonTooltip(controller.shortcutLabel)
        : l10n.screenshotButtonTooltipPlain;
  }
}
