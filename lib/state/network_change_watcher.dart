import 'dart:async';
import 'dart:io';

typedef NetworkFingerprintProvider = Future<Set<String>> Function();

/// Detects local network interface/IP changes across desktop and mobile
/// without requiring platform-specific connectivity plugins.
///
/// Polls `NetworkInterface.list` lightly on an interval (5s foreground, 20s
/// background on mobile), supports immediate sampling via [checkNow] on
/// system wake or app resume, and debounces rapid interface churn before
/// invoking [onNetworkChanged].
final class NetworkChangeWatcher {
  NetworkChangeWatcher({
    required this.onNetworkChanged,
    NetworkFingerprintProvider? fingerprintProvider,
    this.foregroundInterval = const Duration(seconds: 5),
    this.backgroundInterval = const Duration(seconds: 20),
    this.debounce = const Duration(seconds: 1),
  }) : _fingerprintProvider = fingerprintProvider ?? defaultNetworkFingerprint;

  final FutureOr<void> Function(Set<String> fingerprint) onNetworkChanged;
  final NetworkFingerprintProvider _fingerprintProvider;
  final Duration foregroundInterval;
  final Duration backgroundInterval;
  final Duration debounce;

  Timer? _pollTimer;
  Timer? _debounceTimer;
  Set<String>? _lastFingerprint;
  Set<String>? _pendingFingerprint;
  bool _running = false;
  bool _backgrounded = false;
  bool _checking = false;

  bool get isRunning => _running;
  bool get isBackgrounded => _backgrounded;

  static Future<Set<String>> defaultNetworkFingerprint() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final entries = <String>{};
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            entries.add('${iface.name}=${addr.address}');
          }
        }
      }
      return entries;
    } on Object {
      return const <String>{};
    }
  }

  /// Captures the baseline fingerprint and starts periodic checks.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _lastFingerprint = await _safeSample();
    if (!_running) return;
    _reschedulePoll();
  }

  void stop() {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingFingerprint = null;
  }

  /// Adjusts polling cadence when the app enters/leaves background (e.g.
  /// Android backgrounded -> slower polling; returning to foreground triggers
  /// an immediate check).
  void setBackgrounded(bool backgrounded) {
    if (_backgrounded == backgrounded) return;
    _backgrounded = backgrounded;
    if (!_running) return;
    _reschedulePoll();
    if (!backgrounded) {
      unawaited(checkNow());
    }
  }

  /// Samples immediately (for system wake or app resume).
  Future<void> checkNow() async {
    if (!_running || _checking) return;
    _checking = true;
    try {
      final sample = await _safeSample();
      if (!_running) return;
      final previous = _lastFingerprint;
      if (previous == null) {
        _lastFingerprint = sample;
        return;
      }
      if (_sameSet(previous, sample)) {
        return;
      }
      _lastFingerprint = sample;
      _pendingFingerprint = sample;
      _debounceTimer?.cancel();
      if (debounce <= Duration.zero) {
        _firePending();
      } else {
        _debounceTimer = Timer(debounce, _firePending);
      }
    } finally {
      _checking = false;
    }
  }

  void _reschedulePoll() {
    _pollTimer?.cancel();
    final interval = _backgrounded ? backgroundInterval : foregroundInterval;
    _pollTimer = Timer.periodic(interval, (_) => unawaited(checkNow()));
  }

  void _firePending() {
    _debounceTimer = null;
    if (!_running) return;
    final snapshot = _pendingFingerprint;
    _pendingFingerprint = null;
    if (snapshot == null) return;
    try {
      final result = onNetworkChanged(Set<String>.unmodifiable(snapshot));
      if (result is Future<void>) {
        unawaited(result.catchError((Object _) {}));
      }
    } on Object {
      // Watcher must not crash on observer errors.
    }
  }

  Future<Set<String>> _safeSample() async {
    try {
      return Set<String>.from(await _fingerprintProvider());
    } on Object {
      return _lastFingerprint ?? const <String>{};
    }
  }

  static bool _sameSet(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final value in a) {
      if (!b.contains(value)) return false;
    }
    return true;
  }
}
