import 'dart:async';

/// 有界接收队列:先背压(pause)、后拒绝(overflow)。
///
/// 水位语义:
/// - 加入后 `pendingBytes >= pauseBytes`(低水位,默认 `maxBytes ~/ 2`)或
///   `pendingItems >= maxItems` 时触发 [onPause],要求上游暂停投递。
/// - [onOverflow] 只在两种情况下触发:单项自身超过 [maxBytes],或对端无视
///   pause 继续灌入、积压越过 `2 × maxBytes` / `2 × maxItems` 硬上限。
///   pause 生效前已在事件队列中的在途项因此不会被误判为溢出。
/// - 排空到 [resumeBytes] / [resumeItems](默认低水位的一半)以下时触发
///   [onResume]。
///
/// 这保证配合背压的对端(发送窗口不超过 [maxBytes])永远不会被 overflow
/// 断联,只会经历 pause/resume。
final class BoundedReceiveQueue {
  BoundedReceiveQueue({
    this.maxItems = 64,
    this.maxBytes = 8 * 1024 * 1024,
    int? pauseBytes,
    int? resumeItems,
    int? resumeBytes,
    this.onPause,
    this.onResume,
    this.onOverflow,
  })  : pauseBytes = pauseBytes ?? maxBytes ~/ 2,
        resumeItems = resumeItems ?? maxItems ~/ 2,
        resumeBytes = resumeBytes ?? (pauseBytes ?? maxBytes ~/ 2) ~/ 2 {
    if (maxItems <= 0 ||
        maxBytes <= 0 ||
        this.pauseBytes <= 0 ||
        this.pauseBytes > maxBytes ||
        this.resumeItems < 0 ||
        this.resumeItems >= maxItems ||
        this.resumeBytes < 0 ||
        this.resumeBytes >= this.pauseBytes) {
      throw ArgumentError('invalid receive queue watermarks');
    }
  }

  final int maxItems;
  final int maxBytes;
  final int pauseBytes;
  final int resumeItems;
  final int resumeBytes;
  final void Function()? onPause;
  final void Function()? onResume;
  final void Function()? onOverflow;

  /// 对不配合背压的对端的硬上限:越过才判溢出。
  int get hardMaxItems => maxItems * 2;
  int get hardMaxBytes => maxBytes * 2;

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
    if (byteLength > maxBytes ||
        _pendingItems + 1 > hardMaxItems ||
        _pendingBytes + byteLength > hardMaxBytes) {
      onOverflow?.call();
      return Future<bool>.value(false);
    }

    _pendingItems += 1;
    _pendingBytes += byteLength;
    if (!_paused &&
        (_pendingItems >= maxItems || _pendingBytes >= pauseBytes)) {
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
