import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sodium/sodium.dart' as sodium;

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>(
  symbol: 'crypto_scalarmult_curve25519',
  assetId: 'package:sodium/libsodium',
  isLeaf: true,
)
external int _x25519(
  Pointer<Uint8> sharedSecret,
  Pointer<Uint8> privateKey,
  Pointer<Uint8> publicKey,
);

final class AuthSessionKeys {
  static sodium.Sodium? _native;

  static void installNativeAcceleration(sodium.Sodium instance) {
    _native = instance;
  }

  const AuthSessionKeys._({
    required this.clientToServerChat,
    required this.serverToClientChat,
    required this.clientToServerMedia,
    required this.serverToClientMedia,
  });

  final SecretKey clientToServerChat;
  final SecretKey serverToClientChat;
  final SecretKey clientToServerMedia;
  final SecretKey serverToClientMedia;

  void destroy() {
    clientToServerChat.destroy();
    serverToClientChat.destroy();
    clientToServerMedia.destroy();
    serverToClientMedia.destroy();
  }

  static Future<AuthSessionKeys> derive({
    required KeyPair localEphemeralKeyPair,
    required PublicKey remoteEphemeralPublicKey,
    required Uint8List transcriptHash,
  }) async {
    if (transcriptHash.length != 32) {
      throw ArgumentError.value(
        transcriptHash.length,
        'transcriptHash.length',
        'must be 32',
      );
    }
    final sharedSecret = _native == null
        ? await X25519().sharedSecretKey(
            keyPair: localEphemeralKeyPair,
            remotePublicKey: remoteEphemeralPublicKey,
          )
        : await _nativeSharedSecret(
            localEphemeralKeyPair,
            remoteEphemeralPublicKey,
          );
    try {
      final sharedSecretBytes = Uint8List.fromList(
        await sharedSecret.extractBytes(),
      );
      try {
        var nonZero = 0;
        for (final byte in sharedSecretBytes) {
          nonZero |= byte;
        }
        if (nonZero == 0) {
          throw const FormatException('Invalid X25519 shared secret');
        }
      } finally {
        sharedSecretBytes.fillRange(0, sharedSecretBytes.length, 0);
      }
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

      Future<SecretKey> derive(String label) {
        return () async {
          final derived = await hkdf.deriveKey(
            secretKey: sharedSecret,
            nonce: transcriptHash,
            info: utf8.encode('whisper-e2ee-v1/$label'),
          );
          try {
            return SecretKeyData(
              Uint8List.fromList(await derived.extractBytes()),
              overwriteWhenDestroyed: true,
            );
          } finally {
            derived.destroy();
          }
        }();
      }

      SecretKey? clientToServerChat;
      SecretKey? serverToClientChat;
      SecretKey? clientToServerMedia;
      SecretKey? serverToClientMedia;
      try {
        clientToServerChat = await derive('client-to-server/chat');
        serverToClientChat = await derive('server-to-client/chat');
        clientToServerMedia = await derive('client-to-server/media');
        serverToClientMedia = await derive('server-to-client/media');
        return AuthSessionKeys._(
          clientToServerChat: clientToServerChat,
          serverToClientChat: serverToClientChat,
          clientToServerMedia: clientToServerMedia,
          serverToClientMedia: serverToClientMedia,
        );
      } catch (_) {
        clientToServerChat?.destroy();
        serverToClientChat?.destroy();
        clientToServerMedia?.destroy();
        serverToClientMedia?.destroy();
        rethrow;
      }
    } finally {
      sharedSecret.destroy();
    }
  }

  static Future<SimpleKeyPair> generateEphemeralKeyPair() async {
    final native = _native;
    if (native == null) return X25519().newKeyPair();
    final pair = native.crypto.box.keyPair();
    try {
      final bytes = pair.secretKey.extractBytes();
      try {
        return SimpleKeyPairData(
          Uint8List.fromList(bytes),
          publicKey: SimplePublicKey(pair.publicKey, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        );
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    } finally {
      pair.secretKey.dispose();
    }
  }

  static Future<SecretKey> _nativeSharedSecret(
    KeyPair local,
    PublicKey remote,
  ) async {
    final pair = await local.extract();
    if (pair is! SimpleKeyPairData ||
        pair.type != KeyPairType.x25519 ||
        pair.bytes.length != 32 ||
        remote is! SimplePublicKey ||
        remote.type != KeyPairType.x25519 ||
        remote.bytes.length != 32) {
      throw ArgumentError('Expected 32-byte X25519 keys');
    }
    final privateBytes = Uint8List.fromList(pair.bytes);
    final publicBytes = Uint8List.fromList(remote.bytes);
    final sharedBytes = Uint8List(32);
    try {
      // The transcript HKDF needs raw X25519, not crypto.box.beforeNm's hash.
      if (_x25519(
            sharedBytes.address,
            privateBytes.address,
            publicBytes.address,
          ) !=
          0) {
        throw const FormatException('Invalid X25519 shared secret');
      }
      return SecretKeyData(
        Uint8List.fromList(sharedBytes),
        overwriteWhenDestroyed: true,
      );
    } finally {
      privateBytes.fillRange(0, privateBytes.length, 0);
      sharedBytes.fillRange(0, sharedBytes.length, 0);
    }
  }

  static Future<String> publicKeyBase64Url(KeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    if (publicKey is! SimplePublicKey || publicKey.bytes.length != 32) {
      throw StateError('Expected a 32-byte X25519 public key');
    }
    return base64Url.encode(publicKey.bytes).replaceAll('=', '');
  }

  static SimplePublicKey parseEphemeralPublicKey(String value) {
    if (value.isEmpty ||
        value.contains('=') ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw const FormatException('Invalid X25519 public key');
    }
    final padding = List<String>.filled((4 - value.length % 4) % 4, '=').join();
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base64Url.decode('$value$padding'));
    } on FormatException {
      throw const FormatException('Invalid X25519 public key');
    }
    if (bytes.length != 32 ||
        base64Url.encode(bytes).replaceAll('=', '') != value) {
      throw const FormatException('Invalid X25519 public key');
    }
    return SimplePublicKey(bytes, type: KeyPairType.x25519);
  }
}
