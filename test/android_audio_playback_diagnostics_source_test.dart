import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android audio plugin logs playback lifecycle and write counters', () {
    final source = File(
            'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt')
        .readAsStringSync();

    expect(source, contains('import android.util.Log'));
    expect(source, contains('WhisperAudioShare'));
    expect(source, contains('startPlayback session='));
    expect(source, contains('writePcm session='));
    expect(source, contains('stopPlayback session='));
    expect(source, contains('writeCount'));
    expect(source, contains('writeBytes'));
    expect(source, contains('peakLeft'));
    expect(source, contains('peakRight'));
  });
}
