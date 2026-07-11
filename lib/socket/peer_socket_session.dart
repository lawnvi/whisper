import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/auth_session_keys.dart';
import 'package:whisper/socket/auth_transcript.dart';
import 'package:whisper/socket/authenticated_frame.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/bounded_receive_queue.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/socket_admission.dart';
import 'package:whisper/state/peer_profile.dart';

enum PeerSocketRole { server, client }

enum PeerSocketPhase {
  awaitingHello,
  awaitingChallenge,
  awaitingProof,
  awaitingLocalApproval,
  awaitingResult,
  authenticated,
  closing,
}

final class AuthHandshakeException implements Exception {
  const AuthHandshakeException(this.code);

  final String code;

  @override
  String toString() => 'AuthHandshakeException($code)';
}

final class PeerSocketSession {
  PeerSocketSession._({
    required this.role,
    required this.connectionGeneration,
    required this.localIdentity,
    required this.localProfile,
    required KeyPair localEphemeralKeyPair,
    required Uint8List localNonce,
    required this.intendedPeerId,
    required this.intendedPublicKeyHash,
    required Duration handshakeTimeout,
    required void Function()? onTimeout,
  })  : _localEphemeralKeyPair = localEphemeralKeyPair,
        _localNonce = Uint8List.fromList(localNonce),
        phase = role == PeerSocketRole.server
            ? PeerSocketPhase.awaitingHello
            : PeerSocketPhase.awaitingChallenge {
    _handshakeTimer = Timer(handshakeTimeout, () {
      if (phase == PeerSocketPhase.authenticated ||
          phase == PeerSocketPhase.closing) {
        return;
      }
      close();
      onTimeout?.call();
    });
  }

  static const int protocolVersion = 6;

  final PeerSocketRole role;
  final int connectionGeneration;
  final DeviceIdentity localIdentity;
  final WirePeerProfile localProfile;
  final KeyPair _localEphemeralKeyPair;
  final Uint8List _localNonce;
  final String intendedPeerId;
  final String intendedPublicKeyHash;

  late Timer _handshakeTimer;
  PeerSocketPhase phase;
  WirePeerProfile? _remoteProfile;
  String? _remoteIdentityPublicKey;
  PublicKey? _remoteEphemeralPublicKey;
  Uint8List? _remoteNonce;
  AuthTranscript? _transcript;
  AuthenticatedFrameCodec? _codec;
  Uint8List? _mediaSendKey;
  Uint8List? _mediaReceiveKey;
  bool _approvalResolved = false;
  bool _approvalAllowed = false;
  bool _remoteApprovalResolved = false;
  bool _remoteApprovalAllowed = false;
  bool _pairingCompletionClaimed = false;
  bool _authenticationApproved = false;
  bool _authenticationCommitted = false;
  bool _closed = false;
  final Completer<void> _closedCompleter = Completer<void>();
  Future<void> _sendChain = Future<void>.value();
  BoundedReceiveQueue? _inboundQueue;
  BoundedOutboundQueue? _outboundQueue;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _receiveStopFuture;
  AdmissionLease? _admissionLease;

  static Future<PeerSocketSession> create({
    required PeerSocketRole role,
    required int connectionGeneration,
    required DeviceIdentity localIdentity,
    required WirePeerProfile localProfile,
    KeyPair? localEphemeralKeyPair,
    Uint8List? localNonce,
    String intendedPeerId = '',
    String intendedPublicKeyHash = '',
    Duration handshakeTimeout = const Duration(seconds: 30),
    void Function()? onTimeout,
  }) async {
    if (localProfile.protocolVersion != protocolVersion) {
      throw ArgumentError.value(
        localProfile.protocolVersion,
        'localProfile.protocolVersion',
      );
    }
    final nonce = localNonce ?? _secureNonce();
    if (nonce.length != 32) {
      throw ArgumentError.value(nonce.length, 'localNonce.length');
    }
    return PeerSocketSession._(
      role: role,
      connectionGeneration: connectionGeneration,
      localIdentity: localIdentity,
      localProfile: localProfile,
      localEphemeralKeyPair: localEphemeralKeyPair ??
          await AuthSessionKeys.generateEphemeralKeyPair(),
      localNonce: nonce,
      intendedPeerId: intendedPeerId,
      intendedPublicKeyHash: intendedPublicKeyHash,
      handshakeTimeout: handshakeTimeout,
      onTimeout: onTimeout,
    );
  }

