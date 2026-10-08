import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart' as sodium;
import 'package:whisper/socket/device_identity.dart';

Uint8List _hex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void main() {
  setUpAll(() async {
    DeviceIdentity.installNativeAcceleration(await sodium.SodiumInit.init());
  });

  test('native identity matches RFC 8032 Ed25519 test vector 1', () async {
    final identity = await DeviceIdentity.fromSeed(
      _hex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'),
    );
    final publicKey = _hex(
      'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    );
    final signature = _hex(
      'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
      '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
    );
    expect(identity.publicKeyBytes, publicKey);
    expect(await identity.sign(Uint8List(0)), _encode(signature));
    expect(
      await verifyDeviceSignature(
        publicKeyBase64Url: _encode(publicKey),
        message: Uint8List(0),
        signatureBase64Url: _encode(signature),
      ),
      isTrue,
    );
  });

  test(
    'native signatures interoperate with Dart and reject altered messages',
    () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => i));
      final identity = await DeviceIdentity.fromSeed(seed);
      final dartPair = await Ed25519().newKeyPairFromSeed(seed);
      addTearDown(dartPair.destroy);
      final message = Uint8List.fromList(List.generate(512, (i) => i & 255));
      final dartSignature = await Ed25519().sign(message, keyPair: dartPair);
      final nativeSignature = await identity.sign(message);
      expect(nativeSignature, _encode(dartSignature.bytes));
      expect(
        await Ed25519().verify(
          message,
          signature: Signature(
            base64Url.decode(base64Url.normalize(nativeSignature)),
            publicKey: await dartPair.extractPublicKey(),
          ),
        ),
        isTrue,
      );
      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: identity.publicKeyBase64Url,
          message: message,
          signatureBase64Url: _encode(dartSignature.bytes),
        ),
        isTrue,
      );
      message[0] ^= 1;
      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: identity.publicKeyBase64Url,
          message: message,
          signatureBase64Url: nativeSignature,
        ),
        isFalse,
      );
    },
  );
}
