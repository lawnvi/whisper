import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:synchronized/synchronized.dart';
import 'package:whisper/helper/local.dart';

abstract interface class DeviceIdentitySeedStorage {
  Future<String?> readSeed();

  Future<void> writeSeed(String value);
}

abstract interface class LegacyIdentitySeedStorage {
  Future<String?> readSeed();

  Future<void> deleteSeed();
}

final class LocalDeviceIdentitySeedStorage
    implements DeviceIdentitySeedStorage, LegacyIdentitySeedStorage {
  LocalDeviceIdentitySeedStorage([LocalSetting? settings])
    : _settings = settings ?? LocalSetting();

  final LocalSetting _settings;

  @override
  Future<String?> readSeed() => _settings.deviceIdentitySeed();

  @override
  Future<void> writeSeed(String value) =>
      _settings.setDeviceIdentitySeed(value);

  @override
  Future<void> deleteSeed() => _settings.deleteDeviceIdentitySeed();
}

abstract interface class SecureIdentitySeedVault {
  Future<String?> readSeed();

  Future<void> writeSeed(String value);
}

final class FlutterSecureIdentitySeedVault implements SecureIdentitySeedVault {
  FlutterSecureIdentitySeedVault([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              resetOnError: false,
              migrateWithBackup: true,
              storageNamespace: 'whisper_identity',
            ),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
              // The data-protection keychain requires a provisioning profile.
              // The standard login Keychain also supports ad-hoc local builds.
              usesDataProtectionKeychain: false,
            ),
          );

  static const String _seedKey = 'device_identity_seed_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readSeed() => _storage.read(key: _seedKey);

  @override
  Future<void> writeSeed(String value) =>
      _storage.write(key: _seedKey, value: value);
}

final class SecureDeviceIdentitySeedStorage
    implements DeviceIdentitySeedStorage {
  SecureDeviceIdentitySeedStorage({
    SecureIdentitySeedVault? vault,
    LegacyIdentitySeedStorage? legacyStorage,
  }) : _vault = vault ?? FlutterSecureIdentitySeedVault(),
       _legacyStorage = legacyStorage ?? LocalDeviceIdentitySeedStorage();

  final SecureIdentitySeedVault _vault;
  final LegacyIdentitySeedStorage _legacyStorage;

  @override
  Future<String?> readSeed() async {
    final secureSeed = await _vault.readSeed();
    final legacySeed = await _legacyStorage.readSeed();
    if (secureSeed != null) {
      _requireCanonicalSeed(secureSeed);
    }
    if (legacySeed != null) {
      _requireCanonicalSeed(legacySeed);
    }
    if (secureSeed != null) {
      if (legacySeed != null && legacySeed != secureSeed) {
        throw StateError('Conflicting device identity seeds');
      }
      if (legacySeed != null) {
        await _deleteAndVerifyLegacySeed();
      }
      return secureSeed;
    }
    if (legacySeed == null) {
      return null;
    }
    await _persistAndVerify(legacySeed);
    await _deleteAndVerifyLegacySeed();
    return legacySeed;
  }

  @override
  Future<void> writeSeed(String value) {
    _requireCanonicalSeed(value);
    return _persistAndVerify(value);
  }

  Future<void> _persistAndVerify(String seed) async {
    await _vault.writeSeed(seed);
    if (await _vault.readSeed() != seed) {
      throw StateError('Device identity seed was not persisted');
    }
  }

  Future<void> _deleteAndVerifyLegacySeed() async {
    await _legacyStorage.deleteSeed();
    if (await _legacyStorage.readSeed() != null) {
      throw StateError('Legacy device identity seed was not removed');
    }
  }
}

final class DeviceIdentity {
  DeviceIdentity._(this._keyPair, Uint8List publicKeyBytes)
    : _publicKeyBytes = Uint8List.fromList(publicKeyBytes);

  final SimpleKeyPair _keyPair;
  final Uint8List _publicKeyBytes;

  String get publicKeyBase64Url => _encodeBase64Url(_publicKeyBytes);

  Uint8List get publicKeyBytes => Uint8List.fromList(_publicKeyBytes);

  static Future<DeviceIdentity> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed.length', 'must be 32');
    }
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return DeviceIdentity._(keyPair, Uint8List.fromList(publicKey.bytes));
  }

  Future<String> sign(Uint8List message) async {
    final signature = await Ed25519().sign(message, keyPair: _keyPair);
    return _encodeBase64Url(signature.bytes);
  }
}

final class DeviceIdentityStore {
  DeviceIdentityStore({DeviceIdentitySeedStorage? storage})
    : _storage = storage ?? SecureDeviceIdentitySeedStorage();

  static final Lock _creationLock = Lock();

  final DeviceIdentitySeedStorage _storage;
  DeviceIdentity? _cachedIdentity;

  Future<DeviceIdentity> loadOrCreate() async {
    final cached = _cachedIdentity;
    if (cached != null) {
      return cached;
    }

    return _creationLock.synchronized(() async {
      final cachedInsideLock = _cachedIdentity;
      if (cachedInsideLock != null) {
        return cachedInsideLock;
      }

      final stored = await _storage.readSeed();
      final Uint8List seed;
      if (stored == null) {
        seed = _randomSeed();
        await _storage.writeSeed(_encodeBase64Url(seed));
      } else {
        seed = _decodeBase64Url(stored, expectedLength: 32);
      }

      try {
        final identity = await DeviceIdentity.fromSeed(seed);
        _cachedIdentity = identity;
        return identity;
      } finally {
        seed.fillRange(0, seed.length, 0);
      }
    });
  }
}

Future<bool> verifyDeviceSignature({
  required String publicKeyBase64Url,
  required Uint8List message,
  required String signatureBase64Url,
}) async {
  try {
    final publicKeyBytes = _decodeBase64Url(
      publicKeyBase64Url,
      expectedLength: 32,
    );
    final signatureBytes = _decodeBase64Url(
      signatureBase64Url,
      expectedLength: 64,
    );
    return Ed25519().verify(
      message,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  } on StateError {
    return false;
  }
}

Uint8List _randomSeed() {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
}

void _requireCanonicalSeed(String value) {
  final decoded = _decodeBase64Url(value, expectedLength: 32);
  decoded.fillRange(0, decoded.length, 0);
}

String _encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _decodeBase64Url(String value, {required int expectedLength}) {
  if (value.isEmpty ||
      value.contains('=') ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid base64url value');
  }
  final padding = List<String>.filled((4 - value.length % 4) % 4, '=').join();
  final Uint8List decoded;
  try {
    decoded = Uint8List.fromList(base64Url.decode('$value$padding'));
  } on FormatException {
    throw const FormatException('Invalid base64url value');
  }
  if (decoded.length != expectedLength || _encodeBase64Url(decoded) != value) {
    decoded.fillRange(0, decoded.length, 0);
    throw const FormatException('Invalid base64url length');
  }
  return decoded;
}
