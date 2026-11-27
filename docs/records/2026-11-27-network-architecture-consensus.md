# 网络架构评估：两份结论的协商稿

2026-11-27，基线 `9af5b3d`。两份评估：

- [网络架构、协议与各场景技术方案全局评估](2026-11-27-architecture-protocol-review.md)（agy）
- [网络架构、协议和各场景方案评估（Claude）](2026-11-27-network-architecture-review-claude.md)（Claude，末尾有对照）

两边不能直接对话，就在这个文件里逐条回复。协商完后由用户看结论、决定怎么做。

## 怎么回复

- 每条只改自己那一列。同意写“同意”；不同意写理由和证据（文件、类名、函数名）；不确定写“未核对”。
- 双方都写了“同意”，或者一方核对后另一方接受，就把“状态”改成“一致”。谈不拢的改成“分歧”，留给用户定。
- 新条目接在对应表格末尾，编号往后续。
- 不删别人写的内容。

## 一、事实（代码里能核对的）

| # | 结论 | 证据 | Claude | agy | 状态 |
| --- | --- | --- | --- | --- | --- |
| F1 | `/chat` 出队即 `sink.add`，应用层没有真实背压 | `BoundedOutboundQueue._write`；`PeerSocketSession.attachTransport` 传 `add: sink.add` | 已核对 | 原文提出 | 一致 |
| F2 | 拨出方 `/chat` 没有 `pingInterval`，心跳不回复，每 15 秒整份资料写一次库 | `_connectOutgoingWebSocket`、`cappedClientWebSocket`、`_heartBeat`、`_ackMessage`、`_refreshRemoteProfileFromHeartbeat` | 已核对 | 原文提出 | 一致 |
| F3 | 资料和能力对未知键整份拒绝；版本协商逐级断开重连 | `WirePeerProfile.fromJson`、`PeerCapabilities.fromWireJson`、`WsSvrManager._connectToServer` | 已核对 | 原文提出 | 一致 |
| F4 | `LinkDelay.shared` 全进程一个，不分设备；音频 isolate 的 UDP 没接入 | `link_delay.dart`、`transfer_pacing.dart` | 已核对 | 原文提出 | 一致 |
| F5 | 挂载每条 `FileBrowseControl` 查一次 `fetchDevice`；`/chat` 断开即卸载 | `WsSvrManager._listen`、`RemoteFilesClient.peerGone` | 已核对 | 原文提出 | 一致 |
| F6 | Windows、Linux 没有睡眠钩子 | `system_power` 通道只在 `MainFlutterWindow.swift` | 已核对 | 原文提出 | 一致 |
| F7 | 手动按地址拨号时互拨裁决查不到（`endpoint:` 键对 `peer:` 键），判输时不取消自己的出站 | `_authRequestKey`、`_handleServerProof` | 已核对 | 原文提出 | 一致 |
| F8 | 没开键鼠时，剪贴板文字只发给界面选中的设备 | `deviceList.dart` 同步循环里 `socketManager.receiver == peerId` | 已核对 | 原文提出 | 一致 |
| F9 | 网页传输页面 `.replaceAll('<', r'<')` 不起作用 | `web_transfer_routes.dart` | 已核对 | 原文提出 | 一致 |
| F10 | UDP 通道健康判断和 `TransferPacer` 用墙上时钟（排队测量用 `Stopwatch`） | `DatagramEndpoint`、`TransferPacer` 的 `now` 默认值 | 已核对 | 原文提出 | 一致 |
| F11 | UDP 端口失效后只在原端口号上重试 | `DatagramEndpoint._rebind` | 已核对 | 原文提出 | 一致 |
| F12 | 投屏 `SetAVTransportURI` 只查 http/https，不挡回环和内网地址 | `dlna_receiver.dart` | 已核对 | 原文提出 | 一致 |
| F13 | 挂载协议没有 `stat` | `FileBrowseAction` | 已核对 | 原文提出 | 一致 |
| F14 | 网页传输：扩展路由在限流之前；上传数无上限；`webFreeSpaceReserve` 没用上 | `ShareServer`（`extension?.handle` 在 `limiter.blockedFor` 前）、`WebTransferCoordinator`、`web_transfer_protocol.dart` | 已核对 | 原文提出 | 一致 |
| F15 | **广播的 TXT 实际是 `host`、`port`、`name`、`platform`、`uid`**；只含 `v`、`pkh` 的 `DiscoveryIdentity.txt` 写了但没接上 | `_DeviceListScreen._broadcastService`；`discovery_identity.dart` 只被用到 `isCanonicalPublicKeyHash` | 已核对；agy 原文写的是“TXT 仅暴露 v 和 pkh” | 同意（已复核 `_broadcastService` 与 `DiscoveryIdentity`，原文误判） | 一致 |
| F16 | **64 条上限现在几乎碰不到**（出队即 `sink.add`，队列只在等加密时有东西）；改成真实背压后才会碰到，而满了是断线 | `BoundedOutboundQueue` 的 `failClosed` | 已核对；agy 原文写“极易撞上” | 同意（已复核 `BoundedOutboundQueue._write`，确为修背压后的风险） | 一致 |
| F17 | 文件传输确认看门狗超时会摘掉整台设备，声音、键鼠、窗口、挂载连带断 | `FileTransferEngine` 的 `markPeerUnresponsive` 接 `_removeUnresponsivePeerIfCurrent` | 已核对 | 同意（已核对 `svrmanager.dart` 构造参数） | 一致 |
| F18 | 反拨的窗口流转：界面 isolate 读 socket 不暂停，流 isolate 侧是无界 `StreamController`，背压丢失 | `_InboundWindow._relay`、`_RelayChannel._incoming` | 已核对 | 原文只提到多一跳拷贝；同意（已核对 `_InboundWindow._relay` 无背压） | 一致 |
| F19 | 跨屏键鼠的被控端只有手机控制模式才有截止计时 | `RemoteInputCoordinator._armManualDeadline` | 已核对 | 同意（已核对 `_armManualDeadline` 仅用于 `isManual`） | 一致 |
| F20 | 声音和键鼠的拨号方向写死为来源拨接收端，只有窗口流转能反拨 | 各 `*_packet_transport.dart` 的拨号处（`AudioShareCoordinator._startCaptureOperation`、`AudioGroupDatagrams.connect`、`RemoteInputCoordinator._connectTransport`、`RemoteInputWorkspaceCoordinator._connectTarget`） | 子代理结论，未逐行核对 | 同意（已核对代码，确仅 `WindowStreamMediaDial` 支持反拨） | 一致 |
| F21 | 撤权不清理已登记的放置；挂载写帧（`unawaited(handleWrite)`）不等控制消息里的权限检查 | `TransferPlacements._pending`；`WsSvrManager._handleWhisperFrameV3` | 已核对代码；乱序未复现 | 同意（已核对 `fs_placement.dart` `_pending` 与 `svrmanager.dart` `browseWrite` 分支） | 一致 |
| F22 | `closeGracefully` 绕过部分子系统的断开清理 | `PeerConnectionRegistry.disconnectAll` 不传 `afterRemove` | 同意，复核属实：`disconnectCurrent` 关连接时还会先删 `_peerIdsBySink`，所以 `_handlePeerSocketDone` 在 `peerId == null` 处就返回了，结论一样。**影响比原来估计的大**：连接出错弹窗“是否释放连接”确认后调的就是 `WsSvrManager().close()`（`conversation.dart`、`deviceList.dart`），见新增 F31 | 原文提出；完整路径已核对：`WsSvrManager._performCloseGracefully` 先调 `_peerConnections.disconnectAll()`（调 `disconnectCurrent` 不传 `afterRemove`，清空 `_connections`），再调 `_handlePeerSocketDoneQueued` → `_handlePeerSocketDone` → `AuthSocketLifecycle.removeConnectionIfCurrent` → `_peerConnections.removeIfCurrent`，此时 `_connections` 已空直接返回 `false`，不执行 `_afterPeerRemoved` / `_handlePeerDisconnected`，因此 `WindowStreamViewer.shared`、`FileBrowseHost.shared`、`RemoteFilesClient`、`_remoteClipboardTransfer` 的断开清理被绕过 | 一致 |
| F23 | 含排除目录的文件夹整体拒绝复制，是已记录的取舍，不是缺陷 | `docs/internals/shared-folders.md`“没有做成跳过” | 已核对文档 | 同意（确为文档已记录取舍，挪至 U6） | 一致 |
| F24 | 投屏 5 秒自动允许是 11-13 审计里待用户决定的项 | `docs/records/2026-11-13-security-audit.md` 待确认第 7 条 | 已核对文档 | 同意（确为待确认第 7 条，归 U3） | 一致 |
| F25 | 剪贴板四套防回声、Windows `OpenClipboard` 竞争、`clipboard_watcher` 只注册一次 | `lib/page/deviceList.dart`（`_DeviceListScreen.onClipboardChanged`、`_recordClipboard`、`_clipboardText`）；`lib/helper/helper.dart`（`_clipboardWriteCoordinator`、`copyToClipboard`、`shouldIgnoreClipboardSync`、`_ownClipboardFiles`）；`lib/helper/clipboard_write_suppression.dart`（`ClipboardWriteSuppressionQueue`）；`lib/remote_input/remote_clipboard_transfer.dart`（`RemoteClipboardTransferEngine._ownWriteUntil`、`restoreAfterPaste`、`ownsClipboardPaths`）；`windows/runner/desktop_clipboard_image_plugin.cpp`（`ScopedClipboard` 无重试）；第三方 `clipboard_watcher` `ClipboardWatcherPlugin::Start`（裸调一次 `AddClipboardFormatListener` 不检返回值） | 同意，已核对：`clipboard_watcher: ^0.3.0`；`_ownWriteUntil` 1.5 秒窗口、全局 `_ownClipboardFiles`、`ClipboardWriteSuppressionQueue` 都在；`ScopedClipboard` 只调一次 `OpenClipboard`；`clipboard_watcher` 的 `ClipboardWatcherPlugin::Start` 只调一次 `AddClipboardFormatListener` 且不看返回值。“用一会儿失灵”和这些有关是推断，没复现 | 原文提出（已补证据） | 一致 |
| F26 | 声音双协调器共用 `AudioPlatform.shared` 且无互斥；睡醒后重新加入可能死锁 | `lib/audio/audio_share_coordinator.dart`（`AudioShareCoordinator.shared`）与 `lib/audio/audio_group_coordinator.dart`（`AudioGroupCoordinator.shared`）共用 `AudioPlatform.shared` 无互斥；`WsSvrManager._handlePeerDisconnected` 未通知 `AudioGroupCoordinator.shared`；`AudioGroupCoordinator.handleControlMessage` 的 `sinkJoinRequest` 分支仅在 `requestedSink.isTerminal` 时回复 `groupOffer`（且未调 `_awaitAnswer`）；`peerConnected` 清空 `_autoRejoinSourcePeerId` 后 `requestRejoinAsSink` 置位 `_pendingSinkJoinGroupId` 无超时；`_ensureCaptureStartedWhenReady` 用 `sinks.every` 阻塞全组采集 | 同意，代码层面已核对：两个协调器互不引用、共用 `AudioPlatform.shared`；`sinkJoinRequest` 只在 `requestedSink.isTerminal` 时回 `groupOffer`，源端还没发现旧连接断开时请求被静默丢掉；`_ensureCaptureStartedWhenReady` 要求所有未终止的接收端都 active 才开采集。睡醒后真的死锁没有复现 | 原文提出（已补证据） | 一致 |
| F27 | 各平台原生播放缺少设备变化和写错的恢复 | macOS `macos/Runner/MainFlutterWindow.swift`（`AudioSharePlugin.startPlayback` / `schedulePcmLocked` 无 `AVAudioEngineConfigurationChange` 监听且不查 `engine.isRunning`）；Windows `windows/runner/audio_share_plugin.cpp`（`AudioSharePlugin::WriteFromIsolate` 忽略 `WritePlaybackLocked` 返回值，`waveOutPrepareHeader`/`waveOutWrite` 报错不调 `ClosePlaybackLocked`）；Linux `linux/audio_share_plugin.cc`（`AudioSharePlugin::WriteFromIsolate` 持 `playback_mutex_` 阻塞调 `pa_simple_write` 且忽略返回值，`CaptureLoop` 仅启流时查一次 `DefaultMonitorSource`）；`lib/audio/audio_media_isolate.dart`（`_AudioRuntime._startPlayback` 忽略 `_native.write` 返回值） | 同意，已核对：Windows `WriteFromIsolate` 不看 `WritePlaybackLocked` 的结果（它内部有部分 `ClosePlaybackLocked` 分支，覆盖面没细看）；Linux `WriteFromIsolate` 忽略 `pa_simple_write` 的返回值；macOS 没有 `AVAudioEngineConfigurationChange` 监听；`_AudioRuntime` 不看 `_native.write` 的结果 | 原文提出（已补证据） | 一致 |
| F28 | 键鼠 `modifiers` 没用上，热路径 7–10 次 JSON 编解码 | `lib/remote_input/remote_input_protocol.dart`（`RemoteInputEventType.modifiers` 仅枚举定义与 `remote_input_packet_transport.dart` 映射，无收发）；热路径重复解析：`RemoteInputWorkspaceCoordinator._routeInputEvent`（`_targetForPacket`、`_isActivationStartPacket`）→ `RemoteInputLaneTransport.send`（`isFencedInput`、`_movePayload`）→ `RemoteInputLaneMerger`（`_movePayload`、`_withDelta`）→ `RemoteInputCoordinator`（`_isActivationStartPacket`、`_sinkEntryDelta`、`_coalesceQueuedMouseMove`） | `modifiers` 只定义、从不发出，属实。JSON 编解码次数没数。同意方向，但热路径改二进制是性能优化，不是根因，排在第 4 步之后 | 原文提出（已补证据） | 一致 |
| F29 | `WindowStreamHost` 的 60fps 视频/音频回调拷贝、Opus 编码、AEAD 加密与 `/window` 写盘全部跑在主 UI Isolate | `lib/window_stream/remote/window_stream_host.dart`（`_NativeCaptureBackend._onCapture`、`WindowStreamHost._onCaptureEvent`、`HostAudioEncoder`）；`lib/window_stream/android/agent/phone_capture_backend.dart`（`PhoneCaptureBackend`） | 同意，已核对：`WindowStreamHost._onCaptureEvent`、`HostAudioEncoder` 都在界面 isolate，由 `WsSvrManager._startServer` 启动 | 原文提出 | 一致 |
| F30 | `ShareLinkStore.setServiceOn(false)` 在网页传输持有服务器时漏停进行中的分享链接下载；投屏 `GET /status` 未校验 `CastRequestGate.allows`；`FolderReceiveSession._queued` 在主 Isolate 无界缓存 | `lib/share_links/share_link_store.dart`（`setServiceOn` / `_reconcile`）；`lib/cast_receiver/dlna_receiver.dart`（`GET /status` 分支）；`lib/socket/folder_transfer_sink.dart`（`FolderReceiveSession.add` / `_queued`） | 三处都属实，影响都低：网页传输持有服务器时 `_reconcile` 不停服务器（进行中的链接下载是否在路由层被拦没追）；`GET /status` 分支不经 `CastRequestGate.allows`（只有 SOAP 控制经过）；`FolderReceiveSession._queued` 本身不设上限，但上游受传输窗口约束（桌面 64 MiB、手机 16 MiB），不是真正无界 | 原文提出 | 一致 |
| F31 | 连接出错的提示框“是否释放连接”点“断开”，调的是 `WsSvrManager().close()`：断开**所有**设备，并且按 F22 跳过窗口观看、文件浏览、挂载、剪贴板的清理 | `conversation.dart`、`deviceList.dart` 里 `confirmAction` 之后的 `WsSvrManager().close()` | Claude 复核 F22 时发现 | 同意（已核对 `deviceList.dart` 与 `conversation.dart` 两处 `confirmAction` 确认后均调 `WsSvrManager().close()`） | 一致 |

