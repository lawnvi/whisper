截至 **2026-07-07** 的调研结论：**不要为了“上岛”整体换通知库；Android 16+ Live Updates 自研原生小模块，媒体播放优先用 `audio_service` 做外壳，普通 action 通知继续用 `flutter_local_notifications`。**

**1. Android 16+ Live Updates**

| 候选 | 版本/发版 | 活跃度 | 是否支持场景 | 结论 |
|---|---:|---|---|---|
| `flutter_local_notifications` | `22.0.1`，pub 显示 22 天前；本项目现用 `18.0.1` | 很活跃，7.3k likes / 2.27M downloads | **不支持** `ProgressStyle` / `requestPromotedOngoing` / `canPostPromotedNotifications`。GitHub issue #2773 仍 open，issue 明确说目前只能绕过插件走原生 | **混合**：保留它做普通通知；Live Updates 走原生 Kotlin |
| `live_activities` | `2.4.9`，pub 显示 2 个月前 | 活跃，638 likes / 49.6k downloads | Android 侧是 `RemoteViews`，而官方 Live Updates 要求不能用 custom `RemoteViews`，所以不适合 Android 16 标准 promoted ongoing | **不用** |
| `awesome_notifications` | `0.12.1`，2026-07-01 | 活跃，3.4k likes / 55.5k downloads | 有普通 progress、media、action，但未看到 Android 16 `ProgressStyle` / promoted ongoing 支持 | **不换库**，收益不够，迁移风险高 |
| `flutter_foreground_task` | `8.17.0` 附近 | 活跃 | 管前台服务，不解决 `ProgressStyle`/promoted ongoing；项目已有自研 service | **不用** |

建议：**Android 16+ Live Updates 自研原生模块**。用 `androidx.core:core >= 1.17.0` 的 `NotificationCompat.ProgressStyle` 和 `NotificationCompat.Builder.setRequestPromotedOngoing()`；同时加 `POST_PROMOTED_NOTIFICATIONS`、`canPostPromotedNotifications()` 检查、普通进度通知 fallback。文件传输符合“用户主动、持续、有明确进度”的官方场景；连接请求不符合。

**2. MediaSession + MediaStyle + audio focus**

| 候选 | 版本/发版 | 活跃度 | 是否支持场景 | 结论 |
|---|---:|---|---|---|
| `audio_service` | `0.18.19`，pub 显示 7 天前 | 活跃，1.3k likes | 官方说明是“wrap existing audio code”，可以只做后台播放、媒体通知、锁屏、耳机按钮、MediaSession 外壳；不要求用 `just_audio` | **推荐使用** |
| `audio_session` | `0.2.4`，pub 显示 7 天前 | 活跃，361 likes / 1.08M downloads | 只管 iOS audio session / Android audio focus、ducking、interruption，不负责媒体通知和 MediaSession | **可配合使用**，但不是完整方案 |
| `androidx.media3-session` | stable `1.10.1`，2026-05-12；`1.11.0-alpha01`，2026-06-24 | Google 官方，活跃 | 可以自研 MediaSession，但 Media3 推荐 session 连接 `Player`；我们裸 `AudioTrack` 要么写 Player adapter，要么绕过很多默认能力 | **不建议 v1 自研到底** |
| `just_audio` / `media_kit` | 活跃 | 会接管播放引擎 | 不符合“保留裸 AudioTrack 实时 PCM 播放” | **不用** |

建议：**`audio_service` + 自研 AudioTrack 的混合方案**。Dart 侧实现一个 `AudioHandler`，系统的 play/pause/stop 回调转发到现有 audio coordinator / native `AudioTrack`；播放状态、标题、设备名、是否 live stream 由我们上报。Android manifest 要补 `mediaPlayback` service type 和 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`。`audio_session` 可用于 audio focus，但如果最终播放服务主要在 Kotlin 层，也可以直接用原生 `AudioManager`，减少状态分裂。

**3. 通知 action 按钮 + 点击跳转**

| 候选 | 版本/发版 | 活跃度 | 是否支持场景 | 结论 |
|---|---:|---|---|---|
| `flutter_local_notifications` | 本项目 `18.0.1`；最新 `22.0.1` | 很活跃 | 支持 Android action、`showsUserInterface`、后台 isolate callback、payload、冷启动 `getNotificationAppLaunchDetails()` | **够用** |
| `awesome_notifications` | `0.12.1` | 活跃 | action 能力强，但切库成本高，和现有通知路径重复 | **不换** |

注意点：本项目 manifest 目前没看到 `com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver`，做 action 必须补。`拒绝` 如果要后台直接生效，不能只依赖当前内存里的 `WsSvrManager`，因为通知 action 可能跑在独立 background isolate；要么 action 唤起主界面，要么把“拒绝连接请求”做成可幂等的原生/Dart桥接命令并能定位 pending request。`同意` 建议 `showsUserInterface=true`，进入 app 确认页更稳。

**最终建议**

- **Live Updates：自研 Android 原生小模块**，不要等 Flutter 插件。
- **媒体播放：用 `audio_service` 做系统媒体外壳，播放仍走现有 AudioTrack。**
- **连接请求 action：继续用 `flutter_local_notifications 18.x`，补 action receiver 和路由处理。**
- 不建议引入 `awesome_notifications` 或 `live_activities` 来替代现有通知栈。

主要依据：
[Android Live Updates 官方要求](https://developer.android.com/develop/ui/compose/notifications/live-update)、[Android Progress-centric notifications](https://developer.android.com/about/versions/16/features/progress-centric-notifications)、[`flutter_local_notifications` issue #2773](https://github.com/MaikuB/flutter_local_notifications/issues/2773)、[`audio_service` pub.dev](https://pub.dev/packages/audio_service)、[`audio_session` pub.dev](https://pub.dev/packages/audio_session)、[`live_activities` pub.dev](https://pub.dev/packages/live_activities)、[`awesome_notifications` pub.dev](https://pub.dev/packages/awesome_notifications)。
