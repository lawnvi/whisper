# `/chat` 出站背压、三级调度与缩帧

`/chat` 这条主 WebSocket 连接承载所有控制消息、聊天文字、文件与文件夹传输、剪贴板和远程文件挂载。过去它只有单条先进先出队列、旁路直写 `sink.add` 且大文件单帧 4 MiB，大文件传输时会把控制消息和挂载读写堵在后面，甚至在弱网下因积压或写超时误断。本文说明改造后的出站路径、防死锁边界和实测结果。

## 为什么过去没有背压

`web_socket_channel` 的 `IOWebSocketChannel` 内部用同步 `WebSocket.add` 抽干 `sink.addStream`，因此不论调用 `sink.add` 还是 `sink.addStream`，都无法感知内核 TCP 发送缓冲是否已满。过去 `PeerSocketSession.attachTransport` 还显式传入了 `add: sink.add`，整个窗口的 `fileData` 会瞬间灌进 Dart 运行时和内核缓冲。

改造后，`/chat` 拨出方与服务端升级统一改用 `lib/socket/backpressure_web_socket.dart` 里的 `BackpressureWebSocketChannel` 和 `upgradeChatWebSocket`，直接包装 `dart:io` 的 `WebSocket`：

- `sink.addStream` 直通 `WebSocket.addStream`，内核发送缓冲打满时会真正挂起写循环。
- 保留原有的全部认证前安全边界：拒收 `Origin`（403）、拒收 `Sec-WebSocket-Protocol`（400）、关闭 WebSocket 压缩与扩展、校验 RFC 6455 握手头与 16 字节 `Sec-WebSocket-Key`、复用 `PreAuthCappedSocket` 的 1 MiB 认证前字节上限和 `SocketAdmissionController` 租约，并设置 `pingInterval`。
- `dart:io` 的 `WebSocket.close()` 在 `addStream` 进行中会抛 `StateError`。`BackpressureWebSocketChannel` 持有底层 `Socket` 引用，写卡住时调用 `close()` 会直接 `destroy()` 底层套接字，让 `addStream` 与 `disconnectPeer` 立刻返回。
- 媒体连接（`/audio`、`/input`、`/window`）保持原样不动。

## 防全双工死锁与队列准入

有了真实背压后，一旦两端同时打满发送与接收缓冲，如果任何入站回调（运行在 `BoundedReceiveQueue` 内）反过来等待出站空位或等 socket 写完，就会形成环形等待死锁。为此拆成两层隔离：

1. **大块发送移出入站处理链**：`FileTransferEngine` 处理 `fileReady`/`fileAck` 时只更新状态与窗口边界（并同步续期 `TransferAckWatchdog`），随后通过 `lib/socket/outgoing_window_pump.dart` 的 `OutgoingWindowPump` 唤醒按传输串行执行的后台发送循环，把限速等待、读盘和等队列空位全部移出 `BoundedReceiveQueue`。
2. **控制消息入队即返回，大块与挂载满时等待**：`BoundedOutboundQueue.chat`（`lib/socket/bounded_outbound_queue.dart`）提供 `enqueueControlLazy` 与 `enqueueWhenSpaceAvailable`：
   - 控制帧经 `enqueueControlLazy` 入队，准入通过即同步返回 `true`，绝不在入站链里等 socket 写出；超限时仍 `failClosed` 触发断开。
   - 挂载与大块帧经 `enqueueWhenSpaceAvailable` 入队，满时挂起等待空位而不触发 `onOverflow`；连接关闭或 `abort()` 时立刻以 `false` 唤醒全部等待者。

## 三级优先级调度与延迟加密

`lib/socket/outbound_frame_class.dart` 的 `classifyOutboundFrame` 直接读取 `WhisperFrameV3` 固定头部第 5 字节的类型码对出站帧分级（不解析 JSON、不额外拷贝），由 `BoundedOutboundQueue.chat` 按三级独立限额排队；每级内部严格 FIFO，出队严格按 Tier 0 → Tier 1 → Tier 2 在帧边界超车：

