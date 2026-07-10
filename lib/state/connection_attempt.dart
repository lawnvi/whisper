import 'package:flutter/foundation.dart';
import 'package:whisper/state/discovery_identity.dart';
import 'package:whisper/state/peer_endpoint.dart';

enum ConnectionAttemptMode { interactive, automatic }

enum ConnectionAttemptStatus {
  authenticated,
  cancelled,
  rejected,
  networkFailure,
}

enum ConnectionAttemptReason {
  none,
  managerClosed,
  manualDisconnect,
  trustRevoked,
  deviceDeleted,
  autoConnectDisabled,
  identityUnpinned,
  requestCancelled,
  duplicateRequest,
  superseded,
  networkUnavailable,
  transportClosed,
  socketError,
  protocolMismatch,
  peerRejected,
  pairingExpired,
  identityMismatch,
  automaticPairingRequired,
  authenticationFailed,
  localStateFailure,
}

@immutable
final class ConnectionAttemptRequest {
  factory ConnectionAttemptRequest({
    required String requestId,
    required PeerEndpoint endpoint,
    required ConnectionAttemptMode mode,
    String expectedPeerId = '',
    String expectedPublicKeyHash = '',
  }) {
    final normalizedRequestId = requestId.trim();
    final normalizedPeerId = expectedPeerId.trim();
    final normalizedPublicKeyHash = expectedPublicKeyHash.trim();
    if (normalizedRequestId.isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'must not be empty');
    }
    if (mode == ConnectionAttemptMode.automatic &&
        (normalizedPeerId.isEmpty || normalizedPublicKeyHash.isEmpty)) {
      throw ArgumentError(
        'automatic attempts require expectedPeerId and '
        'expectedPublicKeyHash',
      );
    }
    if (normalizedPublicKeyHash.isNotEmpty &&
        !DiscoveryIdentity.isCanonicalPublicKeyHash(
          normalizedPublicKeyHash,
        )) {
      throw ArgumentError.value(
        expectedPublicKeyHash,
        'expectedPublicKeyHash',
        'must be a canonical SHA-256 base64url hash',
      );
    }
    return ConnectionAttemptRequest._(
      requestId: normalizedRequestId,
      endpoint: endpoint,
      expectedPeerId: normalizedPeerId,
      expectedPublicKeyHash: normalizedPublicKeyHash,
      mode: mode,
    );
  }

  const ConnectionAttemptRequest._({
    required this.requestId,
    required this.endpoint,
    required this.expectedPeerId,
    required this.expectedPublicKeyHash,
    required this.mode,
  });

  final String requestId;
  final PeerEndpoint endpoint;
  final String expectedPeerId;
  final String expectedPublicKeyHash;
  final ConnectionAttemptMode mode;

  bool get isAutomatic => mode == ConnectionAttemptMode.automatic;
}

@immutable
final class ConnectionAttemptResult {
  factory ConnectionAttemptResult.authenticated({
    required String requestId,
    required String peerId,
    required int generation,
  }) {
    final normalizedRequestId = _requireRequestId(requestId);
    final normalizedPeerId = peerId.trim();
    if (normalizedPeerId.isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'must not be empty');
    }
    if (generation <= 0) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
    return ConnectionAttemptResult._(
      requestId: normalizedRequestId,
      status: ConnectionAttemptStatus.authenticated,
      peerId: normalizedPeerId,
      generation: generation,
      reason: ConnectionAttemptReason.none,
    );
  }

  factory ConnectionAttemptResult.cancelled({
    required String requestId,
    ConnectionAttemptReason reason = ConnectionAttemptReason.requestCancelled,
  }) =>
      ConnectionAttemptResult._terminal(
        requestId: requestId,
        status: ConnectionAttemptStatus.cancelled,
        reason: reason,
      );

  factory ConnectionAttemptResult.rejected({
    required String requestId,
    ConnectionAttemptReason reason = ConnectionAttemptReason.peerRejected,
  }) =>
      ConnectionAttemptResult._terminal(
        requestId: requestId,
        status: ConnectionAttemptStatus.rejected,
        reason: reason,
      );

  factory ConnectionAttemptResult.networkFailure({
    required String requestId,
    ConnectionAttemptReason reason = ConnectionAttemptReason.networkUnavailable,
  }) =>
      ConnectionAttemptResult._terminal(
        requestId: requestId,
        status: ConnectionAttemptStatus.networkFailure,
        reason: reason,
      );

  factory ConnectionAttemptResult._terminal({
    required String requestId,
    required ConnectionAttemptStatus status,
    required ConnectionAttemptReason reason,
  }) {
    if (reason == ConnectionAttemptReason.none) {
      throw ArgumentError.value(reason, 'reason', 'must describe the failure');
    }
    return ConnectionAttemptResult._(
      requestId: _requireRequestId(requestId),
      status: status,
      peerId: '',
      generation: 0,
      reason: reason,
    );
  }

  const ConnectionAttemptResult._({
    required this.requestId,
    required this.status,
    required this.peerId,
    required this.generation,
    required this.reason,
  });

  final String requestId;
  final ConnectionAttemptStatus status;
  final String peerId;
  final int generation;
  final ConnectionAttemptReason reason;

  bool get isAuthenticated => status == ConnectionAttemptStatus.authenticated;

  static String _requireRequestId(String requestId) {
    final normalized = requestId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'must not be empty');
    }
    return normalized;
  }
}
