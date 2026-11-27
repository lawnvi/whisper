# 声音共享：谁负责接着放、按什么时钟

协议 16 起只有组播放：一台来源（`AudioGroupCoordinator` 里 `sourcePeerId` 是本机的那一端）把声音放给一台或多台播放端。本文说明连接出问题之后由谁、在什么时候把声音接回来。代码在 `lib/audio/audio_group_coordinator.dart` 和 `lib/audio/audio_group_recovery.dart`。

## 来源说了算

以前每台播放端自己记着要不要重连（五个标志），断线后发 `sinkJoinRequest`。来源如果还没发现旧连接断了，会把这个请求当成多余的丢掉，那台音箱就一直不响，直到有人重开整个组。现在播放端不再自己重连，只有来源决定：

| 发生了什么 | 来源怎么做 |
| --- | --- |
| 播放端的设备断开（`WsSvrManager` 调 `peerDisconnected`） | 标成失败，记进 `AudioGroupRecovery`；不发任何东西 |
| 那台设备重新连上（`peerConnected`，资料刷新也会调到） | 立刻用新会话号重新 `groupOffer`，重试次数清零；已经在等应答的不重复发 |
| 设备还连着，但媒体通道断了，或 offer 没人应答 | 等 1、3、8 秒各重发一次；用完后等它重新连上 |
| 播放端暂停或断开（收到它的 `groupStop`），或来源这边取消勾选 | 从恢复名单里删掉，不再主动放过去 |
| 收到 `sinkJoinRequest`（那边用户点了继续） | 一律重新 offer，即使来源以为它还在放：先断掉旧的媒体通道 |
| 收到不认识的组的 `sinkJoinRequest` | 回 `groupStop`，那边清掉“可以继续”的状态 |

播放端断线时只停播放、保留 `_sinkRejoinContext`，界面上仍能点继续。

## 交错到达的 offer

播放端暂停或断开后，来源可能已经发出了一个 offer（应答更早的继续，或刚好在重新放）。播放端在暂停后 5 秒内收到同一组的第一个 offer 时回 `groupStop` 拒掉，避免回到“在放但没声音”；超过 5 秒的 offer 是来源那边的人又勾选了它，照常接受。用的是单调时钟，改系统时间不影响。

## 一台准备好就开始

来源在任意一台播放端完成时钟同步（`rttMicros > 0`）后就开始采集，延迟按已同步的那些算。以前要等所有勾选的设备都同步，一台连不上，其余的也都不响。

## 时钟

两种时钟分开用（`lib/audio/audio_clock_sync.dart`）：

- **墙上时钟**（`audioWallClockMicros`）：设备之间传的播放时间、时钟探测的时间戳。安卓原生播放器也拿它和 `System.currentTimeMillis` 比，判断一帧是否过期，所以跨设备的部分不换。
- **单调时钟**（`audioMonotonicMicros`，即 `Timeline.now`，同一进程的各个 isolate 共用同一个起点）：本机算间隔的地方，包括上报节流、健康检查（来源没声音、播放端听不到、播放端断粮）和迟到包统计。以前用墙上时钟，时间往回调多少，上报就停多久。

墙上时钟被调整时（网络对时、手动改），`AudioClockSyncEstimator` 会把旧样本全部丢掉：一个样本给出的偏差离真值不超过它来回时间的一半，所以时钟不变的两个样本相差不会超过两者来回时间之和的一半；超过这个界限再加 20 ms 余量，就说明时钟被调过了。以前旧样本来回时间更短，会在最优样本里留十几次探测，这期间每个包都按错的时间播放。重新 offer 时，那台播放端的估计也会从头算。

## 原生播放器

输出设备变了或没了，三端都由原生播放器自己接回，Dart 不用管：没有输出时丢掉写来的数据，有了再接着放。`writePcm` 仍然只在句柄已不是当前这次播放时返回 1。

- **macOS**（`macos/Runner/AudioSharePlugin.swift`）：插拔耳机、连上 AirPods、换默认输出时 `AVAudioEngine` 会自己停下。每次写入前看 `isRunning`，停了就重新连接节点再启动，最多每秒试一次。以前停下后照样排缓冲区，引擎停着时调 `player.play()` 还会抛异常让应用崩溃。
- **Windows**（`windows/runner/audio_share_plugin.cpp`）：原来就会在默认输出变化或缓冲区不动时重开；现在 `waveOutPrepareHeader`/`waveOutWrite` 失败也关掉句柄，下次写入重开。拔掉的设备在旧句柄上会一直失败。
- **Linux**（`linux/audio_share_plugin.cc`）：耳机之类的切换由 PipeWire/PulseAudio 自己挪流。声音服务重启后旧连接每次写都失败，以前声音就一直没了；现在写失败就释放连接，下次写入时重连，最多每秒一次。重连在锁外做，`pa_simple_new` 等服务器时不会卡住平台线程上的停止。

## 测试

`test/audio_group_coordinator_test.dart` 的“the source alone brings a lost sink back”一组覆盖断开再连上、暂停后不主动放、`sinkJoinRequest` 总被应答、不认识的组回停止；`test/audio_clock_sync_estimator_test.dart` 覆盖时钟被调整后重新估计、网络抖动时不重来。没在真机上测：电脑睡眠醒来后声音自动接回、Wi-Fi 短暂断开、Android 做播放端、播放中手动改系统时间、三端播放中换输出设备、Linux 重启 PipeWire。原生改动只做了编译检查：macOS 真编，Windows 用 zig/mingw（不等于 MSVC `/W4 /WX`），Linux 用 clang 加 PulseAudio 桩头文件查语法。
