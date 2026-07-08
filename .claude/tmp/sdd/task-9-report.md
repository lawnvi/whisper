# Task 9 Report: Android 原生媒体外壳

## 改动文件

- `android/app/src/main/kotlin/com/vireen/whisper/MediaPlaybackService.kt`
  - 新增 `MediaPlaybackService`,提供 `MediaSessionCompat`、`PlaybackStateCompat`、`MediaStyle` 通知和 `mediaPlayback` 前台服务承载。
  - 通知 id 使用 `10023`,channel 使用 `whisper.media_playback`。
  - 支持 `playing`/`paused`/`buffering`/`stopped` 状态;直播流不设置 duration。
  - 新增 `MediaControlReceiver`,把通知 action 转发到 `AudioSharePlugin.dispatchMediaControl()`。
- `android/app/src/main/kotlin/com/vireen/whisper/AudioSharePlugin.kt`
  - `channel` 调整为 `internal lateinit var`。
  - `onAttachedToEngine` 保存 `binding.applicationContext`,并登记 active plugin instance。
  - 新增 `dispatchMediaControl()` 静态分发,通过 channel 回调 `"mediaControl"`。
  - 新增 `updateMediaState` method channel case,启动/停止 `MediaPlaybackService` 并处理 Android 12+ FGS 启动限制。
  - 新增 `AudioFocusRequest`/legacy audio focus 管理,焦点变化回调 `focusPause`、`focusPauseTransient`、`focusResume`。
  - 未改动既有 `startPlayback`、`writePcm`、`stopPlayback` 播放方法体。
- `android/app/src/main/AndroidManifest.xml`
  - 新增 `android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK`。
  - 注册 `.MediaPlaybackService` 并声明 `android:foregroundServiceType="mediaPlayback"`。
  - 注册 `.MediaControlReceiver`。
- `android/app/build.gradle`
  - 新增 `implementation 'androidx.media:media:1.7.0'`。
- `test/android_media_session_source_test.dart`
  - 新增 source test 锚定 MediaSession/MediaStyle/BUFFERING/audio focus/updateMediaState/manifest/gradle 依赖。

## TDD 记录

1. 先新增 `test/android_media_session_source_test.dart`。
2. 运行:
   - `flutter test test/android_media_session_source_test.dart`
   - RED: 退出码 1,`PathNotFoundException`,缺少 `MediaPlaybackService.kt`。
3. 按 brief 实现原生媒体外壳、AudioSharePlugin 挂接、manifest 与 Gradle 依赖。
4. 重新运行 source test 转绿。

## 验证命令与输出摘要

- `flutter test test/android_media_session_source_test.dart`
  - 初始 RED: 退出码 1,缺少 `MediaPlaybackService.kt`。
  - 最终 GREEN: 退出码 0,`All tests passed!`。
- `flutter build apk --debug`
  - 退出码: 0。
  - 输出摘要:`✓ Built build/app/outputs/flutter-apk/app-debug.apk`。
  - `MediaSessionCompat`/`MediaStyle` API 未需要因编译错误调整。
- `flutter analyze`
  - 退出码: 0。
  - 输出摘要:`No issues found!`
- `flutter test`
  - 退出码: 0。
  - 输出摘要:`All tests passed!`,共 506 项通过。
- `dart format --set-exit-if-changed test/android_media_session_source_test.dart`
  - 最终退出码: 0,`Formatted 1 file (0 changed)`。
- `git diff --check`
  - 退出码: 0。

## 自审

- 本任务只做 Android 原生媒体外壳,未实现 Dart 桥,未改 `lib/`。
- `AudioSharePlugin` 只新增字段、方法、method channel case 和生命周期登记;既有裸 `AudioTrack` 播放通路方法体保持不变。
- `updateMediaState == stopped` 会拆服务并 abandon audio focus;播放态请求 audio focus,但请求失败不阻断现有播放路径。
- 通知 action 和 MediaSession callback 均只转发控制意图给 Dart,不在原生侧接管播放引擎。

## Concerns

- 无。
