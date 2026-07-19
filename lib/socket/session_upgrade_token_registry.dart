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
    required Uint8List channelBinding,
    this.connectionGeneration = 0,
  }) : _mediaMacKey = Uint8List.fromList(mediaMacKey),
       _channelBinding = Uint8List.fromList(channelBinding) {
    if (mediaMacKey.length != 32 || channelBinding.length != 32) {
      throw ArgumentError('media keys and channel binding must be 32 bytes');
    }
  }

  final String route;
  final String namespace;
  final String sessionId;
  final String peerId;
  final int connectionGeneration;
  final Uint8List _mediaMacKey;
  final Uint8List _channelBinding;
  bool _destroyed = false;

  T withMediaMacKey<T>(T Function(Uint8List key) action) {
    if (_destroyed) {
      throw StateError('session upgrade claim has been destroyed');
    }
    final scopedKey = Uint8List.fromList(_mediaMacKey);
    try {
      return action(scopedKey);
    } finally {
      scopedKey.fillRange(0, scopedKey.length, 0);
    }
  }

  bool matchesMediaMacKey(Uint8List candidate) {
    return !_destroyed && constantTimeBytesEqual(_mediaMacKey, candidate);
  }

  T withMediaPacketContext<T>(
    T Function(Uint8List key, Uint8List channelBinding) action,
  ) {
    if (_destroyed) {
      throw StateError('session upgrade claim has been destroyed');
    }
    final scopedKey = Uint8List.fromList(_mediaMacKey);
    final scopedBinding = Uint8List.fromList(_channelBinding);
    try {
      return action(scopedKey, scopedBinding);
    } finally {
      scopedKey.fillRange(0, scopedKey.length, 0);
      scopedBinding.fillRange(0, scopedBinding.length, 0);
    }
  }

  bool matchesChannelBinding(Uint8List candidate) {
    return !_destroyed && constantTimeBytesEqual(_channelBinding, candidate);
  }

  bool get isDestroyed => _destroyed;

  void destroy() {
    if (_destroyed) {
      return;
    }
    _destroyed = true;
    _mediaMacKey.fillRange(0, _mediaMacKey.length, 0);
    _channelBinding.fillRange(0, _channelBinding.length, 0);
  }
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
    int connectionGeneration = 0,
    required DateTime now,
  }) {
    final normalizedRoute = normalizeMediaRoute(route);
    final normalizedNamespace = normalizeMediaNamespace(
      namespace,
      route: normalizedRoute,
    );
    if (sessionId.isEmpty || peerId.isEmpty || connectionGeneration < 0) {
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
          connectionGeneration: connectionGeneration,
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
    SessionUpgradeClaim? expected,
  }) {
    final matchingIndex = _findMatchingIndex(
      route: route,
      sessionId: sessionId,
      token: token,
      now: now,
      expected: expected,
    );
    if (matchingIndex < 0) {
      return null;
    }
    final entry = _entries.removeAt(matchingIndex);
    final claim = _claimFor(entry);
    entry.destroy();
    return claim;
  }

  SessionUpgradeClaim? lookup({
    required String route,
    required String sessionId,
    required String token,
    required DateTime now,
  }) {
    final matchingIndex = _findMatchingIndex(
      route: route,
      sessionId: sessionId,
      token: token,
      now: now,
    );
    return matchingIndex < 0 ? null : _claimFor(_entries[matchingIndex]);
  }

  int _findMatchingIndex({
    required String route,
    required String sessionId,
    required String token,
    required DateTime now,
    SessionUpgradeClaim? expected,
  }) {
    final normalizedRoute = _tryNormalizeMediaRoute(route);
    final tokenBytes = _decodeToken(token);
    _purgeExpired(now);
    if (normalizedRoute == null || sessionId.isEmpty || tokenBytes == null) {
      return -1;
    }

    var matchingIndex = -1;
    for (var index = 0; index < _entries.length; index++) {
      final entry = _entries[index];
      final tokenMatches = constantTimeBytesEqual(entry.tokenBytes, tokenBytes);
      if (tokenMatches &&
          entry.route == normalizedRoute &&
          entry.sessionId == sessionId &&
          (expected == null || _entryMatchesClaim(entry, expected))) {
        matchingIndex = index;
      }
    }
    return matchingIndex;
  }

  SessionUpgradeClaim _claimFor(_SessionUpgradeEntry entry) {
    return SessionUpgradeClaim(
      route: entry.route,
      namespace: entry.namespace,
      sessionId: entry.sessionId,
      peerId: entry.peerId,
      mediaMacKey: entry.mediaMacKey,
      channelBinding: entry.tokenBytes,
      connectionGeneration: entry.connectionGeneration,
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
    _removeWhereAndDestroy(
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
    _removeWhereAndDestroy((entry) => entry.peerId == peerId);
  }

  void clearAll() {
    for (final entry in _entries) {
      entry.destroy();
    }
    _entries.clear();
  }

  void _purgeExpired(DateTime now) {
    _removeWhereAndDestroy((entry) => !now.isBefore(entry.expiresAt));
  }

  void _removeWhereAndDestroy(bool Function(_SessionUpgradeEntry) remove) {
    for (var index = _entries.length - 1; index >= 0; index -= 1) {
      final entry = _entries[index];
      if (!remove(entry)) {
        continue;
      }
      _entries.removeAt(index);
      entry.destroy();
    }
  }
}

String normalizeMediaRoute(String route) {
  final normalized = _tryNormalizeMediaRoute(route);
  if (normalized == null) {
    throw ArgumentError.value(route, 'route', 'must be /audio or /input');
  }
  return normalized;
}

String normalizeMediaNamespace(String namespace, {required String route}) {
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
    required this.connectionGeneration,
    required this.expiresAt,
  });

  final Uint8List tokenBytes;
  final String route;
  final String namespace;
  final String sessionId;
  final String peerId;
  final Uint8List mediaMacKey;
  final int connectionGeneration;
  final DateTime expiresAt;

  void destroy() {
    tokenBytes.fillRange(0, tokenBytes.length, 0);
    mediaMacKey.fillRange(0, mediaMacKey.length, 0);
  }
}

bool _entryMatchesClaim(_SessionUpgradeEntry entry, SessionUpgradeClaim claim) {
  return entry.route == claim.route &&
      entry.namespace == claim.namespace &&
      entry.sessionId == claim.sessionId &&
      entry.peerId == claim.peerId &&
      entry.connectionGeneration == claim.connectionGeneration &&
      claim.matchesMediaMacKey(entry.mediaMacKey) &&
      claim.matchesChannelBinding(entry.tokenBytes);
}
