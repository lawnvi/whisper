import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/pairing_attempt_limiter.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/pending_outgoing_connection.dart';
import 'package:whisper/state/connection_attempt.dart';

/// What an outgoing connection reports when its handshake failed with
/// [code], the failure code of either side.
ConnectionAttemptResult authFailureResult(
  ConnectionAttemptRequest request,
  String code,
) {
  if (code == 'superseded') {
    return ConnectionAttemptResult.cancelled(
      requestId: request.requestId,
      reason: ConnectionAttemptReason.superseded,
    );
  }
  final reason = switch (code) {
    'pairing_expired' => ConnectionAttemptReason.pairingExpired,
    'upgrade_required' ||
    'peer_upgrade_required' => ConnectionAttemptReason.protocolMismatch,
    'local_upgrade_required' => ConnectionAttemptReason.localUpgradeRequired,
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

ConnectionAttemptResult connectionExceptionResult(
  ConnectionAttemptRequest request,
  Object error,
) {
  final upgradeRejected =
      error is WebSocketUpgradeRejected ||
      (error is WebSocketChannelException &&
          error.inner is WebSocketUpgradeRejected);
  if (upgradeRejected) {
    return ConnectionAttemptResult.rejected(
      requestId: request.requestId,
      reason: ConnectionAttemptReason.authenticationFailed,
    );
  }
  final transportError =
      error is WebSocketChannelException && error.inner != null
      ? error.inner!
      : error;
  final isNetworkFailure =
      transportError is SocketException ||
      transportError is HttpException ||
      transportError is TimeoutException ||
      transportError is WebSocketException ||
      error is WebSocketChannelException;
  if (isNetworkFailure) {
    final reason = switch (transportError) {
      TimeoutException() => ConnectionAttemptReason.connectionTimedOut,
      SocketException(:final osError) => _socketDiagnosticReason(
        osError?.errorCode,
      ),
      WebSocketException() => ConnectionAttemptReason.transportClosed,
      HttpException() => ConnectionAttemptReason.connectionRefused,
      _ => ConnectionAttemptReason.transportClosed,
    };
    return ConnectionAttemptResult.networkFailure(
      requestId: request.requestId,
      reason: reason,
    );
  }
  return ConnectionAttemptResult.rejected(
    requestId: request.requestId,
    reason: error is AuthHandshakeException
        ? ConnectionAttemptReason.authenticationFailed
        : ConnectionAttemptReason.localStateFailure,
  );
}

ConnectionAttemptReason _socketDiagnosticReason(int? errorCode) {
  return switch (errorCode) {
    61 || 111 || 10061 => ConnectionAttemptReason.connectionRefused,
    60 || 110 || 10060 => ConnectionAttemptReason.connectionTimedOut,
    _ => ConnectionAttemptReason.networkUnavailable,
  };
}
