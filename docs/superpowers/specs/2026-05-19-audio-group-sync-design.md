# Audio Group Sync Design

## Goal

把 Whisper 的音频共享从“一台 source 只能推给一个 sink”的一对一模型，升级为“一台 source 可以同时推给多个 sink”的音频组模型。第一版目标是 **准同步扬声器组**：局域网内多台设备可以共同播放同一音频流，支持左/右声道分配，并通过时钟估算、目标播放时间和 jitter buffer 让听感尽量同步。

这不是专业音响系统的最终形态。第一版不追求强同步、低相位误差或极低延迟，但必须从协议和模块边界上为以后升级到更强的同步方案留下空间。

## Why This Matters

当前 `AudioShareCoordinator` 只有一个 runtime state、一个 capture source、一个 playback sink、一个 transport。这个模型适合“临时把手机当扬声器”，但不适合“组成立体声”：

- 如果直接允许多个独立 audio session，会产生多个互不相关的音频流。
- 如果每个 sink 单独采集或编码一次，会让 CPU、带宽、序列号、时间戳和同步控制全部分裂。
- 如果协议不带同步语义，后续从“多设备同播”升级到“同步扬声器组”会接近重写。

因此本设计要求第一版就引入 `AudioGroupSession` / `AudioStream` 概念：**单采集、单时间线、多 sink fanout**。

## Confirmed Scope

- 一个 source 设备可以创建一个 audio group，并把同一音频流推给多个 sink。
- source 端只启动一次系统音频采集。
- source 端只编码一条统一的音频时间线，然后 fanout 到多个 sink。
- 每个 sink 有独立连接、独立状态、独立失败处理。
- 支持 sink 声道角色：`stereo`、`mono`、`left`、`right`。
- 支持轻量同步：时钟偏移估算、网络延迟估算、jitter buffer、目标播放时间。
- 同一台设备同一时刻仍然只允许一个本地 audio group 角色：
  - source 可以服务多个 sinks。
  - sink 同时只能加入一个 source 的 audio group。
  - 不做多 source 混音。
- v1 继续使用 WebSocket 传输音频包，不切 UDP。
- 协议字段和模块边界必须允许未来切换到 UDP/QUIC/RTP 风格传输。

## Non-Goals

- 不做多个 source 同时混音到一个 sink。
- 不做跨公网 relay。
- 不做专业音响级相位同步。
- 不保证所有 Android 机型都能达到稳定低延迟。
- 不做自动发现最优扬声器摆位。
- 不做跨设备环绕声，仅支持基础左右声道角色。
- 不把文件传输、文本消息、键鼠控制混入音频数据通道。

## Approaches Considered

### Option A: Allow Multiple Existing Sessions

直接放开当前 `AudioShareCoordinator` 的“只能一个 session”限制，让 source 同时创建多个一对一 session。

优点是实现最快，UI 和协议改动少。缺点是每个 session 都有自己的状态、transport、时间线和同步判断。它能让多个设备同时响，但不适合立体声；后续要做同步时，仍然需要重新设计 group 和 stream。

结论：不采用。它会制造明显技术债。

### Option B: Audio Group Over Current WebSocket Transport

引入 `AudioGroupSession`，source 只采集和编码一次，再把同一 packet fanout 到多个 sink。控制面仍走现有 chat WebSocket，音频数据面仍走 `/audio` WebSocket。协议带 `groupId`、`streamId`、`sinkId`、`sequence`、`captureTimeMicros`、`targetPlaybackTimeMicros`、`channelRole` 和延迟报告。

优点是可以较快落地，能支持多 sink 和左右声道，同时不会堵死未来升级。缺点是 WebSocket 在抖动、拥塞、队头阻塞方面不如 UDP 类方案，强同步能力有限。

结论：推荐作为第一版。

### Option C: Dedicated Realtime Transport And Drift Correction

在 Option B 的 group/session 模型上，把数据面升级为 UDP/QUIC/RTP 风格传输，加入更强的时钟漂移校正、丢包处理、播放队列控制和平台级低延迟播放能力。

优点是上限更高，适合追求更低延迟、更稳同步。缺点是工程量大，平台差异明显，验证成本高。

结论：作为 Option B 的演进方向，不作为第一版入口。

## Recommended Design

采用 **Option B: Audio Group Over Current WebSocket Transport**。

关键原则：

- **先建 group 模型，不放大旧 session 模型。**
- **采集一次，编码一次，fanout 多份。**
- **同步字段第一版就进协议。**
- **WebSocket 只是当前 transport，不写死到业务模型。**
- **每个 sink 独立失败，不影响 group 内其他 sink。**
- **立体声是 channel role，不是两个互不相关的 session。**