| 层级 | 帧类型 | 独立限额 | 满时行为 |
| --- | --- | --- | --- |
| Tier 0（控制） | `message`（全部 `MessageEnum`）、`fileOffer`/`fileReady`/`fileAck`/`fileComplete`/`fileCancel`/`fileError`、`clipboardOffer`/`clipboardRequest`/`clipboardClear`/`clipboardError` | 512 条 / 32 MiB | `failClosed` |
| Tier 1（挂载） | `browseData`、`browseWrite` | 16 条 / 8 MiB | 等待空位 |
| Tier 2（大块） | `fileData`、`clipboardData`、`clipboardComplete` | 8 条 / 2 MiB | 等待空位 |

所有认证后出站项均以延迟回调进入队列，直到 `_pump()` 真正出队写入 socket 的那一刻才调用 `PeerSocketSession.encodeOutgoing` / `encodeOutgoingBuffer` 做 XChaCha20-Poly1305 加密，因此即便控制或挂载帧跨级超车，线上 AEAD 密文序号依然严格单调递增，且队列里不会提前囤积大量密文缓冲。

顺序约束：`fetch` 回复与 `fileOffer` 同在 Tier 0 FIFO；`clipboardComplete` 与 `clipboardData` 同在 Tier 2 FIFO；`fileCancel`/`fileError` 在 Tier 0 超车后，接收端 `WireInputPolicy.validateFileData` 对终态后的迟到 `fileData` 会静默忽略而不断线。传输卡住、取消、失败或重发 `fileOffer` 前，`OutgoingWindowPump` 会递增该传输的尝试代际并调用 `BoundedOutboundQueue.dropInvalid()` 清除 Tier 2 里遗留的旧 `fileData` 并唤醒等待者，出队前也会再次校验代际，防止重试的 `fileOffer` 超车旧 `fileData` 导致接收端序号失配断开连接。

## 写超时、低水位与缩帧

- **按体积自适应写超时**：`BoundedOutboundQueue.chat` 在 `PeerSocketSession.attachTransport` 中配置 `writerTimeout = 30s`、`minWriteBytesPerSecond = 16 KiB/s`、`maxWriterTimeout = 120s`，单项写出上限为 `clamp(30s + ceil(bytes / 16 KiB/s), 30s, 120s)`。在 20 KB/s 弱网上，1 MiB `browseData`（约 52 s）和 512 KiB `fileData`（约 26 s）都不会被误判假死；对端真正断网时，双向 `pingInterval`（45 s）会先关闭 WebSocket 立即打断阻塞中的 `addStream`。
- **低水位（`TCP_NOTSENT_LOWAT`）**：`lib/socket/no_delay_socket.dart` 的 `tuneChatSocket` 仅针对 `/chat` 套接字调用 `widenTransferBuffers` 并在 macOS/Linux/Android 上尽力设置 `TCP_NOTSENT_LOWAT = 256 KiB`，限制网络瓶颈时内核未发缓冲中的不可超车积压。Windows 没有 `TCP_NOTSENT_LOWAT`，保留独立的发送/接收缓冲常量待真机对比。
- **发射帧上限（512 KiB）**：`lib/socket/file_transfer_v3.dart` 保持协商流控参数 `fileTransferV3FramePayloadSize`（4 MiB）与 `isValidFileTransferV3FlowParameters` 不变以兼容现有对端，另增 `fileTransferV3EmitFramePayloadSize = 512 KiB`，由 `FileTransferEngine._sendFileTransferV3Window` 限制实际发出的每帧 `fileData` 载荷不超过 `min(flow.chunkSize, 512 KiB)`。`browseData` 仍维持 1 MiB 一请求一帧，避免拆成多次串行 RTT。
- **与 `TransferPacer` 的配合**：`TransferPacer` 继续负责在键鼠或声音活动时把链路队列压在 10 ms 切片内，并在无实时媒体时把在途未确认量控制在两秒链路量内；改造后，这两秒在途量中只有当前一帧（≤512 KiB）、内核少量未发缓冲与链路/对端接收缓冲不可超车，其余全部停在应用层等待队列，控制与挂载消息在下一帧边界即可发出。

## 本机实测数据

