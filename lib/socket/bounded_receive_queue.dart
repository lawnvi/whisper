import 'dart:async';

/// 有界接收队列:先背压(pause)、后拒绝(overflow)。
///
/// 水位语义:
/// - 加入后 `pendingBytes >= pauseBytes`(低水位,默认 `maxBytes ~/ 2`)或
///   `pendingItems >= pauseItems`(默认 `maxItems ~/ 2`)时触发 [onPause],
///   要求上游暂停投递。
/// - [onOverflow] 只在两种情况下触发:单项自身超过 [maxBytes],或对端无视
///   pause 继续灌入、积压越过 `1 × maxBytes` / `1 × maxItems` 硬上限。
///   pause 水位只占预算的一半,生效前已在事件队列中的在途项仍有半个预算
///   的余量吸收(默认 4MiB / 32 项,远大于典型 TCP 窗口),不会被误判为
///   溢出;不配合 pause 的对端最多只能钉住一份预算的内存。
/// - 排空到 [resumeBytes] / [resumeItems](默认低水位的一半)以下时触发
///   [onResume]。
///
/// 这保证配合背压的对端(发送窗口不超过 [pauseBytes])永远不会被 overflow
/// 断联,只会经历 pause/resume。
final class BoundedReceiveQueue {
  BoundedReceiveQueue({
    this.maxItems = 64,
    this.maxBytes = 8 * 1024 * 1024,
    int? pauseItems,
    int? pauseBytes,
    int? resumeItems,
    int? resumeBytes,
    this.onPause,
    this.onResume,
    this.onOverflow,
  })  : pauseItems = pauseItems ?? maxItems ~/ 2,
        pauseBytes = pauseBytes ?? maxBytes ~/ 2,
        resumeItems = resumeItems ?? (pauseItems ?? maxItems ~/ 2) ~/ 2,
        resumeBytes = resumeBytes ?? (pauseBytes ?? maxBytes ~/ 2) ~/ 2 {
    if (maxItems <= 0 ||
        maxBytes <= 0 ||
        this.pauseItems <= 0 ||
        this.pauseItems > maxItems ||
        this.pauseBytes <= 0 ||
        this.pauseBytes > maxBytes ||
        this.resumeItems < 0 ||
        this.resumeItems >= this.pauseItems ||
        this.resumeBytes < 0 ||
        this.resumeBytes >= this.pauseBytes) {
      throw ArgumentError('invalid receive queue watermarks');
    }
  }

  final int maxItems;
  final int maxBytes;
  final int pauseItems;
  final int pauseBytes;
  final int resumeItems;
  final int resumeBytes;
  final void Function()? onPause;
  final void Function()? onResume;
  final void Function()? onOverflow;

  /// 对不配合背压的对端的硬上限:越过才判溢出。
  /// 收敛为 1×预算——pause 水位在半预算处,余下一半吸收在途项。
  int get hardMaxItems => maxItems;
  int get hardMaxBytes => maxBytes;

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
        (_pendingItems >= pauseItems || _pendingBytes >= pauseBytes)) {
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
