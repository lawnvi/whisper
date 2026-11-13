import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/state/peer_profile.dart';

/// From this protocol version the client's hello carries only a commitment to
/// its nonce, and the nonce itself comes in the proof, after the server has
/// signed its own nonce and keys. Neither side can then steer the pairing
/// code once it sees the other's values. Before it, a server in the middle
/// saw the client's nonce and could try server nonces until the code matched.
const int nonceCommitmentProtocolVersion = 15;

bool usesNonceCommitment(int protocolVersion) =>
    protocolVersion >= nonceCommitmentProtocolVersion;

/// SHA-256 over a fixed tag and the 32-byte client nonce.
Uint8List commitClientNonce(Uint8List nonce) {
  if (nonce.length != 32) {
    throw ArgumentError.value(nonce.length, 'nonce.length', 'must be 32');
  }
  return Uint8List.fromList(
    sha256.convert(<int>[..._commitmentTag, ...nonce]).bytes,
  );
}

final List<int> _commitmentTag = utf8.encode(
  'whisper-auth-v15/client-nonce-commitment',
);

final class AuthTranscript {
  /// From [nonceCommitmentProtocolVersion] on, [clientNonceCommitment] is
  /// required and [clientNonce] may be missing until the client reveals it;
  /// before it, [clientNonce] is required and there is no commitment.
  AuthTranscript({
    required this.protocolVersion,
    required this.clientPeerId,
    required this.serverPeerId,
    required Uint8List clientIdentityPublicKey,
    required Uint8List serverIdentityPublicKey,
    required Uint8List clientEphemeralPublicKey,
    required Uint8List serverEphemeralPublicKey,
    required this.intendedPublicKeyHash,
    this.serverPairingRequired = false,
    Uint8List? clientNonce,
    Uint8List? clientNonceCommitment,
    required Uint8List serverNonce,
    required Uint8List clientProfileDigest,
    required Uint8List serverProfileDigest,
  }) : _clientIdentityPublicKey = _copyFixed(
         clientIdentityPublicKey,
         'clientIdentityPublicKey',
       ),
       _serverIdentityPublicKey = _copyFixed(
         serverIdentityPublicKey,
         'serverIdentityPublicKey',
       ),
       _clientEphemeralPublicKey = _copyFixed(
         clientEphemeralPublicKey,
         'clientEphemeralPublicKey',
       ),
       _serverEphemeralPublicKey = _copyFixed(
         serverEphemeralPublicKey,
         'serverEphemeralPublicKey',
       ),
       _clientNonce = clientNonce == null
           ? null
           : _copyFixed(clientNonce, 'clientNonce'),
       _clientNonceCommitment = clientNonceCommitment == null
           ? null
           : _copyFixed(clientNonceCommitment, 'clientNonceCommitment'),
       _serverNonce = _copyFixed(serverNonce, 'serverNonce'),
       _clientProfileDigest = _copyFixed(
         clientProfileDigest,
         'clientProfileDigest',
       ),
       _serverProfileDigest = _copyFixed(
         serverProfileDigest,
         'serverProfileDigest',
       ) {
    if (protocolVersion <= 0 || protocolVersion > 0xffffffff) {
      throw ArgumentError.value(protocolVersion, 'protocolVersion');
    }
    if (clientPeerId.isEmpty || serverPeerId.isEmpty) {
      throw ArgumentError('Peer ids must not be empty');
    }
    final commitment = _clientNonceCommitment;
    final nonce = _clientNonce;
    if (usesNonceCommitment(protocolVersion) != (commitment != null)) {
      throw ArgumentError('Nonce commitment does not match protocol version');
    }
    if (commitment == null && nonce == null) {
      throw ArgumentError('Missing the client nonce');
    }
    if (commitment != null &&
        nonce != null &&
        !_sameBytes(commitClientNonce(nonce), commitment)) {
      throw ArgumentError('Client nonce does not match its commitment');
    }
  }

  /// Decodes the base64url wire values of a hello and its challenge.
  factory AuthTranscript.fromWire({
    required int protocolVersion,
    required WirePeerProfile clientProfile,
    required WirePeerProfile serverProfile,
    required String clientIdentityKey,
    required String serverIdentityKey,
    required String clientEphemeralKey,
    required String serverEphemeralKey,
    Uint8List? clientNonce,
    Uint8List? clientNonceCommitment,
    required Uint8List serverNonce,
    required String intendedPkh,
    required bool serverPairingRequired,
  }) => AuthTranscript(
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
    serverPairingRequired: serverPairingRequired,
    clientNonce: clientNonce,
    clientNonceCommitment: clientNonceCommitment,
    serverNonce: serverNonce,
    clientProfileDigest: clientProfile.canonicalDigest(),
    serverProfileDigest: serverProfile.canonicalDigest(),
  );

  final int protocolVersion;
  final String clientPeerId;
  final String serverPeerId;
  final Uint8List _clientIdentityPublicKey;
  final Uint8List _serverIdentityPublicKey;
  final Uint8List _clientEphemeralPublicKey;
  final Uint8List _serverEphemeralPublicKey;
  final String intendedPublicKeyHash;
  final bool serverPairingRequired;
  final Uint8List? _clientNonce;
  final Uint8List? _clientNonceCommitment;
  final Uint8List _serverNonce;
  final Uint8List _clientProfileDigest;
  final Uint8List _serverProfileDigest;

