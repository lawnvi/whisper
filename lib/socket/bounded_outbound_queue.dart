import 'dart:async';
import 'dart:collection';

enum OutboundPacketKind {
  chat,
  control,
  mount,
  file,
  audio,
  mouseMove,
  scroll,
  key,
  button,
  release,

  /// Window-stream video: codec parameter sets, keyframes, other frames.
  videoConfig,
  videoKey,
  videoDelta,
}

enum OutboundQueueResult { sent, dropped, closed, writerFailure }

enum _OutboundPolicy { failClosed, dropOldest, remoteInput, video }

final class BoundedOutboundQueue {
  BoundedOutboundQueue._({
    required Future<void> Function(Stream<Object>) addStream,
    void Function(Object)? add,
    required _OutboundPolicy policy,
    required this.maxItems,
    required this.maxBytes,
    int? waitMaxItems,
    int? waitMaxBytes,
    required this.writerTimeout,
    int? minWriteBytesPerSecond,
    Duration? maxWriterTimeout,
    this.onOverflow,
  }) : _addStream = addStream,
       _add = add,
       _policy = policy,
       _waitMaxItems = waitMaxItems ?? maxItems,
       _waitMaxBytes = waitMaxBytes ?? maxBytes,
       _minWriteBytesPerSecond = minWriteBytesPerSecond,
       _maxWriterTimeout = maxWriterTimeout ?? writerTimeout {
    if (maxItems <= 0 ||
        maxBytes <= 0 ||
        _waitMaxItems <= 0 ||
        _waitMaxBytes <= 0 ||
        writerTimeout <= Duration.zero) {
      throw ArgumentError('outbound queue limits must be positive');
    }
  }

  factory BoundedOutboundQueue.chat({
    required Future<void> Function(Stream<Object>) addStream,
    void Function(Object)? add,
    int maxItems = 512,
    int maxBytes = 32 * 1024 * 1024,
    int waitMaxItems = 16,
    int waitMaxBytes = 8 * 1024 * 1024,
    Duration writerTimeout = const Duration(seconds: 30),
    int? minWriteBytesPerSecond,
    Duration maxWriterTimeout = const Duration(seconds: 120),
    void Function()? onOverflow,
  }) => BoundedOutboundQueue._(
    addStream: addStream,
    add: add,
    policy: _OutboundPolicy.failClosed,
    maxItems: maxItems,
    maxBytes: maxBytes,
    waitMaxItems: waitMaxItems,
    waitMaxBytes: waitMaxBytes,
    writerTimeout: writerTimeout,
    minWriteBytesPerSecond: minWriteBytesPerSecond,
    maxWriterTimeout: maxWriterTimeout,
    onOverflow: onOverflow,
  );

  factory BoundedOutboundQueue.audio({
    required Future<void> Function(Stream<Object>) addStream,
    int maxItems = 32,
    int maxBytes = 512 * 1024,
    Duration writerTimeout = const Duration(seconds: 2),
    void Function()? onOverflow,
  }) => BoundedOutboundQueue._(
    addStream: addStream,
    policy: _OutboundPolicy.dropOldest,
    maxItems: maxItems,
    maxBytes: maxBytes,
    writerTimeout: writerTimeout,
    onOverflow: onOverflow,
  );

  factory BoundedOutboundQueue.remoteInput({
    required Future<void> Function(Stream<Object>) addStream,
    int maxItems = 128,
    int maxBytes = 256 * 1024,
    Duration writerTimeout = const Duration(seconds: 2),
    void Function()? onOverflow,
  }) => BoundedOutboundQueue._(
    addStream: addStream,
    policy: _OutboundPolicy.remoteInput,
    maxItems: maxItems,
    maxBytes: maxBytes,
    writerTimeout: writerTimeout,
    onOverflow: onOverflow,
  );

