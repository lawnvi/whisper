# Android 通知"上岛"设计(连接请求 / 传输进度 / 播放端媒体化)

日期:2026-07-06
状态:已与产品确认
范围:仅 Android。iOS、macOS、Linux、Windows 一律不动。

## 背景与目标

Whisper 的三类后台状态目前对用户不可见或呈现不佳:

1. **连接请求**只有应用内 Flutter 弹窗(`lib/page/deviceList.dart` 的 `onAuth` → `showConfirmationDialog`),app 非前台时用户完全看不到请求。
2. **文件传输进度**复用"保活前台通知"渲染(`lib/page/conversation.dart` 的 `_syncAndroidKeepAliveService()` → `KeepAliveForegroundService` 的 `setProgress`),且仅在用户开启保活设置时可见。
3. **音频播放端**为裸 `AudioTrack`(`AudioSharePlugin.kt`),无 MediaSession、无 audio focus、无锁屏控件;后台续命依赖 dataSync 保活服务,受 Android 15+ dataSync 前台服务 6 小时/天限时约束。

目标:让这三类状态以 Android 标准方式"上岛"——Android 16+ Live Updates(状态栏 chip / 锁屏卡片,由 OEM 的 Now Bar / 胶囊 / Live Alerts 自动接管)、MediaStyle 媒体卡;Android 15- 优雅降级为经典通知。**质量要求:动效平滑、状态完整自洽、不突兀**(详见各节"状态自洽"与"动效"条目)。

## 已确认的产品决策

| 决策点 | 结论 |
|---|---|
| 范围 | 三块全做(连接请求通知、独立传输进度/Live Updates、播放端 MediaSession) |
| 动效落点 | 通知侧润色为主;**不做**应用内胶囊/浮层 |
| 连接请求交互 | "同意"和"拒绝"都在通知栏一键直接生效;通知正文展示设备名 + IP |
| 播放控制语义 | 暂停 = 断流(停止接收音频包);播放 = 重新加入音频组;直播流不显示进度条 |
| 改动约束 | 播放引擎(AudioTrack / 时钟同步 / 追赶逻辑)零改动;媒体外壳只做状态呈现与控制转发 |

## 技术选型(依据 whisper-intj 2026-07 调研,见同目录 `2026-07-06-android-notification-libs-research.md`)