## Core Concepts

### AudioGroupSession

`AudioGroupSession` 表示一次多设备音频共享。

字段建议：

- `groupId`: group 唯一 id。
- `sourcePeerId`: 音频来源设备。
- `streamId`: 音频时间线 id。一个 group 第一版只有一个 stream。
- `format`: codec、采样率、声道数、帧长、码率。
- `state`: `offering`、`connecting`、`active`、`partial`、`stopping`、`stopped`、`failed`。
- `startedAtMicros`: source 本地开始时间。
- `targetLatencyMs`: 目标端到端播放延迟。
- `sinks`: `Map<String, AudioGroupSinkState>`。

### AudioGroupSinkState

每个 sink 独立记录：

- `sinkPeerId`
- `host`
- `port`
- `channelRole`: `stereo`、`mono`、`left`、`right`
- `state`: `offered`、`accepted`、`connecting`、`active`、`lagging`、`failed`、`stopped`
- `sessionId`: transport/session id，可兼容现有音频 session。
- `clockOffsetMicros`: source 时钟到 sink 时钟的估算偏移。
- `rttMicros`: 最近估算往返延迟。
- `jitterMicros`: 最近估算抖动。
- `bufferTargetMicros`: sink 目标缓冲。
- `lastPacketSequence`
- `lastError`

### AudioChannelRole

第一版支持：

- `stereo`: 播放完整双声道。
- `mono`: 将输入混为单声道后播放。
- `left`: 只播放左声道，可选择复制到本机左右输出。
- `right`: 只播放右声道，可选择复制到本机左右输出。

建议第一版 UI 暴露 `stereo`、`left`、`right`，`mono` 可作为兼容或自动降级选项。

## Protocol

### Capabilities

在 `PeerCapabilities` 中新增能力位：

- `audioGroupSourceV1`
- `audioGroupSinkV1`
- `audioSyncClockV1`
- `audioChannelRoleV1`

旧的 `systemAudioSourceV1` 和 `speakerSinkV1` 继续保留，表示基础一对一音频能力。多设备同步入口必须检查新能力位。

### Control Messages

可以扩展现有 `AudioControlMessage`，也可以新增 `AudioGroupControlMessage`。推荐新增 group control，避免把一对一字段继续塞大。

建议 action：

- `groupOffer`: source 邀请一个 sink 加入 group。
- `groupAccept`: sink 接受，返回本端能力、建议 buffer、初始 clock sample。
- `groupReject`: sink 拒绝加入。
- `groupUpdate`: 更新 sink 角色、目标延迟、组状态。
- `groupStop`: source 或 sink 停止。
- `clockProbe`: source 发起时钟探测。
- `clockReport`: sink 返回时钟和播放状态。
- `latencyReport`: sink 周期性上报 buffer、late packet、drop、underrun。
- `error`: 某个 sink 或 group 失败。

核心字段：

- `groupId`
- `streamId`
- `sessionId`
- `sourcePeerId`
- `sinkPeerId`
- `sinkPeerIds`
- `format`
- `transport`
- `path`
- `channelRole`
- `targetLatencyMs`
- `sentAtMicros`
- `receivedAtMicros`
- `sinkClockMicros`
- `playbackCursorMicros`
- `errorMessage`

### Packet Frames

现有 `AudioPacketFrame` 需要升级或新增 `AudioGroupPacketFrame`。

字段建议：

- `magic`: 新 magic，例如 `WSG1`，避免和旧 `WSA1` 混淆。
- `groupId`
- `streamId`
- `sessionId`
- `sourcePeerId`
- `sequence`
- `captureTimeMicros`
- `targetPlaybackTimeMicros`
- `durationMicros`
- `channelMask`
- `payloadLength`
- `payload`

同一 source 对所有 sinks 使用同一个 `sequence` 和 `captureTimeMicros`。source 可以为不同 sink 设置不同 `targetPlaybackTimeMicros`，但默认应使用同一个目标播放时间，方便立体声成组。

## Runtime Architecture

### AudioGroupCoordinator

新增 `AudioGroupCoordinator`，不要把所有 group 逻辑继续塞进 `AudioShareCoordinator`。

职责：

- 创建、更新、停止 audio group。
- 管理 source 角色和 sink 角色。
- 处理 group control message。
- 维护 group 内每个 sink 的状态。
- 与 capture、encoder、fanout、sync estimator、playback scheduler 协作。
- 给 UI 暴露 group 状态。