  /// Live video: only the freshest frames matter. Frames are dropped before
  /// they are produced (and therefore before they are encrypted), so the
  /// packet sequence stays contiguous. Once any non-keyframe is dropped, the
  /// following ones are dropped too until a keyframe arrives, and
  /// [onKeyframeNeeded] asks the encoder for one. Everything else (codec
  /// config, keyframes, small control packets) is never dropped silently.
  factory BoundedOutboundQueue.video({
    required Future<void> Function(Stream<Object>) addStream,
    int maxItems = 48,
    int maxBytes = 24 * 1024 * 1024,
    Duration writerTimeout = const Duration(seconds: 5),
    void Function()? onOverflow,
    void Function()? onKeyframeNeeded,
  }) => BoundedOutboundQueue._(
    addStream: addStream,
    policy: _OutboundPolicy.video,
    maxItems: maxItems,
    maxBytes: maxBytes,
    writerTimeout: writerTimeout,
    onOverflow: onOverflow,
  ).._onKeyframeNeeded = onKeyframeNeeded;

  final Future<void> Function(Stream<Object>) _addStream;
  final void Function(Object)? _add;
  void Function()? _onKeyframeNeeded;
  bool _videoNeedsKeyframe = false;

  /// Video only: deltas are being dropped until the next keyframe.
  bool get videoNeedsKeyframe => _videoNeedsKeyframe;
  final _OutboundPolicy _policy;
  final int maxItems;
  final int maxBytes;
  final int _waitMaxItems;
  final int _waitMaxBytes;
  final Duration writerTimeout;
  final int? _minWriteBytesPerSecond;
  final Duration _maxWriterTimeout;
  final void Function()? onOverflow;
  final Queue<_OutboundItem> _waiting = Queue<_OutboundItem>();
  final Queue<Completer<bool>> _spaceWaiters = Queue<Completer<bool>>();

  _OutboundItem? _active;
  Future<void>? _pumpFuture;
  Completer<void>? _drainCompleter;
  bool _accepting = true;
  bool _terminal = false;
  bool _overflowSignaled = false;
  int _writerAttempt = 0;
  int _pendingItems = 0;
  int _pendingBytes = 0;
  int _pendingWaitItems = 0;
  int _pendingWaitBytes = 0;
  int _droppedItems = 0;

  int get pendingItems => _pendingItems;
  int get pendingBytes => _pendingBytes;
  int get droppedItems => _droppedItems;
  bool get isClosed => !_accepting;

  /// Enqueues a control frame and resolves immediately upon admission without
  /// waiting for the underlying socket write to complete, so inbound receive
  /// handlers never deadlock waiting on outbound TCP backpressure.
  bool enqueueControl(
    Object value, {
    required int byteLength,
    OutboundPacketKind kind = OutboundPacketKind.control,
  }) =>
      enqueueControlLazy(() async => value, byteLength: byteLength, kind: kind);

