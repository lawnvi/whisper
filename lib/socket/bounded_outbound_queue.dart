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

enum _OutboundTier { control, mount, bulk }

final class _TierQueue {
  _TierQueue({required this.maxItems, required this.maxBytes});

  final int maxItems;
  final int maxBytes;
  final Queue<_OutboundItem> waiting = Queue<_OutboundItem>();
  final Queue<Completer<bool>> waiters = Queue<Completer<bool>>();
  int pendingItems = 0;
  int pendingBytes = 0;

  bool wouldOverflow(int byteLength) =>
      pendingItems >= maxItems || byteLength > maxBytes - pendingBytes;

  bool hasWaitSpace(int byteLength) {
    if (pendingItems == 0) {
      return true;
    }
    return pendingItems < maxItems && byteLength <= maxBytes - pendingBytes;
  }

  void wakeWaiters() {
    while (waiters.isNotEmpty) {
      final waiter = waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(true);
      }
    }
  }

  void failWaiters() {
    while (waiters.isNotEmpty) {
      final waiter = waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(false);
      }
    }
  }
}

final class BoundedOutboundQueue {
  BoundedOutboundQueue._({
    required Future<void> Function(Stream<Object>) addStream,
    void Function(Object)? add,
    required _OutboundPolicy policy,
    required this.maxItems,
    required this.maxBytes,
    int? mountMaxItems,
    int? mountMaxBytes,
    int? bulkMaxItems,
    int? bulkMaxBytes,
    required this.writerTimeout,
    int? minWriteBytesPerSecond,
    Duration? maxWriterTimeout,
    this.onOverflow,
  }) : _addStream = addStream,
       _add = add,
       _policy = policy,
       _control = _TierQueue(maxItems: maxItems, maxBytes: maxBytes),
       _mount = _TierQueue(
         maxItems: mountMaxItems ?? maxItems,
         maxBytes: mountMaxBytes ?? maxBytes,
       ),
       _bulk = _TierQueue(
         maxItems: bulkMaxItems ?? maxItems,
         maxBytes: bulkMaxBytes ?? maxBytes,
       ),
       _minWriteBytesPerSecond = minWriteBytesPerSecond,
       _maxWriterTimeout = maxWriterTimeout ?? writerTimeout {
    if (maxItems <= 0 ||
        maxBytes <= 0 ||
        _mount.maxItems <= 0 ||
        _mount.maxBytes <= 0 ||
        _bulk.maxItems <= 0 ||
        _bulk.maxBytes <= 0 ||
        writerTimeout <= Duration.zero) {
      throw ArgumentError('outbound queue limits must be positive');
    }
  }