  WirePeerProfile? get remoteProfile => _remoteProfile;
  String get remotePeerId => _remoteProfile?.uid ?? '';
  String get remoteIdentityPublicKey => _remoteIdentityPublicKey ?? '';
  String get pairingCode => _transcript?.pairingCode() ?? '';
  AuthenticatedFrameCodec? get codec => _codec;
  Uint8List? get mediaSendKey => isAuthenticated && _mediaSendKey != null
      ? Uint8List.fromList(_mediaSendKey!)
      : null;
  Uint8List? get mediaReceiveKey => isAuthenticated && _mediaReceiveKey != null
      ? Uint8List.fromList(_mediaReceiveKey!)
      : null;
  bool get isAuthenticated =>
      !_closed && phase == PeerSocketPhase.authenticated;
  bool get isAuthenticationReady {
    final expectedPhase = role == PeerSocketRole.server
        ? PeerSocketPhase.awaitingLocalApproval
        : PeerSocketPhase.awaitingResult;
    return !_closed &&
        phase == expectedPhase &&
        _authenticationApproved &&
        _authenticationCommitted &&
        _codec != null;
  }

  bool get isClosed => _closed;
  Future<void> get closed => _closedCompleter.future;
  bool get isMutuallyApproved =>
      role == PeerSocketRole.server &&
      _approvalResolved &&
      _approvalAllowed &&
      _remoteApprovalResolved &&
      _remoteApprovalAllowed;
  bool get hasPairingRejection =>
      (_approvalResolved && !_approvalAllowed) ||
      (_remoteApprovalResolved && !_remoteApprovalAllowed);
  bool get _canResolveLocalApproval => switch (role) {
        PeerSocketRole.client => phase == PeerSocketPhase.awaitingLocalApproval,
        PeerSocketRole.server => phase == PeerSocketPhase.awaitingProof ||
            phase == PeerSocketPhase.awaitingLocalApproval,
      };

  bool tryClaimPairingCompletion() {
    if (role != PeerSocketRole.server ||
        isClosed ||
        phase != PeerSocketPhase.awaitingLocalApproval ||
        _pairingCompletionClaimed ||
        (!isMutuallyApproved && !hasPairingRejection)) {
      return false;
    }
    _pairingCompletionClaimed = true;
    return true;
  }

  int get pendingReceiveItems => _inboundQueue?.pendingItems ?? 0;
  int get pendingOutboundItems => _outboundQueue?.pendingItems ?? 0;

  void attachTransport({
    required StreamSubscription<dynamic> subscription,
    required Future<void> Function(Stream<Object>) addStream,
    AdmissionLease? admissionLease,
    required void Function() onOverflow,
  }) {
    if (_subscription != null ||
        _inboundQueue != null ||
        _outboundQueue != null) {
      throw StateError('transport already attached');
    }
    _subscription = subscription;
    _admissionLease = admissionLease;
    _inboundQueue = BoundedReceiveQueue(
      onPause: subscription.pause,
      onResume: subscription.resume,
      onOverflow: onOverflow,
    );
    _outboundQueue = BoundedOutboundQueue.chat(
      addStream: addStream,
      onOverflow: onOverflow,
    );
  }

  Future<bool> enqueueIncoming(
    int byteLength,
    Future<void> Function() action,
  ) {
    final queue = _inboundQueue;
    if (queue == null) {
      return Future<bool>.value(false);
    }
    return queue.add(byteLength, action);
  }

