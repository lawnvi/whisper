import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android audio diagnostics use privacy-safe lifecycle counters', () {
    final source = File(
            'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt')
        .readAsStringSync();

    expect(source, contains('NativePrivacyLog.event('));
    expect(source, contains('NativeLogEvent.audioPlaybackStarted'));
    expect(source, contains('NativeLogEvent.audioPlaybackStopped'));
    expect(source, contains('writeCount'));
    expect(source, contains('writeBytes'));
    expect(source, isNot(contains('session=\$sessionId')));
    expect(source, isNot(contains('peakLeft=')));
    expect(source, isNot(contains('peakRight=')));
    expect(source, isNot(contains('NativeLogEvent.audioWriteProgress')));
  });
}
