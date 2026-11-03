import 'package:flutter/material.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/pairing_dialog.dart';

/// `phone-scanned.jpg`, the prototype's `placePair`: the six digits both devices
/// show, as a page of the stack. Leaving it is saying no.
class PhonePairPage extends StatefulWidget {
  const PhonePairPage({
    super.key,
    required this.request,
    required this.onResolved,
  });

  final PairingRequest request;
  final ValueChanged<bool> onResolved;

  @override
  State<PhonePairPage> createState() => _PhonePairPageState();
}

class _PhonePairPageState extends State<PhonePairPage> {
  bool _resolved = false;

  void _resolve(bool allow) {
    if (_resolved) return;
    setState(() => _resolved = true);
    widget.onResolved(allow);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: true);
    final request = widget.request;
    final device = request.device;
    final name = device.name;
    final warning = request.reason != PairingReason.newDevice;
    final title = switch (request.reason) {
      PairingReason.newDevice => l10n.shellNearbyTitle(name),
      PairingReason.identityChanged => l10n.pairingIdentityChangedTitle,
      PairingReason.legacyTrustWithoutPin => l10n.pairingLegacyTrustTitle,
    };
    final body = switch (request.reason) {
      PairingReason.newDevice =>
        request.isInitiator
            ? l10n.pairingCompareCode
            : l10n.pairingNewDeviceCompareCode(name),
      PairingReason.identityChanged => l10n.pairingIdentityChangedDescription(
        name,
      ),
      PairingReason.legacyTrustWithoutPin => l10n.pairingLegacyTrustDescription(
        name,
      ),
    };
    final code = request.pairingCode;
    return PhonePage(
      title: '',
      background: c.content,
      onBack: () => _resolve(false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            // Between the bar and the buttons, and it scrolls on a small screen.
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (warning)
                        WhisperIcon(WhisperGlyph.warn, size: 44, color: c.warn)
                      else
                        _Devices(device: device),
                      const SizedBox(height: 28),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: type.title,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        body,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: type.note,
                          height: 1.5,
                          color: c.ink2,
                        ),
                      ),
                      if (warning)
                        Text(
                          l10n.pairingCompareCode,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: type.note,
                            height: 1.5,
                            color: c.ink2,
                          ),
                        ),
                      const SizedBox(height: 28),
                      Semantics(
                        key: pairingCodeKey,
                        label: l10n.pairingCodeSemantics(code),
                        liveRegion: true,
                        child: ExcludeSemantics(child: _Digits(code: code)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              12 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PhoneButton(
                  key: pairingApproveKey,
                  large: true,
                  kind: PhoneButtonKind.primary,
                  label: warning ? l10n.pairingApprove : l10n.phonePairApprove,
                  onTap: _resolved ? null : () => _resolve(true),
                ),
                const SizedBox(height: 4),
                PhoneButton(
                  key: request.isInitiator
                      ? pairingCancelKey
                      : pairingRejectKey,
                  kind: PhoneButtonKind.quiet,
                  color: request.isInitiator ? c.ink2 : c.bad,
                  label: request.isInitiator ? l10n.cancel : l10n.pairingReject,
                  onTap: _resolved ? null : () => _resolve(false),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.pairingEncryptionNotice,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: type.tiny,
                    height: 1.4,
                    color: c.ink3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// This phone and the other device, joined by a lock: what is about to happen.
class _Devices extends StatelessWidget {
  const _Devices({required this.device});

  final DeviceData device;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    Widget dot() => Container(
      width: 4,
      height: 4,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(color: c.ink3, shape: BoxShape.circle),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const DeviceArt(
          kind: DeviceKind.phone,
          wallpaper: DeviceWallpaper.self,
          size: 72,
        ),
        const SizedBox(width: 16),
        dot(),
        dot(),
        Container(
          width: 32,
          height: 32,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.fill, shape: BoxShape.circle),
          child: WhisperIcon(WhisperGlyph.lock, size: 16, color: c.ink2),
        ),
        dot(),
        dot(),
        const SizedBox(width: 16),
        deviceArtFor(
          device,
          size: deviceKindOf(device).handheld ? 72 : 92,
          paired: false,
        ),
      ],
    );
  }
}

/// The six digits, each in its own tile, three and three: easy to compare one by
/// one with the other screen.
class _Digits extends StatelessWidget {
  const _Digits({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    Widget tile(String digit) => Container(
      width: 44,
      height: 58,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: c.fill,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(WhisperRadius.m),
        ),
      ),
      child: Text(
        digit,
        style: TextStyle(
          fontFamily: WhisperMono.family,
          fontFamilyFallback: WhisperMono.fallback,
          fontSize: WhisperSizes.pairCode,
          height: 1,
          fontWeight: FontWeight.w600,
          color: c.ink,
        ),
      ),
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < code.length; i++) ...[
            if (i == code.length ~/ 2) const SizedBox(width: 10),
            tile(code[i]),
          ],
        ],
      ),
    );
  }
}
