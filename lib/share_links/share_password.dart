import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A link's password as stored: PBKDF2-HMAC-SHA256 with a random salt.
/// The password itself is never kept.
class SharePasswordHash {
  const SharePasswordHash({
    required this.iterations,
    required this.salt,
    required this.hash,
  });

  static const algorithm = 'pbkdf2-sha256';
  static const defaultIterations = 120000;

  final int iterations;
  final Uint8List salt;
  final Uint8List hash;

  /// A new hash of [password]; runs in another isolate since it takes a
  /// noticeable moment by design.
  static Future<SharePasswordHash> create(
    String password, {
    int iterations = defaultIterations,
    Random? random,
  }) async {
    final rng = random ?? Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );
    final bytes = utf8.encode(password);
    final hash = await Isolate.run(
      () => pbkdf2HmacSha256(bytes, salt, iterations, 32),
    );
    return SharePasswordHash(iterations: iterations, salt: salt, hash: hash);
  }

  /// Whether [password] matches, compared in constant time. Off the main
  /// isolate like [create].
  Future<bool> verify(String password) async {
    final bytes = utf8.encode(password);
    final salt = this.salt;
    final iterations = this.iterations;
    final length = hash.length;
    final candidate = await Isolate.run(
      () => pbkdf2HmacSha256(bytes, salt, iterations, length),
    );
    return constantTimeEquals(candidate, hash);
  }

  Map<String, Object?> toJson() => {
    'alg': algorithm,
    'i': iterations,
    's': base64.encode(salt),
    'h': base64.encode(hash),
  };

  static SharePasswordHash? fromJson(Object? json) {
    if (json is! Map || json['alg'] != algorithm) {
      return null;
    }
    final iterations = json['i'];
    final salt = json['s'];
    final hash = json['h'];
    if (iterations is! int || salt is! String || hash is! String) {
      return null;
    }
    try {
      return SharePasswordHash(
        iterations: iterations,
        salt: base64.decode(salt),
        hash: base64.decode(hash),
      );
    } on FormatException {
      return null;
    }
  }
}

/// PBKDF2 (RFC 8018) with HMAC-SHA256.
Uint8List pbkdf2HmacSha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int length,
) {
  if (iterations < 1 || length < 1) {
    throw ArgumentError('iterations and length must be positive');
  }
  final hmac = Hmac(sha256, password);
  final out = Uint8List(length);
  final blocks = (length + 31) ~/ 32;
  final block = Uint8List(salt.length + 4)..setAll(0, salt);
  for (var index = 1; index <= blocks; index++) {
    block[salt.length] = index >> 24;
    block[salt.length + 1] = index >> 16;
    block[salt.length + 2] = index >> 8;
    block[salt.length + 3] = index;
    var u = hmac.convert(block).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    final offset = (index - 1) * 32;
    final take = min(32, length - offset);
    out.setRange(offset, offset + take, t);
  }
  return out;
}

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Signs the cookie a visitor gets after typing a link's password, so the
/// server keeps no session table: `<expiry>.<mac>`, where the MAC covers
/// the link's id, the expiry and the password's salt (a new password or a
/// re-created link invalidates old cookies).
class ShareCookieSigner {
  ShareCookieSigner(List<int> secret) : _hmac = Hmac(sha256, secret);

  static const lifetime = Duration(hours: 24);

  final Hmac _hmac;

  /// Per link, so being let into one link says nothing about another.
  static String cookieName(String linkId) =>
      'wsl_${linkId.length > 16 ? linkId.substring(0, 16) : linkId}';

  String issue({
    required String linkId,
    required List<int> salt,
    required DateTime now,
  }) {
    final expiry = now.add(lifetime).millisecondsSinceEpoch ~/ 1000;
    return '$expiry.${_mac(linkId, salt, expiry)}';
  }

  bool verify({
    required String linkId,
    required List<int> salt,
    required String? token,
    required DateTime now,
  }) {
    if (token == null) {
      return false;
    }
    final dot = token.indexOf('.');
    if (dot <= 0) {
      return false;
    }
    final expiry = int.tryParse(token.substring(0, dot));
    if (expiry == null || expiry * 1000 < now.millisecondsSinceEpoch) {
      return false;
    }
    final expected = utf8.encode(_mac(linkId, salt, expiry));
    return constantTimeEquals(utf8.encode(token.substring(dot + 1)), expected);
  }

  String _mac(String linkId, List<int> salt, int expiry) {
    final message = utf8.encode('v1|$linkId|$expiry|${base64.encode(salt)}');
    return base64Url.encode(_hmac.convert(message).bytes).replaceAll('=', '');
  }
}
