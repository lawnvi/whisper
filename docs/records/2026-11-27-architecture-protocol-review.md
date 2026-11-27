# 2026-11-27 网络架构、协议与各场景技术方案全局评估

- **评估基线**：提交 `9af5b3d`（`v0.0.62` 之后）。
- **评估范围**：网络拓扑、加密与认证协议、传输层与拥塞控制、连接与休眠生命周期、全部核心协作场景（发现/重连、文件与文件夹传输、剪贴板同步、键鼠共享、声音共享、窗口流转、跨设备文件浏览与挂载、分享链接与网页传输、电视投屏、UDP 通道），以及全局 Isolate 边界与代码组织。
- **未验证边界**：本次为基于源码、测试与已有记录的静态架构审计，未执行多机实网压测、Windows/Linux/Android 真机编译与弱网复现；实测数字引用自仓库既有 `docs/records/` 记录。

---

## 摘要与总体判断

Whisper 的**安全底线、数据落盘安全和针对局域网真实痛点的工程探索**非常扎实：
- X25519 + HKDF-SHA256 绑定握手抄本的端到端加密、`AuthTranscript` 的 v15 随机数承诺、`WhisperAead` 的 libsodium FFI 零拷贝加解密、`PreAuthCappedSocket` 认证前限流；
- `VerifiedFilePublisher` 的原子落盘与回滚、`FsProtectedAreas` 对敏感目录与 `.git` 的防护；
- `DatagramEndpoint` / `DatagramLane` 的加密 UDP 通道与 Wi-Fi 网卡防休眠回包、`FolderWritePool` 对小文件并发写入的优化。

但在功能快速扩展的过程中，系统演化出了 **5 个全局性结构病根**，导致多个看似独立的线上问题（休眠唤醒无声、剪贴板用一会儿失灵、传文件时键鼠发飘、单文件膨胀到数千行）不断以局部补丁的方式互相叠加。**不触动这些底层边界，只修单点 bug 很难收敛。**

### 全局评估总览

| 层次 / 场景 | 现行核心方案 | 建议动作 | 核心评价 |
| :--- | :--- | :--- | :--- |
| **加密与认证核心** | X25519 + XChaCha20-Poly1305 + v15 nonce commitment | **保留，局部调整** | 密码学底座稳固；需改单 RTT 版本协商、补全同时互连 tie-breaking |
| **线缆协议与演进** | `WAE1` + `WhisperFrameV3` + `MessageData` 双重 JSON + 严格拒收未知键 | **阶段性重构（v16）** | 每加字段必升版本 + 逐次重连降级；三套重复 AEAD 封包；控制信令帧头冗余严重 |
| **主传输通道与 Isolate** | 单条 `/chat` WebSocket 在主 Isolate 混跑控制、聊天、文件、挂载与部分视频 | **重点重构** | 头阻塞（HoL）、主线程争抢、背压绕过与 1100 行应用层限速的共同源头 |
| **连接与休眠生命周期** | `WsSvrManager` 集中管理 + 仅 macOS `SystemPowerBridge` | **重点重构** | 6904 行上帝对象；断连/关闭通知不对称；Windows/Linux 缺休眠钩子；客户端缺 ping 保活 |
| **文件/文件夹传输与调速** | `FileTransferEngine` + V3 滑窗 + 文件夹流式打包 + `TransferPacer` | **架构拆分 + 通道隔离** | 落盘安全扎实；引擎职责过重（4896 行）；数据面迁出主连接/主 Isolate 可大幅简化调速 |
| **剪贴板同步** | `deviceList.dart` + `clipboard_watcher` + 4 套防回声补丁 + 延迟粘贴 | **重新设计（做减法）** | 6 层碎片 + 1.5s 盲窗误杀 + Windows `OpenClipboard` 自相竞争；应改用系统序列号原子快照 |
| **声音共享** | `AudioShareCoordinator`（旧）+ `AudioGroupCoordinator`（新）+ Audio Isolate | **状态机重构 + 原生补齐** | 恢复权责倒置导致休眠死锁；双协调器无互斥；墙钟跳变致命；macOS/Linux 播放端缺自愈 |
| **键鼠共享与工作区** | `RemoteInputCoordinator` + `RemoteInputWorkspaceCoordinator` + UDP lane | **合并去重 + 热路径优化** | 生命周期归属清晰；但双轨重复、热路径 7–10 次 JSON 编解码、修饰键同步缺失 |
| **窗口流转** | `WindowStreamHost`（主 Isolate）+ `StreamIsolate`（Viewer）+ 原生 FFI | **Host 端迁入 Isolate** | Viewer 端架构优秀；Host 端 60fps 编码/加密与回拨中继压在 UI 线程，断线无恢复 |
| **远程文件浏览与挂载** | 主 WS 帧 `browseData`/`browseWrite` + 三端自研 NFS/FUSE/CloudFiles | **协议补短 + 评估收敛** | 缺 `stat` 引发目录放大、每 RPC 串行查库、三套 VFS 维护面极大（5800+ 行） |
| **分享链接与网页传输** | `ShareServer`（10003 端口）+ `ShareServerExtension` 挂载 `WebTransferRoutes` | **保留，修补具体漏洞** | 整体设计克制干净；需修 `<` 转义笔误、总开关关断漏停、上传 FD 无上限与限流绕过 |
| **电视投屏（DLNA）** | `CastReceiverManager` + `DlnaReceiver` + 独立播放子窗口 | **保留，收紧安全边界** | 全仓模块化最干净的子系统；需封堵回环/内网地址 SSRF、`/status` 暴露与 5 秒自动放行 |

