import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS audio capture reports actual sample format to Dart', () {
    final source =
        File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();

    expect(source, contains('"sampleRate": captured.sampleRate'));
    expect(source, contains('"channels": captured.channels'));
    expect(source, isNot(contains('audioCaptureProgress')));
    expect(source, isNot(contains('frameLogCount')));
    expect(source, isNot(contains('WhisperAudioCapture frame session=')));
  });

  test(
      'macOS audio capture duplicates mono buffers instead of leaving right silent',
      () {
    final source =
        File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();

    expect(source, contains('copyInterleavedFloat32'));
    expect(source, contains('sourceChannels == 1 ? 0 : min(channel'));
    expect(source, contains('copyInterleavedInt16'));
  });
}