使用 `test/manual/outbound_scheduling_peer.dart` 在同一台 Mac 上起双进程走局域网 IP（512 MiB 文件，启用原生 sodium AEAD 与原生 SHA-256），并用 `tool/cpu_profile.dart` 在单向传输期间采样接收端主 isolate 3 秒（1000 us 间隔）：

| 方案 | 单向 A→B | 单向文字 RTT (p50/p95/max) | 单向挂载 1 MiB 读 RTT (p50/p95/max) | 双向 A→B / B→A | 双向文字 RTT (p50/p95/max) | 接收端主 isolate CPU 采样 |
| --- | --- | --- | --- | --- | --- | --- |
| 改前基线（4 MiB，无背压单队列） | 260.3 MiB/s | 174.4 / 282.3 / 306.9 ms | 52.9 / 232.5 / 232.5 ms | 156.6 / 156.7 MiB/s | 299.5 / 346.8 / 385.1 ms | 1006 样本 (~51.1%) |
| 改后（仅背压+三级调度，4 MiB） | 232.2 MiB/s | 47.5 / 93.6 / 135.8 ms | 74.6 / 149.4 / 149.4 ms | 166.8 / 169.6 MiB/s | 75.8 / 152.7 / 164.3 ms | 1052 样本 (~47.6%) |
| 改后 + 1 MiB 上限 | 257.5 MiB/s | 11.9 / 53.9 / 55.2 ms | 18.1 / 55.9 / 55.9 ms | 153.9 / 182.8 MiB/s | 27.6 / 238.2 / 290.6 ms | 1046 样本 (~52.6%) |
| **改后 + 512 KiB 上限（采用）** | **243.0 MiB/s** | **12.4 / 53.2 / 59.8 ms** | **17.6 / 59.0 / 59.0 ms** | **155.3 / 190.7 MiB/s** | **22.4 / 74.6 / 90.5 ms** | **1103 样本 (~52.3%)** |
| 改后 + 256 KiB 上限 | 207.2 MiB/s | 9.4 / 18.3 / 24.3 ms | 12.0 / 22.6 / 22.6 ms | 133.7 / 162.0 MiB/s | 106.1 / 127.7 / 129.0 ms | 1335 样本 (~54.0%) |

256 KiB 在高吞吐本机链路上带来 16 倍帧派发开销，导致单向吞吐下降约 20%、接收端 CPU 采样上升约 33%，双向互传下事件循环更忙反而抬高了双向文字 RTT；512 KiB 在保持约 243 MiB/s 单向吞吐、双向总吞吐高于基线且接收端 CPU 基本持平的同时，将单向与双向文字 RTT p50 降低一个数量级、挂载读 p95 降低约 4 倍，因此作为默认发射上限。

## 自动化测试

- `test/bounded_outbound_queue_test.dart`：三级优先级出队顺序、延迟生产器在出队瞬间执行（序号单调）、挂载与大块独立等待限额、断开立刻唤醒等待者、按体积缩放写超时。
- `test/outbound_backpressure_integration_test.dart`：真实 socket 上阻塞期间 `disconnectPeer` 1 秒内返回、双向慢链路并发大文件+挂载读+文字不死锁、慢链路下文字与挂载读超车队列中的大文件数据。
- `test/socket_server_lifecycle_test.dart`：直通 `/chat` 升级的 `Origin`/`Sec-WebSocket-Protocol` 拒绝、认证前字节上限、以及 `addStream` 阻塞时直接关闭套接字。

## 未验证项

以下场景受当前单机 macOS 环境限制尚未实测，需在真机上验证：

- **Win↔Mac 千兆有线吞吐**，以及 Windows 侧 `SO_SNDBUF`（2 / 4 / 16 MiB）在千兆吞吐与弱 Wi-Fi 控制延迟之间的权衡。
- **弱 Wi-Fi（2–5 MB/s 或丢包环境）**下大文件传输叠加键鼠指针移动时的实际指针延迟与聊天/挂载响应。
- **Android / Linux 真机**上的 `TCP_NOTSENT_LOWAT`（Linux）及移动端低内存/弱网长时间传输表现。
