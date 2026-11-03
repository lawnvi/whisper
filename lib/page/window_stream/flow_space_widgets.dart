import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widget/device_glyph.dart';
import '../../window_stream/core/window_stream_models.dart';
import 'flow_space_theme.dart';

/// [tablet]: the device said it is one (`DeviceFormFactors`); show it with
/// [DeviceGlyph], which stands the tablet upright.
IconData flowDeviceGlyph(WindowStreamPlatform platform, {bool tablet = false}) {
  return switch (platform) {
    WindowStreamPlatform.android || WindowStreamPlatform.ios =>
      tablet ? tabletGlyph : CupertinoIcons.device_phone_portrait,
    WindowStreamPlatform.macos => CupertinoIcons.device_laptop,
    WindowStreamPlatform.windows => CupertinoIcons.desktopcomputer,
    WindowStreamPlatform.linux => CupertinoIcons.desktopcomputer,
  };
}

class FlowEmptyState extends StatelessWidget {
  const FlowEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.actionLabel,
    this.onAction,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const CupertinoActivityIndicator(radius: 13)
              else
                Icon(icon, size: 40, color: colors.tertiaryLabel),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.label,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 6),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.secondaryLabel,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                CupertinoButton.filled(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  onPressed: onAction,
                  child: Text(
                    actionLabel!,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
