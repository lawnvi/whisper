import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final class AuthTranscript {
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
    required Uint8List clientNonce,
    required Uint8List serverNonce,
    required Uint8List clientProfileDigest,
    required Uint8List serverProfileDigest,
  })  : _clientIdentityPublicKey = _copyFixed(
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
        _clientNonce = _copyFixed(clientNonce, 'clientNonce'),
        _serverNonce = _copyFixed(serverNonce, 'serverNonce'),
        _clientProfileDigest =
            _copyFixed(clientProfileDigest, 'clientProfileDigest'),
        _serverProfileDigest =
            _copyFixed(serverProfileDigest, 'serverProfileDigest') {
    if (protocolVersion <= 0 || protocolVersion > 0xffffffff) {
      throw ArgumentError.value(protocolVersion, 'protocolVersion');
    }
    if (clientPeerId.isEmpty || serverPeerId.isEmpty) {
      throw ArgumentError('Peer ids must not be empty');
    }
  }

  final int protocolVersion;
  final String clientPeerId;
  final String serverPeerId;
  final Uint8List _clientIdentityPublicKey;
  final Uint8List _serverIdentityPublicKey;
  final Uint8List _clientEphemeralPublicKey;
  final Uint8List _serverEphemeralPublicKey;
  final String intendedPublicKeyHash;
  final bool serverPairingRequired;
  final Uint8List _clientNonce;
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
  Uint8List get clientNonce => Uint8List.fromList(_clientNonce);
  Uint8List get serverNonce => Uint8List.fromList(_serverNonce);
  Uint8List get clientProfileDigest => Uint8List.fromList(_clientProfileDigest);
  Uint8List get serverProfileDigest => Uint8List.fromList(_serverProfileDigest);

  Uint8List challengeBytes() => _canonical('challenge');

  Uint8List proofBytes({String reason = 'approved'}) => _canonical(
        'proof',
        extraFields: <List<int>>[utf8.encode(reason)],
      );

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

  Uint8List transcriptHash() => Uint8List.fromList(
        sha256.convert(_canonical('transcript')).bytes,
      );

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
      _clientNonce,
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
}

Uint8List _copyFixed(Uint8List value, String name) {
  if (value.length != 32) {
    throw ArgumentError.value(value.length, '$name.length', 'must be 32');
  }
  return Uint8List.fromList(value);
}
