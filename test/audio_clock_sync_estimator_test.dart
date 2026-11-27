import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_clock_sync.dart';

void main() {
  test('estimates sink clock offset using the lowest RTT sample', () {
    final estimator = AudioClockSyncEstimator();

    estimator.addSample(const AudioClockSyncSample(
      sourceSentAtMicros: 1000000,
      sinkReceivedAtMicros: 1120000,
      sinkSentAtMicros: 1121000,
      sourceReceivedAtMicros: 1021000,
    ));
    estimator.addSample(const AudioClockSyncSample(
      sourceSentAtMicros: 2000000,
      sinkReceivedAtMicros: 2103000,
      sinkSentAtMicros: 2104000,
      sourceReceivedAtMicros: 2008000,
    ));

    final snapshot = estimator.snapshot;

    expect(snapshot.rttMicros, 7000);
    expect(snapshot.clockOffsetMicros, 99500);
    expect(snapshot.jitterMicros, greaterThan(0));
  });

  test('ignores impossible samples', () {
    final estimator = AudioClockSyncEstimator();

    estimator.addSample(const AudioClockSyncSample(
      sourceSentAtMicros: 1000000,
      sinkReceivedAtMicros: 1100000,
      sinkSentAtMicros: 1099000,
      sourceReceivedAtMicros: 1005000,
    ));

    expect(estimator.snapshot.isValid, isFalse);
  });

  test('keeps the last stable estimate when later samples are congested', () {
    final estimator = AudioClockSyncEstimator();

    estimator.addSample(const AudioClockSyncSample(
      sourceSentAtMicros: 1000000,
      sinkReceivedAtMicros: 1110000,
      sinkSentAtMicros: 1111000,
      sourceReceivedAtMicros: 1021000,
    ));
    final stable = estimator.snapshot;

    estimator.addSample(const AudioClockSyncSample(
      sourceSentAtMicros: 2000000,
      sinkReceivedAtMicros: 2400000,
      sinkSentAtMicros: 2401000,
      sourceReceivedAtMicros: 2558000,
    ));

    final snapshot = estimator.snapshot;

    expect(stable.rttMicros, 20000);
    expect(snapshot.clockOffsetMicros, stable.clockOffsetMicros);
    expect(snapshot.rttMicros, stable.rttMicros);
    expect(snapshot.sampleCount, stable.sampleCount);
  });

  // A wall clock set mid-share (network time, by hand) used to leave the old
  // samples winning on round trip for a dozen probes, every packet scheduled
  // seconds off: silence until they aged out.
  test('starts over when a clock is set, not when the network wobbles', () {
    final estimator = AudioClockSyncEstimator();
    estimator.addSample(const AudioClockSyncSample(
      sourceSentAtMicros: 1000000,
      sinkReceivedAtMicros: 1110000,
      sinkSentAtMicros: 1111000,
      sourceReceivedAtMicros: 1021000,
    ));
    // Same clocks, uneven ways: 5 ms apart, within the round trips.
    estimator.addSample(const AudioClockSyncSample(
      sourceSentAtMicros: 2000000,
      sinkReceivedAtMicros: 2115000,
      sinkSentAtMicros: 2116000,
      sourceReceivedAtMicros: 2021000,
    ));
    expect(estimator.snapshot.sampleCount, 2);
    expect(estimator.snapshot.clockOffsetMicros, 100000);

    // The sink's clock jumped two seconds ahead.
    estimator.addSample(const AudioClockSyncSample(
      sourceSentAtMicros: 3000000,
      sinkReceivedAtMicros: 5110000,
      sinkSentAtMicros: 5111000,
      sourceReceivedAtMicros: 3031000,
    ));
    expect(estimator.snapshot.sampleCount, 1);
    expect(estimator.snapshot.clockOffsetMicros, 2095000);
  });
}
