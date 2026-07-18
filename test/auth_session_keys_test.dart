import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/auth_session_keys.dart';

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('X25519 peers derive the same directional chat and media keys',
      () async {
    final algorithm = X25519();
    final clientPair = await algorithm.newKeyPairFromSeed(
      List<int>.generate(32, (index) => index),
    );
    final serverPair = await algorithm.newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 32),
    );
    final clientPublicKey = await clientPair.extractPublicKey();
    final serverPublicKey = await serverPair.extractPublicKey();
    final transcriptHash =
        Uint8List.fromList(List<int>.generate(32, (index) => 255 - index));

    final clientKeys = await AuthSessionKeys.derive(
      localEphemeralKeyPair: clientPair,
      remoteEphemeralPublicKey: serverPublicKey,
      transcriptHash: transcriptHash,
    );
    final serverKeys = await AuthSessionKeys.derive(
      localEphemeralKeyPair: serverPair,
      remoteEphemeralPublicKey: clientPublicKey,
      transcriptHash: transcriptHash,
    );

    expect(
      await clientKeys.clientToServerChat.extractBytes(),
      orderedEquals(await serverKeys.clientToServerChat.extractBytes()),
    );
    expect(
      await clientKeys.serverToClientChat.extractBytes(),
      orderedEquals(await serverKeys.serverToClientChat.extractBytes()),
    );
    expect(
      await clientKeys.clientToServerMedia.extractBytes(),
      orderedEquals(await serverKeys.clientToServerMedia.extractBytes()),
    );
    expect(
      await clientKeys.serverToClientMedia.extractBytes(),
      orderedEquals(await serverKeys.serverToClientMedia.extractBytes()),
    );
    expect(
      await clientKeys.clientToServerChat.extractBytes(),
      isNot(orderedEquals(
        await clientKeys.serverToClientChat.extractBytes(),
      )),
    );
    expect(
      await clientKeys.clientToServerChat.extractBytes(),
      isNot(orderedEquals(
        await clientKeys.clientToServerMedia.extractBytes(),
      )),
    );
    expect(
      _hex(await clientKeys.clientToServerChat.extractBytes()),
      '03b5318b37f7e8e24f08f74e7cbe61e18cb228936aa906401aa0ce27533e7044',
    );
    expect(
      _hex(await clientKeys.serverToClientChat.extractBytes()),
      '0d3c9797e5c48eff94b42cd3b1cdbd24597278dd4d5a77f755cd66f1b3c3e62c',
    );
    expect(
      _hex(await clientKeys.clientToServerMedia.extractBytes()),
      'ee11d31efde0e8b261ccffd2bd724bb2b38945cb9b65bcc90e2021993b804894',
    );
    expect(
      _hex(await clientKeys.serverToClientMedia.extractBytes()),
      '9301f6e2a47d1bcc1b9dfd398a404461868f84eea2e45881afe00c0de5859b9e',
    );
  });

  test('the complete transcript hash is part of key derivation', () async {
    final algorithm = X25519();
    final first = await algorithm.newKeyPairFromSeed(List<int>.filled(32, 1));
    final second = await algorithm.newKeyPairFromSeed(List<int>.filled(32, 2));
    final secondPublicKey = await second.extractPublicKey();

    final keysA = await AuthSessionKeys.derive(
      localEphemeralKeyPair: first,
      remoteEphemeralPublicKey: secondPublicKey,
      transcriptHash: Uint8List(32),
    );
    final keysB = await AuthSessionKeys.derive(
      localEphemeralKeyPair: first,
      remoteEphemeralPublicKey: secondPublicKey,
      transcriptHash: Uint8List.fromList(<int>[1, ...List<int>.filled(31, 0)]),
    );

    expect(
      await keysA.clientToServerChat.extractBytes(),
      isNot(orderedEquals(
        await keysB.clientToServerChat.extractBytes(),
      )),
    );
  });

  test('rejects an all-zero X25519 shared secret', () async {
    final localPair = await X25519().newKeyPairFromSeed(
      List<int>.filled(32, 7),
    );
    final allZeroPublicKey = SimplePublicKey(
      List<int>.filled(32, 0),
      type: KeyPairType.x25519,
    );

    await expectLater(
      AuthSessionKeys.derive(
        localEphemeralKeyPair: localPair,
        remoteEphemeralPublicKey: allZeroPublicKey,
        transcriptHash: Uint8List(32),
      ),
      throwsFormatException,
    );
  });
}
