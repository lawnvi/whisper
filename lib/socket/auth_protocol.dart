import 'dart:convert';
import 'dart:typed_data';

enum AuthAction { hello, challenge, proof, result }

final class AuthEnvelope {
  const AuthEnvelope._({
    required this.action,
    required this.protocolVersion,
    required this.peerId,
    required this.nonce,
    required this.profileDigest,
    this.identityPublicKey,
    this.ephemeralPublicKey,
    this.peerNonce,
    this.signature,
    this.intendedPeerId,
    this.intendedPublicKeyHash,
    this.profile,
    this.allow,
    this.reason,
  });

  factory AuthEnvelope.hello({
    required int protocolVersion,
    required String peerId,
    required String identityPublicKey,
    required String ephemeralPublicKey,
    required String nonce,
    required String profileDigest,
    String? intendedPeerId,
    String? intendedPublicKeyHash,
    Map<String, Object?>? profile,
  }) {
    return _validated(
      action: AuthAction.hello,
      protocolVersion: protocolVersion,
      peerId: peerId,
      identityPublicKey: identityPublicKey,
      ephemeralPublicKey: ephemeralPublicKey,
      nonce: nonce,
      profileDigest: profileDigest,
      intendedPeerId: intendedPeerId,
      intendedPublicKeyHash: intendedPublicKeyHash,
      profile: profile,
    );
  }

  factory AuthEnvelope.challenge({
    required int protocolVersion,
    required String peerId,
    required String identityPublicKey,
    required String ephemeralPublicKey,
    required String nonce,
    required String peerNonce,
    required String profileDigest,
    required String signature,
    Map<String, Object?>? profile,
  }) {
    return _validated(
      action: AuthAction.challenge,
      protocolVersion: protocolVersion,
      peerId: peerId,
      identityPublicKey: identityPublicKey,
      ephemeralPublicKey: ephemeralPublicKey,
      nonce: nonce,
      peerNonce: peerNonce,
      profileDigest: profileDigest,
      signature: signature,
      profile: profile,
    );
  }

  factory AuthEnvelope.proof({
    required int protocolVersion,
    required String peerId,
    required String nonce,
    required String peerNonce,
    required String profileDigest,
    required String signature,
  }) {
    return _validated(
      action: AuthAction.proof,
      protocolVersion: protocolVersion,
      peerId: peerId,
      nonce: nonce,
      peerNonce: peerNonce,
      profileDigest: profileDigest,
      signature: signature,
    );
  }

  factory AuthEnvelope.result({
    required int protocolVersion,
    required String peerId,
    required String nonce,
    required String peerNonce,
    required String profileDigest,
    required String signature,
    required bool allow,
    required String reason,
  }) {
    return _validated(
      action: AuthAction.result,
      protocolVersion: protocolVersion,
      peerId: peerId,
      nonce: nonce,
      peerNonce: peerNonce,
      profileDigest: profileDigest,
      signature: signature,
      allow: allow,
      reason: reason,
    );
  }

  final AuthAction action;
  final int protocolVersion;
  final String peerId;
  final String? identityPublicKey;
  final String? ephemeralPublicKey;
  final String nonce;
  final String? peerNonce;
  final String profileDigest;
  final String? signature;
  final String? intendedPeerId;
  final String? intendedPublicKeyHash;
  final Map<String, Object?>? profile;
  final bool? allow;
  final String? reason;

