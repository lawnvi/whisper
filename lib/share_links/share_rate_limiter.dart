/// Slows down guessing: a client that gets a password wrong or asks for a
/// link that does not exist [maxFailures] times within [window] is turned
/// away for [backOff].
class ShareRateLimiter {
  ShareRateLimiter({
    this.maxFailures = 10,
    this.window = const Duration(minutes: 1),
    this.backOff = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxFailures;
  final Duration window;
  final Duration backOff;
  final DateTime Function() _clock;
  final _clients = <String, _Client>{};

  /// How long [client] must still wait, or null when it may go ahead.
  Duration? blockedFor(String client) {
    final entry = _clients[client];
    final until = entry?.blockedUntil;
    if (until == null) {
      return null;
    }
    final left = until.difference(_clock());
    if (left <= Duration.zero) {
      entry!.blockedUntil = null;
      entry.failures.clear();
      return null;
    }
    return left;
  }

  /// Notes a failure; true when [client] is now blocked.
  bool fail(String client) {
    final now = _clock();
    _prune(now);
    final entry = _clients.putIfAbsent(client, _Client.new);
    entry.failures
      ..removeWhere((at) => now.difference(at) >= window)
      ..add(now);
    if (entry.failures.length >= maxFailures) {
      entry.blockedUntil = now.add(backOff);
      return true;
    }
    return false;
  }

  /// Counts a password try as a failure before it is checked, so tries
  /// sent in parallel cannot all slip past [blockedFor] while the slow
  /// check runs. False (and nothing counted) when [client] must wait. A
  /// right password then clears it with [succeed].
  bool attempt(String client) {
    if (blockedFor(client) != null) {
      return false;
    }
    fail(client);
    return true;
  }

  /// A right password clears the client's earlier mistakes, the try that
  /// was counted for it included.
  void succeed(String client) => _clients.remove(client);

  void _prune(DateTime now) {
    if (_clients.length < 512) {
      return;
    }
    _clients.removeWhere((_, entry) {
      final until = entry.blockedUntil;
      if (until != null && until.isAfter(now)) {
        return false;
      }
      return entry.failures.every((at) => now.difference(at) >= window);
    });
  }
}

class _Client {
  final failures = <DateTime>[];
  DateTime? blockedUntil;
}
