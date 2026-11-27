import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/socket/file_browse_trust_cache.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/pending_outgoing_connection.dart';
import 'package:whisper/state/connection_attempt.dart';
import 'package:whisper/state/pairing_request.dart';

enum PeerPolicyDisposition { manualDisconnect, trustRevoked, deviceDeleted }

enum PeerAuthSuppressionReason { manualDisconnect, trustRevoked, deviceDeleted }

/// Tracks per-peer and global authentication policy epochs, invalidation
/// revisions, auth suppressions, and deleted-peer discovery suppressions.
class PeerPolicyStore {
  PeerPolicyStore({required FileBrowseTrustCache fileBrowseTrustCache})
    : _fileBrowseTrustCache = fileBrowseTrustCache;

  final FileBrowseTrustCache _fileBrowseTrustCache;

  final Set<String> _deletedPeerDiscoverySuppressions = <String>{};
  final Map<String, int> _peerPolicyEpochs = <String, int>{};
  final Map<String, int> _peerInvalidationRevisions = <String, int>{};
  final Map<String, PeerPolicyDisposition> _peerPolicyDispositions =
      <String, PeerPolicyDisposition>{};
  final Map<String, Set<PeerAuthSuppressionReason>> _peerAuthSuppressions =
      <String, Set<PeerAuthSuppressionReason>>{};
  final Map<PeerSocketSession, int> _sessionStartedPolicyRevisions =
      <PeerSocketSession, int>{};

  int _globalPolicyEpoch = 0;
  int _policyRevision = 0;

  int get globalPolicyEpoch => _globalPolicyEpoch;

  int get policyRevision => _policyRevision;

  int peerPolicyEpoch(String peerId) => _peerPolicyEpochs[peerId] ?? 0;

  int peerInvalidationRevision(String peerId) =>
      _peerInvalidationRevisions[peerId] ?? 0;

  void bumpGlobalPolicyEpoch() {
    _globalPolicyEpoch += 1;
  }

  void recordSessionStarted(PeerSocketSession session) {
    _sessionStartedPolicyRevisions[session] = _policyRevision;
  }

  void forgetSession(PeerSocketSession session) {
    _sessionStartedPolicyRevisions.remove(session);
  }

  void clearSessionRevisions() {
    _sessionStartedPolicyRevisions.clear();
  }

  void invalidatePeerPolicy(String peerId, PeerPolicyDisposition disposition) {
    _fileBrowseTrustCache.invalidate(peerId);
    _policyRevision += 1;
    _peerInvalidationRevisions[peerId] = _policyRevision;
    _peerPolicyDispositions[peerId] = disposition;
    _peerPolicyEpochs[peerId] = (_peerPolicyEpochs[peerId] ?? 0) + 1;
  }

  Set<PeerAuthSuppressionReason> _suppressionsFor(String peerId) =>
      _peerAuthSuppressions.putIfAbsent(
        peerId,
        () => <PeerAuthSuppressionReason>{},
      );

  PairingReason? incomingPolicyRepairReason(String peerId) {
    final suppressions = _peerAuthSuppressions[peerId];
    if (suppressions == null || suppressions.isEmpty) {
      return null;
    }
    if (suppressions.contains(PeerAuthSuppressionReason.deviceDeleted)) {
      return null;
    }
    return suppressions.every(
          (reason) =>
              reason == PeerAuthSuppressionReason.trustRevoked ||
              reason == PeerAuthSuppressionReason.manualDisconnect,
        )
        ? PairingReason.newDevice
        : null;
  }

