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
}
