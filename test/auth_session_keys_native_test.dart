import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart' as sodium;
import 'package:whisper/socket/auth_session_keys.dart';

import 'auth_session_keys_test.dart' as shared;

void main() {
  setUpAll(() async {
    AuthSessionKeys.installNativeAcceleration(await sodium.SodiumInit.init());
  });

  // Both backends must satisfy the same protocol vectors and reject zero keys.
  shared.main();

  test('native ephemeral pairs interoperate with Dart X25519', () async {
    final native = await AuthSessionKeys.generateEphemeralKeyPair();
    addTearDown(native.destroy);
    final bytes = await native.extractPrivateKeyBytes();
    final dart = await X25519().newKeyPairFromSeed(bytes);
    addTearDown(dart.destroy);
    expect(await native.extractPublicKey(), await dart.extractPublicKey());
    final encoded = await AuthSessionKeys.publicKeyBase64Url(native);
    expect(
      AuthSessionKeys.parseEphemeralPublicKey(encoded),
      await dart.extractPublicKey(),
    );
    native.destroy();
    await expectLater(native.extractPrivateKeyBytes(), throwsStateError);
  });
}