---

## 一、五个全局性结构病根

### 病根 1：控制面与大流量数据面混跑在主 WebSocket 和主 UI Isolate 上
每对已认证设备只有一条主 `/chat` TCP WebSocket，却同时承载：
- 低延迟控制面：认证、心跳、文本/ACK、`AudioGroupControl`、`RemoteInputControl`、`WindowStreamControl`、`FileBrowseControl`；
- 大吞吐数据面：`FileTransferEngine` 单文件/文件夹分块（桌面单帧最大 4 MiB、64 MiB 窗口）、`RemoteFiles` 挂载的 `browseData`/`browseWrite`（并发最高 8 MiB 在途）、剪贴板文件帧、窗口缩略图/图标 Base64。

这直接引发了连锁代价：
1. **三层头阻塞（HoL）**：TCP 丢包重传阻塞控制信令（Windows 还把 `/chat` 缓冲扩到 16 MiB 加剧缓冲膨胀）；`BoundedOutboundQueue.chat` 和 `PeerSocketSession._sendChain` 严格 FIFO 无优先级；`BoundedReceiveQueue` 串行执行每一帧动作，写盘、SQLite `upsertDevice` 或 `fetchDevice` 直接卡住后续控制帧的解密。
2. **主 Isolate 背压形同虚设且存在隐蔽断连悬崖**：
   - `PeerSocketSession.attachTransport` 同时向 `BoundedOutboundQueue.chat` 传入了 `add: sink.add` 与 `addStream: sink.addStream`。而 `BoundedOutboundQueue._write` 只要发现 `_add != null`，就会直接走非阻塞 `sink.add()` 而不等待 `_addStream`。结果 128 MiB 队列上限与 15 秒 `writerTimeout` **无法对真实 TCP 写入施加背压**，也测不出写端假死。
   - 同时，`PeerSocketSession.attachTransport` 把字节上限提高到了 128 MiB，却把 `maxItems` 留在默认值 `64`（`pauseItems = 32`）。当 `TransferPacer` 按 10 ms 切片（~100 帧/秒）或 `RemoteMounts` 并发读写叠加时，极易撞上 64 项上限触发 `onOverflow` 断开整条连接。
3. **主 UI 线程承载过重**：单文件加解密与读写、`WindowStreamHost` 的 60 fps 视频拷贝/Opus 编码/AEAD 加密、`hostDials` 场景下 `_InboundWindow` 把视频帧经 UI 线程中转给 `StreamIsolate`、`RemoteMounts` 所有未命中缓存的块都经主 Isolate 过主 WS、`WebUpload` 纯 Dart SHA-256 与 `ShareZipPlan` CRC-32，都在与 Flutter 渲染和交互抢主线程。
4. **被迫在用户态 TCP 之上造 1100 行限速器**：`TransferPacer` + `TransferSteering` 在应用层对抗 Wi-Fi 缓冲膨胀和主线程卡顿，仍受限于主线程事件循环抖动（空闲 p99 已达 14–30 ms），且 `RemoteMounts`、`ShareServer`、`WebTransfer` 均未纳入限速。

### 病根 2：状态机缺少单一真相源，生命周期与恢复权责倒置
- **音频共享恢复倒置**：正常流程由源端掌控成员集合，但断线后源端收不到 `peerDisconnected` 通知，反而让接收端用 `_sinkRejoinContext`、`_autoRejoinSourcePeerId`、`_autoRejoinAttempts`、`_pendingSinkJoinGroupId`、`_declinedOfferGroupId` 5 个状态位去求源端重连；一旦双方对状态判断错位，直接永久死锁。
- **连接清理与关机路径分裂**：`WsSvrManager._handlePeerDisconnected` 逐一硬编码通知各子系统，却漏掉了 `AudioGroupCoordinator` / `AudioShareCoordinator`；而 `WsSvrManager.closeGracefully` 调用 `PeerConnectionRegistry.disconnectAll()` 时不触发 `afterRemove`，绕过了 `WindowStreamViewer`、`FileBrowseHost`、`RemoteFilesClient`、`RemoteClipboardTransfer` 的断连清理。
- **跨平台休眠与断线检测严重不对称**：只有 macOS 有 `SystemPowerBridge`（`willSleep`/`didWake`）；Windows 缺 `WM_POWERBROADCAST`，Linux 缺 `logind` `PrepareForSleep`。更致命的是，**客户端主动发起的 `/chat` WebSocket 从未设置 `WebSocket.pingInterval`**，仅靠每 15 秒发一次全量 `WirePeerProfile` 心跳，而 `_ackMessage` 又直接忽略 `Heartbeat`——没有应用层回包超时看门狗，导致非 macOS 设备休眠后出现长达数分钟的半开假死连接，同时在线时每 15 秒给每个对端做一次无条件 SQLite `upsertDevice`。
- **墙钟（`DateTime.now()`）渗入实时调度与健康检查**：音频时钟同步、延迟上报节流、`DatagramLane.healthy`、`TransferPacer`/`TransferSteering` 均使用可跳变的墙钟。休眠唤醒或 NTP 回拨会直接让 `AudioGroupPlaybackPipeline._maybeReport` 停止上报、让 `AudioClockSyncEstimator` 死守旧低 RTT 样本 12 秒以上，或让 UDP 通道误判健康状态。

