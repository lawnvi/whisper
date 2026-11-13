import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Ed25519 public keys (raw 32 bytes, base64) whose signatures make an update
/// package installable. The private key exists only as the release workflow's
/// `UPDATE_SIGNING_KEY` secret, used by `script/sign_update_packages.sh`. A
/// mirror or a changed release listing can serve other bytes, but not a
/// signature for them. To change keys, first ship a version that trusts both.
const List<String> whisperUpdateSigningKeys = <String>[
  'v2ixE8F2Qro9mOH1JQkjOorJ1PUSEmQ7FOtpQ5e7gz4=',
];

/// The suffix of the release asset that holds a package's signature.
const String updateSignatureSuffix = '.sig';

/// The longest signature file read: base64 of 64 bytes plus a line end.
const int maxUpdateSignatureBytes = 1024;

/// What a signature covers. The tag is part of it so that an older signed
/// package can't be passed off as a newer release.
String updateSignatureStatement({
  required String tag,
  required String assetName,
  required String sha256Hex,
}) => 'whisper-update-v1\n$tag\n$assetName\n${sha256Hex.toLowerCase()}\n';

/// Whether [signature] (base64) is one of [trustedKeys] signing this package.
Future<bool> verifyUpdateSignature({
  required String tag,
  required String assetName,
  required String sha256Hex,
  required String? signature,
  required List<String> trustedKeys,
}) async {
  if (signature == null) {
    return false;
  }
  final List<int> signatureBytes;
  try {
    signatureBytes = base64.decode(signature.trim());
  } on FormatException {
    return false;
  }
  if (signatureBytes.length != 64) {
    return false;
  }
  final message = utf8.encode(
    updateSignatureStatement(
      tag: tag,
      assetName: assetName,
      sha256Hex: sha256Hex,
    ),
  );
  final algorithm = Ed25519();
  for (final key in trustedKeys) {
    final List<int> keyBytes;
    try {
      keyBytes = base64.decode(key);
    } on FormatException {
      continue;
    }
    if (keyBytes.length != 32) {
      continue;
    }
    final valid = await algorithm.verify(
      message,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (valid) {
      return true;
    }
  }
  return false;
}
