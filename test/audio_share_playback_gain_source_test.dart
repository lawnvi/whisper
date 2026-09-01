import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings exposes shared speaker playback gain configuration', () {
    final settings = File('lib/page/settings.dart').readAsStringSync();

    expect(settings, contains('_audioSharePlaybackGain'));
    expect(settings, contains('audioSharePlaybackGainSetting('));
    expect(settings, contains('_showAudioSharePlaybackGainSheet'));
    expect(settings, contains('showWhisperGlassBottomSheet<void>('));
    expect(settings, contains('WhisperGlassBottomSheet('));
    expect(settings, contains('WhisperSettingsSlider('));
    expect(settings, contains('setAudioSharePlaybackGain'));
    expect(
        settings, contains('AudioShareCoordinator.shared.updatePlaybackGain'));
  });

  test('local settings persists playback gain with safe bounds', () {
    final local = File('lib/helper/local.dart').readAsStringSync();

    expect(local, contains('_audioSharePlaybackGain'));
    expect(local, contains('audioSharePlaybackGain()'));
    expect(local, contains('setAudioSharePlaybackGain'));
    expect(local, contains('clamp(1.0, 3.0)'));
  });
}