### 病根 3：协议演进僵化与多层重复封装
- **严格拒收未知键锁死演进**：`WirePeerProfile.fromJson`、`PeerCapabilities.fromWireJson`、`AuthEnvelope.fromJson`、`_wireTopologyFromJson` 对任何未知字段直接抛 `FormatException`。每新增一个纯可选元数据或能力位，就必须升一次 `protocolVersion`（已升至 v15）并在 `toWireJson`/`fromWireJson` 手工维护按版本剥离表。
- **O(N) 串行重连降级协商**：`WsSvrManager._connectToServer` 连接旧对端时，不是在 `hello` 里带 `[minVersion, maxVersion]` 一次协商完成，而是从 15 降到 9 **每次建一条全新 TCP + WebSocket 连接试探**，还不缓存结果——连一个 v9 对端最多要连 7 次，每次重连重复试探，并消耗 `SocketAdmissionController` 限流配额。
- **三套重复的 AEAD 封包 + 过重的控制帧头**：主连接 `WAE1`（Tag 在密文后）、媒体 WS `WEP1`（Tag 在密文前）、UDP `WUD1`（带 8B laneId）各自维护一遍头部/nonce/AAD 逻辑。主连接上每条控制消息和聊天文本都要背负 32B `WAE1` + 96B `WhisperFrameV3`（其中 80+ 字节强制全零）+ 16 个数据库列的 `MessageData` JSON + 内层再转义一层 JSON 字符串；`Ack` 还要把整条 `MessageData` 全字段原样回传。
- **双轨并存与遗留协议包袱**：音频有 `AudioShareCoordinator`（1:1）和 `AudioGroupCoordinator`（组播）；键鼠有 `RemoteInputCoordinator`（1:1 + 全部 sink + 手机控制）和 `RemoteInputWorkspaceCoordinator`（多机 source）；`WsSvrManager` 仍保留单对端字段（`_sink`、`receiver`、`_remoteProfile`）与多对端映射并存；`MessageEnum` 保留 `UNKONWN`、`FileSignal`、`TransferControl` 等废枚举。

### 病根 4：中心化上帝对象与逆向依赖网
从 `tool/size_baseline.txt` 可见，全仓已有 37 个文件超限，核心复杂度集中在少数超级文件：
- `lib/socket/svrmanager.dart`（6,904 行）：集 HTTP/WS 服务、拨号与去重、认证状态机、重连调度、休眠钩子、媒体升级令牌签发、消息分发、剪贴板中继及 8+ 子系统接线于一身，维护 25+ 个按不同键索引的可变 Map。
- `lib/socket/file_transfer_engine.dart`（4,896 行）：单文件 V3、文件夹流、多对端队列、数据库入账、看门狗与平滑进度混写，~30 个按 `transferId` 索引的平行 Map。
- `lib/page/deviceList.dart`（4,173 行）：名义上是列表页 Widget，实为**应用真正的根生命周期宿主**——把 mDNS 发现与广播、剪贴板监听与历史、托盘、快捷发送、`AppShutdownCoordinator` 全部绑在 UI 状态树上。
- **45+ 个全局 `.shared` 单例形成双向隐式依赖**：`WsSvrManager._startServer` 启动时再去逐个给 `WindowStreamHost.shared`、`FileBrowseHost.shared`、`RemoteFilesClient`（静态可变字段）等塞回调；UI 层仍有文件直接 import `lib/socket/` 内部类（`device_identity.dart`、`peer_socket_session.dart`、`file_transfer_engine.dart`、`folder_transfer_manifest.dart`）。
- **原生端违背单插件单文件**：`macos/Runner/MainFlutterWindow.swift`（5,190 行）、`linux/remote_input_plugin.cc`（6,676 行）、`windows/runner/remote_input_plugin.cpp`（3,832 行）。

### 病根 5：原生硬件与系统事件生命周期未统一抽象
各端对“设备变更 / 休眠唤醒 / 系统锁竞争”的处理极度不均衡：

| 能力 | macOS | Windows | Linux | Android |
| :--- | :--- | :--- | :--- | :--- |
| **系统休眠/唤醒** | `IORegisterForSystemPower`（完善） | 缺失 `WM_POWERBROADCAST` | 缺失 `logind` `PrepareForSleep` | 前台服务保活，无统一休眠信号 |
| **音频采集** | `SCStream` + 亮屏/3s watchdog | WASAPI loopback 5ms 轮询 + 轮询默认设备 | 阻塞式 `pa_simple`，无设备切换/唤醒恢复 | 不支持 |
| **音频播放** | `AVAudioEngine`，**缺 `ConfigurationChange` 监听**；FFI 写错被忽略 | WinMM `waveOut`，**写失败不关句柄重开**；音频线程轮询 COM | 阻塞式 `pa_simple_write`，**忽略错误且持锁可能卡死 UI** | `AudioTrack`（唯一具备自适应变速追帧），但无 Isolate/UDP |
| **剪贴板监听与读写** | `clipboard_watcher` 轮询 `changeCount`，未暴露给 Dart | `AddClipboardFormatListener` 不检返回值无兜底；**`OpenClipboard` 零重试且自相竞争** | 劫持 `clipboard_watcher` 通道；主线程阻塞读；Wayland 失焦失效 | 仅文本 |
| **键鼠采集/注入** | `CGEventTap` + `IOHIDUserDevice` | Raw Input + LL Hook + `SendInput` + 可选锁屏服务 | X11 `XTest` + Wayland Portal / GNOME 辅助插件 | 手动触控/体感源端 |

