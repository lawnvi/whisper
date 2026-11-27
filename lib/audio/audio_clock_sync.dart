import 'dart:developer' show Timeline;

/// Microseconds on a clock that only moves forward, the same in every isolate
/// of this process. For how long something took or since when; times sent to
/// another device stay on the wall clock, which both sides share.
int audioMonotonicMicros() => Timeline.now;

/// Microseconds on the wall clock: what playback times sent between devices
/// are counted in.
int audioWallClockMicros() => DateTime.now().microsecondsSinceEpoch;

class AudioClockSyncSample {
  const AudioClockSyncSample({
    required this.sourceSentAtMicros,
    required this.sinkReceivedAtMicros,
    required this.sinkSentAtMicros,
    required this.sourceReceivedAtMicros,
  });

  final int sourceSentAtMicros;
  final int sinkReceivedAtMicros;
  final int sinkSentAtMicros;
  final int sourceReceivedAtMicros;

  bool get isValid {
    if (sourceReceivedAtMicros <= sourceSentAtMicros) {
      return false;
    }
    if (sinkSentAtMicros < sinkReceivedAtMicros) {
      return false;
    }
    return rttMicros >= 0;
  }

  int get rttMicros {
    return (sourceReceivedAtMicros - sourceSentAtMicros) -
        (sinkSentAtMicros - sinkReceivedAtMicros);
  }

  int get clockOffsetMicros {
    return ((sinkReceivedAtMicros - sourceSentAtMicros) +
            (sinkSentAtMicros - sourceReceivedAtMicros)) ~/
        2;
  }
}

class AudioClockSyncSnapshot {
  const AudioClockSyncSnapshot({
    required this.clockOffsetMicros,
    required this.rttMicros,
    required this.jitterMicros,
    required this.sampleCount,
  });

  static const empty = AudioClockSyncSnapshot(
    clockOffsetMicros: 0,
    rttMicros: 0,
    jitterMicros: 0,
    sampleCount: 0,
  );

  final int clockOffsetMicros;
  final int rttMicros;
  final int jitterMicros;
  final int sampleCount;

  bool get isValid => sampleCount > 0;
}

class AudioClockSyncEstimator {
  AudioClockSyncEstimator({
    this.maxSamples = 12,
    this.maxUsableRttMicros = 100000,
    this.driftToleranceMicros = 20000,
  });

  final int maxSamples;
  final int maxUsableRttMicros;

  /// How far two samples may disagree beyond what their round trips allow
  /// before the clocks count as stepped.
  final int driftToleranceMicros;
  final List<AudioClockSyncSample> _samples = <AudioClockSyncSample>[];

  void addSample(AudioClockSyncSample sample) {
    if (!sample.isValid) {
      return;
    }
    if (sample.rttMicros > maxUsableRttMicros) {
      return;
    }
    // A sample puts the offset within half its round trip of the truth, so
    // two samples of steady clocks never differ by more than half their round
    // trips together. Further apart, a wall clock was set (by the network
    // time service, by hand): the older samples describe clocks that are gone
    // and, with their shorter round trips, would win for a dozen probes while
    // every packet played at the wrong time.
    for (final earlier in _samples) {
      final apart = (sample.clockOffsetMicros - earlier.clockOffsetMicros)
          .abs();
      if (apart >
          (sample.rttMicros + earlier.rttMicros) ~/ 2 + driftToleranceMicros) {
        _samples.clear();
        break;
      }
    }
    _samples.add(sample);
    if (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
  }

  AudioClockSyncSnapshot get snapshot {
    if (_samples.isEmpty) {
      return AudioClockSyncSnapshot.empty;
    }
    var best = _samples.first;
    for (final sample in _samples.skip(1)) {
      if (sample.rttMicros < best.rttMicros) {
        best = sample;
      }
    }
    return AudioClockSyncSnapshot(
      clockOffsetMicros: best.clockOffsetMicros,
      rttMicros: best.rttMicros,
      jitterMicros: _jitterMicros(best.clockOffsetMicros),
      sampleCount: _samples.length,
    );
  }

  int _jitterMicros(int referenceOffsetMicros) {
    if (_samples.length < 2) {
      return 0;
    }
    var total = 0;
    for (final sample in _samples) {
      total += (sample.clockOffsetMicros - referenceOffsetMicros).abs();
    }
    return total ~/ _samples.length;
  }
}
