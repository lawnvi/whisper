import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/outgoing_progress_estimator.dart';

void main() {
  const mb = 1024 * 1024;

  test('interpolates between ACKs using the windowed average rate', () {
    final estimator = OutgoingProgressEstimator(durableOffset: 0, nowMs: 0);
    // 32MB ACK 每 1000ms 一次 -> 32MB/s。
    estimator.onAck(32 * mb, 1000);
    estimator.onAck(64 * mb, 2000);
    expect(estimator.rateBytesPerMs, closeTo(32 * mb / 1000, 1));

    // 无新 ACK 时按均速推进。
    final at2500 = estimator.estimate(
      nowMs: 2500,
      sentEnd: 128 * mb,
      size: 1024 * mb,
    );
    expect(at2500, 64 * mb + 16 * mb);
    final at3000 = estimator.estimate(
      nowMs: 3000,
      sentEnd: 128 * mb,
      size: 1024 * mb,
    );
    expect(at3000, 96 * mb);
  });

  test('alternating fast/slow ACK gaps average out inside the window', () {
    final estimator = OutgoingProgressEstimator(durableOffset: 0, nowMs: 0);
    // 接收端在 ACK 点刷盘导致的快慢交替:400ms / 1600ms,均值 1000ms。
    var t = 0;
    var offset = 0;
    for (var i = 0; i < 4; i++) {
      t += i.isEven ? 400 : 1600;
      offset += 32 * mb;
      estimator.onAck(offset, t);
    }
    expect(estimator.rateBytesPerMs, closeTo(32 * mb / 1000, 1));
  });

  test('never exceeds bytes handed to the transport nor the file size', () {
    final estimator = OutgoingProgressEstimator(
      durableOffset: 0,
      nowMs: 0,
      seedRateBytesPerMs: 1000,
    );
    expect(estimator.estimate(nowMs: 10000, sentEnd: 5000, size: 100000), 5000);
    expect(estimator.estimate(nowMs: 20000, sentEnd: 100000, size: 8000), 8000);
  });

  test('display is monotonic and snaps up to a newer durable offset', () {
    final estimator = OutgoingProgressEstimator(durableOffset: 0, nowMs: 0);
    // 尚无速率:显示停在 0。
    expect(estimator.estimate(nowMs: 500, sentEnd: 64 * mb, size: 64 * mb), 0);
    // 首个 ACK 直接把显示值抬到 durableOffset。
    estimator.onAck(32 * mb, 1000);
    expect(estimator.displayed, 32 * mb);
    // 后续显示值只增不减。
    final a = estimator.estimate(nowMs: 1500, sentEnd: 64 * mb, size: 64 * mb);
    final b = estimator.estimate(nowMs: 1400, sentEnd: 64 * mb, size: 64 * mb);
    expect(b, a);
    // 迟到/重复的旧 ACK 不会拉低基准。
    estimator.onAck(16 * mb, 1600);
    expect(estimator.durableOffset, 32 * mb);
  });

  test('seed rate drives display before the first ACK arrives', () {
    final estimator = OutgoingProgressEstimator(
      durableOffset: 0,
      nowMs: 0,
      seedRateBytesPerMs: 2048,
    );
    expect(
      estimator.estimate(nowMs: 100, sentEnd: 64 * mb, size: 64 * mb),
      2048 * 100,
    );
  });

  test('reset is the only path that moves the display backwards', () {
    final estimator = OutgoingProgressEstimator(durableOffset: 0, nowMs: 0);
    estimator.onAck(32 * mb, 1000);
    estimator.reset(8 * mb, 5000);
    expect(estimator.displayed, 8 * mb);
    expect(estimator.durableOffset, 8 * mb);
    expect(estimator.rateBytesPerMs, 0);
  });
}
