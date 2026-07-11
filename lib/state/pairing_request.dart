import 'package:whisper/model/LocalDatabase.dart';

enum PairingReason {
  newDevice,
  identityChanged,
  legacyTrustWithoutPin,
}

enum PairingPromptMode { initiator, responder }

final class PairingRequest {
  const PairingRequest({
    required this.device,
    required this.pairingCode,
    required this.reason,
    required this.mode,
    this.cancellation,
  }) : assert(pairingCode.length == 6);

  final DeviceData device;
  final String pairingCode;
  final PairingReason reason;
  final PairingPromptMode mode;
  final Future<void>? cancellation;

  bool get isInitiator => mode == PairingPromptMode.initiator;
}

PairingReason? pairingReasonForIdentity(
  DeviceData? stored,
  String presentedPublicKey,
) {
  final pinned = stored?.identityPublicKey ?? '';
  if (stored?.auth == true &&
      pinned.isNotEmpty &&
      pinned == presentedPublicKey) {
    return null;
  }
  if (pinned.isNotEmpty && pinned != presentedPublicKey) {
    return PairingReason.identityChanged;
  }
  if (stored?.auth == true && pinned.isEmpty) {
    return PairingReason.legacyTrustWithoutPin;
  }
  return PairingReason.newDevice;
}
