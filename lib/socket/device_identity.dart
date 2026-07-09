import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:synchronized/synchronized.dart';
import 'package:whisper/helper/local.dart';

abstract interface class DeviceIdentitySeedStorage {
  Future<String?> readSeed();

  Future<void> writeSeed(String value);
}

final class LocalDeviceIdentitySeedStorage
    implements DeviceIdentitySeedStorage {
  LocalDeviceIdentitySeedStorage([LocalSetting? settings])
      : _settings = settings ?? LocalSetting();

  final LocalSetting _settings;

  @override
  Future<String?> readSeed() => _settings.deviceIdentitySeed();

  @override
  Future<void> writeSeed(String value) =>
      _settings.setDeviceIdentitySeed(value);
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
      : _storage = storage ?? LocalDeviceIdentitySeedStorage();

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

      final identity = await DeviceIdentity.fromSeed(seed);
      _cachedIdentity = identity;
      return identity;
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
        publicKey: SimplePublicKey(
          publicKeyBytes,
          type: KeyPairType.ed25519,
        ),
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
  return Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
}

String _encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _decodeBase64Url(String value, {required int expectedLength}) {
  if (value.isEmpty ||
      value.contains('=') ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid base64url value');
  }
  final padding = List<String>.filled(
    (4 - value.length % 4) % 4,
    '=',
  ).join();
  final Uint8List decoded;
  try {
    decoded = Uint8List.fromList(base64Url.decode('$value$padding'));
  } on FormatException {
    throw const FormatException('Invalid base64url value');
  }
  if (decoded.length != expectedLength || _encodeBase64Url(decoded) != value) {
    throw const FormatException('Invalid base64url length');
  }
  return decoded;
}
