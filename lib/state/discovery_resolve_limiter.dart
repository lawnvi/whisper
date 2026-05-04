class DiscoveryResolveLimiter {
  DiscoveryResolveLimiter({
    required this.minimumInterval,
  });

  final Duration minimumInterval;
  final Map<String, DateTime> _lastResolvedAt = <String, DateTime>{};

  bool shouldResolve(String key, {DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final previous = _lastResolvedAt[key];
    if (previous != null &&
        timestamp.difference(previous) < minimumInterval) {
      return false;
    }
    _lastResolvedAt[key] = timestamp;
    return true;
  }

  void clear(String key) {
    _lastResolvedAt.remove(key);
  }
}
