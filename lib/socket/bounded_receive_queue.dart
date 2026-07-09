import 'dart:async';

final class BoundedReceiveQueue {
  BoundedReceiveQueue({
    this.maxItems = 64,
    this.maxBytes = 8 * 1024 * 1024,
    int? resumeItems,
    this.resumeBytes = 4 * 1024 * 1024,
    this.onPause,
    this.onResume,
    this.onOverflow,
  }) : resumeItems = resumeItems ?? maxItems ~/ 2 {
    if (maxItems <= 0 ||
        maxBytes <= 0 ||
        this.resumeItems < 0 ||
        this.resumeItems >= maxItems ||
        resumeBytes < 0 ||
        resumeBytes >= maxBytes) {
      throw ArgumentError('invalid receive queue watermarks');
    }
  }

  final int maxItems;
  final int maxBytes;
  final int resumeItems;
  final int resumeBytes;
  final void Function()? onPause;
  final void Function()? onResume;
  final void Function()? onOverflow;

  Future<void> _tail = Future<void>.value();
  Future<void>? _drainFuture;
  int _pendingItems = 0;
  int _pendingBytes = 0;
  bool _accepting = true;
  bool _paused = false;

  int get pendingItems => _pendingItems;
  int get pendingBytes => _pendingBytes;
  bool get isPaused => _paused;
  bool get isClosed => !_accepting;

  Future<bool> add(
    int byteLength,
    Future<void> Function() action,
  ) {
    if (byteLength < 0) {
      throw ArgumentError.value(byteLength, 'byteLength');
    }
    if (!_accepting) {
      return Future<bool>.value(false);
    }
    if (_pendingItems >= maxItems || byteLength > maxBytes - _pendingBytes) {
      onOverflow?.call();
      return Future<bool>.value(false);
    }

    _pendingItems += 1;
    _pendingBytes += byteLength;
    if (!_paused && (_pendingItems >= maxItems || _pendingBytes >= maxBytes)) {
      _paused = true;
      onPause?.call();
    }

    final completion = Completer<bool>();
    final previous = _tail;
    _tail = () async {
      try {
        await previous.catchError((Object _) {});
        await action();
        completion.complete(true);
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      } finally {
        _pendingItems -= 1;
        _pendingBytes -= byteLength;
        if (_paused &&
            _pendingItems <= resumeItems &&
            _pendingBytes <= resumeBytes) {
          _paused = false;
          onResume?.call();
        }
      }
    }();
    return completion.future;
  }

  Future<void> closeAndDrain() {
    _accepting = false;
    return _drainFuture ??= _tail.catchError((Object _) {});
  }
}
