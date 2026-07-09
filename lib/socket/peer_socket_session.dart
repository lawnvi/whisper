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
import 'package:whisper/socket/device_identity.dart';
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

  static const int protocolVersion = 5;

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
  bool _approvalResolved = false;
  bool _approvalAllowed = false;
  bool _authenticationCommitted = false;
  bool _closed = false;
  Future<void> _sendChain = Future<void>.value();

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
  bool get isAuthenticated =>
      !_closed && phase == PeerSocketPhase.authenticated;
  bool get isClosed => _closed;

  Future<Uint8List> encodeOutgoing(Uint8List payload) {
    final completer = Completer<Uint8List>();
    _sendChain = _sendChain.then((_) async {
      if (!isAuthenticated || _codec == null) {
        throw const AuthHandshakeException('session_not_authenticated');
      }
      completer.complete(await _codec!.encode(payload));
    }).catchError((Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Uint8List> decodeIncoming(Uint8List frame) {
    if (!isAuthenticated || _codec == null) {
      throw const AuthHandshakeException('session_not_authenticated');
    }
    return _codec!.decode(frame);
  }

  Future<AuthEnvelope> createHello() async {
    _require(PeerSocketRole.client, PeerSocketPhase.awaitingChallenge);
    final publicKey =
        await AuthSessionKeys.publicKeyBase64Url(_localEphemeralKeyPair);
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
      _remoteProfile = remoteProfile;
      _remoteIdentityPublicKey = hello.identityPublicKey!;
      _remoteEphemeralPublicKey = AuthSessionKeys.parseEphemeralPublicKey(
        hello.ephemeralPublicKey!,
      );
      _remoteNonce = decodeAuthBase64Url(hello.nonce, expectedLength: 32);
      _transcript = await _buildTranscript(
        clientProfile: remoteProfile,
        serverProfile: localProfile,
        clientIdentityKey: hello.identityPublicKey!,
        serverIdentityKey: localIdentity.publicKeyBase64Url,
        clientEphemeralKey: hello.ephemeralPublicKey!,
        serverEphemeralKey:
            await AuthSessionKeys.publicKeyBase64Url(_localEphemeralKeyPair),
        clientNonce: _remoteNonce!,
        serverNonce: _localNonce,
        intendedPkh: hello.intendedPublicKeyHash ?? '',
      );
      final signature = await localIdentity.sign(_transcript!.challengeBytes());
      phase = PeerSocketPhase.awaitingProof;
      return AuthEnvelope.challenge(
        protocolVersion: protocolVersion,
        peerId: localProfile.uid,
        identityPublicKey: localIdentity.publicKeyBase64Url,
        ephemeralPublicKey:
            await AuthSessionKeys.publicKeyBase64Url(_localEphemeralKeyPair),
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
      _remoteProfile = remoteProfile;
      _remoteIdentityPublicKey = challenge.identityPublicKey!;
      _remoteEphemeralPublicKey = AuthSessionKeys.parseEphemeralPublicKey(
        challenge.ephemeralPublicKey!,
      );
      _remoteNonce = decodeAuthBase64Url(challenge.nonce, expectedLength: 32);
      _transcript = await _buildTranscript(
        clientProfile: localProfile,
        serverProfile: remoteProfile,
        clientIdentityKey: localIdentity.publicKeyBase64Url,
        serverIdentityKey: challenge.identityPublicKey!,
        clientEphemeralKey:
            await AuthSessionKeys.publicKeyBase64Url(_localEphemeralKeyPair),
        serverEphemeralKey: challenge.ephemeralPublicKey!,
        clientNonce: _localNonce,
        serverNonce: _remoteNonce!,
        intendedPkh: intendedPublicKeyHash,
      );
      final valid = await verifyDeviceSignature(
        publicKeyBase64Url: challenge.identityPublicKey!,
        message: _transcript!.challengeBytes(),
        signatureBase64Url: challenge.signature!,
      );
      if (!valid) {
        _fail<void>('invalid_challenge_signature');
      }
      phase = PeerSocketPhase.awaitingLocalApproval;
    } on AuthHandshakeException {
      rethrow;
    } catch (_) {
      _fail<void>('invalid_challenge');
    }
  }

  Future<AuthEnvelope> createProof() async {
    _require(PeerSocketRole.client, PeerSocketPhase.awaitingResult);
    if (!_approvalResolved || !_approvalAllowed || _transcript == null) {
      return _fail('approval_required');
    }
    return AuthEnvelope.proof(
      protocolVersion: protocolVersion,
      peerId: localProfile.uid,
      nonce: encodeAuthBase64Url(_localNonce),
      peerNonce: encodeAuthBase64Url(_remoteNonce!),
      profileDigest: encodeAuthBase64Url(localProfile.canonicalDigest()),
      signature: await localIdentity.sign(_transcript!.proofBytes()),
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
      final valid = await verifyDeviceSignature(
        publicKeyBase64Url: remoteIdentityPublicKey,
        message: _transcript!.proofBytes(),
        signatureBase64Url: proof.signature!,
      );
      if (!valid) {
        _fail<void>('invalid_proof_signature');
      }
      phase = PeerSocketPhase.awaitingLocalApproval;
    } on AuthHandshakeException {
      rethrow;
    } catch (_) {
      _fail<void>('invalid_proof');
    }
  }

  bool resolveLocalApproval({
    required int generation,
    required bool allow,
  }) {
    if (generation != connectionGeneration ||
        phase != PeerSocketPhase.awaitingLocalApproval ||
        _approvalResolved) {
      return false;
    }
    _approvalResolved = true;
    _approvalAllowed = allow;
    if (role == PeerSocketRole.client) {
      if (allow) {
        phase = PeerSocketPhase.awaitingResult;
      } else {
        close();
      }
    }
    return true;
  }

  void Function(bool) guardApprovalCallback(void Function(bool) callback) {
    final generation = connectionGeneration;
    var delivered = false;
    return (allow) {
      if (delivered ||
          generation != connectionGeneration ||
          phase != PeerSocketPhase.awaitingLocalApproval ||
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
    if (!_approvalResolved ||
        _approvalAllowed != allow ||
        _transcript == null) {
      return _fail('approval_result_mismatch');
    }
    final result = AuthEnvelope.result(
      protocolVersion: protocolVersion,
      peerId: localProfile.uid,
      nonce: encodeAuthBase64Url(_localNonce),
      peerNonce: encodeAuthBase64Url(_remoteNonce!),
      profileDigest: encodeAuthBase64Url(localProfile.canonicalDigest()),
      signature: await localIdentity.sign(
        _transcript!.resultBytes(allow: allow, reason: reason),
      ),
      allow: allow,
      reason: reason,
    );
    _requireOpen();
    if (allow) {
      await _enableCodec();
      _requireOpen();
      phase = PeerSocketPhase.authenticated;
      _handshakeTimer.cancel();
    } else {
      close();
    }
    return result;
  }

  Future<bool> receiveResult(AuthEnvelope result) async {
    _require(PeerSocketRole.client, PeerSocketPhase.awaitingResult);
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
      final valid = await verifyDeviceSignature(
        publicKeyBase64Url: remoteIdentityPublicKey,
        message: _transcript!.resultBytes(
          allow: result.allow!,
          reason: result.reason!,
        ),
        signatureBase64Url: result.signature!,
      );
      _requireOpen();
      if (!valid) {
        return _fail('invalid_result_signature');
      }
      if (!result.allow!) {
        close();
        return false;
      }
      await _enableCodec();
      _requireOpen();
      phase = PeerSocketPhase.authenticated;
      _handshakeTimer.cancel();
      return true;
    } on AuthHandshakeException {
      rethrow;
    } catch (_) {
      return _fail('invalid_result');
    }
  }

  Future<bool> commitAuthentication({
    required int generation,
    required Future<void> Function() pinIdentity,
    required Future<void> Function() registerPeer,
  }) async {
    if (generation != connectionGeneration ||
        !isAuthenticated ||
        _authenticationCommitted) {
      return false;
    }
    _authenticationCommitted = true;
    await pinIdentity();
    if (generation != connectionGeneration || !isAuthenticated) {
      return false;
    }
    await registerPeer();
    return true;
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    phase = PeerSocketPhase.closing;
    _handshakeTimer.cancel();
  }

  Future<void> _enableCodec() async {
    final keys = await AuthSessionKeys.derive(
      localEphemeralKeyPair: _localEphemeralKeyPair,
      remoteEphemeralPublicKey: _remoteEphemeralPublicKey!,
      transcriptHash: _transcript!.transcriptHash(),
    );
    _requireOpen();
    _codec = role == PeerSocketRole.client
        ? AuthenticatedFrameCodec(
            sendKey: keys.clientToServerChat,
            receiveKey: keys.serverToClientChat,
          )
        : AuthenticatedFrameCodec(
            sendKey: keys.serverToClientChat,
            receiveKey: keys.clientToServerChat,
          );
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
    if (isClosed || role != expectedRole || phase != expectedPhase) {
      _fail<void>('unexpected_phase');
    }
  }

  void _requireOpen() {
    if (isClosed) {
      throw const AuthHandshakeException('session_closed');
    }
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
