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
      'a03d79e7b4a5168e2035c5cb3cc021d03ec5be96324e3b9aece0a349b0a3a1c2',
    );
    expect(
      _hex(await clientKeys.serverToClientChat.extractBytes()),
      '175d25ac0784a1807f8df5b8126b9b4dcdd66016ab2ed205807a52669becdf48',
    );
    expect(
      _hex(await clientKeys.clientToServerMedia.extractBytes()),
      'cddd2697cc102f16494e714c3a9118c12779bf09f7d09f4b5dbb375269d1d819',
    );
    expect(
      _hex(await clientKeys.serverToClientMedia.extractBytes()),
      '759b5e9cdbdce50ea870d170be93978f43805c3e864557402798528c7a7811c5',
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
}
