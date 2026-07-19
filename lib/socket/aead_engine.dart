import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sodium/sodium.dart' as sodium;

final class WhisperAeadAuthenticationException implements Exception {
  const WhisperAeadAuthenticationException();
}

final class WhisperAeadResult {
  const WhisperAeadResult({
    required this.cipherText,
    required this.mac,
  });

  final Uint8List cipherText;
  final Uint8List mac;
}

/// Installs the native XChaCha20-Poly1305 backend used by production builds.
/// Tests can omit initialization and exercise the wire-compatible Dart backend.
abstract final class WhisperAead {
  static sodium.Sodium? _sodium;

  static bool get nativeAccelerationEnabled => _sodium != null;

  static void installNativeAcceleration(sodium.Sodium instance) {
    final current = _sodium;
    if (current != null && !identical(current, instance)) {
      throw StateError('native AEAD acceleration is already initialized');
    }
    _sodium = instance;
  }

  /// Takes ownership of [keyBytes]. The bytes are either moved into the Dart
  /// key container or copied to locked native memory and immediately cleared.
  static WhisperAeadKey takeKey(Uint8List keyBytes) {
    if (keyBytes.length != 32) {
      keyBytes.fillRange(0, keyBytes.length, 0);
      throw ArgumentError.value(keyBytes.length, 'keyBytes.length');
    }
    final sodium = _sodium;
    if (sodium == null) {
      return _DartWhisperAeadKey(
        SecretKeyData(keyBytes, overwriteWhenDestroyed: true),
      );
    }
    try {
      return _NativeWhisperAeadKey(
        sodium,
        sodium.secureCopy(keyBytes),
      );
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
  }
}

abstract interface class WhisperAeadKey {
  bool get isDestroyed;

  WhisperAeadResult encrypt({
    required Uint8List message,
    required Uint8List nonce,
    required Uint8List additionalData,
  });

  Uint8List decrypt({
    required Uint8List cipherText,
    required Uint8List mac,
    required Uint8List nonce,
    required Uint8List additionalData,
  });

  void destroy();
}

final class _NativeWhisperAeadKey implements WhisperAeadKey {
  _NativeWhisperAeadKey(this._sodium, this._key);

  final sodium.Sodium _sodium;
  sodium.SecureKey? _key;

  @override
  bool get isDestroyed => _key == null;

  @override
  WhisperAeadResult encrypt({
    required Uint8List message,
    required Uint8List nonce,
    required Uint8List additionalData,
  }) {
    final key = _requireKey();
    final result = _sodium.crypto.aeadXChaCha20Poly1305IETF.encryptDetached(
      message: message,
      nonce: nonce,
      key: key,
      additionalData: additionalData,
    );
    return WhisperAeadResult(
      cipherText: result.cipherText,
      mac: result.mac,
    );
  }

  @override
  Uint8List decrypt({
    required Uint8List cipherText,
    required Uint8List mac,
    required Uint8List nonce,
    required Uint8List additionalData,
  }) {
    final key = _requireKey();
    try {
      return _sodium.crypto.aeadXChaCha20Poly1305IETF.decryptDetached(
        cipherText: cipherText,
        mac: mac,
        nonce: nonce,
        key: key,
        additionalData: additionalData,
      );
    } on sodium.SodiumException {
      throw const WhisperAeadAuthenticationException();
    }
  }

  @override
  void destroy() {
    final key = _key;
    _key = null;
    key?.dispose();
  }

  sodium.SecureKey _requireKey() {
    final key = _key;
    if (key == null) {
      throw StateError('AEAD key has been destroyed');
    }
    return key;
  }
}

final class _DartWhisperAeadKey implements WhisperAeadKey {
  _DartWhisperAeadKey(this._key);

  static final _cipher = Xchacha20.poly1305Aead().toSync();

  final SecretKeyData _key;

  @override
  bool get isDestroyed => _key.isDestroyed;

  @override
  WhisperAeadResult encrypt({
    required Uint8List message,
    required Uint8List nonce,
    required Uint8List additionalData,
  }) {
    final result = _cipher.encryptSync(
      message,
      secretKey: _key,
      nonce: nonce,
      aad: additionalData,
    );
    return WhisperAeadResult(
      cipherText: Uint8List.fromList(result.cipherText),
      mac: Uint8List.fromList(result.mac.bytes),
    );
  }

  @override
  Uint8List decrypt({
    required Uint8List cipherText,
    required Uint8List mac,
    required Uint8List nonce,
    required Uint8List additionalData,
  }) {
    try {
      return Uint8List.fromList(
        _cipher.decryptSync(
          SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
          secretKey: _key,
          aad: additionalData,
        ),
      );
    } on SecretBoxAuthenticationError {
      throw const WhisperAeadAuthenticationException();
    }
  }

  @override
  void destroy() => _key.destroy();
}
