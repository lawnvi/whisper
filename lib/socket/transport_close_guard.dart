import 'dart:async';

final class TransportCloseGuard {
  TransportCloseGuard({
    required Future<void> Function() close,
    this.timeout = const Duration(seconds: 2),
  }) : _close = close {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
  }

  final Future<void> Function() _close;
  final Duration timeout;
  Future<void>? _closeFuture;

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    return _closeFuture = Future<void>.sync(_close).timeout(
      timeout,
      onTimeout: () {},
    );
  }
}