  /// Lazy variant of [enqueueControl]: [produce] runs only when dequeued for
  /// writing so encryption sequence numbers match actual wire order.
  bool enqueueControlLazy(
    Future<Object> Function() produce, {
    required int byteLength,
    OutboundPacketKind kind = OutboundPacketKind.control,
  }) {
    if (byteLength < 0) {
      throw ArgumentError.value(byteLength, 'byteLength');
    }
    if (!_accepting || _terminal) {
      return false;
    }
    if (_wouldOverflowControl(byteLength)) {
      _accepting = false;
      _failSpaceWaiters();
      _signalOverflow();
      return false;
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
    return true;
  }

  /// Waits until bulk/mount capacity is available, then enqueues [produce]
  /// lazily and returns `true` upon admission (or `false` if the queue closes
  /// while waiting). Never fails closed on capacity limits.
  Future<bool> enqueueWhenSpaceAvailable(
    Future<Object> Function() produce, {
    required int byteLength,
    OutboundPacketKind kind = OutboundPacketKind.file,
  }) async {
    if (byteLength < 0) {
      throw ArgumentError.value(byteLength, 'byteLength');
    }
    while (true) {
      if (!_accepting || _terminal) {
        return false;
      }
      if (_hasWaitSpace(byteLength)) {
        final item = _OutboundItem(
          produce: produce,
          byteLength: byteLength,
          kind: kind,
          countsTowardWaitCap: true,
        );
        _waiting.addLast(item);
        _pendingItems += 1;
        _pendingBytes += byteLength;
        _pendingWaitItems += 1;
        _pendingWaitBytes += byteLength;
        _ensurePump();
        return true;
      }
      final waiter = Completer<bool>();
      _spaceWaiters.addLast(waiter);
      final resumed = await waiter.future;
      if (!resumed) {
        return false;
      }
    }
  }

  bool _hasWaitSpace(int byteLength) {
    if (_pendingWaitItems == 0) {
      return true;
    }
    return _pendingWaitItems < _waitMaxItems &&
        byteLength <= _waitMaxBytes - _pendingWaitBytes;
  }

  bool _wouldOverflowControl(int byteLength) {
    final controlItems = _pendingItems - _pendingWaitItems;
    final controlBytes = _pendingBytes - _pendingWaitBytes;
    return controlItems >= maxItems || byteLength > maxBytes - controlBytes;
  }

  void _wakeSpaceWaiters() {
    while (_spaceWaiters.isNotEmpty && _accepting && !_terminal) {
      final waiter = _spaceWaiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(true);
      }
    }
  }