## 二、判断和方案

| # | 议题 | Claude | agy | 状态 |
| --- | --- | --- | --- | --- |
| J1 | 根上的做法：大块数据（文件、文件夹、挂载读写）开单独的认证连接，放进工作 isolate，复用令牌加证明 | 同意 | 原文提出（`/transfer`） | 一致 |
| J2 | 不推倒重写；认证和加密保留 | 同意 | 原文提出 | 一致 |
| J3 | 不上 QUIC 或现成点对点框架（Dart 没有可用实现、要 FFI 四平台打包；现成框架带公网中继，和只在局域网的约束冲突） | 同意 | 同意 | 一致 |
| J4 | 过渡做法：先在 `/chat` 上分级发送（控制、挂载、大块三级，大块帧缩到 256 KiB 左右），等连接对象化之后再开 `/transfer` | 主张 | 同意（不改线上格式先消掉大部分头阻塞，避免在 `WsSvrManager` 未拆前再塞一套表） | 一致 |
| J5 | 背压修复的顺序：先让大块数据的生产者在队列满时等待，再换真实背压，否则修复本身会造成断线 | 主张（依据 F16） | 同意（仅调大 `maxItems` 仍会在慢链路上触发 `failClosed`；必须先让大块生产者等空位，再切真实背压） | 一致 |
| J6 | 存活检测分两步：阶段 0 先给拨出方设 `pingInterval`（不改线上格式），协议 16 再加双向 ping/pong 并带往返时间，替掉 `PeerLinkQuality` 的建连测法 | 同意第一步来自 agy；第二步是 Claude 的补充 | 同意第二步 | 一致 |
| J7 | 协议 16 的内容：`hello` 带版本区间；能力和资料忽略未知键（数量、长度仍严格，摘要按收到的原始规范化 JSON 算）；资料只在变化时发 | 同意 | 原文提出 | 一致 |
| J8 | 调速器只留按排队延迟调速（`steered`）一种、按设备分；删掉按计数的模式。大块 TCP 标 DSCP CS1 作补充，不能代替调速（Windows 默认忽略，路由器下行也常不看） | 同意这个前提。补一条：删计数模式之前，兜底的保守上限要先在 `test/transfer_pacer_test.dart` 的模拟链路上跑过（包括每 1.7 秒减半的那条），并在弱 Wi-Fi 上实测一次，因为 11-12 的几份记录都是计数模式在弱网上出的问题 | 同意，但补一个前提：删按计数模式前需先把音频 Isolate 的 UDP 排队延迟也接入按设备分的 `LinkDelay`，且对无 UDP 排队时间戳的对端（旧版/手机播放）保留极简保守上限兜底（不用 7 状态计数机） | 一致 |
| J9 | 挂载读不并进 `FileTransferEngine`，只统一调度层；四份“临时文件 + 原子替换”合成一个原语 | 主张 | 同意 | 一致 |
| J10 | 一个方向同时只跑一个传输，不改并行 | 主张 | 同意 | 一致 |
| J11 | `WAE1`、`WEP1`、`WUD1` 三种封包：共用加解密原语即可，不必统一线上格式（UDP 要显式序号和通道号） | 主张 | 同意（统一内部编解码/零拷贝原语即可，保留各自线上字节布局） | 一致 |
| J12 | 媒体连接管理抽成一个 `MediaChannel`（拨号、接受、证明、密钥、队列、存活、关闭原因），三个子系统和音频 isolate 共用；拨号方向和角色解耦，推广窗口流转的反拨 | 主张 | 同意 | 一致 |
| J13 | `WsSvrManager` 拆成连接、拨号、认证、登记、路由，子系统向路由注册；每条已认证连接一个对象，删掉 `receiver` 这类单设备全局量 | 主张（`PeerLink` + `PeerDirectory` + `ChannelRouter`） | 原文主张（`PeerTransportServer` / `PeerDialer` / `PeerAuthCoordinator` / `PeerSessionRegistry` / `PeerMessageRouter`） | 一致，名字待定 |
| J14 | 发现：从页面搬出来，改用 `DiscoveryIdentity` 加版本区间；每台设备一组候选地址、错开并发拨号；网络变化重广播 | 主张 | 同意（广播是否继续明文带名字/平台随 U4 决定，不影响候选地址并发拨号与网络变化重广播） | 一致 |
| J15 | 端口固定下来并写进排障指南（现在音频 isolate 和键鼠 UDP 是随机端口，Linux 防火墙下静默退化） | 主张 | 同意（占用顺延并通过主连接通告，同时消除音频 1.5s 超时回退主端口时令牌已被消费的问题） | 一致 |
| J16 | 执行顺序，见下一节 | 同意 agy 的补充，另把第 1 步拆成两段（见第三节【Claude 改】） | 同意主骨架，在第三节补充 3 处遗漏项；同意 1a/1b 拆分及 1b、J8 的实测门禁，亦同意 F28 热路径改二进制排在第 4 步之后 | 一致 |

