import 'dart:ffi';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';
import 'package:sodium/sodium.dart' as sodium;

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint64>,
    Pointer<Uint8>,
    Uint64,
    Pointer<Uint8>,
    Uint64,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
  )
>(
  symbol: 'crypto_aead_xchacha20poly1305_ietf_encrypt_detached',
  assetId: 'package:sodium/libsodium',
  isLeaf: true,
)
external int _encryptDetached(
  Pointer<Uint8> cipherText,
  Pointer<Uint8> mac,
  Pointer<Uint64> macLength,
  Pointer<Uint8> message,
  int messageLength,
  Pointer<Uint8> additionalData,
  int additionalDataLength,
  Pointer<Uint8> secretNonce,
  Pointer<Uint8> nonce,
  Pointer<Uint8> key,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Uint64,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Uint64,
    Pointer<Uint8>,
    Pointer<Uint8>,
  )
>(
  symbol: 'crypto_aead_xchacha20poly1305_ietf_decrypt_detached',
  assetId: 'package:sodium/libsodium',
  isLeaf: true,
)
external int _decryptDetached(
  Pointer<Uint8> message,
  Pointer<Uint8> secretNonce,
  Pointer<Uint8> cipherText,
  int cipherTextLength,
  Pointer<Uint8> mac,
  Pointer<Uint8> additionalData,
  int additionalDataLength,
  Pointer<Uint8> nonce,
  Pointer<Uint8> key,
);

@Native<Void Function(Pointer<Void>, IntPtr)>(
  symbol: 'sodium_memzero',
  assetId: 'package:sodium/libsodium',
  isLeaf: true,
)
external void _sodiumMemzero(Pointer<Void> address, int length);

final class WhisperAeadAuthenticationException implements Exception {
  const WhisperAeadAuthenticationException();
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
  /// key container or copied to native memory and immediately cleared.
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
      return _NativeWhisperAeadKey(keyBytes);
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
  }
}

abstract interface class WhisperAeadKey {
  bool get isDestroyed;

  void encryptInto({
    required Uint8List message,
    required Uint8List cipherText,
    required Uint8List mac,
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
  _NativeWhisperAeadKey(Uint8List keyBytes) {
    final key = calloc<Uint8>(_keyLength);
    key.asTypedList(_keyLength).setAll(0, keyBytes);
    _key = key;
  }

  static const int _keyLength = 32;
  static const int _nonceLength = 24;
  static const int _macLength = 16;

  Pointer<Uint8>? _key;

  @override
  bool get isDestroyed => _key == null;

  @override
  void encryptInto({
    required Uint8List message,
    required Uint8List cipherText,
    required Uint8List mac,
    required Uint8List nonce,
    required Uint8List additionalData,
  }) {
    final key = _requireKey();
    _validateNonce(nonce);
    if (cipherText.length != message.length || mac.length != _macLength) {
      throw ArgumentError('Native AEAD output buffers have invalid lengths');
    }
    final result = _encryptDetached(
      cipherText.address,
      mac.address,
      nullptr.cast<Uint64>(),
      message.address,
      message.length,
      additionalData.address,
      additionalData.length,
      nullptr.cast<Uint8>(),
      nonce.address,
      key,
    );
    if (result != 0) {
      throw StateError('Native AEAD encryption failed');
    }
  }

  @override
  Uint8List decrypt({
    required Uint8List cipherText,
    required Uint8List mac,
    required Uint8List nonce,
    required Uint8List additionalData,
  }) {
    final key = _requireKey();
    _validateNonce(nonce);
    if (mac.length != _macLength) {
      throw const WhisperAeadAuthenticationException();
    }
    final result = _decryptDetached(
      cipherText.address,
      nullptr.cast<Uint8>(),
      cipherText.address,
      cipherText.length,
      mac.address,
      additionalData.address,
      additionalData.length,
      nonce.address,
      key,
    );
    if (result != 0) {
      throw const WhisperAeadAuthenticationException();
    }
    return cipherText;
  }

  @override
  void destroy() {
    final key = _key;
    _key = null;
    if (key != null) {
      _sodiumMemzero(key.cast<Void>(), _keyLength);
      calloc.free(key);
    }
  }

  Pointer<Uint8> _requireKey() {
    final key = _key;
    if (key == null) {
      throw StateError('AEAD key has been destroyed');
    }
    return key;
  }

  static void _validateNonce(Uint8List nonce) {
    if (nonce.length != _nonceLength) {
      throw ArgumentError.value(nonce.length, 'nonce.length');
    }
  }
}

final class _DartWhisperAeadKey implements WhisperAeadKey {
  _DartWhisperAeadKey(this._key);

  static final _cipher = Xchacha20.poly1305Aead().toSync();

  final SecretKeyData _key;

  @override
  bool get isDestroyed => _key.isDestroyed;

  @override
  void encryptInto({
    required Uint8List message,
    required Uint8List cipherText,
    required Uint8List mac,
    required Uint8List nonce,
    required Uint8List additionalData,
  }) {
    final result = _cipher.encryptSync(
      message,
      secretKey: _key,
      nonce: nonce,
      aad: additionalData,
    );
    if (cipherText.length != result.cipherText.length ||
        mac.length != result.mac.bytes.length) {
      throw ArgumentError('Dart AEAD output buffers have invalid lengths');
    }
    cipherText.setAll(0, result.cipherText);
    mac.setAll(0, result.mac.bytes);
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
