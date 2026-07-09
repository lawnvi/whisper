import 'dart:async';
import 'dart:collection';

enum OutboundPacketKind {
  chat,
  control,
  file,
  audio,
  mouseMove,
  scroll,
  key,
  button,
  release,
}

enum OutboundQueueResult { sent, dropped, closed, writerFailure }

enum _OutboundPolicy { failClosed, dropOldest, remoteInput }

final class BoundedOutboundQueue {
  BoundedOutboundQueue._({
    required Future<void> Function(Stream<Object>) addStream,
    required _OutboundPolicy policy,
    required this.maxItems,
    required this.maxBytes,
    this.onOverflow,
  })  : _addStream = addStream,
        _policy = policy {
    if (maxItems <= 0 || maxBytes <= 0) {
      throw ArgumentError('outbound queue limits must be positive');
    }
  }

  factory BoundedOutboundQueue.chat({
    required Future<void> Function(Stream<Object>) addStream,
    int maxItems = 64,
    int maxBytes = 8 * 1024 * 1024,
    void Function()? onOverflow,
  }) =>
      BoundedOutboundQueue._(
        addStream: addStream,
        policy: _OutboundPolicy.failClosed,
        maxItems: maxItems,
        maxBytes: maxBytes,
        onOverflow: onOverflow,
      );

  factory BoundedOutboundQueue.audio({
    required Future<void> Function(Stream<Object>) addStream,
    int maxItems = 32,
    int maxBytes = 512 * 1024,
    void Function()? onOverflow,
  }) =>
      BoundedOutboundQueue._(
        addStream: addStream,
        policy: _OutboundPolicy.dropOldest,
        maxItems: maxItems,
        maxBytes: maxBytes,
        onOverflow: onOverflow,
      );

  factory BoundedOutboundQueue.remoteInput({
    required Future<void> Function(Stream<Object>) addStream,
    int maxItems = 128,
    int maxBytes = 256 * 1024,
    void Function()? onOverflow,
  }) =>
      BoundedOutboundQueue._(
        addStream: addStream,
        policy: _OutboundPolicy.remoteInput,
        maxItems: maxItems,
        maxBytes: maxBytes,
        onOverflow: onOverflow,
      );

  final Future<void> Function(Stream<Object>) _addStream;
  final _OutboundPolicy _policy;
  final int maxItems;
  final int maxBytes;
  final void Function()? onOverflow;
  final Queue<_OutboundItem> _waiting = Queue<_OutboundItem>();

  _OutboundItem? _active;
  Future<void>? _pumpFuture;
  Completer<void>? _drainCompleter;
  bool _accepting = true;
  bool _overflowSignaled = false;
  int _pendingItems = 0;
  int _pendingBytes = 0;
  int _droppedItems = 0;

  int get pendingItems => _pendingItems;
  int get pendingBytes => _pendingBytes;
  int get droppedItems => _droppedItems;
  bool get isClosed => !_accepting;

  Future<bool> add(
    Object value, {
    required int byteLength,
    OutboundPacketKind kind = OutboundPacketKind.chat,
  }) {
    return addWithResult(
      value,
      byteLength: byteLength,
      kind: kind,
    ).then((result) => result == OutboundQueueResult.sent);
  }

  Future<OutboundQueueResult> addWithResult(
    Object value, {
    required int byteLength,
    OutboundPacketKind kind = OutboundPacketKind.chat,
  }) {
    return addLazyWithResult(
      () async => value,
      byteLength: byteLength,
      kind: kind,
    );
  }

  Future<bool> addLazy(
    Future<Object> Function() produce, {
    required int byteLength,
    OutboundPacketKind kind = OutboundPacketKind.chat,
  }) {
    return addLazyWithResult(
      produce,
      byteLength: byteLength,
      kind: kind,
    ).then((result) => result == OutboundQueueResult.sent);
  }

  Future<OutboundQueueResult> addLazyWithResult(
    Future<Object> Function() produce, {
    required int byteLength,
    OutboundPacketKind kind = OutboundPacketKind.chat,
  }) {
    if (byteLength < 0) {
      throw ArgumentError.value(byteLength, 'byteLength');
    }
    if (!_accepting) {
      return Future<OutboundQueueResult>.value(OutboundQueueResult.closed);
    }

    if (_policy == _OutboundPolicy.remoteInput && _isCoalescible(kind)) {
      final stale =
          _waiting.where((item) => item.kind == kind).toList(growable: false);
      for (final item in stale) {
        _waiting.remove(item);
        _drop(item);
      }
    }

    if (_policy == _OutboundPolicy.dropOldest) {
      while (_wouldOverflow(byteLength) && _waiting.isNotEmpty) {
        _drop(_waiting.removeFirst());
      }
      if (_wouldOverflow(byteLength)) {
        _droppedItems += 1;
        return Future<OutboundQueueResult>.value(OutboundQueueResult.dropped);
      }
    } else if (_wouldOverflow(byteLength)) {
      _accepting = false;
      _signalOverflow();
      return Future<OutboundQueueResult>.value(OutboundQueueResult.dropped);
    }

    final item = _OutboundItem(
      produce: produce,
      byteLength: byteLength,
      kind: kind,
    );
    _waiting.addLast(item);
    _pendingItems += 1;
    _pendingBytes += byteLength;
    _ensurePump();
    return item.completion.future;
  }

  bool _wouldOverflow(int byteLength) {
    return _pendingItems >= maxItems || byteLength > maxBytes - _pendingBytes;
  }

  bool _isCoalescible(OutboundPacketKind kind) {
    return kind == OutboundPacketKind.mouseMove ||
        kind == OutboundPacketKind.scroll;
  }

  void _drop(_OutboundItem item) {
    _pendingItems -= 1;
    _pendingBytes -= item.byteLength;
    _droppedItems += 1;
    if (!item.completion.isCompleted) {
      item.completion.complete(OutboundQueueResult.dropped);
    }
  }

  void _signalOverflow() {
    if (_overflowSignaled) {
      return;
    }
    _overflowSignaled = true;
    onOverflow?.call();
  }

  void _ensurePump() {
    if (_pumpFuture != null) {
      return;
    }
    _pumpFuture = _pump().whenComplete(() {
      _pumpFuture = null;
      if (_waiting.isNotEmpty) {
        _ensurePump();
      } else if (_pendingItems == 0) {
        _completeDrain();
      }
    });
  }

  Future<void> _pump() async {
    while (_waiting.isNotEmpty) {
      final item = _waiting.removeFirst();
      _active = item;
      try {
        await _addStream(Stream<Object>.fromFuture(item.produce()));
        if (!item.completion.isCompleted) {
          item.completion.complete(OutboundQueueResult.sent);
        }
      } catch (_) {
        _accepting = false;
        _signalOverflow();
        if (!item.completion.isCompleted) {
          item.completion.complete(OutboundQueueResult.writerFailure);
        }
      } finally {
        _active = null;
        _pendingItems -= 1;
        _pendingBytes -= item.byteLength;
      }
    }
  }

  Future<void> closeAndDrain() {
    _accepting = false;
    if (_pendingItems == 0) {
      return Future<void>.value();
    }
    return (_drainCompleter ??= Completer<void>()).future;
  }

  void _completeDrain() {
    final completer = _drainCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}

final class _OutboundItem {
  _OutboundItem({
    required this.produce,
    required this.byteLength,
    required this.kind,
  });

  final Future<Object> Function() produce;
  final int byteLength;
  final OutboundPacketKind kind;
  final Completer<OutboundQueueResult> completion =
      Completer<OutboundQueueResult>();
}