  Future<bool> enqueueOutgoing(
    Object value, {
    required int byteLength,
  }) {
    final queue = _outboundQueue;
    if (queue == null) {
      return Future<bool>.value(false);
    }
    return queue.add(value, byteLength: byteLength);
  }

  Future<bool> enqueueAuthenticatedOutgoing(
    Uint8List payload, {
    required int byteLength,
  }) {
    final queue = _outboundQueue;
    if (queue == null) {
      return Future<bool>.value(false);
    }
    return queue.addLazy(
      () => encodeOutgoing(payload),
      byteLength: byteLength,
    );
  }

  void markTransportAuthenticated() {
    _admissionLease?.markAuthenticated();
  }

  Future<void> stopReceivingAndDrain() {
    return _receiveStopFuture ??= _stopReceivingAndDrain();
  }

  Future<void> _stopReceivingAndDrain() async {
    final subscription = _subscription;
    try {
      await subscription?.cancel();
    } finally {
      if (identical(_subscription, subscription)) {
        _subscription = null;
      }
      await _inboundQueue?.closeAndDrain();
    }
  }

  Future<void> drainOutbound() async {
    await _outboundQueue?.closeAndDrain();
  }

  void releaseAdmission() {
    _admissionLease?.close();
    _admissionLease = null;
  }

