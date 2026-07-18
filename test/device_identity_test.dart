import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/device_identity.dart';

const _seedA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _seedB = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE';

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

class _MemorySeedVault implements SecureIdentitySeedVault {
  _MemorySeedVault({this.seed, this.ignoreWrites = false});

  String? seed;
  final bool ignoreWrites;

  @override
  Future<String?> readSeed() async => seed;

  @override
  Future<void> writeSeed(String value) async {
    if (!ignoreWrites) {
      seed = value;
    }
  }
}

class _MemoryLegacySeedStorage implements LegacyIdentitySeedStorage {
  _MemoryLegacySeedStorage(this.seed);

  String? seed;
  int deletes = 0;

  @override
  Future<String?> readSeed() async => seed;

  @override
  Future<void> deleteSeed() async {
    deletes += 1;
    seed = null;
  }
}

void main() {
  group('SecureDeviceIdentitySeedStorage', () {
    test('migrates and verifies a legacy seed before removing plaintext',
        () async {
      final vault = _MemorySeedVault();
      final legacy = _MemoryLegacySeedStorage(_seedA);
      final storage = SecureDeviceIdentitySeedStorage(
        vault: vault,
        legacyStorage: legacy,
      );

      expect(await storage.readSeed(), _seedA);
      expect(vault.seed, _seedA);
      expect(legacy.seed, isNull);
      expect(legacy.deletes, 1);
    });

    test('never deletes the legacy seed when secure persistence fails',
        () async {
      final vault = _MemorySeedVault(ignoreWrites: true);
      final legacy = _MemoryLegacySeedStorage(_seedA);
      final storage = SecureDeviceIdentitySeedStorage(
        vault: vault,
        legacyStorage: legacy,
      );

      await expectLater(storage.readSeed(), throwsStateError);
      expect(legacy.seed, _seedA);
      expect(legacy.deletes, 0);
    });

    test('rejects conflicting secure and legacy identities', () async {
      final legacy = _MemoryLegacySeedStorage(_seedA);
      final storage = SecureDeviceIdentitySeedStorage(
        vault: _MemorySeedVault(seed: _seedB),
        legacyStorage: legacy,
      );

      await expectLater(storage.readSeed(), throwsStateError);
      expect(legacy.seed, _seedA);
      expect(legacy.deletes, 0);
    });

    test('does not migrate or delete a malformed legacy seed', () async {
      final vault = _MemorySeedVault();
      final legacy = _MemoryLegacySeedStorage('malformed');
      final storage = SecureDeviceIdentitySeedStorage(
        vault: vault,
        legacyStorage: legacy,
      );

      await expectLater(storage.readSeed(), throwsFormatException);
      expect(vault.seed, isNull);
      expect(legacy.seed, 'malformed');
      expect(legacy.deletes, 0);
    });
  });

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