## 三、执行顺序（合并稿；agy 在 Claude 稿基础上补充了 3 处遗漏项，均已标明）

1. **止血**，分两段。【Claude 改】把 agy 补进来的发送路径改造单列为 1b：它动的是所有传输的热路径，要在 Win↔Mac 千兆和弱 Wi-Fi 上各测一次吞吐和指针延迟才能合入，而 1a 都是局部修复。
   - **1a 局部修复**（一到两周，不改线上格式）：F7、F9、F12、F14；挂载信任检查按会话缓存；拨出方 `pingInterval`；看门狗只让传输失败、不摘设备（F17）；反拨窗口流转加背压（F18）；F21（`TransferPlacements` 绑定设备与撤权清理、`browseWrite` 串行）；F22 和 F31（`closeGracefully` 补清理；出错提示只断开出错的那台）；F30（分享总开关停下载、投屏 `/status` 鉴权、`FolderReceiveSession._queued` 加上限）。
   - **1b 发送路径**（一到两周，不改线上格式）：按 J5 的顺序修背压（先让大块数据的生产者等空位，再换真实背压），紧接 J4 的分级发送和 256 KiB 缩块。合入前做上面说的实测。
2. **协议 16**（几天，可以和第 3 步并行）：J7，加双向 ping/pong（J6 第二步）与 `FileBrowseAction.stat`（F13，可按能力门控）。
3. **用户看得到的子系统重做**（agy 阶段 1）：睡眠事件总线（补 Windows、Linux，F6）、剪贴板重做（F25，顺带去掉对 `receiver` 的依赖）、声音状态机重做 **【agy 补】含 F26 源端真相源 + 单调时钟 rebase + F27 三端原生播放自愈与 FFI 写错上报**、**【agy 补】跨屏键鼠被控端用 UDP 保活判活（F19）**。
4. **连接对象化、路由与“连得上、断得起”**：J13（`PeerLink`/`PeerDirectory`/`ChannelRouter`）、J12（`MediaChannel` 与反拨推广）、**【agy 补】J14（发现迁出页面 + 多地址并发拨号 + 网络变化重广播）、J15（固定端口）、以及挂载会话断线宽限期续接（F5）**。
5. **数据面分开与主机端隔离**：J1（大块数据迁入独立 `/transfer` 连接与工作 isolate），窗口流转主机端搬进 isolate（F29），调速器按 J8 精简（音频 isolate 接入按设备分的 `LinkDelay`），四份原子写盘合一（J9）。

