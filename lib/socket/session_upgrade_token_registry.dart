import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

typedef SecureRandomBytes = Uint8List Function(int length);

final class SessionUpgradeClaim {
  SessionUpgradeClaim({
    required this.route,
    required this.namespace,
    required this.sessionId,
    required this.peerId,
    required Uint8List mediaMacKey,
  }) : _mediaMacKey = Uint8List.fromList(mediaMacKey);

  final String route;
  final String namespace;
  final String sessionId;
  final String peerId;
  final Uint8List _mediaMacKey;

  Uint8List get mediaMacKey => Uint8List.fromList(_mediaMacKey);
}

final class SessionUpgradeTokenRegistry {
  SessionUpgradeTokenRegistry({
    this.maxEntries = 128,
    this.timeToLive = const Duration(seconds: 30),
    SecureRandomBytes? randomBytes,
  }) : _randomBytes = randomBytes ?? _secureRandomBytes {
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
    if (timeToLive <= Duration.zero) {
      throw ArgumentError.value(timeToLive, 'timeToLive');
    }
  }

  final int maxEntries;
  final Duration timeToLive;
  final SecureRandomBytes _randomBytes;
  final List<_SessionUpgradeEntry> _entries = <_SessionUpgradeEntry>[];

  int get length => _entries.length;

  String issue({
    required String route,
    String namespace = '',
    required String sessionId,
    required String peerId,
    required Uint8List mediaMacKey,
    required DateTime now,
  }) {
    final normalizedRoute = normalizeMediaRoute(route);
    final normalizedNamespace = normalizeMediaNamespace(
      namespace,
      route: normalizedRoute,
    );
    if (sessionId.isEmpty || peerId.isEmpty) {
      throw ArgumentError('sessionId and peerId must not be empty');
    }
    if (mediaMacKey.length != 32) {
      throw ArgumentError.value(
        mediaMacKey.length,
        'mediaMacKey.length',
        'must be 32',
      );
    }
    _purgeExpired(now);
    if (_entries.length >= maxEntries) {
      throw StateError('session upgrade token registry is full');
    }

    for (var attempt = 0; attempt < 8; attempt++) {
      final tokenBytes = _randomBytes(32);
      if (tokenBytes.length != 32) {
        throw StateError('secure random source returned an invalid length');
      }
      if (_entries.any(
        (entry) => constantTimeBytesEqual(entry.tokenBytes, tokenBytes),
      )) {
        continue;
      }
      final storedToken = Uint8List.fromList(tokenBytes);
      _entries.add(
        _SessionUpgradeEntry(
          tokenBytes: storedToken,
          route: normalizedRoute,
          namespace: normalizedNamespace,
          sessionId: sessionId,
          peerId: peerId,
          mediaMacKey: Uint8List.fromList(mediaMacKey),
          expiresAt: now.add(timeToLive),
        ),
      );
      return base64Url.encode(storedToken).replaceAll('=', '');
    }
    throw StateError('secure random source produced duplicate tokens');
  }

  SessionUpgradeClaim? consume({
    required String route,
    required String sessionId,
    required String token,
    required DateTime now,
  }) {
    final normalizedRoute = _tryNormalizeMediaRoute(route);
    final tokenBytes = _decodeToken(token);
    _purgeExpired(now);
    if (normalizedRoute == null || sessionId.isEmpty || tokenBytes == null) {
      return null;
    }

    var matchingIndex = -1;
    for (var index = 0; index < _entries.length; index++) {
      final entry = _entries[index];
      final tokenMatches = constantTimeBytesEqual(entry.tokenBytes, tokenBytes);
      if (tokenMatches &&
          entry.route == normalizedRoute &&
          entry.sessionId == sessionId) {
        matchingIndex = index;
      }
    }
    if (matchingIndex < 0) {
      return null;
    }
    final entry = _entries.removeAt(matchingIndex);
    return SessionUpgradeClaim(
      route: entry.route,
      namespace: entry.namespace,
      sessionId: entry.sessionId,
      peerId: entry.peerId,
      mediaMacKey: entry.mediaMacKey,
    );
  }

