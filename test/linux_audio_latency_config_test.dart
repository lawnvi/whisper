import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux audio share configures PulseAudio low-latency buffers', () {
    final plugin = File('linux/audio_share_plugin.cc').readAsStringSync();

    expect(plugin, contains('pa_buffer_attr'));
    expect(plugin, contains('LowLatencyPlaybackBufferAttr'));
    expect(plugin, contains('LowLatencyCaptureBufferAttr'));
    expect(plugin, isNot(contains('nullptr, &pulse_error);')));
  });
}
