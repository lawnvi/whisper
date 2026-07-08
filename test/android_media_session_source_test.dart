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

  test('compact view indices follow the actual action count', () {
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MediaPlaybackService.kt',
    ).readAsStringSync();

    // M2 回归钉:非播放态只有 disconnect 一个 action,固定两索引
    // (或重复 (0, 0))会把"断开"挤出紧凑视图。索引必须按实际
    // addAction 数量分支,且镜像条件与 addAction 分支一致。
    final start = service.indexOf('val hasPlaybackAction');
    expect(start, greaterThanOrEqualTo(0),
        reason: '紧凑视图索引需按实际 action 数量分支');
    final styleBlock =
        service.substring(start, service.indexOf('builder.setStyle', start));
    expect(styleBlock,
        contains('state == STATE_PLAYING || state == STATE_BUFFERING || canResume'));
    expect(styleBlock, contains('setShowActionsInCompactView(0, 1)'));
    expect(styleBlock, contains('setShowActionsInCompactView(0)'));
    expect(
      service,
      isNot(contains('setShowActionsInCompactView(0, if')),
      reason: '不得回退到与 addAction 分支脱节的内联索引选择',
    );
  });
}
