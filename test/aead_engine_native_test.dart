import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart' as sodium;
import 'package:whisper/socket/aead_engine.dart';

void main() {
  test(
    'native backend matches the Dart XChaCha20-Poly1305 wire format',
    () async {
      final keyBytes = Uint8List.fromList(
        List<int>.generate(32, (index) => index),
      );
      final nonce = Uint8List.fromList(
        List<int>.generate(24, (index) => 23 - index),
      );
      final message = Uint8List.fromList(<int>[1, 3, 3, 7, 9, 11]);
      final additionalData = Uint8List.fromList(<int>[4, 2, 4, 2]);
      final referenceKey = SecretKeyData(
        Uint8List.fromList(keyBytes),
        overwriteWhenDestroyed: true,
      );
      final reference = Xchacha20.poly1305Aead().toSync().encryptSync(
        message,
        secretKey: referenceKey,
        nonce: nonce,
        aad: additionalData,
      );

      WhisperAead.installNativeAcceleration(await sodium.SodiumInit.init());
      final nativeKey = WhisperAead.takeKey(keyBytes);
      expect(keyBytes, everyElement(0));
      final cipherText = Uint8List(message.length);
      final mac = Uint8List(16);
      nativeKey.encryptInto(
        message: message,
        cipherText: cipherText,
        mac: mac,
        nonce: nonce,
        additionalData: additionalData,
      );

      expect(cipherText, orderedEquals(reference.cipherText));
      expect(mac, orderedEquals(reference.mac.bytes));
      expect(
        nativeKey.decrypt(
          cipherText: cipherText,
          mac: mac,
          nonce: nonce,
          additionalData: additionalData,
        ),
        orderedEquals(message),
      );

      nativeKey.destroy();
      referenceKey.destroy();
    },
  );
}