---

## 二、网络拓扑、传输层与协议层详细评估

### 1. 现行通道与 Isolate 拓扑

| 通道 | 端口 / 路由 | 传输与封装 | 所在 Isolate | 评价 |
| :--- | :--- | :--- | :--- | :--- |
| 主控制 + 数据通道 | `:10002` `/chat` | TCP + WS + `WAE1` + `WhisperFrameV3` | **主 Isolate** | 职责过载，急需剥离大流量数据 |
| 媒体升级通道（主端口） | `:10002` `/audio`, `/input`, `/window` | 独立 TCP WS + 一次性 Token 挑战证明 + `WEP1` | `/input`、`/window` Host、`/audio` 回退在**主 Isolate**；`/window` Viewer 在 **`StreamIsolate`** | 令牌认证模型优秀；Host 视频与回拨中继应移出主 Isolate |
| 桌面音频独立端口 | `:0` TCP + 同号 UDP | 独立 `HttpServer` + `WebSocketTransformer` + `WUD1` | **Audio Isolate** | 架构方向正确，值得作为独立数据面范本 |
| 键鼠 UDP 通道 | `:0` UDP | `DatagramEndpoint` + `DatagramLane`（`WUD1`） | **主 Isolate** | 解决弱网拖尾有效；仅支持 IPv4 且受主线程抖动影响 |
| 分享链接 & 网页传输 | `:10003` HTTP + `/w/ws` | `ShareLanServerSocket` 明文 HTTP/WS | **主 Isolate** | 按需启停、安全边界清晰；需修若干资源治理缺口 |
| 辅助本地/局域网端口 | NFS `:0` / WoL / DLNA SSDP+HTTP | 本地回环或局域网明文 | NFS 在 `MountWorker` Isolate；其余在主 Isolate | DLNA 与主通道完全解耦，边界清晰 |

### 2. 连接建立与同时互连（Simultaneous Dial）
- `resolveSimultaneousDial`（`lib/socket/dial_tiebreaker.dart`）按 `localUid.compareTo(remoteUid)` 确定胜负，方向正确，但存在两处缺口：
  1. 手动按 IP 或仅按 `pkh` 发起的出站连接在 `_authRequestGate` 中按 `endpoint:<host>:<port>` 登记，收到 `challenge` 得知 `verifiedPeerId` 后未补充 `peer:<uid>` 索引，导致服务端 `_handleServerProof` 查询 `hasOutgoing` 返回 `false` 而跳过仲裁。
  2. 仲裁决定 `acceptIncoming` 时，未主动取消本端在途的出站连接，两路握手仍竞态抢注 `PeerConnectionRegistry`，触发多余的 `superseded` 断连清理抖动。
- `PeerReconnectController`（退避 + 抖动 + 30 秒稳定连接阈值 + 显式抑制原因）设计优良，应作为统一基元保留；需注意 `protocolFailure`/`localFailure` 后的恢复语义以及 `duplicateRequest` 不递增退避的潜在空转。

### 3. 协议层最值得调整的三件事
1. **单 RTT 版本协商**：`hello` 携带 `minVersion` + `maxVersion`，服务端直接选定 `negotiatedVersion` 写入 `challenge` 与抄本，彻底取消 `15..9` 逐次重连循环。
2. **从“严格拒收未知字段”转向“宽容前向兼容”**：在 v16+ 的 `WirePeerProfile` 与 `PeerCapabilities` 中忽略未知可选键（摘要仍按原始规范化 JSON 计算以保证签名覆盖完整），新增元数据或能力标志不再被迫升级主版本号或写剥离逻辑。
3. **收敛 AEAD 封包与控制帧头**：统一 `WAE1`/`WEP1`/`WUD1` 的底层帧封装原语（避免反复分配 nonce/header/AAD 缓冲及多余 `Uint8List.fromList` 拷贝）；为非文件传输消息提供精简控制帧头，逐步淘汰双层转义 JSON、全字段回显 `Ack` 和 `MessageEnum` 历史废项。

---

## 三、各业务场景技术方案逐项评估

### 3.1 设备发现与自动连接
- **现状**：mDNS（`_whisper._tcp`，TXT 仅暴露 `v` 和 `pkh`）+ `DiscoveryEndpointResolver`（优先局域网 IPv4、规避虚拟/代理网卡和 RFC 2544 假 IP）+ `DiscoveryResolveLimiter`。
- **问题**：发现与广播的生命周期全部写在 UI 组件 `lib/page/deviceList.dart` 中，网络发现强耦合界面挂载；且未缓存对端协商后的协议版本。
- **建议**：抽离无头 `DiscoveryCoordinator` 到 `lib/state/`，与 UI 解耦。

