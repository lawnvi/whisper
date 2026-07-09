import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/device_identity.dart';

class _MemorySeedStorage implements DeviceIdentitySeedStorage {
  String? seed;
  int writes = 0;

  @override
  Future<String?> readSeed() async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return seed;
  }

  @override
  Future<void> writeSeed(String value) async {
    writes += 1;
    seed = value;
  }
}

void main() {
  group('DeviceIdentityStore', () {
    test('concurrent loadOrCreate calls persist exactly one identity',
        () async {
      final storage = _MemorySeedStorage();
      final stores = List<DeviceIdentityStore>.generate(
        8,
        (_) => DeviceIdentityStore(storage: storage),
      );

      final identities = await Future.wait(
        stores.map((store) => store.loadOrCreate()),
      );

      expect(storage.writes, 1);
      expect(
        identities.map((identity) => identity.publicKeyBase64Url).toSet(),
        hasLength(1),
      );

      final reloaded =
          await DeviceIdentityStore(storage: storage).loadOrCreate();
      expect(reloaded.publicKeyBase64Url, identities.first.publicKeyBase64Url);
      expect(storage.writes, 1);
    });
  });

  group('DeviceIdentity', () {
    test('signatures verify only for the exact key and transcript', () async {
      final identity = await DeviceIdentity.fromSeed(
        Uint8List.fromList(List<int>.generate(32, (index) => index)),
      );
      final otherIdentity = await DeviceIdentity.fromSeed(
        Uint8List.fromList(List<int>.generate(32, (index) => index + 32)),
      );
      final transcript = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final signature = await identity.sign(transcript);

      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: identity.publicKeyBase64Url,
          message: transcript,
          signatureBase64Url: signature,
        ),
        isTrue,
      );
      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: otherIdentity.publicKeyBase64Url,
          message: transcript,
          signatureBase64Url: signature,
        ),
        isFalse,
      );
      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: identity.publicKeyBase64Url,
          message: Uint8List.fromList(<int>[1, 2, 3, 5]),
          signatureBase64Url: signature,
        ),
        isFalse,
      );
    });

    test('rejects malformed public keys and signatures', () async {
      expect(
        await verifyDeviceSignature(
          publicKeyBase64Url: 'not-base64!',
          message: Uint8List(0),
          signatureBase64Url: 'also-not-base64!',
        ),
        isFalse,
      );
    });
  });
}