`AudioShareCoordinator` 可以继续负责旧的一对一入口，或在 UI 层逐步迁移到 group coordinator。第一版可以让“一对一音频共享”也走只有一个 sink 的 group，以减少长期双轨。

### AudioGroupSourcePipeline

source 端 pipeline：

1. `AudioPlatform.startCapture(groupId, format)` 启动一次系统音频采集。
2. `AudioCaptureSource` 输出统一时间线 PCM frame。
3. codec 编码为统一 `AudioGroupPacketFrame` payload。
4. `AudioFanoutTransport` 按 sink 列表发送同一 packet。
5. `AudioSyncEstimator` 根据 sink report 调整 `targetPlaybackTimeMicros` 和 buffer 建议。

第一版可以先共用现有 `AudioCaptureSource`，但需要避免它把 session id 绑定成单个 sink。建议改为 stream/session 抽象，让 capture 只关心 `streamId`。

### AudioFanoutTransport

`AudioFanoutTransport` 管理多个 sink transport。

行为：

- 每个 sink 一个 transport 实例。
- 一个 sink 连接失败，只标记该 sink failed。
- fanout 时不等待慢 sink 阻塞快 sink。
- 发送队列应有上限；慢 sink 超过阈值后丢弃旧包或标记 `lagging`。
- 保留 transport 接口，第一版实现 WebSocket，后续可加 UDP/QUIC。

### AudioGroupPlaybackScheduler

sink 端新增播放调度层，不应直接收到包就 `writePcm`。

职责：

- 解码 packet。
- 根据 `targetPlaybackTimeMicros` 放入 jitter buffer。
- 过早到达的 packet 等待播放窗口。
- 过晚到达的 packet 丢弃或快速追赶。
- 按 `channelRole` 做声道处理。
- 周期性上报 buffer、late、drop、underrun。

第一版目标是听感同步，不追求完美相位一致。建议默认目标缓冲从 120ms 到 200ms 起步，后续由实测调整。

## Sync Model

第一版使用轻量时钟同步：

1. source 周期发送 `clockProbe(sentAtMicros)`。
2. sink 收到时记录 `receivedAtMicros` 和本地 `sinkClockMicros`。
3. sink 回复 `clockReport`，带上收到和回复时间。
4. source 估算 RTT 和 offset。
5. source 为后续 packet 写入 `targetPlaybackTimeMicros`。
6. sink 按本地时钟和 offset 把 packet 排入播放窗口。

这类估算会受系统调度、WebSocket 队头阻塞、平台播放延迟影响。第一版验收标准应是“明显比多个独立 session 更同步，并能组成可接受的左右声道”，不是“专业音响同步”。

## User Experience

### Entry

在已连接设备列表或会话页提供“音频组”入口。

基础流程：

1. 用户选择 source 设备的“共享系统音频”。
2. 弹出已连接且支持 audio group sink 的设备列表。
3. 用户勾选一个或多个 sink。
4. 每个 sink 可设置声道角色：`stereo`、`left`、`right`。
5. 用户点击开始。
6. source 显示 group 状态和每个 sink 的状态。

### Status

需要显示：

- group 是否 active。
- 每个 sink 是否 active、lagging、failed。
- 每个 sink 的 channel role。
- 一个统一停止按钮。
- 单个 sink 的移除按钮。

### Degraded States

当某个 sink 抖动明显：

- UI 显示 `同步不稳定` 或类似状态。
- source 可以继续给其他 sink 播放。
- sink 可被单独移除。

当左右声道其中一侧失败：

- group 进入 `partial`。
- 另一侧继续播放。
- UI 明确提示立体声组不完整。

## Safety And Compatibility

- 多设备音频只保证新版同版本客户端。
- 老客户端仍走旧的一对一音频入口。
- group control 必须只发给显式连接且已认证 peer。
- sink 只能加入自己收到的 group offer，不接受第三方转发。
- stop/error 必须只影响对应 group 或 sink，不误停文件传输、文本、键鼠连接。
- 关闭 app、断开 peer、source capture 失败时必须释放平台音频资源。

## Data Flow

### Start Group

1. UI 选择 sinks 和 channel roles。
2. `AudioGroupCoordinator.createGroup()` 生成 `groupId` 和 `streamId`。
3. source 给每个 sink 发送 `groupOffer`。
4. sink 校验能力和当前本地音频状态。
5. sink 启动 playback scheduler，回复 `groupAccept`。
6. source 收到第一个 accept 后启动 capture pipeline。
7. source 给已 accepted sinks 建立 transport。
8. source fanout packet。

### Packet Playback