### 3.2 文件与文件夹传输 + 传输限速
- **现状**：
  - `VerifiedFilePublisher`（零拷贝独占移动/硬链接、防符号链接穿越、DB 失败回滚）和文件夹流式打包（`FolderManifest` 懒解码 + `FolderWritePool` 小文件并发 + 日志断点续传）是亮点。
  - `FileTransferEngine`（4,896 行）把队列调度、单文件 V3、文件夹流、落盘发布、看门狗全揉在一处，且文件夹不得不通过一系列特判绕过 `IncomingAckClock` 和 `TransferAckWatchdog`；`FolderReceiveSession._queued` 在主 Isolate 无界缓存（磁盘慢时最多滞留整窗 64 MiB）；`FsSharePolicy` 排除列表未传给 `scanFolderInBackground`，导致目录含排除子目录时整目录复制直接失败。
  - `TransferPacer` + `TransferSteering`（~1,100 行，7 种模式、两套控制环）在主 Isolate 上对抗 Wi-Fi 缓冲膨胀，但仍无法解决主线程抖动、无音频排队信号、慢 ACK 设备被彻底放开限速、以及挂载/网页传输绕过限速的问题。
- **建议**：
  - **结构根治**：为批量数据传输开辟独立 TCP 升级通道 `/transfer` 并放进独立数据 Isolate（复用现有 `SessionUpgradeTokenRegistry` 与 `MediaUpgradeServerSession`），将 `FileTransferV3`、文件夹流和 `browseData`/`browseWrite` 全部移出 `/chat` 与主 Isolate。同时给批量 TCP 设低优先级 DSCP（如 `CS1` / 后台流），与高优先级 UDP（`EF` / `VO`）配合，再把 `TransferPacer` 收敛为数据 Isolate 内一套简洁的按排队调速器（探针不受 UI 抖动污染）。
  - **代码拆分**：将 `FileTransferEngine` 拆为队列与持久化协调器、单文件 V3 收发器、文件夹策略适配器，去掉散落全文件的 `if (_isFolderTransfer)` 分支；对 `FolderReceiveSession._queued` 加背压上限。

### 3.3 剪贴板同步（Issue #7 相关）
- **现状**：逻辑分散在 `deviceList.dart`、`helper.dart`、`clipboard_sync.dart`、`RemoteClipboardTransferEngine`、`RemoteClipboardPasteWatch`、`svrmanager.dart` 6 个位置，叠加了 **4 套互不知情的防回声/去重机制**（1.5s `_ownWriteUntil` 盲窗、永不过期的全局 `_ownClipboardFiles`、会话缓存路径检查、2s `ClipboardWriteSuppressionQueue` + `_clipboardText` 字符串对比）。
- **核心缺陷**：
  1. `onClipboardChanged` 与托盘历史 `_recordClipboard()` 并发调用，在 Windows 上直接自相竞争 `OpenClipboard`；且 Windows 原生 `ScopedClipboard` 零重试、`Clipboard.setData` 零重试，瞬时占锁直接丢复制或粘贴失败。
  2. Windows 依赖第三方 `clipboard_watcher 0.3.0`，只裸调一次 `AddClipboardFormatListener` 且不检返回值、无唤醒重挂、无 `GetClipboardSequenceNumber()` 兜底，是“用一会儿失效，重启软件又好一下”的直接诱因。
  3. 1.5s–3s 全局静音窗误杀粘贴后紧接着的正常复制；`sendMessageTo` 未校验返回值就污染 `_clipboardText`；安卓验证码自动写入未设 `suppressWatcher: true`；非键鼠模式下文字只发给当前 UI 选中的单个 `socketManager.receiver`，多设备连接时极易“莫名其妙不同步”。
- **建议（从设计上做减法）**：
  - 废除第三方 `clipboard_watcher`（桌面端）和 4 套启发式防回声补丁，在已有原生插件层统一实现**基于系统版本号的原子快照接口**（Windows 在单次带短重试的 `OpenClipboard` 中一并读取 `GetClipboardSequenceNumber()` + 敏感标记 + 文件/图片/文本；macOS 读取 `NSPasteboard.changeCount`；Linux 使用 selection owner/私有标记，并改为异步非阻塞读取）。
  - Whisper 任意写入剪贴板均走统一入口并记录写后版本号，监听端只凭 `sequence == lastOwnWriteSequence` 精准消回声，**0 ms 误杀**。
  - 从 `deviceList.dart` 拆出独立 `ClipboardSyncCoordinator`，由它统一驱动同步和托盘历史（一次快照两处复用），并明确定义多设备未开键鼠共享时的同步目标语义（建议广播给所有已连接且开启剪贴板权限的设备）。

### 3.4 键鼠共享与多设备工作区
- **现状**：`RemoteInputLifecycle` 对本机键鼠归属与迟到原生启动回滚的设计很干净；UDP 通道 `travel` + `fence` 顺序与丢包补位设计合理。
- **核心缺陷**：
  1. **角色割裂与代码重复**：`RemoteInputWorkspaceCoordinator` 只实现多机 Controller（source），所有被控端（sink）和手机手控仍跑在旧的 `RemoteInputCoordinator` 上，两者重复维护连接、事件订阅、滚动归一化与日志逻辑，且前者直接借用后者的 `platform`。
  2. **热路径 7–10 次 JSON 编解码**：`RemoteInputPacketFrame.payload` 是不透明 JSON，单次鼠标移动在捕获 → 路由 → UDP 封包 → 合并 → 注入路径中被反复 UTF-8 解码、JSON 解析和重新序列化。
  3. **修饰键状态缺少权威同步**：`RemoteInputEventType.modifiers` 已定义但从未启用；工作区跨屏跳转时未向离开的设备补发抬键，切回本机时未清空 `_pressedKeyFrames`，易留幽灵按键。
  4. **无路由工作区不自动重连**：`RemoteInputWorkspaceCoordinator.handlePeerReconnected` 仅在 `_workspaceRoutes.isNotEmpty` 时重发 offer。
