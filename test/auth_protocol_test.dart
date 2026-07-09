import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/auth_transcript.dart';
import 'package:whisper/socket/device_identity.dart';

String _b64(int length, int start) => base64Url
    .encode(List<int>.generate(length, (index) => (start + index) & 0xff))
    .replaceAll('=', '');

AuthTranscript _transcript() {
  return AuthTranscript(
    protocolVersion: 5,
    clientPeerId: 'client-a',
    serverPeerId: 'server-b',
    clientIdentityPublicKey:
        Uint8List.fromList(List<int>.generate(32, (index) => index)),
    serverIdentityPublicKey:
        Uint8List.fromList(List<int>.generate(32, (index) => index + 32)),
    clientEphemeralPublicKey:
        Uint8List.fromList(List<int>.generate(32, (index) => index + 64)),
    serverEphemeralPublicKey:
        Uint8List.fromList(List<int>.generate(32, (index) => index + 96)),
    intendedPublicKeyHash: 'discover-pkh',
    clientNonce:
        Uint8List.fromList(List<int>.generate(32, (index) => index + 128)),
    serverNonce:
        Uint8List.fromList(List<int>.generate(32, (index) => index + 160)),
    clientProfileDigest:
        Uint8List.fromList(List<int>.generate(32, (index) => index + 192)),
    serverProfileDigest: Uint8List.fromList(
      List<int>.generate(32, (index) => (index + 224) & 0xff),
    ),
  );
}

