import 'dart:async';

import 'package:whisper/model/LocalDatabase.dart';

enum PairingReason {
  newDevice,
  identityChanged,
  legacyTrustWithoutPin,
}

enum PairingPromptMode { initiator, responder }

/// Couples every pairing decision to the lifetime of its visible prompt.
/// Notification actions dismiss the prompt before the handshake continues.
final class PairingPresentationBinding {
  PairingPresentationBinding({
    required Future<void> sessionCancellation,
    required void Function(bool) onResolve,
  }) : _onResolve = onResolve {
    unawaited(sessionCancellation.then<void>((_) => dismiss()));
  }

  final void Function(bool) _onResolve;
  final Completer<void> _dismissed = Completer<void>();

  Future<void> get cancellation => _dismissed.future;
  bool get isDismissed => _dismissed.isCompleted;

  void dismiss() {
    if (!_dismissed.isCompleted) {
      _dismissed.complete();
    }
  }

  void resolve(bool allow) {
    dismiss();
    _onResolve(allow);
  }
}

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