- **建议**：将单对单跨屏收敛为 1 目标的工作区，按角色拆分为 `RemoteInputSourceController` 与 `RemoteInputSinkController`；对 `mouseMove`/`mouseButton`/`mouseWheel`/`key` 改用紧凑定长二进制载荷；启用 `modifiers` 状态位图同步，在切换焦点/离开目标时显式释放旧按键。

### 3.5 声音共享（Issue #8 相关）
- **现状**：桌面端通过 `DesktopAudioGroupMedia` + FFI 指针把音频数据面搬入独立 `audio` Isolate，架构方向正确。
- **核心缺陷**：
  1. **双协调器无互斥**：旧 `AudioShareCoordinator`（1:1）与新 `AudioGroupCoordinator`（组播）共用 `AudioPlatform.shared` 却无互斥锁，互相覆盖原生句柄；旧协调器在 `offering` 状态断线永久卡死。
  2. **休眠重连死锁**：源端断线不通知 `AudioGroupCoordinator` 拆 `_fanout`；接收端先重连发 `sinkJoinRequest` 时，源端因旧连接尚未超时认为 `!isTerminal` 直接吞掉请求，或源端已清空会话却不回 `groupStop`；源端响应 `sinkJoinRequest` 漏设 `_awaitAnswer`；`_ensureCaptureStartedWhenReady` 要求 `sinks.every(...)`，一个卡住的 sink 会拖死全组采集。
  3. **墙钟与 FFI 错误处理漏洞**：`AudioGroupPlaybackPipeline._maybeReport` 在墙钟回拨时永久停发报告；`AudioClockSyncEstimator` 在时钟跳变后死守旧低 RTT 样本 12 秒；`_AudioRuntime` 忽略 `_native.write` 返回的失败状态。
  4. **三端原生播放恢复缺失**：macOS 播放端未监听 `AVAudioEngineConfigurationChange`；Windows `WritePlaybackLocked` 写错时不关闭旧 `wave_out_` 重开；Linux 阻塞式 `pa_simple` 无设备切换恢复且 `StopPlayback` 可能被阻塞写死锁主线程；Android 未接入 Isolate 与 UDP。
- **建议（从设计上做减法）**：
  - 将 1:1 音频收敛进 `AudioGroupCoordinator`（或加统一 `AudioLifecycle` 互斥）；**恢复控制权收归源端单一真相源**（成员明确为 `active` / `waitingReconnect` / `pausedBySink`，源端监听 `peerDisconnected`/`peerConnected` 自主重建，砍掉接收端 5 个自动重连标志位与 1 秒 Timer；`sinkJoinRequest` 仅留给用户手动恢复且无条件覆盖旧连接；任意一个 sink 就绪即可开启采集）。
  - 全部调度/上报间隔改用单调时钟，时钟偏移突变超过阈值立即清空旧窗口 rebase。
  - 原生层统一遵循设备生命周期：macOS 监听 `AVAudioEngineConfigurationChange`；Windows 迁移至事件驱动 WASAPI + `IMMNotificationClient`（或至少先在 `waveOut` 写错时立刻 `Close -> Reopen`）；Linux 迁移至异步 `pa_stream` + `pa_context_subscribe`；FFI 写失败向 Isolate 上报。

### 3.6 窗口流转
- **现状**：Viewer 端（`StreamIsolate` + 原生窗口 FFI 零主线程跳数输入路由）和 Android 双路径（ADB 优先自动去重 + 无线调试自启）设计成熟。
- **核心缺陷**：
  1. **Host 端整条 60 fps 媒体管线压在主 UI Isolate**：`WindowStreamHost` 在主线程收原生 H.264/PCM 回调、做字节拷贝、同步 Opus 编码、AEAD 加密并写 WebSocket；Android `PhoneCaptureBackend` 也在主线程泵本地回环 socket。
  2. **`hostDials` 回拨二次中转**：手机作为 Host 反连电脑 Viewer 时，`/window` 连接落在主 Isolate 的 `WsSvrManager`，每帧视频经 `SendPort` 复制进 `StreamIsolate`。
  3. **断线/休眠无流级恢复**：短暂 Wi-Fi 抖动或休眠直接硬关所有远程窗口；图标与缩略图以 Base64 挤占 `/chat` 主通道。
- **建议**：参照 `DesktopAudioGroupMedia` 把 `WindowStreamHost` 的媒体编码/加密/发包搬入独立 Isolate；`hostDials` 直接在 `StreamIsolate` 绑临时端口并通过现有 `transportPort` 告知对端，消除主线程中转；断线后增加短时 `reconnecting` 缓冲而非立即销毁窗口。