void main() {
  group('AuthTranscript', () {
    test('uses separate domains for challenge, proof, and result', () {
      final transcript = _transcript();

      expect(transcript.challengeBytes(), isNot(transcript.proofBytes()));
      expect(
        transcript.proofBytes(),
        isNot(transcript.resultBytes(allow: true, reason: 'approved')),
      );
      expect(
        transcript.resultBytes(allow: true, reason: 'approved'),
        isNot(transcript.resultBytes(allow: false, reason: 'rejected')),
      );
    });

    test('a signature for one auth stage cannot verify another stage',
        () async {
      final transcript = _transcript();
      final identity = await DeviceIdentity.fromSeed(Uint8List(32));
      final signature = await identity.sign(transcript.challengeBytes());

      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: identity.publicKeyBase64Url,
          message: transcript.challengeBytes(),
          signatureBase64Url: signature,
        ),
        isTrue,
      );
      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: identity.publicKeyBase64Url,
          message: transcript.proofBytes(),
          signatureBase64Url: signature,
        ),
        isFalse,
      );
      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: identity.publicKeyBase64Url,
          message: transcript.resultBytes(allow: true, reason: 'approved'),
          signatureBase64Url: signature,
        ),
        isFalse,
      );
    });

    test('pairing code has a stable six-digit golden value', () {
      expect(_transcript().pairingCode(), '028218');
    });

    test('both peers get the same pairing code from the canonical transcript',
        () {
      final first = _transcript();
      final second = AuthTranscript(
        protocolVersion: first.protocolVersion,
        clientPeerId: first.clientPeerId,
        serverPeerId: first.serverPeerId,
        clientIdentityPublicKey: first.clientIdentityPublicKey,
        serverIdentityPublicKey: first.serverIdentityPublicKey,
        clientEphemeralPublicKey: first.clientEphemeralPublicKey,
        serverEphemeralPublicKey: first.serverEphemeralPublicKey,
        intendedPublicKeyHash: first.intendedPublicKeyHash,
        clientNonce: first.clientNonce,
        serverNonce: first.serverNonce,
        clientProfileDigest: first.clientProfileDigest,
        serverProfileDigest: first.serverProfileDigest,
      );

      expect(first.pairingCode(), second.pairingCode());
      expect(
        first.transcriptHash(),
        orderedEquals(second.transcriptHash()),
      );
    });

    test('changing either signed profile changes proof and transcript hash',
        () {
      final original = _transcript();
      final changedClient = AuthTranscript(
        protocolVersion: original.protocolVersion,
        clientPeerId: original.clientPeerId,
        serverPeerId: original.serverPeerId,
        clientIdentityPublicKey: original.clientIdentityPublicKey,
        serverIdentityPublicKey: original.serverIdentityPublicKey,
        clientEphemeralPublicKey: original.clientEphemeralPublicKey,
        serverEphemeralPublicKey: original.serverEphemeralPublicKey,
        intendedPublicKeyHash: original.intendedPublicKeyHash,
        clientNonce: original.clientNonce,
        serverNonce: original.serverNonce,
        clientProfileDigest: Uint8List(32),
        serverProfileDigest: original.serverProfileDigest,
      );
      final changedServer = AuthTranscript(
        protocolVersion: original.protocolVersion,
        clientPeerId: original.clientPeerId,
        serverPeerId: original.serverPeerId,
        clientIdentityPublicKey: original.clientIdentityPublicKey,
        serverIdentityPublicKey: original.serverIdentityPublicKey,
        clientEphemeralPublicKey: original.clientEphemeralPublicKey,
        serverEphemeralPublicKey: original.serverEphemeralPublicKey,
        intendedPublicKeyHash: original.intendedPublicKeyHash,
        clientNonce: original.clientNonce,
        serverNonce: original.serverNonce,
        clientProfileDigest: original.clientProfileDigest,
        serverProfileDigest: Uint8List(32),
      );

      expect(
        changedClient.proofBytes(),
        isNot(orderedEquals(original.proofBytes())),
      );
      expect(
        changedServer.proofBytes(),
        isNot(orderedEquals(original.proofBytes())),
      );
      expect(
        changedClient.transcriptHash(),
        isNot(orderedEquals(original.transcriptHash())),
      );
      expect(
        changedServer.transcriptHash(),
        isNot(orderedEquals(original.transcriptHash())),
      );
    });

    test('does not expose mutable canonical transcript bytes', () {
      final transcript = _transcript();
      final originalHash = transcript.transcriptHash();

      transcript.clientNonce[0] ^= 0xff;
      transcript.serverProfileDigest[0] ^= 0xff;

      expect(transcript.transcriptHash(), orderedEquals(originalHash));
    });
  });

  group('AuthEnvelope', () {
    test('round-trips every auth action with canonical base64url fields', () {
      final hello = AuthEnvelope.hello(
        protocolVersion: 5,
        peerId: 'client-a',
        identityPublicKey: _b64(32, 0),
        ephemeralPublicKey: _b64(32, 32),
        nonce: _b64(32, 64),
        profileDigest: _b64(32, 96),
        intendedPeerId: 'server-b',
        intendedPublicKeyHash: 'pkh',
      );
      final challenge = AuthEnvelope.challenge(
        protocolVersion: 5,
        peerId: 'server-b',
        identityPublicKey: _b64(32, 1),
        ephemeralPublicKey: _b64(32, 33),
        nonce: _b64(32, 65),
        peerNonce: _b64(32, 64),
        profileDigest: _b64(32, 97),
        signature: _b64(64, 2),
      );
      final proof = AuthEnvelope.proof(
        protocolVersion: 5,
        peerId: 'client-a',
        nonce: _b64(32, 64),
        peerNonce: _b64(32, 65),
        profileDigest: _b64(32, 96),
        signature: _b64(64, 3),
      );
      final result = AuthEnvelope.result(
        protocolVersion: 5,
        peerId: 'server-b',
        nonce: _b64(32, 65),
        peerNonce: _b64(32, 64),
        profileDigest: _b64(32, 97),
        signature: _b64(64, 4),
        allow: true,
        reason: 'approved',
      );

      for (final envelope in <AuthEnvelope>[
        hello,
        challenge,
        proof,
        result,
      ]) {
        expect(AuthEnvelope.fromJson(envelope.toJson()), envelope);
        expect(
          AuthEnvelope.fromJsonString(envelope.toJsonString()),
          envelope,
        );
      }
    });

    test('rejects unknown actions, missing fields, and unexpected fields', () {
      final valid = AuthEnvelope.hello(
        protocolVersion: 5,
        peerId: 'client-a',
        identityPublicKey: _b64(32, 0),
        ephemeralPublicKey: _b64(32, 32),
        nonce: _b64(32, 64),
        profileDigest: _b64(32, 96),
        intendedPublicKeyHash: 'pkh',
      ).toJson();

      expect(
        () => AuthEnvelope.fromJson(<String, Object?>{
          ...valid,
          'action': 'unknown',
        }),
        throwsFormatException,
      );
      final missing = Map<String, Object?>.from(valid)..remove('nonce');
      expect(() => AuthEnvelope.fromJson(missing), throwsFormatException);
      expect(
        () => AuthEnvelope.fromJson(<String, Object?>{
          ...valid,
          'password': 'must-not-cross-the-wire',
        }),
        throwsFormatException,
      );
    });

    test('rejects non-canonical base64 and incorrect binary lengths', () {
      final valid = AuthEnvelope.hello(
        protocolVersion: 5,
        peerId: 'client-a',
        identityPublicKey: _b64(32, 0),
        ephemeralPublicKey: _b64(32, 32),
        nonce: _b64(32, 64),
        profileDigest: _b64(32, 96),
        intendedPublicKeyHash: 'pkh',
      ).toJson();

      expect(
        () => AuthEnvelope.fromJson(<String, Object?>{
          ...valid,
          'nonce': _b64(31, 0),
        }),
        throwsFormatException,
      );
      expect(
        () => AuthEnvelope.fromJson(<String, Object?>{
          ...valid,
          'identityKey': '${_b64(32, 0)}=',
        }),
        throwsFormatException,
      );
      expect(
        () => AuthEnvelope.fromJson(<String, Object?>{
          ...valid,
          'ephemeralKey': 'not/base64',
        }),
        throwsFormatException,
      );
      expect(
        () => AuthEnvelope.fromJsonString(jsonEncode(<String, Object?>{
          ...valid,
          'version': 0,
        })),
        throwsFormatException,
      );
    });
  });
}
