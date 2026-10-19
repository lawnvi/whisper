import 'package:flutter/material.dart';

import '../helper/macos_permissions.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// The end of a permission's settings row: a dot and what macOS allows
/// now, then the arrow to where it is changed.
class MacPermissionStatus extends StatelessWidget {
  const MacPermissionStatus({
    super.key,
    required this.permission,
    this.permissions,
    this.optional = false,
  });

  final MacPermission permission;
  final MacPermissions? permissions;

  /// Whisper works without it: off reads as "optional", not as a warning.
  final bool optional;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.whisperPalette;
    final source = permissions ?? MacPermissions.shared;
    return AnimatedBuilder(
      animation: source,
      builder: (context, _) {
        final state = source.stateOf(permission);
        final (label, color) = switch (state) {
          MacPermissionState.granted => (
            l10n.macPermissionGranted,
            palette.trusted,
          ),
          MacPermissionState.denied || MacPermissionState.notAsked
              when optional =>
            (l10n.macPermissionOptional, palette.textMuted),
          MacPermissionState.denied => (
            l10n.macPermissionDenied,
            palette.warning,
          ),
          MacPermissionState.notAsked => (
            l10n.macPermissionNotAsked,
            palette.warning,
          ),
          MacPermissionState.unknown => (
            '',
            palette.textMuted.withValues(alpha: 0.5),
          ),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label.isNotEmpty) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  letterSpacing: 0,
                  color: palette.textMuted,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Icon(Icons.arrow_forward_ios, size: 14, color: palette.textMuted),
          ],
        );
      },
    );
  }
}