| 块 | 方案 | 理由 |
|---|---|---|
| 连接请求 | 现有 `flutter_local_notifications` 18.x + 补 `ActionBroadcastReceiver` | 18.x 已支持 action/payload/后台回调,不升级大版本以缩小回归面 |
| Live Updates | **自研原生 Kotlin 小模块**(`androidx.core >= 1.17.0` 的 `NotificationCompat.ProgressStyle` + `setRequestPromotedOngoing`) | 无任何 Flutter 插件支持(`flutter_local_notifications` issue #2773 仍 open);复用项目成熟的自研 platform channel 模式 |
| 播放端媒体外壳 | **自研原生**:MediaSession + MediaStyle + `AudioManager` 焦点 + 小型 `mediaPlayback` 前台服务,嵌入现有 `AudioSharePlugin.kt` | 零新依赖、不动 `main()`/`MainActivity`;`audio_service` 接入面反而更大(main 初始化、Activity 继承、focus 另配) |
| 不引入 | `awesome_notifications`、`live_activities`、`audio_service`、`just_audio`/`media_kit` | 或不支持 ProgressStyle/promoted,或接管播放引擎,或迁移风险高收益低 |

## 总体架构

**状态单一来源**原则:每个状态只在一处呈现;系统通知一律原地更新同一 notification id,绝不删除重发。

```
Dart 层                                原生层 (Kotlin)
─────────────────────────────────────────────────────────────
ConnectionRequestNotifier  ──────────► flutter_local_notifications
  (新,订阅 ISocketEvent.onAuth)          (+ ActionBroadcastReceiver 补进 manifest)

TransferNotificationBridge ──channel─► TransferNotificationPlugin (新)
  (新,订阅 onTransferUpdated/onProgress)  ProgressStyle + promoted ongoing
                                         降级:16+ 岛 → 15- setProgress

AudioSessionBridge ────────channel───► AudioSharePlugin (扩展)
  (新,接 audio_group_coordinator 状态)    + MediaSessionCompat + MediaStyle
                                         + AudioManager 焦点
                                         + MediaPlaybackService (新,mediaPlayback 类型)
```

通知 channel 划分:

| channel | importance | 声音/震动 | 用途 |
|---|---|---|---|
| `whisper.connect_request` | HIGH | 默认提示音 | 连接请求(heads-up) |
| `whisper.transfer` | LOW | 静音 | 传输进度与终态 |
| (MediaStyle 随媒体通知) | LOW | 静音 | 播放状态 |
| `whisper.keep_alive`(现有) | LOW | 静音 | 纯保活,**移除**其上的传输进度与音频文案 |

保活通知降级为纯保活是"状态自洽"的前提:同一状态不在两处显示。`conversation.dart` 中 `_buildAndroidKeepAliveNotification()` 的进度/音频文案逻辑随之删除。

## 组件设计

### 1. 连接请求通知

- **触发**:`ISocketEvent.onAuth`(`lib/socket/svrmanager.dart`)且 app 非前台 → 发通知;前台 → 仅现有 dialog。二者互斥,由同一入口分流。
- **内容**:标题"连接请求",正文含**设备名 + IP**;两个 action:"同意"、"拒绝",均一键直接生效。
- **isolate 路由**:action 回调可能运行在 background isolate(`flutter_local_notifications` 的 `onDidReceiveBackgroundNotificationResponse`)。回调通过 `IsolateNameServer` 注册的端口把 `{requestId, accept|reject}` 发回主 isolate;主 isolate 按 requestId 在 `AuthRequestGate`(`lib/socket/auth_request_gate.dart`,需扩展为携带 requestId 的 pending 表)定位回调并执行。**幂等**:重复点击、已被应用内 dialog 处理过、请求已失效,均安全无副作用。
- **状态自洽**:
  - 请求在别处被处理(应用内 dialog、对方断开、超时)→ 通知自动 cancel;
  - 点击 action 时请求已失效 → 通知原地更新为"请求已过期"(可滑走),不静默消失;
  - 主 isolate 端口不存在(进程已死,pending 必然已失效)→ 同样落"已过期"。
- **依赖**:AndroidManifest 补 `com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver`。

### 2. 传输进度通知(动效重点)

- **聚合**:并发多文件合并为**单条**通知,固定 notification id;文案"N 个文件 · 发送/接收 · 55%",进度按各传输字节数加权汇总。
- **动效细则**:
  - 更新节流 ≤1 次/秒(Dart 侧节流,复用 `onTransferUpdated` 的 `TransferSnapshot`);
  - 聚合进度**单调不回退**——新传输加入时重新加权,但显示值取 `max(上次显示值, 新计算值)` 的收敛策略,避免进度条倒车;
  - `setOnlyAlertOnce(true)` + 静音 channel,更新全程无声无震动;
  - 图标/文案随状态演进(发送/接收/混合、速度、剩余量)。
- **降级链**(同一状态输入,两种渲染):
  1. Android 16+(`Build.VERSION.SDK_INT >= 36`)且 `canPostPromotedNotifications()` → `NotificationCompat.ProgressStyle` + `setRequestPromotedOngoing(true)`(状态栏 chip、锁屏大卡、OEM 岛接管);manifest 声明 `POST_PROMOTED_NOTIFICATIONS`;
  2. 否则 → 经典 `setProgress(100, p, false)`。
- **终态收尾**:同一条通知原地转终态,不闪断、不弹新条:
  - 完成 → 移除进度条,"已完成 · N 个文件",`setOngoing(false)` + `setAutoCancel(true)`,点击进入对应会话;
  - 失败/中断 → "已中断 · 回到应用可恢复"(项目已有可恢复传输),点击进入会话;
  - 全部传输取消 → 直接 cancel 通知。
- **进程保障**:保活服务开启时无额外动作;未开启且从前台发起传输 → 启动跟随传输生命周期的短时 dataSync 前台服务(前台发起,不受后台启动 FGS 限制),传输全部结束即 `stopForeground`。后台无保活时收不到新传输(socket 已死),不存在"后台起 FGS"路径,逻辑闭环。
- **与保活通知的关系**:`startAndroidBackgroundKeepAlive(progress:...)` 的进度参数路径删除,保活通知回归静态文案。

### 3. 播放端媒体外壳

- **挂接点**:`AudioSharePlugin.kt` 的 `startPlayback`/`stopPlayback`(播放生命周期已在此汇聚)。开始播放 → 创建 `MediaSessionCompat` + MediaStyle 通知 + 启动 `MediaPlaybackService`(`foregroundServiceType="mediaPlayback"`);停止 → 释放会话、`stopForeground`。
- **通知内容**:标题 = 来源设备名,副题 = "正在播放系统音频";**不设置时长/进度**(直播流不显示假进度条);action:暂停/播放、断开。
- **控制语义与状态映射**(PlaybackStateCompat):
  - 暂停 → 断流(退出接收),状态 `PAUSED`;
  - 播放 → 重新加入音频组,握手期间状态 **`BUFFERING`**(锁屏控件显示加载而非假装播放),成功后 `PLAYING`;
  - 断开 → 退出音频组并收尾,通知消失;
  - 控制回调经现有 `com.vireen.whisper/audio_share` channel 回 Dart,由 `audio_group_coordinator` 执行加入/退出。
- **焦点策略**(`AudioManager.requestAudioFocus`,USAGE_MEDIA):
  - `AUDIOFOCUS_LOSS_TRANSIENT`(来电等)→ 自动断流置 `PAUSED`,记"待恢复";焦点回来 → 自动重新加入;
  - `AUDIOFOCUS_LOSS`(用户播放其他媒体)→ 断流置 `PAUSED`,**不**自动恢复;
  - `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` → 仅压低音量,不断流。
- **零改动承诺**:`AudioTrack` 写入、时钟同步、追赶/丢帧逻辑不动;外壳只读状态、只转发控制意图。
- **附带收益**:播放期间进程由 mediaPlayback FGS 保障,消除 dataSync 6 小时限时对长时播放的风险。

## 错误处理与降级总表

| 故障 | 行为 |
|---|---|
| promoted 权限被拒 / API < 36 | 落经典进度通知,功能等价 |
| 通知权限(POST_NOTIFICATIONS)被拒 | 三块全部静默降级为现状(应用内呈现),不重试轰炸、不崩溃 |
| action 命中已失效请求 | 通知原地转"已过期" |
| 重新加入音频组失败 | PlaybackState 置 `ERROR` → 通知显示"连接断开",提供"重试"即再走加入流程 |
| 音频焦点请求失败 | 照常播放(与现状一致),不阻塞 |

## 不做清单

- 应用内浮层/胶囊动效;
- OEM 私有 SDK(小米/华为/荣耀/OPPO 任何私有岛接口);
- 聊天消息、剪贴板、通知转发的 ongoing 化;
- 连接请求上岛(一次性事件,不符合 Live Updates 官方场景);
- `flutter_local_notifications` 18.x → 22.x 升级;
- iOS / macOS / Linux / Windows 任何改动。

## 测试与验收

**自动化**(CI 门槛 `flutter analyze` + `flutter test`):
- source-level 测试(项目惯例):连接请求通知触发条件与前后台互斥、isolate 路由与幂等、传输通知降级链分支、媒体外壳状态映射与焦点分支;
- 纯 Dart 单元测试:聚合进度加权与单调收敛、1Hz 节流。

**手测矩阵**(原生行为无法本地自动验证,发布前逐项过):

| 设备 | 验证点 |
|---|---|
| Pixel(Android 16) | 状态栏 chip、锁屏 ProgressStyle 卡、promoted 权限开关两种状态 |
| 三星 One UI 7 | Now Bar 接管媒体卡与进度 |
| 任一 Android 15- 设备 | 经典进度通知降级、媒体通知、连接请求 action |

**验收标准**:
1. app 后台/锁屏时收到连接请求,5 秒内出现 heads-up 通知,同意/拒绝一键生效且幂等;请求他处已处理时通知自动消失。
2. 传输开始即出现独立进度通知(与保活开关无关);Android 16+ 出现状态栏 chip;更新无声、进度不回退、≤1Hz;终态原地转换,点击进入会话。
3. 播放开始后锁屏/通知中心出现媒体卡(无进度条);暂停=断流、播放=重连且中间态为 BUFFERING;来电自动暂停、挂断自动恢复;其他 app 播放音乐则让出且不自动回;连续播放 >6 小时不被系统杀。
4. 保活通知不再显示传输进度与音频文案。
5. 所有新文案经 ARB 三语(zh/en/es)本地化;`flutter analyze`、`flutter test` 通过。

## 残余风险

- promoted ongoing 在部分 OEM 上的实际呈现(chip 样式、Now Bar 映射)不可控,以 AOSP 标准行为为验收基线;
- `targetSdkVersion` 目前跟随 Flutter 默认值,promoted 行为与 targetSdk 的关系需在 Pixel 真机上确认,若需要则显式提升并全量回归;
- 通知 action 的 background isolate 在个别 OEM 深度杀后台下可能延迟,兜底路径(过期态)已覆盖。