  factory BoundedOutboundQueue.chat({
    required Future<void> Function(Stream<Object>) addStream,
    void Function(Object)? add,
    int maxItems = 512,
    int maxBytes = 32 * 1024 * 1024,
    int mountMaxItems = 16,
    int mountMaxBytes = 8 * 1024 * 1024,
    int bulkMaxItems = 8,
    int bulkMaxBytes = 2 * 1024 * 1024,
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
    mountMaxItems: mountMaxItems,
    mountMaxBytes: mountMaxBytes,
    bulkMaxItems: bulkMaxItems,
    bulkMaxBytes: bulkMaxBytes,
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
  final Duration writerTimeout;
  final int? _minWriteBytesPerSecond;
  final Duration _maxWriterTimeout;
  final void Function()? onOverflow;
  final _TierQueue _control;
  final _TierQueue _mount;
  final _TierQueue _bulk;

  Queue<_OutboundItem> get _waiting => _control.waiting;
  bool get _hasWaiting =>
      _control.waiting.isNotEmpty ||
      _mount.waiting.isNotEmpty ||
      _bulk.waiting.isNotEmpty;

  _OutboundItem? _active;
  Future<void>? _pumpFuture;
  Completer<void>? _drainCompleter;
  bool _accepting = true;
  bool _terminal = false;
  bool _overflowSignaled = false;
  int _writerAttempt = 0;
  int _pendingItems = 0;
  int _pendingBytes = 0;
  int _droppedItems = 0;

  int get pendingItems => _pendingItems;
  int get pendingBytes => _pendingBytes;
  int get droppedItems => _droppedItems;
  bool get isClosed => !_accepting;

  _OutboundTier _tierFor(OutboundPacketKind kind) => switch (kind) {
    OutboundPacketKind.mount => _OutboundTier.mount,
    OutboundPacketKind.file => _OutboundTier.bulk,
    _ => _OutboundTier.control,
  };

  _TierQueue _queueFor(_OutboundTier tier) => switch (tier) {
    _OutboundTier.control => _control,
    _OutboundTier.mount => _mount,
    _OutboundTier.bulk => _bulk,
  };

  void _enqueueItem(_OutboundItem item) {
    final tierQueue = _queueFor(item.tier);
    tierQueue.waiting.addLast(item);
    tierQueue.pendingItems += 1;
    tierQueue.pendingBytes += item.byteLength;
    _pendingItems += 1;
    _pendingBytes += item.byteLength;
    _ensurePump();
  }

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
    if (_control.wouldOverflow(byteLength)) {
      _accepting = false;
      _failAllSpaceWaiters();
      _signalOverflow();
      return false;
    }
    _enqueueItem(
      _OutboundItem(
        produce: produce,
        byteLength: byteLength,
        kind: kind,
        tier: _OutboundTier.control,
      ),
    );
    return true;
  }

  /// Waits until mount or bulk tier capacity is available, then enqueues
  /// [produce] lazily and returns `true` upon admission (or `false` if the
  /// queue closes or [isValid] becomes `false` while waiting). Never fails
  /// closed on capacity limits.
  Future<bool> enqueueWhenSpaceAvailable(
    Future<Object> Function() produce, {
    required int byteLength,
    OutboundPacketKind kind = OutboundPacketKind.file,
    bool Function()? isValid,
  }) async {
    if (byteLength < 0) {
      throw ArgumentError.value(byteLength, 'byteLength');
    }
    final tier = kind == OutboundPacketKind.mount
        ? _OutboundTier.mount
        : _OutboundTier.bulk;
    final tierQueue = _queueFor(tier);
    while (true) {
      if (!_accepting || _terminal) {
        return false;
      }
      if (isValid != null && !isValid()) {
        return false;
      }
      if (tierQueue.hasWaitSpace(byteLength)) {
        _enqueueItem(
          _OutboundItem(
            produce: produce,
            byteLength: byteLength,
            kind: kind,
            tier: tier,
            isValid: isValid,
          ),
        );
        return true;
      }
      final waiter = Completer<bool>();
      tierQueue.waiters.addLast(waiter);
      final resumed = await waiter.future;
      if (!resumed) {
        return false;
      }
    }
  }

  /// Drops queued wait-tier items whose [isValid] predicate now returns false
  /// and wakes waiting producers so invalidated attempts exit immediately.
  void dropInvalid() {
    _dropInvalidFromTier(_mount);
    _dropInvalidFromTier(_bulk);
    if (_pendingItems == 0 && !_accepting) {
      _completeDrain();
    }
  }

  void _dropInvalidFromTier(_TierQueue tierQueue) {
    var removed = false;
    final kept = <_OutboundItem>[];
    while (tierQueue.waiting.isNotEmpty) {
      final item = tierQueue.waiting.removeFirst();
      if (item.isValid != null && !item.isValid!()) {
        tierQueue.pendingItems -= 1;
        tierQueue.pendingBytes -= item.byteLength;
        _pendingItems -= 1;
        _pendingBytes -= item.byteLength;
        _droppedItems += 1;
        if (!item.completion.isCompleted) {
          item.completion.complete(OutboundQueueResult.dropped);
        }
        removed = true;
      } else {
        kept.add(item);
      }
    }
    tierQueue.waiting.addAll(kept);
    if ((removed || tierQueue.waiters.isNotEmpty) && _accepting && !_terminal) {
      tierQueue.wakeWaiters();
    }
  }

  void _failAllSpaceWaiters() {
    _mount.failWaiters();
    _bulk.failWaiters();
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

    final tier = _policy == _OutboundPolicy.failClosed
        ? _tierFor(kind)
        : _OutboundTier.control;
    final item = _OutboundItem(
      produce: produce,
      byteLength: byteLength,
      kind: kind,
      tier: tier,
    );
    _enqueueItem(item);
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
    final tierQueue = _queueFor(item.tier);
    tierQueue.pendingItems -= 1;
    tierQueue.pendingBytes -= item.byteLength;
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
      if (_hasWaiting && !_terminal) {
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

  _OutboundItem? _dequeueNext() {
    if (_policy != _OutboundPolicy.failClosed) {
      return _waiting.isNotEmpty ? _waiting.removeFirst() : null;
    }
    for (final tierQueue in <_TierQueue>[_control, _mount, _bulk]) {
      while (tierQueue.waiting.isNotEmpty) {
        final item = tierQueue.waiting.removeFirst();
        if (item.isValid != null && !item.isValid!()) {
          tierQueue.pendingItems -= 1;
          tierQueue.pendingBytes -= item.byteLength;
          _pendingItems -= 1;
          _pendingBytes -= item.byteLength;
          _droppedItems += 1;
          if (!item.completion.isCompleted) {
            item.completion.complete(OutboundQueueResult.dropped);
          }
          if (_accepting && !_terminal) {
            tierQueue.wakeWaiters();
          }
          continue;
        }
        return item;
      }
    }
    return null;
  }

  Future<void> _pump() async {
    while (!_terminal) {
      final item = _dequeueNext();
      if (item == null) {
        return;
      }
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
    if (item.isValid != null && !item.isValid!()) {
      return;
    }
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
    final tierQueue = _queueFor(item.tier);
    tierQueue.pendingItems -= 1;
    tierQueue.pendingBytes -= item.byteLength;
    _pendingItems -= 1;
    _pendingBytes -= item.byteLength;
    if (_accepting && !_terminal) {
      tierQueue.wakeWaiters();
    }
    if (!item.completion.isCompleted) {
      item.completion.complete(result);
    }
  }

  void _drainTierAsClosed(_TierQueue tierQueue) {
    while (tierQueue.waiting.isNotEmpty) {
      final waiting = tierQueue.waiting.removeFirst();
      tierQueue.pendingItems -= 1;
      tierQueue.pendingBytes -= waiting.byteLength;
      _pendingItems -= 1;
      _pendingBytes -= waiting.byteLength;
      if (!waiting.completion.isCompleted) {
        waiting.completion.complete(OutboundQueueResult.closed);
      }
    }
  }

  void _failWriter(_OutboundItem item) {
    _accepting = false;
    _terminal = true;
    _writerAttempt += 1;
    _finishActive(item, OutboundQueueResult.writerFailure);
    _drainTierAsClosed(_control);
    _drainTierAsClosed(_mount);
    _drainTierAsClosed(_bulk);
    _failAllSpaceWaiters();
    _completeDrain();
    _signalOverflow();
  }

  void abort() {
    if (_terminal && _pendingItems == 0) {
      _failAllSpaceWaiters();
      return;
    }
    _accepting = false;
    _terminal = true;
    _writerAttempt += 1;
    final active = _active;
    if (active != null) {
      _finishActive(active, OutboundQueueResult.closed);
    }
    _drainTierAsClosed(_control);
    _drainTierAsClosed(_mount);
    _drainTierAsClosed(_bulk);
    _failAllSpaceWaiters();
    _completeDrain();
  }

  Future<void> closeAndDrain() {
    _accepting = false;
    _failAllSpaceWaiters();
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
    required this.tier,
    this.isValid,
  });

  final Future<Object> Function() produce;
  final int byteLength;
  final OutboundPacketKind kind;
  final _OutboundTier tier;
  final bool Function()? isValid;
  final Completer<OutboundQueueResult> completion =
      Completer<OutboundQueueResult>();
}
