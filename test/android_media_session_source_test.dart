import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio playback exposes a media session shell on android', () {
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MediaPlaybackService.kt',
    ).readAsStringSync();
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt',
    ).readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final gradle = File('android/app/build.gradle').readAsStringSync();

    expect(service, contains('MediaSessionCompat'));
    expect(service, contains('MediaStyle'));
    expect(service, contains('PlaybackStateCompat.STATE_BUFFERING'));
    expect(service, isNot(contains('setDuration'))); // 直播流不设时长

    expect(plugin, contains('AudioFocusRequest'));
    expect(plugin, contains('AUDIOFOCUS_LOSS_TRANSIENT'));
    expect(plugin, contains('"mediaControl"'));
    expect(plugin, contains('"updateMediaState"'));
    // 播放引擎零改动锚定:关键播放逻辑仍在
    expect(plugin, contains('PLAYBACK_CATCH_UP_SPEED'));
    expect(plugin, contains('WRITE_NON_BLOCKING'));

    expect(manifest, contains('android:foregroundServiceType="mediaPlayback"'));
    expect(manifest,
        contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'));
    expect(gradle, contains('androidx.media:media:1.7.0'));
  });
}
