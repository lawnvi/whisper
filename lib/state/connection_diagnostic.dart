import 'package:flutter/foundation.dart';
import 'package:whisper/state/connection_attempt.dart';

enum ConnectionDiagnosticStage {
  wifi,
  address,
  service,
  firewall,
  identity,
  version,
  pairing,
}

@immutable
final class ConnectionDiagnostic {
  const ConnectionDiagnostic({required this.stage});

  final ConnectionDiagnosticStage stage;

  factory ConnectionDiagnostic.fromReason(ConnectionAttemptReason reason) {
    return ConnectionDiagnostic(
      stage: switch (reason) {
        ConnectionAttemptReason.invalidEndpoint =>
          ConnectionDiagnosticStage.address,
        ConnectionAttemptReason.networkUnavailable =>
          ConnectionDiagnosticStage.wifi,
        ConnectionAttemptReason.connectionRefused =>
          ConnectionDiagnosticStage.service,
        ConnectionAttemptReason.connectionTimedOut =>
          ConnectionDiagnosticStage.firewall,
        ConnectionAttemptReason.identityMismatch ||
        ConnectionAttemptReason.identityUnpinned ||
        ConnectionAttemptReason.trustRevoked =>
          ConnectionDiagnosticStage.identity,
        ConnectionAttemptReason.protocolMismatch =>
          ConnectionDiagnosticStage.version,
        ConnectionAttemptReason.peerRejected ||
        ConnectionAttemptReason.pairingExpired ||
        ConnectionAttemptReason.automaticPairingRequired =>
          ConnectionDiagnosticStage.pairing,
        ConnectionAttemptReason.socketError ||
        ConnectionAttemptReason.transportClosed ||
        ConnectionAttemptReason.authenticationFailed =>
          ConnectionDiagnosticStage.service,
        _ => ConnectionDiagnosticStage.address,
      },
    );
  }
}