  static AuthEnvelope fromJsonString(String value) {
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      throw const FormatException('Invalid auth JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('Auth envelope must be an object');
    }
    final json = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        throw const FormatException('Auth keys must be strings');
      }
      json[entry.key as String] = entry.value;
    }
    return fromJson(json);
  }

  static AuthEnvelope fromJson(Map<String, Object?> json) {
    final actionName = _requiredString(json, 'action');
    AuthAction? action;
    for (final candidate in AuthAction.values) {
      if (candidate.name == actionName) {
        action = candidate;
        break;
      }
    }
    if (action == null) {
      throw const FormatException('Unknown auth action');
    }
    _rejectUnexpectedKeys(json, _allowedKeys[action]!);

    final common = (
      protocolVersion: _requiredInt(json, 'version'),
      peerId: _requiredString(json, 'peerId'),
      nonce: _requiredString(json, 'nonce'),
      profileDigest: _requiredString(json, 'profileDigest'),
    );
    switch (action) {
      case AuthAction.hello:
        return AuthEnvelope.hello(
          protocolVersion: common.protocolVersion,
          peerId: common.peerId,
          identityPublicKey: _requiredString(json, 'identityKey'),
          ephemeralPublicKey: _requiredString(json, 'ephemeralKey'),
          nonce: common.nonce,
          profileDigest: common.profileDigest,
          intendedPeerId: _optionalString(json, 'intendedPeerId'),
          intendedPublicKeyHash: _optionalString(json, 'intendedPkh'),
          profile: _optionalProfile(json, 'profile'),
        );
      case AuthAction.challenge:
        return AuthEnvelope.challenge(
          protocolVersion: common.protocolVersion,
          peerId: common.peerId,
          identityPublicKey: _requiredString(json, 'identityKey'),
          ephemeralPublicKey: _requiredString(json, 'ephemeralKey'),
          nonce: common.nonce,
          peerNonce: _requiredString(json, 'peerNonce'),
          profileDigest: common.profileDigest,
          signature: _requiredString(json, 'signature'),
          profile: _optionalProfile(json, 'profile'),
        );
      case AuthAction.proof:
        return AuthEnvelope.proof(
          protocolVersion: common.protocolVersion,
          peerId: common.peerId,
          nonce: common.nonce,
          peerNonce: _requiredString(json, 'peerNonce'),
          profileDigest: common.profileDigest,
          signature: _requiredString(json, 'signature'),
        );
      case AuthAction.result:
        return AuthEnvelope.result(
          protocolVersion: common.protocolVersion,
          peerId: common.peerId,
          nonce: common.nonce,
          peerNonce: _requiredString(json, 'peerNonce'),
          profileDigest: common.profileDigest,
          signature: _requiredString(json, 'signature'),
          allow: _requiredBool(json, 'allow'),
          reason: _requiredString(json, 'reason', allowEmpty: true),
        );
    }
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'action': action.name,
      'version': protocolVersion,
      'peerId': peerId,
      if (identityPublicKey != null) 'identityKey': identityPublicKey,
      if (ephemeralPublicKey != null) 'ephemeralKey': ephemeralPublicKey,
      'nonce': nonce,
      if (peerNonce != null) 'peerNonce': peerNonce,
      'profileDigest': profileDigest,
      if (signature != null) 'signature': signature,
      if (intendedPeerId != null) 'intendedPeerId': intendedPeerId,
      if (intendedPublicKeyHash != null) 'intendedPkh': intendedPublicKeyHash,
      if (profile != null) 'profile': profile,
      if (allow != null) 'allow': allow,
      if (reason != null) 'reason': reason,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) {
    return other is AuthEnvelope &&
        other.action == action &&
        other.protocolVersion == protocolVersion &&
        other.peerId == peerId &&
        other.identityPublicKey == identityPublicKey &&
        other.ephemeralPublicKey == ephemeralPublicKey &&
        other.nonce == nonce &&
        other.peerNonce == peerNonce &&
        other.profileDigest == profileDigest &&
        other.signature == signature &&
        other.intendedPeerId == intendedPeerId &&
        other.intendedPublicKeyHash == intendedPublicKeyHash &&
        jsonEncode(other.profile) == jsonEncode(profile) &&
        other.allow == allow &&
        other.reason == reason;
  }

  @override
  int get hashCode => Object.hash(
        action,
        protocolVersion,
        peerId,
        identityPublicKey,
        ephemeralPublicKey,
        nonce,
        peerNonce,
        profileDigest,
        signature,
        intendedPeerId,
        intendedPublicKeyHash,
        jsonEncode(profile),
        allow,
        reason,
      );
}

