import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux builds require PulseAudio development libraries', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    final releaseWorkflow =
        File('.github/workflows/release.yml').readAsStringSync();
    final debScript = File('linux/build_deb.sh').readAsStringSync();

    expect(
      cmake,
      contains('pkg_check_modules(PULSE REQUIRED IMPORTED_TARGET'),
    );
    expect(releaseWorkflow, contains('lld'));
    expect(releaseWorkflow, contains('pkg-config'));
    expect(releaseWorkflow, contains('libpulse-dev'));
    expect(debScript, contains('Depends: libpulse0'));
    expect(debScript, contains('--root-owner-group'));
  });

  test('Ubuntu 26 builds tolerate tray manager deprecation warnings', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();

    expect(cmake, contains('if(TARGET tray_manager_plugin)'));
    expect(cmake, contains('-Wno-deprecated-declarations'));
  });

  test('Linux audio share configures PulseAudio low-latency buffers', () {
    final plugin = File('linux/audio_share_plugin.cc').readAsStringSync();

    expect(plugin, contains('pa_buffer_attr'));
    expect(plugin, contains('LowLatencyPlaybackBufferAttr'));
    expect(plugin, contains('LowLatencyCaptureBufferAttr'));
    expect(plugin, isNot(contains('nullptr, &pulse_error);')));
  });

  test('PulseAudio-only helpers are gated with PulseAudio support', () {
    final plugin = File('linux/audio_share_plugin.cc').readAsStringSync();

    expect(_isInsidePulseAudioBlock(plugin, 'int IntValue('), isTrue);
    expect(_isInsidePulseAudioBlock(plugin, 'struct MainThreadEvent'), isTrue);
    expect(
      _isInsidePulseAudioBlock(plugin, 'gboolean InvokeMainThreadEvent('),
      isTrue,
    );
    expect(_isInsidePulseAudioBlock(plugin, 'int64_t NowMicros('), isTrue);
  });
}

bool _isInsidePulseAudioBlock(String source, String declaration) {
  var pulseAudioDepth = 0;
  var offset = 0;
  for (final line in source.split('\n')) {
    if (offset >= source.indexOf(declaration)) {
      return pulseAudioDepth > 0;
    }

    final trimmed = line.trim();
    if (trimmed == '#if HAVE_PULSE_AUDIO') {
      pulseAudioDepth++;
    } else if (trimmed == '#endif' && pulseAudioDepth > 0) {
      pulseAudioDepth--;
    }
    offset += line.length + 1;
  }

  return false;
}
