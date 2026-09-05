import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';

class DeviceConnectionWelcome extends StatelessWidget {
  const DeviceConnectionWelcome({
    super.key,
    required this.hasDevices,
    required this.onPair,
    required this.onManualConnect,
  });

  final bool hasDevices;
  final VoidCallback onPair;
  final VoidCallback onManualConnect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.whisperPalette;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.devices_rounded, size: 52, color: palette.connected),
              const SizedBox(height: 24),
              Text(
                hasDevices
                    ? l10n.selectConversationPlaceholder
                    : l10n.connectFirstDevice,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.deviceConnectionGuide,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textMuted, height: 1.6),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: onPair,
                    icon: const Icon(Icons.qr_code_rounded),
                    label: Text(l10n.qrPairingTitle),
                  ),
                  OutlinedButton.icon(
                    onPressed: onManualConnect,
                    icon: const Icon(Icons.add_link_rounded),
                    label: Text(l10n.manualConnectAction),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                l10n.deviceDiscoveryHelp,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DeviceToolbarButton extends StatelessWidget {
  const DeviceToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    height: 32,
    child: Semantics(
      label: label,
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(11),
          onPressed: onPressed,
          child: Icon(
            icon,
            size: 20,
            color: iconColor ?? context.whisperPalette.textMuted,
          ),
        ),
      ),
    ),
  );
}

/// Presentation only: session selection, trust, and menus stay with the page.
class DesktopDeviceSessionTile extends StatelessWidget {
  const DesktopDeviceSessionTile({
    super.key,
    required this.name,
    required this.identity,
    required this.statusLabel,
    required this.preview,
    required this.time,
    required this.avatar,
    required this.statusColor,
    required this.selected,
    required this.trusted,
    required this.onTap,
  });

  final String name, identity, statusLabel, preview, time;
  final Widget avatar;
  final Color statusColor;
  final bool selected, trusted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return Material(
      color: selected
          ? (colors.brightness == Brightness.dark
                ? palette.surfaceMuted
                : colors.primary.withValues(alpha: 0.08))
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              avatar,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        if (trusted) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: AppLocalizations.of(
                              context,
                            )!.e2eeTrustedConnection,
                            child: Icon(
                              Icons.verified_user_rounded,
                              size: 16,
                              color: palette.trusted,
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Tooltip(
                            message: '$statusLabel · $identity',
                            child: Text(
                              preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
