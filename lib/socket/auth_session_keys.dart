import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final class AuthSessionKeys {
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
    final sharedSecret = await X25519().sharedSecretKey(
      keyPair: localEphemeralKeyPair,
      remotePublicKey: remoteEphemeralPublicKey,
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

  static Future<SimpleKeyPair> generateEphemeralKeyPair() =>
      X25519().newKeyPair();

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