### 3.7 跨设备文件浏览与系统挂载
- **现状**：目录共享策略与安全底线（`FsSharePolicy`、`FsProtectedAreas`、符号链接真路径校验）考虑极细；每个挂载独立 `MountWorker` Isolate 防止自死锁。
- **核心缺陷**：
  1. **协议短板放大网络开销**：缺 `stat` RPC 导致 `MountTree.stat` 每 3 秒触发整个父目录分页 `list`（万文件目录 = 20 轮 JSON）；`WsSvrManager._listen` 每条 `FileBrowseControl` 都在串行收包队列里查一次 SQLite `fetchDevice`；`browseData`/`browseWrite` 未走零拷贝 `AuthenticatedPayloadBuffer` 且不受限速约束；非截断写打开（`truncate: false`）会先把整个旧文件在宿主机完整拷贝一份。
  2. **状态与恢复脆弱**：`MountTree._nodes` 的已删除节点永不回收；主 WS 瞬断立刻卸载整个系统盘符，中断系统文件管理器正在进行的操作。
  3. **跨平台维护面过大**：macOS 自研 NFSv3/XDR 服务 + Linux 裸写 FUSE 内核 ABI FFI + Windows C++ WinRT Cloud Files DLL 合计 5,800+ 行，各 OS 的 VFS 怪癖持续渗透进 `MountTree`。
- **建议**：短期补 `stat` RPC、缓存会话级信任状态消除每 RPC 查库、给 `RemoteMounts` 加 10–15 秒断线宽限重挂、清理 `MountTree._nodes`；中期把 `browseData`/`browseWrite` 迁入独立数据通道，并审慎评估是否继续为三个平台各维护一套底层 VFS（例如对超大文件修改限制/引导走文件传输，或评估更统一的协议层收敛）。

### 3.8 局域网分享链接与网页传输
- **现状**：按需启停 `ShareServer`、IP 局域网白名单、防 DNS 重绑定、`Origin` 校验、动态哈希 CSP、流式 ZIP64、零表结构改动复用 `device`/`file_transfer` 表——整体克制且工程质量高。
- **发现的具体缺陷（建议立刻修）**：
  1. `WebTransferRoutes._servePage` 中 `.replaceAll('<', r'<')` 漏写了 `\u003c`，属于无操作，设备名含 `</script>` 可破坏引导 JSON。
  2. `ShareLinkStore.setServiceOn(false)` 在网页传输持有服务器（`_held == true`）时直接返回，未取消正在进行的分享链接下载。
  3. `WebTransferCoordinator._receiveOffer` 对单会话并发 `uploads` 无数量上限，且收到 `offer` 立即打开 `RandomAccessFile`，存在 FD 与 `.part` 文件耗尽风险；`webFreeSpaceReserve` 已定义但未使用。
  4. `ShareServerExtension` 在 `limiter.blockedFor` 之前运行，绕过了速率限制；网页下载 detach 后脱离了 `ShareServer` 的 `stallTimeout` 与停服跟踪；上传 `PUT` 缺分块停滞超时；且 SHA-256 / ZIP CRC-32 在主 Isolate 同步计算。

### 3.9 电视投屏（DLNA）
- **现状**：11 个紧凑文件、无超限文件、与 `WsSvrManager` 零耦合、独立子窗口播放且按需创建/销毁 `libmpv`，是全仓模块化边界最健康的子系统。
- **需收紧的安全与生命周期项**：
  1. `SetAVTransportURI` 未拒绝回环地址（`127.0.0.1`/`localhost`/`::1`）、链路本地地址（`169.254.0.0/16`）及本机 Whisper 端口（如 `10003`），存在经 `libmpv` 触发 SSRF 的风险。
  2. `GET /status` 未校验 `CastRequestGate.allows`，向局域网任意主机暴露设备名与当前播放进度/状态。
  3. `CastRequestGate` 弹窗默认 5 秒倒计时自动允许，无人值守时同局域网主机可自动获得播放与音量控制权。
  4. 启动时只选一次网卡地址，切 Wi-Fi 或休眠唤醒后不重绑 SSDP/HTTP。

### 3.10 UDP 通道（`DatagramEndpoint` / `DatagramLane`）
- **现状**：加密、方向密钥隔离、1024 滑动防重放窗口、Wi-Fi 40 ms 反向防休眠回包和单程排队测量设计非常出色。
- **结构短板**：
  1. 硬编码 IPv4 且要求字面 IP 地址，IPv6-only 或主机名直连退回 TCP。
  2. 网卡变化失活后 `_rebind()` 死循环重绑原随机端口，被占用则永久无法恢复（缺端口重协商）。
  3. `DatagramLane.healthy` 用墙钟；`_inboundFirst` 一次性锁存永不重置，系统休眠导致两机单调钟差超 ±35.7 分钟即回绕损坏 `RoundTrips`。
  4. `LinkDelay.shared` 全局单实例，多设备混连（如一台千兆有线 + 一台拥塞 2.4 GHz Wi-Fi）时慢设备会拖慢给快设备的传输；且音频 Isolate 的 UDP 通道未接入 `LinkDelay`。

---

## 四、分阶段优化与重构路线图

不建议推倒重写，建议按**风险最低、架构杠杆最高**的顺序分四阶段推进：

### 阶段 0：零风险止血与确定性漏洞修复（1–2 周）
直接修掉已实锤的稳定性与安全缺陷，不改主协议：
1. 修复 `BoundedOutboundQueue.chat` 的 `add` 背压绕过，并将 `maxItems` 与 128 MiB / 10 ms 切片匹配调大；为客户端出站 `/chat` WebSocket 补上 `pingInterval`。
2. 修复 `WebTransferRoutes` `<` 转义笔误、`ShareLinkStore.setServiceOn(false)` 停下载、`WebTransfer` 上传数上限/限流/超时，以及 `DlnaReceiver` 的回环地址过滤与 `/status` 鉴权。
3. 修复 `FileBrowseControl` 每条 RPC 查 SQLite（改为会话级缓存信任态）与 `FolderReceiveSession._queued` 无界内存积压。
4. 补齐同时互连 `_authRequestGate` 的 `verifiedPeerId` 索引与输方出站取消。