AuthEnvelope _validated({
  required AuthAction action,
  required int protocolVersion,
  required String peerId,
  required String nonce,
  required String profileDigest,
  String? identityPublicKey,
  String? ephemeralPublicKey,
  String? peerNonce,
  String? signature,
  String? intendedPeerId,
  String? intendedPublicKeyHash,
  Map<String, Object?>? profile,
  bool? allow,
  String? reason,
}) {
  if (protocolVersion <= 0 || protocolVersion > 0xffff) {
    throw const FormatException('Invalid protocol version');
  }
  if (peerId.isEmpty || utf8.encode(peerId).length > 256) {
    throw const FormatException('Invalid peer id');
  }
  decodeAuthBase64Url(nonce, expectedLength: 32);
  decodeAuthBase64Url(profileDigest, expectedLength: 32);
  if (identityPublicKey != null) {
    decodeAuthBase64Url(identityPublicKey, expectedLength: 32);
  }
  if (ephemeralPublicKey != null) {
    decodeAuthBase64Url(ephemeralPublicKey, expectedLength: 32);
  }
  if (peerNonce != null) {
    decodeAuthBase64Url(peerNonce, expectedLength: 32);
  }
  if (signature != null) {
    decodeAuthBase64Url(signature, expectedLength: 64);
  }
  if (reason != null && utf8.encode(reason).length > 256) {
    throw const FormatException('Invalid auth reason');
  }
  return AuthEnvelope._(
    action: action,
    protocolVersion: protocolVersion,
    peerId: peerId,
    identityPublicKey: identityPublicKey,
    ephemeralPublicKey: ephemeralPublicKey,
    nonce: nonce,
    peerNonce: peerNonce,
    profileDigest: profileDigest,
    signature: signature,
    intendedPeerId: intendedPeerId,
    intendedPublicKeyHash: intendedPublicKeyHash,
    profile:
        profile == null ? null : Map<String, Object?>.unmodifiable(profile),
    allow: allow,
    reason: reason,
  );
}

String encodeAuthBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List decodeAuthBase64Url(
  String value, {
  required int expectedLength,
}) {
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
  if (decoded.length != expectedLength ||
      encodeAuthBase64Url(decoded) != value) {
    throw const FormatException('Invalid base64url length');
  }
  return decoded;
}

const Map<AuthAction, Set<String>> _allowedKeys = <AuthAction, Set<String>>{
  AuthAction.hello: <String>{
    'action',
    'version',
    'peerId',
    'identityKey',
    'ephemeralKey',
    'nonce',
    'profileDigest',
    'intendedPeerId',
    'intendedPkh',
    'profile',
  },
  AuthAction.challenge: <String>{
    'action',
    'version',
    'peerId',
    'identityKey',
    'ephemeralKey',
    'nonce',
    'peerNonce',
    'profileDigest',
    'signature',
    'profile',
  },
  AuthAction.proof: <String>{
    'action',
    'version',
    'peerId',
    'nonce',
    'peerNonce',
    'profileDigest',
    'signature',
  },
  AuthAction.result: <String>{
    'action',
    'version',
    'peerId',
    'nonce',
    'peerNonce',
    'profileDigest',
    'signature',
    'allow',
    'reason',
  },
};

void _rejectUnexpectedKeys(Map<String, Object?> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Unexpected auth field');
  }
}

String _requiredString(
  Map<String, Object?> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('Missing or invalid $key');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('Invalid $key');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('Missing or invalid $key');
  }
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('Missing or invalid $key');
  }
  return value;
}

Map<String, Object?>? _optionalProfile(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! Map) {
    throw FormatException('Invalid $key');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('Invalid $key');
    }
    result[entry.key as String] = entry.value;
  }
  try {
    jsonEncode(result);
  } on JsonUnsupportedObjectError {
    throw FormatException('Invalid $key');
  }
  return result;
}
