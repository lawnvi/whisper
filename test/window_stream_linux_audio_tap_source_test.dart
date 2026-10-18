import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Source-level checks for the Linux window-audio tap
// (packages/window_stream_native/linux/capture/audio_tap.cc).
//
// End to end (Linux -> Windows, 2026-10-18), the tap lost about 2.4 % of the
// sound in 40-80 ms pieces when its capture stream was processed on the
// shared PipeWire loop thread: that thread also takes every video frame, and
// at the 5.33 ms graph quantum an app asking for low latency gets, it missed
// cycles (pw-top showed 167 xruns in 38 s), so the viewer kept starving.
void main() {
  final source = File(
    'packages/window_stream_native/linux/capture/audio_tap.cc',
  ).readAsStringSync();

  test('capture stream is processed on the PipeWire data thread', () {
    expect(source, contains('PW_STREAM_FLAG_RT_PROCESS'));
  });

  test('process drains every ready buffer, not one per wakeup', () {
    expect(
      source,
      contains('while (pw_buffer* buffer = pw.stream_dequeue_buffer(stream_))'),
    );
  });

  test('the data thread reads listeners through a locked copy', () {
    expect(source, contains('std::lock_guard<std::mutex> lock(emit_mutex_);'));
    // Listener changes go through SetListener, which refreshes that copy.
    expect(source, isNot(contains('->listeners.erase(capture)')));
    expect(source, isNot(contains('tap->listeners[capture] =')));
    expect(source, contains('SetListener(capture, std::min(mode, 2))'));
  });
}
