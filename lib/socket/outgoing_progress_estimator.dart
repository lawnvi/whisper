import 'dart:collection';
import 'dart:math' as math;

/// 发送端进度估计器。
///
/// 发送端只有在对端 ACK(每 `ackIntervalSize`,桌面 32MB / 移动 8MB)到达时
/// 才知道 `durableOffset`,而帧是同步塞进 WebSocket sink 的,没有线路级
/// 回压信号;直接把 `durableOffset` 当进度显示会一顿一顿,网速也会在
/// 0 与几十 MB/s 之间跳。
///
/// 接收端每到 ACK 点要先排空写盘管线再回 ACK,所以相邻 ACK 的间隔天然
/// 快慢交替;若按相邻两次 ACK 算速率,显示网速会在半速与全速之间摆动。
/// 这里改为按最近 [_rateWindowMs] 内的多次 ACK 求平均吞吐,显示值以该均速
/// 匀速推进:落后于已确认字节时向上追平,上限为已交给传输层的字节数,
/// 单调不回退。真实线路位置必然落在 `[durableOffset, sentEnd]` 内,显示值
/// 不会"凭空"超过实际发送量。
final class OutgoingProgressEstimator {
  OutgoingProgressEstimator({
    required int durableOffset,
    required int nowMs,
    double seedRateBytesPerMs = 0,
  }) : _durableOffset = durableOffset,
       _displayed = durableOffset,
       _lastTickMs = nowMs,
       _seedRateBytesPerMs = seedRateBytesPerMs > 0 ? seedRateBytesPerMs : 0 {
    _samples.add(_AckSample(offset: durableOffset, atMs: nowMs));
  }

  /// 求平均速率时回看的时长;至少覆盖两三个 ACK 间隔才能抹平快慢交替。
  static const int _rateWindowMs = 4000;

  final Queue<_AckSample> _samples = Queue<_AckSample>();
  final double _seedRateBytesPerMs;
  int _durableOffset;
  int _displayed;
  int _lastTickMs;

  int get durableOffset => _durableOffset;
  int get displayed => _displayed;

  /// 最近窗口内按 ACK 吞吐求得的平均速率(字节/毫秒)。
  /// 只有起点、尚无 ACK 样本时退回种子速率(同一对端上次传输的均速)。
  double get rateBytesPerMs {
    if (_samples.length < 2) {
      return _seedRateBytesPerMs;
    }
    final first = _samples.first;
    final last = _samples.last;
    final elapsed = last.atMs - first.atMs;
    if (elapsed <= 0) {
      return _seedRateBytesPerMs;
    }
    return (last.offset - first.offset) / elapsed;
  }

  /// 收到对端 ACK:记录样本,裁掉窗口外的旧样本(始终保留两个以上)。
  void onAck(int offset, int nowMs) {
    if (offset < _durableOffset) {
      return;
    }
    _durableOffset = offset;
    _samples.add(_AckSample(offset: offset, atMs: nowMs));
    while (_samples.length > 2 &&
        nowMs - _samples.first.atMs > _rateWindowMs) {
      _samples.removeFirst();
    }
    if (_displayed < offset) {
      // 显示值被 ACK 向上对齐后,积分基准也要同步前移,否则下一次
      // estimate 会把 ACK 之前那段时间再算一遍。
      _displayed = offset;
      _lastTickMs = nowMs;
    }
  }

  /// 显式重置基准(续传/重连后对端报告新的 durableOffset)。
  /// 这是唯一允许显示值回退的入口。
  void reset(int offset, int nowMs) {
    _durableOffset = offset;
    _displayed = offset;
    _lastTickMs = nowMs;
    _samples
      ..clear()
      ..add(_AckSample(offset: offset, atMs: nowMs));
  }

  /// 当前应显示的字节数:自上次调用起按均速推进,下限为 durableOffset,
  /// 上限为 `min(sentEnd, size)`,单调不回退。
  int estimate({required int nowMs, required int sentEnd, required int size}) {
    final elapsed = math.max(0, nowMs - _lastTickMs);
    _lastTickMs = nowMs;
    final ceiling = math.max(_durableOffset, math.min(sentEnd, size));
    var value = _displayed + (rateBytesPerMs * elapsed).floor();
    if (value < _durableOffset) {
      value = _durableOffset;
    }
    if (value > ceiling) {
      value = ceiling;
    }
    if (value > _displayed) {
      _displayed = value;
    }
    return _displayed;
  }
}

final class _AckSample {
  const _AckSample({required this.offset, required this.atMs});

  final int offset;
  final int atMs;
}
