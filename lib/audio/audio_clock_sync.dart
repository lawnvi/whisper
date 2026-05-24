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
  });

  final int maxSamples;
  final int maxUsableRttMicros;
  final List<AudioClockSyncSample> _samples = <AudioClockSyncSample>[];

  void addSample(AudioClockSyncSample sample) {
    if (!sample.isValid) {
      return;
    }
    if (sample.rttMicros > maxUsableRttMicros) {
      return;
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
