import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android audio playback only requests low latency mode on API 26+', () {
    final source = File(
            'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt')
        .readAsStringSync();

    expect(source, contains('import android.os.Build'));
    expect(source, contains('Build.VERSION.SDK_INT >= Build.VERSION_CODES.O'));

    final performanceMode = RegExp(
      r'if \(Build\.VERSION\.SDK_INT >= Build\.VERSION_CODES\.O\) \{[\s\S]*?setPerformanceMode\(AudioTrack\.PERFORMANCE_MODE_LOW_LATENCY\)',
    );
    expect(performanceMode.hasMatch(source), isTrue);
  });

  test('Android audio playback does not force a 200ms output buffer', () {
    final source = File(
            'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt')
        .readAsStringSync();

    expect(source, contains('targetBufferSize'));
    expect(source, contains('sampleRate * activeChannels * 2 / 20'));
    expect(source, isNot(contains('sampleRate * activeChannels * 2 / 5')));
  });

  test('Android audio playback adapts speed when native queue drifts', () {
    final source = File(
            'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt')
        .readAsStringSync();

    expect(source, contains('import android.media.PlaybackParams'));
    expect(source, contains('playbackHeadPosition'));
    expect(source, contains('writtenFrames'));
    expect(source, contains('nativeQueuedMicros'));
    expect(source, contains('updatePlaybackSpeed'));
    expect(source, contains('PLAYBACK_CATCH_UP_SPEED'));
    expect(source, contains('PLAYBACK_NORMAL_SPEED'));
  });

  test('Android audio playback drops stale frames and hard-resyncs backlog',
      () {
    final source = File(
            'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt')
        .readAsStringSync();

    expect(source, contains('targetPlaybackTimeMicros'));
    expect(source, contains('PLAYBACK_STALE_DROP_TOLERANCE_MICROS'));
    expect(
      source,
      contains('PLAYBACK_STALE_DROP_TOLERANCE_MICROS = 80_000L'),
    );
    expect(source, contains('PLAYBACK_RESYNC_QUEUE_MICROS'));
    expect(source, contains('PLAYBACK_RESYNC_QUEUE_MICROS = 220_000L'));
    expect(source, contains('isStaleFrame'));
    expect(source, contains('resyncPlaybackQueue'));
    expect(source, contains('droppedStaleCount'));
    expect(source, contains('.flush()'));
  });
}