### 阶段 1：高痛点子系统设计层重塑（做减法，根治 #7 / #8）
1. **统一连接与系统休眠事件总线**：引入带 `peerId` 和 `PeerDisconnectCause` 的 `PeerLifecycleObserver`，修复 `closeGracefully()` 清理缺口；在 Windows（`WM_POWERBROADCAST`）和 Linux（`logind`）接入 `SystemPowerBridge`；把 15 秒全量心跳降频为轻量摘要比对，停掉无条件写 SQLite。
2. **剪贴板同步重构**：在原生插件统一实现“系统序列号 + 原子快照 + 统一写入重试”，删掉桌面端 `clipboard_watcher` 依赖与 4 套防回声补丁，从 `deviceList.dart` 抽离独立 `ClipboardSyncCoordinator`。
3. **声音共享状态机重构 + 原生播放自愈**：收敛双协调器、恢复权责收归源端、单调时钟 + 偏移跳变 rebase、补齐 macOS `AVAudioEngineConfigurationChange` / Windows `waveOut` 写错重开（中期迁 WASAPI） / Linux 异步 `pa_stream`，并把 FFI 写失败透传回 Isolate。

### 阶段 2：控制面与数据面物理隔离 + 上帝对象拆解（核心结构升级）
1. **建立每对端独立 `/transfer` 数据通道与数据 Isolate**：把单文件 V3、文件夹流、远程挂载 `browseData`/`browseWrite` 迁离 `/chat` 与主 Isolate；`TransferPacer` 改为按对端隔离（per-peer `LinkDelay`）并接入音频 Isolate 的排队信号。
2. **将 `WindowStreamHost` 与 `hostDials` 迁入独立媒体 Isolate**，彻底解放 UI 线程；补齐窗口流转短断线 `reconnecting` 状态。
3. **拆解三大超级文件与原生 Runner**：
   - `WsSvrManager` 拆为 `PeerTransportServer` / `PeerDialer` / `PeerAuthCoordinator` / `PeerSessionRegistry` / `PeerMessageRouter`（反转依赖，子系统主动向路由注册，打破双向耦合）；
   - 从 `deviceList.dart` 抽离 `DiscoveryCoordinator` 与 `DesktopLifecycleCoordinator`；
   - `FileTransferEngine` 拆为队列调度、单文件 V3、文件夹适配器；
   - 拆分 `MainFlutterWindow.swift` 及 Linux/Windows 巨型原生插件，清理 UI 对 `lib/socket/` 内部的直接 import。

### 阶段 3：协议 v16+ 演进与长远收敛
1. 协议 v16 引入单 RTT 版本协商（`minVersion`/`maxVersion`）、宽容未知键的能力协商、统一 AEAD 封包原语、`FileBrowseAction.stat`，以及清理遗留单对端和历史废协议字段。
2. 键鼠共享合并单对单与工作区双轨、对热路径移动/按键事件做紧凑二进制编码并启用 `modifiers` 状态同步。
3. UDP 通道支持 IPv6 双栈与失活后动态端口重协商；评估 Android 音频接入 UDP 接收与三端系统挂载 VFS 的长期维护边界。

---

## 五、供并行评审人重点交叉印证的 6 个架构抉择

建议另一位独立评估者重点对照以下 6 个问题，印证结论是否一致：

1. **主连接隔离的粒度**：大文件与远程挂载是直接上独立的 `/transfer` TCP + 数据 Isolate（彻底隔离 HoL 与主线程），还是先在 `/chat` 上做双优先级队列（控制优先于数据）作为过渡？
2. **应用层限速（`TransferPacer`/`TransferSteering`）的去留**：数据面迁出主线程并设 OS DSCP 优先级后，用户态延迟调速器是保留精简版（按对端隔离，专治普通家用 Wi-Fi 路由器无视 DSCP 的缓冲膨胀），还是尝试降级为更轻量的窗口上限控制？
3. **系统挂载（`RemoteMounts`）的投入产出比**：目前 macOS NFSv3 + Linux raw FUSE + Windows C++ CloudFiles 维护面达 5,800+ 行，且 `FsUploads` 对大文件非截断写会整文件复制。应继续补齐 `stat`/宽限重连并打磨三套 VFS，还是收窄挂载写能力（偏只读 + 显式复制）或寻找更统一的跨平台挂载方案？
4. **非键鼠共享时的多设备剪贴板语义**：连着多台设备时，复制文字默认应同步给“所有已连接且允许剪贴板的设备”，还是保持“仅发给当前选中的单个设备”？
5. **协议 v16 的兼容断舍离时机**：是否借 v16 一次性引入单 RTT 版本协商 + 忽略未知能力键，并设定旧版音频 1:1 / 旧版键鼠 1:1 协议的退役版本线？
6. **DLNA 投屏的默认信任策略**：5 秒倒计时自动放行是否应改为默认必须手动点击允许（至少在“记住本网络前”不自动放行）？