  void revoke({
    required String route,
    String? namespace,
    required String sessionId,
    String? peerId,
  }) {
    final normalizedRoute = _tryNormalizeMediaRoute(route);
    final normalizedNamespace = namespace == null
        ? null
        : _tryNormalizeMediaNamespace(namespace, route: normalizedRoute);
    if (normalizedRoute == null ||
        sessionId.isEmpty ||
        (namespace != null && normalizedNamespace == null)) {
      return;
    }
    _entries.removeWhere(
      (entry) =>
          entry.route == normalizedRoute &&
          (normalizedNamespace == null ||
              entry.namespace == normalizedNamespace) &&
          entry.sessionId == sessionId &&
          (peerId == null || entry.peerId == peerId),
    );
  }

  void clearPeer(String peerId) {
    if (peerId.isEmpty) {
      return;
    }
    _entries.removeWhere((entry) => entry.peerId == peerId);
  }

  void clearAll() {
    _entries.clear();
  }

  void _purgeExpired(DateTime now) {
    _entries.removeWhere((entry) => !now.isBefore(entry.expiresAt));
  }
}

String normalizeMediaRoute(String route) {
  final normalized = _tryNormalizeMediaRoute(route);
  if (normalized == null) {
    throw ArgumentError.value(route, 'route', 'must be /audio or /input');
  }
  return normalized;
}

String normalizeMediaNamespace(
  String namespace, {
  required String route,
}) {
  final normalized = _tryNormalizeMediaNamespace(namespace, route: route);
  if (normalized == null) {
    throw ArgumentError.value(
      namespace,
      'namespace',
      'must match the media route',
    );
  }
  return normalized;
}

String? _tryNormalizeMediaNamespace(
  String namespace, {
  required String? route,
}) {
  final normalizedRoute = route == null ? null : _tryNormalizeMediaRoute(route);
  if (normalizedRoute == null) {
    return null;
  }
  final trimmed = namespace.trim();
  if (trimmed.isEmpty) {
    return normalizedRoute == '/audio' ? 'audio' : 'remote-input';
  }
  return switch ((normalizedRoute, trimmed)) {
    ('/audio', 'audio') => 'audio',
    ('/audio', 'audio-group') => 'audio-group',
    ('/input', 'remote-input') => 'remote-input',
    _ => null,
  };
}

String? _tryNormalizeMediaRoute(String route) {
  final trimmed = route.trim();
  final normalized = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  return switch (normalized) {
    '/audio' || '/input' => normalized,
    _ => null,
  };
}

bool constantTimeBytesEqual(List<int> first, List<int> second) {
  final length = max(first.length, second.length);
  var difference = first.length ^ second.length;
  for (var index = 0; index < length; index++) {
    final firstByte = index < first.length ? first[index] : 0;
    final secondByte = index < second.length ? second[index] : 0;
    difference |= firstByte ^ secondByte;
  }
  return difference == 0;
}

Uint8List? _decodeToken(String token) {
  if (token.length != 43 ||
      token.contains('=') ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) {
    return null;
  }
  try {
    final decoded = Uint8List.fromList(base64Url.decode('$token='));
    if (decoded.length != 32 ||
        base64Url.encode(decoded).replaceAll('=', '') != token) {
      return null;
    }
    return decoded;
  } on FormatException {
    return null;
  }
}

Uint8List _secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

final class _SessionUpgradeEntry {
  const _SessionUpgradeEntry({
    required this.tokenBytes,
    required this.route,
    required this.namespace,
    required this.sessionId,
    required this.peerId,
    required this.mediaMacKey,
    required this.expiresAt,
  });

  final Uint8List tokenBytes;
  final String route;
  final String namespace;
  final String sessionId;
  final String peerId;
  final Uint8List mediaMacKey;
  final DateTime expiresAt;
}
