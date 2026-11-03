import 'package:flutter/material.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/state/pairing_request.dart';
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
    final spaced = '${code.substring(0, 3)} ${code.substring(3)}';
    return PhonePage(
      title: name,
      background: c.content,
      onBack: () => _resolve(false),
      child: CustomMultiChildLayout(
        delegate: _PairLayout(),
        children: [
          LayoutId(
            id: _PairLayout.content,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  deviceArtFor(device, size: 84, paired: warning),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: type.title,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: warning ? c.warn : c.ink,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: type.body,
                      height: 1.5,
                      color: c.ink2,
                    ),
                  ),
                  if (warning) ...[
                    const SizedBox(height: 4),
                    Text(
                      l10n.pairingCompareCode,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: type.body,
                        height: 1.5,
                        color: c.ink2,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Semantics(
                    key: pairingCodeKey,
                    label: l10n.pairingCodeSemantics(code),
                    liveRegion: true,
                    child: ExcludeSemantics(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            left: WhisperSizes.pairCode * .22,
                          ),
                          child: Text(
                            spaced,
                            maxLines: 1,
                            style: TextStyle(
                              fontFamily: WhisperMono.family,
                              fontFamilyFallback: WhisperMono.fallback,
                              fontSize: WhisperSizes.pairCode,
                              height: 1,
                              fontWeight: FontWeight.w600,
                              letterSpacing: WhisperSizes.pairCode * .22,
                              color: c.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  PhoneButton(
                    key: pairingApproveKey,
                    large: true,
                    kind: PhoneButtonKind.primary,
                    label: warning
                        ? l10n.pairingApprove
                        : l10n.phonePairApprove,
                    onTap: _resolved ? null : () => _resolve(true),
                  ),
                  const SizedBox(height: 4),
                  PhoneButton(
                    key: request.isInitiator
                        ? pairingCancelKey
                        : pairingRejectKey,
                    kind: PhoneButtonKind.quiet,
                    color: request.isInitiator ? c.accent : c.bad,
                    label: request.isInitiator
                        ? l10n.cancel
                        : l10n.pairingReject,
                    onTap: _resolved ? null : () => _resolve(false),
                  ),
                ],
              ),
            ),
          ),
          LayoutId(
            id: _PairLayout.notice,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                28,
                8,
                28,
                12 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Text(
                l10n.pairingEncryptionNotice,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: type.tiny,
                  height: 1.4,
                  color: c.ink3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The digits and the button where the prototype has them, in the middle of the
/// page as if the quiet button under them were not there. The notice stays at the
/// bottom, and on a small screen the rest gives way to it and scrolls.
class _PairLayout extends MultiChildLayoutDelegate {
  static const content = 'content', notice = 'notice';

  /// What goes under the part that is centred: the quiet button and its gap.
  static const _under = 48.0;

  @override
  void performLayout(Size size) {
    final foot = layoutChild(
      notice,
      BoxConstraints(maxWidth: size.width, minWidth: size.width),
    );
    positionChild(notice, Offset(0, size.height - foot.height));
    final room = size.height - foot.height;
    final body = layoutChild(
      content,
      BoxConstraints(
        maxWidth: size.width,
        minWidth: size.width,
        maxHeight: room,
      ),
    );
    final centred = (size.height - (body.height - _under)) / 2;
    positionChild(
      content,
      Offset(0, centred.clamp(0.0, room - body.height).toDouble()),
    );
  }

  @override
  bool shouldRelayout(_PairLayout oldDelegate) => false;
}
