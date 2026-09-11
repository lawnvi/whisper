import 'dart:async';

class RemoteInputBusyException implements Exception {
  const RemoteInputBusyException();

  @override
  String toString() => 'Remote input is busy';
}

/// One native input owner per device, shared by both routing modes.
class RemoteInputLifecycle {
  RemoteInputLifecycleOwner? _owner;

  RemoteInputLifecycleOwner createOwner({
    required Future<void> Function(bool notifyPeer) cleanup,
    bool Function()? canYield,
  }) => RemoteInputLifecycleOwner._(this, cleanup, canYield);
}

class RemoteInputLifecycleOwner {
  RemoteInputLifecycleOwner._(this._lifecycle, this._cleanup, this._canYield);

  final RemoteInputLifecycle _lifecycle;
  final Future<void> Function(bool notifyPeer) _cleanup;
  final bool Function()? _canYield;
  int _generation = 0;
  Future<void>? _stopping;
  Completer<void>? _drained;
  bool _cleanupFinished = false;
  int _pendingNativeStarts = 0;

  int get generation => _generation;
  bool get isCurrent => identical(_lifecycle._owner, this) && _stopping == null;

  bool get canStart {
    final owner = _lifecycle._owner;
    return owner == null || identical(owner, this) || owner._canRelinquish;
  }

  bool get _canRelinquish => _stopping != null || _canYield?.call() == true;

  /// A null result means an explicit stop or a newer start cancelled this one.
  Future<int?> start() async {
    if (!canStart) throw const RemoteInputBusyException();
    final stopping = stop(notifyPeer: true);
    final generation = _generation;
    await stopping;
    await _drained?.future;
    if (generation != _generation) return null;

    final previous = _lifecycle._owner;
    if (previous != null && !identical(previous, this)) {
      if (!previous._canRelinquish) throw const RemoteInputBusyException();
      await previous.stop(notifyPeer: true);
      await previous._drained?.future;
      if (generation != _generation) return null;
    }
    // Another caller may have acquired native input while cleanup was pending.
    if (_lifecycle._owner != null) throw const RemoteInputBusyException();
    _lifecycle._owner = this;
    return generation;
  }

  Future<bool> startNative({
    required int generation,
    required Future<void> Function() start,
    required Future<void> Function() rollback,
  }) async {
    if (generation != _generation || !isCurrent) return false;
    _pendingNativeStarts++;
    try {
      try {
        await start();
      } catch (_) {
        if (generation != _generation || !isCurrent) await rollback();
        rethrow;
      }
      if (generation != _generation || !isCurrent) {
        await rollback();
        return false;
      }
      return true;
    } finally {
      _pendingNativeStarts--;
      _finishDrain();
    }
  }

  Future<void> stop({bool notifyPeer = false}) {
    _generation++;
    final stopping = _stopping;
    if (stopping != null) return stopping;
    // Install the barrier before cleanup notifies listeners or closes sockets.
    final completer = Completer<void>();
    _stopping = completer.future;
    _drained = Completer<void>();
    _cleanupFinished = false;
    unawaited(
      Future<void>.sync(() => _cleanup(notifyPeer)).then<void>(
        (_) => _finishStop(completer),
        onError: (Object error, StackTrace stackTrace) =>
            _finishStop(completer, error, stackTrace),
      ),
    );
    return completer.future;
  }

  void _finishStop(
    Completer<void> completer, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    _cleanupFinished = true;
    _finishDrain();
    if (error == null) {
      completer.complete();
    } else {
      completer.completeError(error, stackTrace);
    }
  }

  void _finishDrain() {
    if (!_cleanupFinished || _pendingNativeStarts != 0 || _drained == null) {
      return;
    }
    // Stop releases held input immediately; a new owner must also wait for
    // outstanding native starts to finish and undo any late side effects.
    if (identical(_lifecycle._owner, this)) _lifecycle._owner = null;
    _stopping = null;
    _drained!.complete();
    _drained = null;
  }
}