  void requirePairingForPolicyRepair(
    String peerId,
    PairingReason? pairingReason,
  ) {
    final suppressions = _peerAuthSuppressions[peerId];
    final requiresConfirmation =
        suppressions?.any(
          (reason) =>
              reason == PeerAuthSuppressionReason.trustRevoked ||
              reason == PeerAuthSuppressionReason.manualDisconnect,
        ) ==
        true;
    if (requiresConfirmation && pairingReason == null) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  void addSuppression(String peerId, PeerAuthSuppressionReason reason) {
    _suppressionsFor(peerId).add(reason);
  }

  void replaceSuppressionForDelete(String peerId) {
    _suppressionsFor(peerId)
      ..clear()
      ..add(PeerAuthSuppressionReason.deviceDeleted);
  }

  bool removeSuppression(String peerId, PeerAuthSuppressionReason reason) {
    final suppressions = _peerAuthSuppressions[peerId];
    if (suppressions == null || !suppressions.remove(reason)) {
      return false;
    }
    if (suppressions.isEmpty) {
      _peerAuthSuppressions.remove(peerId);
    }
    _policyRevision += 1;
    _peerInvalidationRevisions[peerId] = _policyRevision;
    _peerPolicyEpochs[peerId] = (_peerPolicyEpochs[peerId] ?? 0) + 1;
    return true;
  }

  bool isPeerAuthenticationAllowed(
    String peerId, {
    PendingOutgoingConnection? attempt,
    bool allowTrustRepair = false,
  }) {
    final suppressions = _peerAuthSuppressions[peerId];
    if (suppressions == null || suppressions.isEmpty) {
      return true;
    }
    if (suppressions.contains(PeerAuthSuppressionReason.deviceDeleted)) {
      return suppressions.length == 1 && attempt?.allowsDeviceRepair == true;
    }
    final repairAllowed =
        allowTrustRepair || attempt?.allowsTrustRepair == true;
    return repairAllowed &&
        suppressions.every(
          (reason) =>
              reason == PeerAuthSuppressionReason.trustRevoked ||
              reason == PeerAuthSuppressionReason.manualDisconnect,
        );
  }

  void authorizeInteractiveAttempt(
    PendingOutgoingConnection attempt,
    String peerId,
  ) {
    if (!attempt.request.isAutomatic) {
      removeSuppression(peerId, PeerAuthSuppressionReason.manualDisconnect);
      final suppressions = _peerAuthSuppressions[peerId];
      final repairableSuppression =
          suppressions != null && suppressions.length == 1
          ? suppressions.single
          : null;
      attempt.allowsDeviceRepair =
          repairableSuppression == PeerAuthSuppressionReason.deviceDeleted;
      attempt.allowsTrustRepair =
          repairableSuppression == PeerAuthSuppressionReason.trustRevoked;
    }
    attempt.peerPolicyEpoch = _peerPolicyEpochs[peerId] ?? 0;
    attempt.startedPolicyRevision = _policyRevision;
  }

  void completeDeviceRepairIfNeeded(
    PendingOutgoingConnection? attempt,
    String peerId,
  ) {
    if (attempt?.allowsDeviceRepair != true) {
      return;
    }
    removeSuppression(peerId, PeerAuthSuppressionReason.deviceDeleted);
    attempt!.allowsDeviceRepair = false;
  }

  void bindAttemptPolicyForDiscoveredPeer(
    PendingOutgoingConnection attempt,
    String peerId,
  ) {
    if (attempt.request.expectedPeerId.isNotEmpty) {
      return;
    }
    attempt.peerPolicyEpoch = _peerPolicyEpochs[peerId] ?? 0;
    final invalidationRevision = _peerInvalidationRevisions[peerId] ?? 0;
    if (attempt.request.mode == ConnectionAttemptMode.interactive &&
        invalidationRevision <= attempt.startedPolicyRevision) {
      authorizeInteractiveAttempt(attempt, peerId);
    }
  }

  bool isPendingPolicyCurrent(PendingOutgoingConnection attempt) {
    if (attempt.isCancelled ||
        (attempt.request.isAutomatic &&
            attempt.globalPolicyEpoch != _globalPolicyEpoch)) {
      return false;
    }
    final peerId = attempt.verifiedPeerId.isNotEmpty
        ? attempt.verifiedPeerId
        : attempt.request.expectedPeerId;
    return peerId.isEmpty ||
        (attempt.peerPolicyEpoch == (_peerPolicyEpochs[peerId] ?? 0) &&
            (_peerInvalidationRevisions[peerId] ?? 0) <=
                attempt.startedPolicyRevision &&
            isPeerAuthenticationAllowed(peerId, attempt: attempt));
  }

  bool isSessionPeerPolicyCurrent(PeerSocketSession session) {
    final startedRevision = _sessionStartedPolicyRevisions[session];
    if (startedRevision == null || session.remotePeerId.isEmpty) {
      return false;
    }
    return (_peerInvalidationRevisions[session.remotePeerId] ?? 0) <=
            startedRevision &&
        isPeerAuthenticationAllowed(
          session.remotePeerId,
          allowTrustRepair: true,
        );
  }

  DeviceData? rollbackPreviousDevice(
    PeerSocketSession session,
    DeviceData? previous,
  ) {
    final startedRevision = _sessionStartedPolicyRevisions[session];
    final invalidationRevision =
        _peerInvalidationRevisions[session.remotePeerId] ?? 0;
    if (startedRevision == null || invalidationRevision <= startedRevision) {
      return previous;
    }
    return switch (_peerPolicyDispositions[session.remotePeerId]) {
      PeerPolicyDisposition.deviceDeleted => null,
      PeerPolicyDisposition.trustRevoked => previous?.copyWith(auth: false),
      PeerPolicyDisposition.manualDisconnect || null => previous,
    };
  }

  void suppressDeletedPeerDiscovery(String peerId) {
    _deletedPeerDiscoverySuppressions.add(peerId);
  }

  bool shouldSuppressDiscoveredPeer(String peerId) =>
      _deletedPeerDiscoverySuppressions.contains(peerId);

  void releaseDeletedPeerDiscoverySuppression(String peerId) {
    _deletedPeerDiscoverySuppressions.remove(peerId);
  }
}
