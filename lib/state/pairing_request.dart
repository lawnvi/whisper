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
  final Set<void Function()> _dismissListeners = <void Function()>{};
  bool _decisionResolved = false;

  Future<void> get cancellation => _dismissed.future;
  bool get isDismissed => _dismissed.isCompleted;

  void dismiss() {
    if (_dismissed.isCompleted) {
      return;
    }
    _dismissed.complete();
    final listeners = _dismissListeners.toList(growable: false);
    _dismissListeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void resolve(bool allow) {
    if (_decisionResolved || isDismissed) {
      return;
    }
    _decisionResolved = true;
    dismiss();
    _onResolve(allow);
  }

  void Function() addDismissListener(void Function() listener) {
    if (isDismissed) {
      listener();
      return () {};
    }
    _dismissListeners.add(listener);
    return () => _dismissListeners.remove(listener);
  }
}

final class PairingRequest {
  const PairingRequest({
    required this.device,
    required this.pairingCode,
    required this.reason,
    required this.mode,
    this.cancellation,
    this.presentation,
  }) : assert(pairingCode.length == 6);

  final DeviceData device;
  final String pairingCode;
  final PairingReason reason;
  final PairingPromptMode mode;
  final Future<void>? cancellation;
  final PairingPresentationBinding? presentation;

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