  Uint8List get clientIdentityPublicKey =>
      Uint8List.fromList(_clientIdentityPublicKey);
  Uint8List get serverIdentityPublicKey =>
      Uint8List.fromList(_serverIdentityPublicKey);
  Uint8List get clientEphemeralPublicKey =>
      Uint8List.fromList(_clientEphemeralPublicKey);
  Uint8List get serverEphemeralPublicKey =>
      Uint8List.fromList(_serverEphemeralPublicKey);
  Uint8List? get clientNonce =>
      _clientNonce == null ? null : Uint8List.fromList(_clientNonce);
  Uint8List? get clientNonceCommitment => _clientNonceCommitment == null
      ? null
      : Uint8List.fromList(_clientNonceCommitment);
  Uint8List get serverNonce => Uint8List.fromList(_serverNonce);
  Uint8List get clientProfileDigest => Uint8List.fromList(_clientProfileDigest);
  Uint8List get serverProfileDigest => Uint8List.fromList(_serverProfileDigest);

  /// False on the server between a committed hello and the client's proof.
  /// Only [challengeBytes] can be computed then.
  bool get hasClientNonce => _clientNonce != null;

  /// This transcript with the client's nonce from its proof, or null when it
  /// is not the nonce the hello committed to (or carried, before commitments).
  AuthTranscript? revealClientNonce(Uint8List nonce) {
    final known = _clientNonce;
    if (known != null) {
      return _sameBytes(known, nonce) ? this : null;
    }
    if (nonce.length != 32 ||
        !_sameBytes(commitClientNonce(nonce), _clientNonceCommitment!)) {
      return null;
    }
    return AuthTranscript(
      protocolVersion: protocolVersion,
      clientPeerId: clientPeerId,
      serverPeerId: serverPeerId,
      clientIdentityPublicKey: _clientIdentityPublicKey,
      serverIdentityPublicKey: _serverIdentityPublicKey,
      clientEphemeralPublicKey: _clientEphemeralPublicKey,
      serverEphemeralPublicKey: _serverEphemeralPublicKey,
      intendedPublicKeyHash: intendedPublicKeyHash,
      serverPairingRequired: serverPairingRequired,
      clientNonce: nonce,
      clientNonceCommitment: _clientNonceCommitment,
      serverNonce: _serverNonce,
      clientProfileDigest: _clientProfileDigest,
      serverProfileDigest: _serverProfileDigest,
    );
  }

  /// Signed by the server before it may know the client's nonce, so from
  /// [nonceCommitmentProtocolVersion] on it covers only the commitment.
  Uint8List challengeBytes() => _canonical('challenge');

  Uint8List proofBytes({String reason = 'approved'}) =>
      _canonical('proof', extraFields: <List<int>>[utf8.encode(reason)]);

  Uint8List approvalBytes({required bool allow, required String reason}) =>
      _canonical(
        'approval',
        extraFields: <List<int>>[
          <int>[allow ? 1 : 0],
          utf8.encode(reason),
        ],
      );

  Uint8List resultBytes({required bool allow, required String reason}) =>
      _canonical(
        'result',
        extraFields: <List<int>>[
          <int>[allow ? 1 : 0],
          utf8.encode(reason),
        ],
      );

  Uint8List transcriptHash() =>
      Uint8List.fromList(sha256.convert(_canonical('transcript')).bytes);

  String pairingCode() {
    final digest = sha256.convert(_canonical('pairing')).bytes;
    var modulo = 0;
    for (final byte in digest) {
      modulo = ((modulo * 256) + byte) % 1000000;
    }
    return modulo.toString().padLeft(6, '0');
  }

  Uint8List _canonical(
    String stage, {
    List<List<int>> extraFields = const <List<int>>[],
  }) {
    final version = ByteData(4)..setUint32(0, protocolVersion);
    final fields = <List<int>>[
      utf8.encode('whisper-auth-v1/$stage'),
      version.buffer.asUint8List(),
      utf8.encode(clientPeerId),
      utf8.encode(serverPeerId),
      _clientIdentityPublicKey,
      _serverIdentityPublicKey,
      _clientEphemeralPublicKey,
      _serverEphemeralPublicKey,
      utf8.encode(intendedPublicKeyHash),
      <int>[serverPairingRequired ? 1 : 0],
      ..._clientNonceFields(stage),
      _serverNonce,
      _clientProfileDigest,
      _serverProfileDigest,
      ...extraFields,
    ];
    final builder = BytesBuilder(copy: false);
    for (final field in fields) {
      final length = ByteData(4)..setUint32(0, field.length);
      builder
        ..add(length.buffer.asUint8List())
        ..add(field);
    }
    return builder.takeBytes();
  }

  /// Before commitments: the nonce, as it always was. From then on: the
  /// commitment, then the nonce, which stays empty in the challenge.
  List<List<int>> _clientNonceFields(String stage) {
    final commitment = _clientNonceCommitment;
    if (commitment == null) {
      return <List<int>>[_clientNonce!];
    }
    if (stage == 'challenge') {
      return <List<int>>[commitment, const <int>[]];
    }
    final nonce = _clientNonce;
    if (nonce == null) {
      throw StateError('The client has not revealed its nonce yet');
    }
    return <List<int>>[commitment, nonce];
  }
}

Uint8List _copyFixed(Uint8List value, String name) {
  if (value.length != 32) {
    throw ArgumentError.value(value.length, '$name.length', 'must be 32');
  }
  return Uint8List.fromList(value);
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