  void _failSpaceWaiters() {
    while (_spaceWaiters.isNotEmpty) {
      final waiter = _spaceWaiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(false);
      }
    }
  }

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
      final stale = _waiting
          .where((item) => item.kind == kind)
          .toList(growable: false);
      for (final item in stale) {
        _waiting.remove(item);
        _drop(item);
      }
    }

    if (_policy == _OutboundPolicy.video) {
      final early = _admitVideo(kind, byteLength);
      if (early != null) {
        return Future<OutboundQueueResult>.value(early);
      }
    } else if (_policy == _OutboundPolicy.dropOldest) {
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

  /// Returns a result when the packet must not be queued.
  OutboundQueueResult? _admitVideo(OutboundPacketKind kind, int byteLength) {
    switch (kind) {
      case OutboundPacketKind.videoDelta:
        if (_videoNeedsKeyframe || _wouldOverflow(byteLength)) {
          _dropWaitingDeltas();
          _droppedItems += 1;
          return OutboundQueueResult.dropped;
        }
        return null;
      case OutboundPacketKind.videoKey:
        // A keyframe makes every queued frame obsolete.
        _dropWaiting(
          (item) =>
              item == OutboundPacketKind.videoDelta ||
              item == OutboundPacketKind.videoKey,
        );
        _videoNeedsKeyframe = false;
      case OutboundPacketKind.videoConfig:
        _dropWaiting((item) => item == OutboundPacketKind.videoConfig);
      default:
        break;
    }
    if (_wouldOverflow(byteLength)) {
      _dropWaitingDeltas();
    }
    if (_wouldOverflow(byteLength)) {
      _accepting = false;
      _signalOverflow();
      return OutboundQueueResult.dropped;
    }
    return null;
  }

  void _dropWaitingDeltas() {
    final dropped = _dropWaiting(
      (item) => item == OutboundPacketKind.videoDelta,
    );
    if (!_videoNeedsKeyframe) {
      _videoNeedsKeyframe = true;
      _onKeyframeNeeded?.call();
    } else if (dropped > 0) {
      _onKeyframeNeeded?.call();
    }
  }

  int _dropWaiting(bool Function(OutboundPacketKind kind) matches) {
    final stale = _waiting
        .where((item) => matches(item.kind))
        .toList(growable: false);
    for (final item in stale) {
      _waiting.remove(item);
      _drop(item);
    }
    return stale.length;
  }

  bool _wouldOverflow(int byteLength) {
    return _pendingItems >= maxItems || byteLength > maxBytes - _pendingBytes;
  }

  bool _isCoalescible(OutboundPacketKind kind) {
    // Mouse movement packets contain an absolute position fallback, while
    // scroll packets are purely relative and must never be replaced without
    // first accumulating their deltas and gesture phases.
    return kind == OutboundPacketKind.mouseMove;
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

  Duration _deadlineFor(int byteLength) {
    final minRate = _minWriteBytesPerSecond;
    if (minRate == null || minRate <= 0) {
      return writerTimeout;
    }
    final extraSeconds = (byteLength / minRate).ceil();
    final scaled = writerTimeout + Duration(seconds: extraSeconds);
    return scaled > _maxWriterTimeout ? _maxWriterTimeout : scaled;
  }

  Future<void> _pump() async {
    while (_waiting.isNotEmpty && !_terminal) {
      final item = _waiting.removeFirst();
      _active = item;
      final attempt = ++_writerAttempt;
      try {
        await _write(item).timeout(_deadlineFor(item.byteLength));
        if (!_isCurrentWriter(item, attempt)) {
          return;
        }
        _finishActive(item, OutboundQueueResult.sent);
      } catch (_) {
        if (!_isCurrentWriter(item, attempt)) {
          return;
        }
        _failWriter(item);
        return;
      }
    }
  }

  Future<void> _write(_OutboundItem item) async {
    final add = _add;
    if (add != null) {
      add(await item.produce());
      return;
    }
    await _addStream(Stream<Object>.fromFuture(item.produce()));
  }

  bool _isCurrentWriter(_OutboundItem item, int attempt) {
    return !_terminal && attempt == _writerAttempt && identical(_active, item);
  }

  void _finishActive(_OutboundItem item, OutboundQueueResult result) {
    if (!identical(_active, item)) {
      return;
    }
    _active = null;
    _pendingItems -= 1;
    _pendingBytes -= item.byteLength;
    if (item.countsTowardWaitCap) {
      _pendingWaitItems -= 1;
      _pendingWaitBytes -= item.byteLength;
      _wakeSpaceWaiters();
    }
    if (!item.completion.isCompleted) {
      item.completion.complete(result);
    }
  }

  void _failWriter(_OutboundItem item) {
    _accepting = false;
    _terminal = true;
    _writerAttempt += 1;
    _finishActive(item, OutboundQueueResult.writerFailure);
    while (_waiting.isNotEmpty) {
      final waiting = _waiting.removeFirst();
      _pendingItems -= 1;
      _pendingBytes -= waiting.byteLength;
      if (waiting.countsTowardWaitCap) {
        _pendingWaitItems -= 1;
        _pendingWaitBytes -= waiting.byteLength;
      }
      if (!waiting.completion.isCompleted) {
        waiting.completion.complete(OutboundQueueResult.closed);
      }
    }
    _failSpaceWaiters();
    _completeDrain();
    _signalOverflow();
  }

  void abort() {
    if (_terminal && _pendingItems == 0) {
      _failSpaceWaiters();
      return;
    }
    _accepting = false;
    _terminal = true;
    _writerAttempt += 1;
    final active = _active;
    if (active != null) {
      _finishActive(active, OutboundQueueResult.closed);
    }
    while (_waiting.isNotEmpty) {
      final waiting = _waiting.removeFirst();
      _pendingItems -= 1;
      _pendingBytes -= waiting.byteLength;
      if (waiting.countsTowardWaitCap) {
        _pendingWaitItems -= 1;
        _pendingWaitBytes -= waiting.byteLength;
      }
      if (!waiting.completion.isCompleted) {
        waiting.completion.complete(OutboundQueueResult.closed);
      }
    }
    _failSpaceWaiters();
    _completeDrain();
  }

  Future<void> closeAndDrain() {
    _accepting = false;
    _failSpaceWaiters();
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
    this.countsTowardWaitCap = false,
  });

  final Future<Object> Function() produce;
  final int byteLength;
  final OutboundPacketKind kind;
  final bool countsTowardWaitCap;
  final Completer<OutboundQueueResult> completion =
      Completer<OutboundQueueResult>();
}
