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
    final unified = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'UnifiedForegroundNotification.kt',
    ).readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final gradle = File('android/app/build.gradle').readAsStringSync();

    expect(service, contains('MediaSessionCompat'));
    expect(unified, contains('MediaStyle'));
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
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'),
    );
    expect(gradle, contains('androidx.media:media:1.7.0'));
  });

  test('compact view indices follow the actual action count', () {
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'UnifiedForegroundNotification.kt',
    ).readAsStringSync();

    // M2 回归钉:非播放态只有 disconnect 一个 action,固定两索引
    // (或重复 (0, 0))会把"断开"挤出紧凑视图。索引必须按实际
    // addAction 数量分支,且镜像条件与 addAction 分支一致。
    final start = service.indexOf('val hasPlaybackAction');
    expect(start, greaterThanOrEqualTo(0), reason: '紧凑视图索引需按实际 action 数量分支');
    final styleBlock = service.substring(
      start,
      service.indexOf('builder.setStyle', start),
    );
    expect(
      styleBlock,
      contains('state.state == MediaPlaybackService.STATE_PLAYING'),
    );
    expect(styleBlock, contains('setShowActionsInCompactView(0, 1)'));
    expect(styleBlock, contains('setShowActionsInCompactView(0)'));
    expect(
      service,
      isNot(contains('setShowActionsInCompactView(0, if')),
      reason: '不得回退到与 addAction 分支脱节的内联索引选择',
    );
  });

  test('engine detach clears playback service state and audio focus', () {
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MediaPlaybackService.kt',
    ).readAsStringSync();

    final detachStart = plugin.indexOf('override fun onDetachedFromEngine');
    final detachEnd = plugin.indexOf('override fun onMethodCall', detachStart);
    expect(detachStart, greaterThanOrEqualTo(0));
    expect(detachEnd, greaterThan(detachStart));
    final detach = plugin.substring(detachStart, detachEnd);
    final stopPlayback = detach.indexOf('stopPlayback()');
    final abandonFocus = detach.indexOf('abandonFocus()');
    final stopService = detach.indexOf(
      'MediaPlaybackService.stopForEngineDetach(appContext)',
    );
    expect(stopPlayback, greaterThanOrEqualTo(0));
    expect(abandonFocus, greaterThan(stopPlayback));
    expect(stopService, greaterThan(abandonFocus));

    expect(service, contains('fun stopForEngineDetach(context: Context)'));
    expect(
      service,
      contains('UnifiedForegroundNotification.clearMedia(context)'),
    );
    expect(service, contains('context.stopService(intent)'));

    final stoppedStart = service.indexOf('if (state == STATE_STOPPED)');
    final stoppedEnd = service.indexOf('val title =', stoppedStart);
    final stoppedBranch = service.substring(stoppedStart, stoppedEnd);
    expect(stoppedBranch, contains('beginStopping()'));
    expect(
      stoppedBranch.indexOf('beginStopping()'),
      lessThan(stoppedBranch.indexOf('stopSelf()')),
      reason: '媒体服务退出前必须先拒绝直投，快速重播才能走系统重启',
    );

    final normalStopStart = plugin.indexOf('private fun stopPlayback()');
    final normalStopEnd = plugin.indexOf(
      'private fun writePcmNonBlocking',
      normalStopStart,
    );
    final normalStop = plugin.substring(normalStopStart, normalStopEnd);
    expect(
      normalStop,
      isNot(contains('stopForEngineDetach')),
      reason: '普通播放重建/重连只能重置 AudioTrack，不能误停媒体会话',
    );
  });

  test('transfer-first notification retains media session controls', () {
    final unified = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'UnifiedForegroundNotification.kt',
    ).readAsStringSync();

    final transferStart = unified.indexOf('transfer?.let');
    final mediaOnlyStart = unified.indexOf(
      'media?.let { state ->',
      transferStart,
    );
    expect(transferStart, greaterThanOrEqualTo(0));
    expect(mediaOnlyStart, greaterThan(transferStart));
    final transferBranch = unified.substring(transferStart, mediaOnlyStart);
    expect(transferBranch, contains('media?.let { mediaState ->'));
    expect(
      transferBranch,
      contains('addMediaControls(context, builder, mediaState)'),
      reason: '传输文案优先时仍须保留暂停/恢复、断开和 MediaSession token',
    );
    expect(transferBranch, contains('media == null && supportsLiveUpdates'));
    expect(
      transferBranch,
      contains('builder.setProgress(100, progress, false)'),
    );

    final controlsStart = unified.indexOf('private fun addMediaControls');
    final controlsEnd = unified.indexOf(
      'private fun baseBuilder',
      controlsStart,
    );
    final controls = unified.substring(controlsStart, controlsEnd);
    expect(controls, contains('MediaStyle'));
    expect(controls, contains('.setMediaSession(state.sessionToken)'));
    expect(controls, contains('mediaControlIntent(context, "pause", 1)'));
    expect(controls, contains('mediaControlIntent(context, "disconnect", 3)'));
  });
}