1. sink 收到 `AudioGroupPacketFrame`。
2. 校验 group、stream、sequence。
3. 解码 payload。
4. 按 channel role 转换 PCM。
5. 放入 jitter buffer。
6. 到达目标播放时间后写入平台播放。
7. 周期性上报 latency。

### Stop Group

1. source stop：向所有 active sinks 发送 `groupStop`，关闭 capture 和 transports。
2. sink stop：向 source 发送 `groupStop`，source 移除该 sink。
3. peer disconnect：只移除对应 sink；如果本机是 sink，则停止本地 playback。

## Testing Strategy

### Protocol Tests

- `AudioGroupControlMessage` JSON round trip。
- `AudioGroupPacketFrame` binary encode/decode。
- 新 packet magic 不被旧 `AudioPacketFrame` 误解析。
- `channelRole` round trip。
- clock report 字段 round trip。

### Manager Tests

- source 创建 group 后包含多个 sink states。
- sink accept 只影响对应 sink。
- 一个 sink reject 不影响其他 sink。
- 一个 sink stop 后 group 仍 active。
- source stop 会 stop 所有 sink sessions。

### Coordinator Tests

- source 只启动一次 capture。
- 一个 encoded packet fanout 到多个 transports。
- 慢 sink 不阻塞快 sink。
- source 允许一个 group 多个 sinks，但拒绝第二个本地 group。
- sink 已加入一个 group 时拒绝另一个 source。
- 左右声道角色进入 playback scheduler。

### Sync Tests

- clock probe/report 计算 RTT 和 offset。
- target playback time 随 target latency 变化。
- late packet 被丢弃或计数。
- jitter buffer 按 sequence 排序。
- sink latency report 更新 sink 状态为 `lagging`。

### UI/State Tests

- connected peers 可多选为 audio sinks。
- 不支持 audio group sink 的设备不可选。
- Android sink 不显示键鼠控制，但可以显示音频 sink 入口。
- left/right role 可保存到 group state。
- group partial 状态可显示。

### Manual Verification

至少覆盖：

- Mac source -> 两台 Android sinks，同播。
- Mac source -> 两台 Android sinks，一台 left，一台 right。
- 断开其中一台 Android，另一台继续播放。
- 一台 sink 网络不稳定时，另一台不被拖慢。
- source 停止后所有 sinks 停止播放。
- Android sink 正在播放 group 时，拒绝另一个 source 的音频 offer。

## Migration Path To Option C

为了避免 B 到 C 积重难返，第一版必须遵守这些约束：

- UI、state、protocol 使用 group/stream/sink 模型，不暴露 WebSocket 细节。
- transport 通过接口注入，不让 coordinator 依赖 WebSocket 类。
- packet 带同步字段，即使第一版算法简单。
- playback 通过 scheduler，不直接收到包就播放。
- latency report 是协议的一部分，而不是日志。
- source fanout 独立于编码器，后续可替换为 UDP/QUIC sender。

后续升级到 C 时，主要替换：

- `AudioFanoutTransport` 的实现。
- `AudioSyncEstimator` 的算法。
- `AudioGroupPlaybackScheduler` 的漂移校正和平台播放队列。
- 平台低延迟 playback/capture 参数。

不应该重写：

- group/session 数据模型。
- UI 的设备组和声道角色。
- control message 的基本生命周期。
- source 单采集单时间线原则。

## Acceptance Criteria

- 一个 source 可以同时让至少两个 sinks 播放同一音频流。
- source 端只启动一次 capture。
- 两个 sinks 收到相同 stream sequence。
- 用户可以把两个 sinks 配成 left/right。
- 单个 sink 失败不会停止整个 group。
- sink 已加入 group 时会拒绝第二个 source。
- `flutter analyze` 通过。
- `flutter test` 通过。
- 真机验证记录包含 Mac + 两台 Android 的同播和左右声道场景。

## Implementation Notes

建议实施顺序：

1. 协议和测试：`AudioGroupControlMessage`、`AudioGroupPacketFrame`、capabilities。
2. 纯 Dart runtime：`AudioGroupSession`、`AudioGroupSinkState`、manager 状态机。
3. source pipeline：单 capture、单 encode、fanout transports。
4. sink scheduler：jitter buffer、channel role、latency report。
5. UI：多选 sink、声道角色、group 状态。
6. 兼容旧入口：一对一音频共享可映射为单 sink group，或暂时保留旧 path。
7. 真机调参：target latency、buffer、lagging 阈值。

第一阶段不要碰 UDP。先把架构骨架和听感同步跑通，再决定是否进入 Option C。
