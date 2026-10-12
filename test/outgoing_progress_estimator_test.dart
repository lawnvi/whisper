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

  group('following what the peer confirmed', () {
    OutgoingProgressEstimator follower() => OutgoingProgressEstimator(
      durableOffset: 0,
      nowMs: 0,
      seedRateBytesPerMs: 64 * mb / 1000,
      followsConfirmed: true,
    );
    int shown(OutgoingProgressEstimator estimator, int nowMs) =>
        estimator.estimate(nowMs: nowMs, sentEnd: 512 * mb, size: 1024 * mb);

    test('nothing is shown before the peer confirms anything', () {
      final estimator = follower();

      // 种子速率和已发出的字节都不算数。
      expect(shown(estimator, 500), 0);
      expect(shown(estimator, 3000), 0);
    });

    test('walks to each confirmed offset over one acknowledgement gap', () {
      final estimator = follower();
      estimator.onAck(10 * mb, 1000);

      expect(shown(estimator, 1000), 0);
      expect(shown(estimator, 1250), closeTo(2.5 * mb, 1));
      expect(shown(estimator, 1500), 5 * mb);
      // 下一次 ACK 到达时正好走到上一个确认点,接着往新的走,中间不停。
      estimator.onAck(50 * mb, 2000);
      expect(shown(estimator, 2000), 10 * mb);
      expect(shown(estimator, 2500), 30 * mb);
      expect(shown(estimator, 3000), 50 * mb);
    });

    test('never passes what was confirmed, however long the peer is quiet', () {
      final estimator = follower();
      estimator.onAck(10 * mb, 1000);
      estimator.onAck(20 * mb, 2000);

      expect(shown(estimator, 3000), 20 * mb);
      expect(shown(estimator, 60000), 20 * mb);
      // 原地重复的 ACK(对端只是在说自己还在写)不让显示值动。
      estimator.onAck(20 * mb, 61000);
      expect(shown(estimator, 61500), 20 * mb);
    });

    test('an acknowledgement that comes early is caught up with smoothly', () {
      final estimator = follower();
      estimator.onAck(10 * mb, 1000);
      // 才走到一半就来了新的确认:从 5MB 处接着走,不跳也不回退。
      estimator.onAck(30 * mb, 1500);

      expect(shown(estimator, 1500), 5 * mb);
      expect(shown(estimator, 1750), closeTo(17.5 * mb, 1));
      expect(shown(estimator, 2000), 30 * mb);
    });

    test('a long gap between acknowledgements is not replayed in full', () {
      final estimator = follower();
      estimator.onAck(10 * mb, 1000);
      // 对端停了 20 秒才又确认:最多用 1.5 秒追上。
      estimator.onAck(40 * mb, 21000);

      expect(shown(estimator, 21750), 25 * mb);
      expect(shown(estimator, 22500), 40 * mb);
    });

    test('reset moves the starting point for a resumed transfer', () {
      final estimator = follower();
      estimator.onAck(10 * mb, 1000);
      estimator.reset(4 * mb, 5000);

      expect(shown(estimator, 5000), 4 * mb);
      estimator.onAck(8 * mb, 6000);
      expect(shown(estimator, 6500), 6 * mb);
    });
  });
}
