import 'package:flutter/material.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// docs/design/surfaces.md「只有这台时」: DESIGN.md's page head for when there is
/// no one else yet. This device, as it is, next to one greyed out: colour means
/// there, grey means not. Fades, and takes no touches, when [visible] is false,
/// so the first device to turn up doesn't make it jump.
class ShellFirstDevice extends StatelessWidget {
  const ShellFirstDevice({
    super.key,
    required this.visible,
    required this.self,
    required this.onConnect,
    this.touch = false,
  });

  final bool visible;
  final DeviceData? self;
  final VoidCallback onConnect;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    return IgnorePointer(
      ignoring: !visible,
      child: SpringBuilder(
        value: visible ? 1 : 0,
        from: 0,
        spring: WhisperSprings.smooth,
        builder: (context, x, child) => x <= .004
            ? const SizedBox.shrink()
            : Opacity(opacity: x.clamp(0, 1), child: child),
        // A little above the middle, where a centred thing looks centred.
        child: Padding(
          padding: EdgeInsets.only(bottom: touch ? 48 : 32),
          child: ShellDeviceState(
            touch: touch,
            art: _Devices(self: self, touch: touch),
            title: l10n.shellFirstDevice,
            body: l10n.shellFirstDeviceHint,
            action: ShellFilledButton(
              touch: touch,
              label: l10n.shellConnectDevice,
              onTap: onConnect,
            ),
          ),
        ),
      ),
    );
  }
}

class _Devices extends StatelessWidget {
  const _Devices({required this.self, required this.touch});

  final DeviceData? self;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final self = this.self;
    final kind = self != null
        ? deviceKindOf(self)
        : (touch ? DeviceKind.phone : DeviceKind.laptop);
    // A height for what is held, a width for the rest: the same real scale.
    final handheld = touch ? 96.0 : 76.0;
    final computer = touch ? 128.0 : 104.0;
    Widget dot() => Container(
      width: 4,
      height: 4,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(color: c.ink3, shape: BoxShape.circle),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DeviceArt(
          kind: kind,
          os: self == null ? DeviceOs.other : deviceOsFor(self.platform),
          wallpaper: DeviceWallpaper.self,
          size: kind.handheld ? handheld : computer,
        ),
        const SizedBox(width: 14),
        dot(),
        dot(),
        dot(),
        const SizedBox(width: 14),
        DeviceArt(
          kind: kind.handheld ? DeviceKind.laptop : DeviceKind.phone,
          wallpaper: DeviceWallpaper.unpaired,
          state: DeviceArtState.offline,
          size: kind.handheld ? computer : handheld,
        ),
      ],
    );
  }
}
