import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/transfer_speed_meter.dart';

void main() {
  const mb = 1024 * 1024;

  test('there is no reading until enough time is covered', () {
    final meter = TransferSpeedMeter();
    expect(meter.bytesPerSecond, isNull);

    meter.add(0, 0);
    expect(meter.bytesPerSecond, isNull);
    meter.add(100, 5 * mb);
    expect(meter.bytesPerSecond, isNull);
    meter.add(500, 10 * mb);
    expect(meter.bytesPerSecond, 20 * mb);
  });

  test('bursts and pauses come out as their average', () {
    final meter = TransferSpeedMeter();
    // 30 MB in the first 100 ms of every second, nothing for the rest.
    final readings = <int>[];
    var bytes = 0;
    meter.add(0, bytes);
    for (var second = 0; second < 6; second += 1) {
      bytes += 30 * mb;
      meter.add(second * 1000 + 100, bytes);
      for (var ms = 200; ms <= 1000; ms += 100) {
        meter.add(second * 1000 + ms, bytes);
        if (second >= 3) readings.add(meter.bytesPerSecond!);
      }
    }

    // Between neighbouring updates this would read 300 MB/s or nothing.
    for (final reading in readings) {
      expect(reading, inInclusiveRange(20 * mb, 40 * mb));
    }
  });

  test('what happened before the window no longer counts', () {
    final meter = TransferSpeedMeter();
    var bytes = 0;
    for (var ms = 0; ms <= 5000; ms += 100) {
      meter.add(ms, bytes);
      bytes += 4 * mb;
    }
    expect(meter.bytesPerSecond, closeTo(40 * mb, mb));

    // The same transfer slows to a tenth: three seconds on, that is all
    // the reading shows.
    for (var ms = 5100; ms <= 8200; ms += 100) {
      bytes += mb ~/ 2.5;
      meter.add(ms, bytes);
    }
    expect(meter.bytesPerSecond, closeTo(4 * mb, mb));
  });

  test('a transfer that starts over is measured afresh', () {
    final meter = TransferSpeedMeter();
    meter.add(0, 0);
    meter.add(1000, 50 * mb);
    expect(meter.bytesPerSecond, 50 * mb);

    meter.add(1100, 2 * mb);
    expect(meter.bytesPerSecond, isNull);
    meter.add(2100, 12 * mb);
    expect(meter.bytesPerSecond, 10 * mb);
  });

  test('reset forgets everything', () {
    final meter = TransferSpeedMeter();
    meter.add(0, 0);
    meter.add(1000, 50 * mb);
    meter.reset();

    expect(meter.bytesPerSecond, isNull);
  });
}