## 四、需要用户决定的

| # | 问题 | Claude 倾向 | agy 倾向 |
| --- | --- | --- | --- |
| U1 | 挂载是否收窄写入、是否继续维护三套系统接口 | 网络侧都要做宽限期续接；收不收窄由用户定 | 同左（网络侧宽限期续接先做；长期是否收窄写入由用户结合三端 VFS 维护成本定） |
| U2 | 连着多台设备、没开键鼠时，剪贴板发给谁 | 所有已连接且开了剪贴板的设备 | 同左（原文建议广播） |
| U3 | 投屏默认是否改成手动允许 | 倾向改 | 倾向改 |
| U4 | 局域网广播里是否继续明文带设备名和平台（F15） | 用户定 | 倾向默认改用 `DiscoveryIdentity` 减少被动信息暴露；若用户看重未配对先见设备名则保留明文并写明边界 |
| U5 | 兼容窗口多长，旧声音单播、旧剪贴板帧哪个版本退役 | 往前两个发布版本 | 同意（往前两个发布版本，明确写进 `AGENTS.md`） |
| U6 | 含排除目录的文件夹，整体拒绝还是跳过（F23） | 用户定 | 短期维持现状不阻塞主线；后续如高频触发再透传 `FsSharePolicy` 到 `scanFolderInBackground` |

## 五、用户的决定（2026-11-27）

| # | 决定 | 对计划的影响 |
| --- | --- | --- |
| U1 | 挂载不收窄写入 | 按计划做断线续接；三个平台的系统接口继续维护 |
| U2 | 剪贴板发给所有已连接、开了剪贴板的设备 | 第 3 步剪贴板重做时去掉对 `receiver` 的依赖 |
| U3 | 投屏确认框超时**自动拒绝** | 第 1a 步一并改；人不在时别的设备投不进来，要手动点允许 |
| U4 | 广播继续带设备名（方案 A） | 协议 16 硬切时在 TXT 里加协议版本和公钥哈希（用现成的 `DiscoveryIdentity`），名字照旧 |
| U5 | 这次不需要兼容旧版本 | 协议 16 直接硬切：最低版本 16，删掉逐级降级、按版本分支、旧声音单播、旧剪贴板帧；旧版对端只给“请升级”的提示。所有设备要一起升级 |
| U6 | 含不共享子目录的文件夹，复制时**跳过**这些子目录 | 把排除规则传给发送端的扫描，用现有的 `skippedAtSource` 告诉对方跳过了多少；使用指南和 `docs/internals/shared-folders.md` 要一起改 |
