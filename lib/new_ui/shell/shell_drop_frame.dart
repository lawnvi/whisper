import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// surfaces.md「拖放发送」: files dragged in from outside. The content gets a
/// thin frame, and a small card in the middle says where they go: the device
/// itself, its name, how many. It is a sign, not a button, so it sits on the
/// paper like a card and is only as wide as what it says.
class ShellDropFrame extends StatelessWidget {
  const ShellDropFrame({
    super.key,
    required this.device,
    required this.canSend,
    this.count = 0,
  });

  final DeviceData device;

  /// False when the device is not connected: the card says why instead.
  final bool canSend;

  /// How many things are dragged, when known.
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    const type = WhisperType(touch: false);
    final brightness = Theme.of(context).brightness;
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: canSend ? c.accent : c.border, width: 2),
            borderRadius: BorderRadius.circular(WhisperRadius.l),
          ),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 20),
              decoration: BoxDecoration(
                color: c.raised,
                borderRadius: BorderRadius.circular(WhisperRadius.l),
                boxShadow: WhisperShadow.e2(brightness),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  deviceArtFor(
                    device,
                    size: 56,
                    // Not connected: faded, as in the list.
                    state: canSend
                        ? DeviceArtState.normal
                        : DeviceArtState.nearby,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    canSend
                        ? l10n.shellComposerHint(device.name)
                        : l10n.shellComposerOffline(device.name),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: type.head,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: canSend ? c.ink : c.ink2,
                    ),
                  ),
                  if (canSend && count > 1) ...[
                    const SizedBox(height: 3),
                    Text(
                      l10n.shellDropSendItems(count),
                      style: TextStyle(fontSize: type.note, color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
