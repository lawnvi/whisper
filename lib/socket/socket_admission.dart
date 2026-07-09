import 'dart:io';

enum SocketAdmissionRejection {
  chatCapacity,
  preAuthCapacity,
  preAuthPerIpCapacity,
  upgradeRateLimit,
}

final class SocketAdmissionResult {
  const SocketAdmissionResult._({this.lease, this.rejection});

  factory SocketAdmissionResult.allowed(AdmissionLease lease) =>
      SocketAdmissionResult._(lease: lease);

  factory SocketAdmissionResult.rejected(
    SocketAdmissionRejection rejection,
  ) =>
      SocketAdmissionResult._(rejection: rejection);

  final AdmissionLease? lease;
  final SocketAdmissionRejection? rejection;

  bool get isAllowed => lease != null;
}

final class AdmissionLease {
  AdmissionLease._(this._owner, this.address);

  final SocketAdmissionController _owner;
  final String address;
  bool _authenticated = false;
  bool _closed = false;

  bool get isAuthenticated => _authenticated;
  bool get isClosed => _closed;

  void markAuthenticated() {
    if (_closed || _authenticated) {
      return;
    }
    _authenticated = true;
    _owner._markAuthenticated(address);
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _owner._release(address, wasAuthenticated: _authenticated);
  }
}

final class SocketAdmissionController {
  SocketAdmissionController({
    this.maxChatConnections = 32,
    this.maxPreAuthConnections = 8,
    this.maxPreAuthConnectionsPerIp = 2,
    this.maxUpgradeAttemptsPerMinutePerIp = 30,
    this.maxTrackedUpgradeAddresses = 4096,
    this.upgradeWindow = const Duration(minutes: 1),
    this.globalCleanupInterval = const Duration(minutes: 1),
  }) {
    if (maxChatConnections <= 0 ||
        maxPreAuthConnections <= 0 ||
        maxPreAuthConnectionsPerIp <= 0 ||
        maxUpgradeAttemptsPerMinutePerIp <= 0 ||
        maxTrackedUpgradeAddresses <= 0 ||
        upgradeWindow <= Duration.zero ||
        globalCleanupInterval <= Duration.zero) {
      throw ArgumentError('admission limits must be positive');
    }
  }

  final int maxChatConnections;
  final int maxPreAuthConnections;
  final int maxPreAuthConnectionsPerIp;
  final int maxUpgradeAttemptsPerMinutePerIp;
  final int maxTrackedUpgradeAddresses;
  final Duration upgradeWindow;
  final Duration globalCleanupInterval;

  final Map<String, int> _preAuthByIp = <String, int>{};
  final Map<String, List<int>> _upgradeAttemptsByIp = <String, List<int>>{};
  int _chatConnectionCount = 0;
  int _preAuthConnectionCount = 0;
  int? _lastGlobalCleanupMillis;

  int get chatConnectionCount => _chatConnectionCount;
  int get preAuthConnectionCount => _preAuthConnectionCount;
  int get trackedUpgradeAddressCount => _upgradeAttemptsByIp.length;

  SocketAdmissionResult tryOpen(Object address, DateTime now) {
    final normalized = normalizeSocketAddress(address);
    final nowMillis = now.toUtc().millisecondsSinceEpoch;
    final cutoff = nowMillis - upgradeWindow.inMilliseconds;
    _cleanupExpiredUpgradeAttempts(nowMillis, cutoff);
    if (!_upgradeAttemptsByIp.containsKey(normalized) &&
        _upgradeAttemptsByIp.length >= maxTrackedUpgradeAddresses) {
      return SocketAdmissionResult.rejected(
        SocketAdmissionRejection.upgradeRateLimit,
      );
    }
    final attempts = _upgradeAttemptsByIp.putIfAbsent(
      normalized,
      () => <int>[],
    );
    attempts.removeWhere((timestamp) => timestamp <= cutoff);
    if (attempts.length >= maxUpgradeAttemptsPerMinutePerIp) {
      return SocketAdmissionResult.rejected(
        SocketAdmissionRejection.upgradeRateLimit,
      );
    }
    attempts.add(nowMillis);

    if (_chatConnectionCount >= maxChatConnections) {
      return SocketAdmissionResult.rejected(
        SocketAdmissionRejection.chatCapacity,
      );
    }
    if (_preAuthConnectionCount >= maxPreAuthConnections) {
      return SocketAdmissionResult.rejected(
        SocketAdmissionRejection.preAuthCapacity,
      );
    }
    if ((_preAuthByIp[normalized] ?? 0) >= maxPreAuthConnectionsPerIp) {
      return SocketAdmissionResult.rejected(
        SocketAdmissionRejection.preAuthPerIpCapacity,
      );
    }

    _chatConnectionCount += 1;
    _preAuthConnectionCount += 1;
    _preAuthByIp.update(normalized, (count) => count + 1, ifAbsent: () => 1);
    return SocketAdmissionResult.allowed(AdmissionLease._(this, normalized));
  }

  void _cleanupExpiredUpgradeAttempts(int nowMillis, int cutoff) {
    final lastCleanup = _lastGlobalCleanupMillis;
    final shouldClean = lastCleanup == null ||
        nowMillis < lastCleanup ||
        nowMillis - lastCleanup >= globalCleanupInterval.inMilliseconds;
    if (!shouldClean) {
      return;
    }
    _lastGlobalCleanupMillis = nowMillis;
    _upgradeAttemptsByIp.removeWhere((_, attempts) {
      attempts.removeWhere((timestamp) => timestamp <= cutoff);
      return attempts.isEmpty;
    });
  }

  void _markAuthenticated(String address) {
    _releasePreAuth(address);
  }

  void _release(String address, {required bool wasAuthenticated}) {
    if (_chatConnectionCount > 0) {
      _chatConnectionCount -= 1;
    }
    if (!wasAuthenticated) {
      _releasePreAuth(address);
    }
  }

  void _releasePreAuth(String address) {
    if (_preAuthConnectionCount > 0) {
      _preAuthConnectionCount -= 1;
    }
    final current = _preAuthByIp[address] ?? 0;
    if (current <= 1) {
      _preAuthByIp.remove(address);
    } else {
      _preAuthByIp[address] = current - 1;
    }
  }
}

String normalizeSocketAddress(Object address) {
  final parsed = address is InternetAddress
      ? address
      : InternetAddress.tryParse(address.toString().trim());
  if (parsed == null) {
    return address.toString().trim().toLowerCase();
  }
  final bytes = parsed.rawAddress;
  if (bytes.length == 16 &&
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff) {
    return InternetAddress.fromRawAddress(bytes.sublist(12)).address;
  }
  return InternetAddress.fromRawAddress(bytes).address.toLowerCase();
}
