import 'package:whisper/socket/pairing_attempt_limiter.dart';
import 'package:whisper/state/connection_attempt.dart';

/// What an outgoing connection reports when its handshake failed with
/// [code], the failure code of either side.
ConnectionAttemptResult authFailureResult(
  ConnectionAttemptRequest request,
  String code,
) {
  final reason = switch (code) {
    'pairing_expired' => ConnectionAttemptReason.pairingExpired,
    'upgrade_required' => ConnectionAttemptReason.protocolMismatch,
    'pairing_requires_update' => ConnectionAttemptReason.pairingNeedsUpdate,
    pairingBusyAction => ConnectionAttemptReason.pairingBusy,
    'wrong_intended_peer' ||
    'wrong_intended_pkh' ||
    'identity_pin_conflict' => ConnectionAttemptReason.identityMismatch,
    'automatic_pairing_required' =>
      ConnectionAttemptReason.automaticPairingRequired,
    'rejected' || 'pairing_rejected' => ConnectionAttemptReason.peerRejected,
    'socket_error' => ConnectionAttemptReason.socketError,
    'connection_closed' ||
    'connection_failed' => ConnectionAttemptReason.transportClosed,
    _ => ConnectionAttemptReason.authenticationFailed,
  };
  if (reason == ConnectionAttemptReason.socketError ||
      reason == ConnectionAttemptReason.transportClosed) {
    return ConnectionAttemptResult.networkFailure(
      requestId: request.requestId,
      reason: reason,
    );
  }
  return ConnectionAttemptResult.rejected(
    requestId: request.requestId,
    reason: reason,
  );
}
