import 'package:whisper/socket/peer_socket_session.dart';

bool matchesExpectedQuickSendIdentity({
  required String expectedPublicKeyHash,
  required String authenticatedIdentityPublicKey,
  required bool storedTrusted,
  required String storedIdentityPublicKey,
}) {
  if (!storedTrusted ||
      expectedPublicKeyHash.length != 43 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(expectedPublicKeyHash) ||
      authenticatedIdentityPublicKey.isEmpty ||
      storedIdentityPublicKey.isEmpty) {
    return false;
  }
  try {
    return identityPublicKeyHash(authenticatedIdentityPublicKey) ==
            expectedPublicKeyHash &&
        identityPublicKeyHash(storedIdentityPublicKey) == expectedPublicKeyHash;
  } on Object {
    return false;
  }
}