  Future<Uint8List> encodeOutgoing(Uint8List payload) {
    final completer = Completer<Uint8List>();
    _sendChain = _sendChain.then((_) async {
      if (!isAuthenticated || _codec == null) {
        throw const AuthHandshakeException('session_not_authenticated');
      }
      completer.complete(await _continueAfter(
        _codec!.encode(payload),
        PeerSocketPhase.authenticated,
      ));
    }).catchError((Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Uint8List> decodeIncoming(Uint8List frame) async {
    if (!isAuthenticated || _codec == null) {
      throw const AuthHandshakeException('session_not_authenticated');
    }
    return _continueAfter(
      _codec!.decode(frame),
      PeerSocketPhase.authenticated,
    );
  }

  Future<AuthEnvelope> createHello() async {
    _require(PeerSocketRole.client, PeerSocketPhase.awaitingChallenge);
    final publicKey = await _continueAfter(
      AuthSessionKeys.publicKeyBase64Url(_localEphemeralKeyPair),
      PeerSocketPhase.awaitingChallenge,
    );
    return AuthEnvelope.hello(
      protocolVersion: protocolVersion,
      peerId: localProfile.uid,
      identityPublicKey: localIdentity.publicKeyBase64Url,
      ephemeralPublicKey: publicKey,
      nonce: encodeAuthBase64Url(_localNonce),
      profileDigest: encodeAuthBase64Url(localProfile.canonicalDigest()),
      intendedPeerId: intendedPeerId.isEmpty ? null : intendedPeerId,
      intendedPublicKeyHash:
          intendedPublicKeyHash.isEmpty ? null : intendedPublicKeyHash,
      profile: localProfile.toJson(),
    );
  }

  Future<AuthEnvelope> receiveHello(AuthEnvelope hello) async {
    _require(PeerSocketRole.server, PeerSocketPhase.awaitingHello);
    try {
      _requireEnvelope(hello, AuthAction.hello);
      if (hello.intendedPeerId != null &&
          hello.intendedPeerId!.isNotEmpty &&
          hello.intendedPeerId != localProfile.uid) {
        return _fail('wrong_intended_peer');
      }
      final localPkh = identityPublicKeyHash(localIdentity.publicKeyBase64Url);
      if (hello.intendedPublicKeyHash != null &&
          hello.intendedPublicKeyHash!.isNotEmpty &&
          hello.intendedPublicKeyHash != localPkh) {
        return _fail('wrong_intended_pkh');
      }
      final remoteProfile = _decodeProfile(hello);
      if (remoteProfile.uid != hello.peerId) {
        return _fail('profile_peer_mismatch');
      }
      final remoteIdentityPublicKey = hello.identityPublicKey!;
      final remoteEphemeralPublicKey = AuthSessionKeys.parseEphemeralPublicKey(
        hello.ephemeralPublicKey!,
      );
      final remoteNonce = decodeAuthBase64Url(
        hello.nonce,
        expectedLength: 32,
      );
      final localEphemeralPublicKey = await _continueAfter(
        AuthSessionKeys.publicKeyBase64Url(_localEphemeralKeyPair),
        PeerSocketPhase.awaitingHello,
      );
      final transcript = await _continueAfter(
        _buildTranscript(
          clientProfile: remoteProfile,
          serverProfile: localProfile,
          clientIdentityKey: remoteIdentityPublicKey,
          serverIdentityKey: localIdentity.publicKeyBase64Url,
          clientEphemeralKey: hello.ephemeralPublicKey!,
          serverEphemeralKey: localEphemeralPublicKey,
          clientNonce: remoteNonce,
          serverNonce: _localNonce,
          intendedPkh: hello.intendedPublicKeyHash ?? '',
        ),
        PeerSocketPhase.awaitingHello,
      );
      final signature = await _continueAfter(
        localIdentity.sign(transcript.challengeBytes()),
        PeerSocketPhase.awaitingHello,
      );
      _remoteProfile = remoteProfile;
      _remoteIdentityPublicKey = remoteIdentityPublicKey;
      _remoteEphemeralPublicKey = remoteEphemeralPublicKey;
      _remoteNonce = remoteNonce;
      _transcript = transcript;
      _transition(
        PeerSocketPhase.awaitingHello,
        PeerSocketPhase.awaitingProof,
      );
      return AuthEnvelope.challenge(
        protocolVersion: protocolVersion,
        peerId: localProfile.uid,
        identityPublicKey: localIdentity.publicKeyBase64Url,
        ephemeralPublicKey: localEphemeralPublicKey,
        nonce: encodeAuthBase64Url(_localNonce),
        peerNonce: hello.nonce,
        profileDigest: encodeAuthBase64Url(localProfile.canonicalDigest()),
        signature: signature,
        profile: localProfile.toJson(),
      );
    } on AuthHandshakeException {
      rethrow;
    } catch (_) {
      return _fail('invalid_hello');
    }
  }

  Future<void> receiveChallenge(AuthEnvelope challenge) async {
    _require(PeerSocketRole.client, PeerSocketPhase.awaitingChallenge);
    try {
      _requireEnvelope(challenge, AuthAction.challenge);
      if (!_sameBytes(
        decodeAuthBase64Url(challenge.peerNonce!, expectedLength: 32),
        _localNonce,
      )) {
        _fail<void>('nonce_mismatch');
      }
      final remoteProfile = _decodeProfile(challenge);
      if (remoteProfile.uid != challenge.peerId) {
        _fail<void>('profile_peer_mismatch');
      }
      if (intendedPeerId.isNotEmpty && remoteProfile.uid != intendedPeerId) {
        _fail<void>('wrong_intended_peer');
      }
      if (intendedPublicKeyHash.isNotEmpty &&
          identityPublicKeyHash(challenge.identityPublicKey!) !=
              intendedPublicKeyHash) {
        _fail<void>('wrong_intended_pkh');
      }
      final remoteIdentityPublicKey = challenge.identityPublicKey!;
      final remoteEphemeralPublicKey = AuthSessionKeys.parseEphemeralPublicKey(
        challenge.ephemeralPublicKey!,
      );
      final remoteNonce = decodeAuthBase64Url(
        challenge.nonce,
        expectedLength: 32,
      );
      final localEphemeralPublicKey = await _continueAfter(
        AuthSessionKeys.publicKeyBase64Url(_localEphemeralKeyPair),
        PeerSocketPhase.awaitingChallenge,
      );
      final transcript = await _continueAfter(
        _buildTranscript(
          clientProfile: localProfile,
          serverProfile: remoteProfile,
          clientIdentityKey: localIdentity.publicKeyBase64Url,
          serverIdentityKey: remoteIdentityPublicKey,
          clientEphemeralKey: localEphemeralPublicKey,
          serverEphemeralKey: challenge.ephemeralPublicKey!,
          clientNonce: _localNonce,
          serverNonce: remoteNonce,
          intendedPkh: intendedPublicKeyHash,
        ),
        PeerSocketPhase.awaitingChallenge,
      );
      final valid = await _continueAfter(
        verifyDeviceSignature(
          publicKeyBase64Url: remoteIdentityPublicKey,
          message: transcript.challengeBytes(),
          signatureBase64Url: challenge.signature!,
        ),
        PeerSocketPhase.awaitingChallenge,
      );
      if (!valid) {
        _fail<void>('invalid_challenge_signature');
      }
      _remoteProfile = remoteProfile;
      _remoteIdentityPublicKey = remoteIdentityPublicKey;
      _remoteEphemeralPublicKey = remoteEphemeralPublicKey;
      _remoteNonce = remoteNonce;
      _transcript = transcript;
      _transition(
        PeerSocketPhase.awaitingChallenge,
        PeerSocketPhase.awaitingLocalApproval,
      );
    } on AuthHandshakeException {
      rethrow;
    } catch (_) {
      _fail<void>('invalid_challenge');
    }
  }

  Future<AuthEnvelope> createProof() async {
    if (role != PeerSocketRole.client || isClosed) {
      return _fail('unexpected_phase');
    }
    if (phase != PeerSocketPhase.awaitingResult ||
        !_approvalResolved ||
        !_approvalAllowed ||
        _transcript == null) {
      return _fail('approval_required');
    }
    final signature = await _continueAfter(
      localIdentity.sign(_transcript!.proofBytes()),
      PeerSocketPhase.awaitingResult,
    );
    return AuthEnvelope.proof(
      protocolVersion: protocolVersion,
      peerId: localProfile.uid,
      nonce: encodeAuthBase64Url(_localNonce),
      peerNonce: encodeAuthBase64Url(_remoteNonce!),
      profileDigest: encodeAuthBase64Url(localProfile.canonicalDigest()),
      signature: signature,
    );
  }

  Future<void> receiveProof(AuthEnvelope proof) async {
    _require(PeerSocketRole.server, PeerSocketPhase.awaitingProof);
    try {
      _requireEnvelope(proof, AuthAction.proof);
      if (proof.peerId != remotePeerId ||
          !_sameBytes(
            decodeAuthBase64Url(proof.nonce, expectedLength: 32),
            _remoteNonce!,
          ) ||
          !_sameBytes(
            decodeAuthBase64Url(proof.peerNonce!, expectedLength: 32),
            _localNonce,
          ) ||
          !_sameBytes(
            decodeAuthBase64Url(proof.profileDigest, expectedLength: 32),
            _remoteProfile!.canonicalDigest(),
          )) {
        _fail<void>('proof_mismatch');
      }
      final valid = await _continueAfter(
        verifyDeviceSignature(
          publicKeyBase64Url: remoteIdentityPublicKey,
          message: _transcript!.proofBytes(),
          signatureBase64Url: proof.signature!,
        ),
        PeerSocketPhase.awaitingProof,
      );
      if (!valid) {
        _fail<void>('invalid_proof_signature');
      }
      _transition(
        PeerSocketPhase.awaitingProof,
        PeerSocketPhase.awaitingLocalApproval,
      );
    } on AuthHandshakeException {
      rethrow;
    } catch (_) {
      _fail<void>('invalid_proof');
    }
  }

  Future<AuthEnvelope> createApproval({
    required bool allow,
    required String reason,
  }) async {
    final expectedPhase = allow
        ? PeerSocketPhase.awaitingResult
        : PeerSocketPhase.awaitingLocalApproval;
    _require(PeerSocketRole.client, expectedPhase);
    if (!_approvalResolved ||
        _approvalAllowed != allow ||
        _transcript == null) {
      return _fail('approval_required');
    }
    final signature = await _continueAfter(
      localIdentity.sign(
        _transcript!.approvalBytes(allow: allow, reason: reason),
      ),
      expectedPhase,
    );
    return AuthEnvelope.approval(
      protocolVersion: protocolVersion,
      peerId: localProfile.uid,
      nonce: encodeAuthBase64Url(_localNonce),
      peerNonce: encodeAuthBase64Url(_remoteNonce!),
      profileDigest: encodeAuthBase64Url(localProfile.canonicalDigest()),
      signature: signature,
      allow: allow,
      reason: reason,
    );
  }

  Future<bool> receiveApproval(AuthEnvelope approval) async {
    _require(PeerSocketRole.server, PeerSocketPhase.awaitingLocalApproval);
    try {
      _requireEnvelope(approval, AuthAction.approval);
      if (_remoteApprovalResolved) {
        return _fail('duplicate_approval');
      }
      if (approval.peerId != remotePeerId ||
          !_sameBytes(
            decodeAuthBase64Url(approval.nonce, expectedLength: 32),
            _remoteNonce!,
          ) ||
          !_sameBytes(
            decodeAuthBase64Url(approval.peerNonce!, expectedLength: 32),
            _localNonce,
          ) ||
          !_sameBytes(
            decodeAuthBase64Url(approval.profileDigest, expectedLength: 32),
            _remoteProfile!.canonicalDigest(),
          )) {
        return _fail('approval_mismatch');
      }
      final valid = await _continueAfter(
        verifyDeviceSignature(
          publicKeyBase64Url: remoteIdentityPublicKey,
          message: _transcript!.approvalBytes(
            allow: approval.allow!,
            reason: approval.reason!,
          ),
          signatureBase64Url: approval.signature!,
        ),
        PeerSocketPhase.awaitingLocalApproval,
      );
      if (!valid) {
        return _fail('invalid_approval_signature');
      }
      _remoteApprovalResolved = true;
      _remoteApprovalAllowed = approval.allow!;
      return approval.allow!;
    } on AuthHandshakeException {
      rethrow;
    } catch (_) {
      return _fail('invalid_approval');
    }
  }

  bool resolveLocalApproval({
    required int generation,
    required bool allow,
  }) {
    if (generation != connectionGeneration ||
        !_canResolveLocalApproval ||
        _approvalResolved) {
      return false;
    }
    _approvalResolved = true;
    _approvalAllowed = allow;
    if (role == PeerSocketRole.client && allow) {
      _transition(
        PeerSocketPhase.awaitingLocalApproval,
        PeerSocketPhase.awaitingResult,
      );
    }
    return true;
  }

  void Function(bool) guardApprovalCallback(void Function(bool) callback) {
    final generation = connectionGeneration;
    var delivered = false;
    return (allow) {
      if (delivered ||
          generation != connectionGeneration ||
          !_canResolveLocalApproval ||
          isClosed) {
        return;
      }
      delivered = true;
      callback(allow);
    };
  }

  Future<AuthEnvelope> createResult({
    required bool allow,
    required String reason,
  }) async {
    _require(PeerSocketRole.server, PeerSocketPhase.awaitingLocalApproval);
    final decisionMatches = allow ? isMutuallyApproved : hasPairingRejection;
    if (!decisionMatches || _transcript == null) {
      return _fail('approval_result_mismatch');
    }
    final signature = await _continueAfter(
      localIdentity.sign(
        _transcript!.resultBytes(allow: allow, reason: reason),
      ),
      PeerSocketPhase.awaitingLocalApproval,
    );
    final result = AuthEnvelope.result(
      protocolVersion: protocolVersion,
      peerId: localProfile.uid,
      nonce: encodeAuthBase64Url(_localNonce),
      peerNonce: encodeAuthBase64Url(_remoteNonce!),
      profileDigest: encodeAuthBase64Url(localProfile.canonicalDigest()),
      signature: signature,
      allow: allow,
      reason: reason,
    );
    if (allow) {
      _authenticationApproved = true;
    }
    return result;
  }

  Future<bool> receiveResult(AuthEnvelope result) async {
    if (role != PeerSocketRole.client ||
        isClosed ||
        (phase != PeerSocketPhase.awaitingLocalApproval &&
            phase != PeerSocketPhase.awaitingResult)) {
      return _fail('unexpected_phase');
    }
    final expectedPhase = phase;
    try {
      _requireEnvelope(result, AuthAction.result);
      if (result.peerId != remotePeerId ||
          !_sameBytes(
            decodeAuthBase64Url(result.nonce, expectedLength: 32),
            _remoteNonce!,
          ) ||
          !_sameBytes(
            decodeAuthBase64Url(result.peerNonce!, expectedLength: 32),
            _localNonce,
          ) ||
          !_sameBytes(
            decodeAuthBase64Url(result.profileDigest, expectedLength: 32),
            _remoteProfile!.canonicalDigest(),
          )) {
        return _fail('result_mismatch');
      }
      final valid = await _continueAfter(
        verifyDeviceSignature(
          publicKeyBase64Url: remoteIdentityPublicKey,
          message: _transcript!.resultBytes(
            allow: result.allow!,
            reason: result.reason!,
          ),
          signatureBase64Url: result.signature!,
        ),
        expectedPhase,
      );
      if (!valid) {
        return _fail('invalid_result_signature');
      }
      if (!result.allow!) {
        close();
        return false;
      }
      if (expectedPhase != PeerSocketPhase.awaitingResult ||
          !_approvalResolved ||
          !_approvalAllowed) {
        return _fail('approval_required');
      }
      _authenticationApproved = true;
      return true;
    } on AuthHandshakeException {
      rethrow;
    } catch (_) {
      return _fail('invalid_result');
    }
  }

  Future<bool> commitAuthentication({
    required int generation,
    required Future<void> Function() persistIdentity,
    required Future<void> Function() registerPeer,
  }) async {
    final expectedPhase = role == PeerSocketRole.server
        ? PeerSocketPhase.awaitingLocalApproval
        : PeerSocketPhase.awaitingResult;
    if (generation != connectionGeneration ||
        isClosed ||
        phase != expectedPhase ||
        !_authenticationApproved ||
        _authenticationCommitted) {
      return false;
    }
    _authenticationCommitted = true;
    try {
      await _continueAfter(persistIdentity(), expectedPhase);
      await _enableCodec(expectedPhase);
      await _continueAfter(registerPeer(), expectedPhase);
      _transition(expectedPhase, PeerSocketPhase.authenticated);
      _handshakeTimer.cancel();
      return true;
    } catch (_) {
      close();
      rethrow;
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    phase = PeerSocketPhase.closing;
    _handshakeTimer.cancel();
    _outboundQueue?.abort();
    _clearMediaKeys();
    _closedCompleter.complete();
  }

  Future<void> _enableCodec(PeerSocketPhase expectedPhase) async {
    final keys = await _continueAfter(
      AuthSessionKeys.derive(
        localEphemeralKeyPair: _localEphemeralKeyPair,
        remoteEphemeralPublicKey: _remoteEphemeralPublicKey!,
        transcriptHash: _transcript!.transcriptHash(),
      ),
      expectedPhase,
    );
    _codec = role == PeerSocketRole.client
        ? AuthenticatedFrameCodec(
            sendKey: keys.clientToServerChat,
            receiveKey: keys.serverToClientChat,
          )
        : AuthenticatedFrameCodec(
            sendKey: keys.serverToClientChat,
            receiveKey: keys.clientToServerChat,
          );
    final sendMediaKey = role == PeerSocketRole.client
        ? keys.clientToServerMedia
        : keys.serverToClientMedia;
    final receiveMediaKey = role == PeerSocketRole.client
        ? keys.serverToClientMedia
        : keys.clientToServerMedia;
    _mediaSendKey = Uint8List.fromList(await sendMediaKey.extractBytes());
    _mediaReceiveKey = Uint8List.fromList(await receiveMediaKey.extractBytes());
  }

  void _clearMediaKeys() {
    final sendKey = _mediaSendKey;
    final receiveKey = _mediaReceiveKey;
    if (sendKey != null) {
      sendKey.fillRange(0, sendKey.length, 0);
    }
    if (receiveKey != null) {
      receiveKey.fillRange(0, receiveKey.length, 0);
    }
    _mediaSendKey = null;
    _mediaReceiveKey = null;
  }

  WirePeerProfile _decodeProfile(AuthEnvelope envelope) {
    final profileJson = envelope.profile;
    if (profileJson == null) {
      return _fail('missing_profile');
    }
    final profile = WirePeerProfile.fromJson(profileJson);
    if (profile.protocolVersion != protocolVersion) {
      return _fail('upgrade_required');
    }
    final claimedDigest = decodeAuthBase64Url(
      envelope.profileDigest,
      expectedLength: 32,
    );
    if (!_sameBytes(claimedDigest, profile.canonicalDigest())) {
      return _fail('profile_digest_mismatch');
    }
    return profile;
  }

  Future<AuthTranscript> _buildTranscript({
    required WirePeerProfile clientProfile,
    required WirePeerProfile serverProfile,
    required String clientIdentityKey,
    required String serverIdentityKey,
    required String clientEphemeralKey,
    required String serverEphemeralKey,
    required Uint8List clientNonce,
    required Uint8List serverNonce,
    required String intendedPkh,
  }) async {
    return AuthTranscript(
      protocolVersion: protocolVersion,
      clientPeerId: clientProfile.uid,
      serverPeerId: serverProfile.uid,
      clientIdentityPublicKey: decodeAuthBase64Url(
        clientIdentityKey,
        expectedLength: 32,
      ),
      serverIdentityPublicKey: decodeAuthBase64Url(
        serverIdentityKey,
        expectedLength: 32,
      ),
      clientEphemeralPublicKey: decodeAuthBase64Url(
        clientEphemeralKey,
        expectedLength: 32,
      ),
      serverEphemeralPublicKey: decodeAuthBase64Url(
        serverEphemeralKey,
        expectedLength: 32,
      ),
      intendedPublicKeyHash: intendedPkh,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
      clientProfileDigest: clientProfile.canonicalDigest(),
      serverProfileDigest: serverProfile.canonicalDigest(),
    );
  }

  void _require(PeerSocketRole expectedRole, PeerSocketPhase expectedPhase) {
    if (role != expectedRole) {
      _fail<void>('unexpected_phase');
    }
    _requirePhase(expectedPhase);
  }

  void _requirePhase(PeerSocketPhase expectedPhase) {
    if (isClosed) {
      throw const AuthHandshakeException('session_closed');
    }
    if (phase != expectedPhase) {
      _fail<void>('unexpected_phase');
    }
  }

  Future<T> _continueAfter<T>(
    Future<T> operation,
    PeerSocketPhase expectedPhase,
  ) async {
    final result = await operation;
    _requirePhase(expectedPhase);
    return result;
  }

  void _transition(
    PeerSocketPhase expectedPhase,
    PeerSocketPhase nextPhase,
  ) {
    _requirePhase(expectedPhase);
    phase = nextPhase;
  }

  void _requireEnvelope(AuthEnvelope envelope, AuthAction action) {
    if (envelope.action != action ||
        envelope.protocolVersion != protocolVersion) {
      _fail<void>(envelope.protocolVersion == protocolVersion
          ? 'unexpected_action'
          : 'upgrade_required');
    }
  }

  Never _fail<T>(String code) {
    close();
    throw AuthHandshakeException(code);
  }
}

String identityPublicKeyHash(String publicKeyBase64Url) {
  final publicKey = decodeAuthBase64Url(
    publicKeyBase64Url,
    expectedLength: 32,
  );
  return base64Url
      .encode(hashes.sha256.convert(publicKey).bytes)
      .replaceAll('=', '');
}

Uint8List _secureNonce() {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < first.length; index += 1) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
