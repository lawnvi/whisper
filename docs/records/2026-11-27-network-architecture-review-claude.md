# 网络架构、协议和各场景方案评估（Claude）

2026-11-27，基于提交 `9af5b3d`（dev）。同一件事另有其他人独立评估，本文末尾列了供互相核对的结论清单。

## 范围和方法

只读代码和已有文档，没有改代码，也没有在真机上跑。看过的部分：

- 主连接：`lib/socket/svrmanager.dart`、`peer_socket_session.dart`、`peer_connection.dart`、`authenticated_frame.dart`、`aead_engine.dart`、`auth_protocol.dart`、`whisper_frame_v3.dart`、`wire_message_codec.dart`、`bounded_outbound_queue.dart`、`bounded_receive_queue.dart`、`socket_admission.dart`、`dial_tiebreaker.dart`。
- 连接状态：`lib/state/peer_profile.dart`、`peer_reconnect_controller.dart`、`auto_connect_planner.dart`、`discovery_endpoint_resolver.dart`、`peer_link_quality.dart`，以及发现和启动所在的 `lib/page/deviceList.dart`。
- 文件传输：`file_transfer_v3.dart`、`peer_transfer_runtime.dart`、`incoming_transfer_parts.dart`、`transfer_pacer.dart` 的设计说明；`file_transfer_engine.dart` 只看了结构。
- 媒体（声音、键鼠、窗口流转）和文件访问（浏览、挂载、共享链接、网页传输）各由一个只读子代理通读，结论我抽查过关键处；没抽查的，在问题清单的“核对”一列标为“子”，从代码推断、没有复现的标为“推”。
- 文档：`docs/internals/udp-lane.md`、`docs/internals/web-transfer.md`、`docs/internals/shared-folders.md`，`docs/records/` 下传输调速和弱网的记录。

没做的：没有抓包、没有测延迟和吞吐，所有“会等多久”的数字都是从代码里的参数推出来的，不是实测。`packages/window_stream_native/` 和各平台原生代码只看了线上格式。

## 现状一览

```
发现     mDNS _whisper._tcp（bonsoir），TXT 里放 host/port/name/platform/uid
         二维码邀请、手输地址、网络唤醒作为补充
连接     TCP 10002（只听 IPv4）── HTTP 升级 ── WebSocket 路由
           /chat    每对设备一条，谁先拨谁保留（uid 小的保留自己的拨出）
           /audio   声音（另有音频 isolate 自己的随机端口，TCP + 同号 UDP）
           /input   键鼠（另有随机 UDP 端口，跨屏时用）
           /window  窗口流转（还有主机反拨观看端的情况，见 WindowStreamMediaDial）
         TCP 10003 起  共享链接和网页传输（HTTP，只在有链接或访客时开）
         DLNA 投屏：随机 HTTP 端口 + SSDP 1900
认证     hello → challenge → proof → approval → result
         身份密钥 + X25519 临时密钥，配对码由握手记录导出，协议 15 起加 nonce 承诺
         媒体路由用主连接发的一次性令牌 + MAC 证明，UDP 通道从媒体密钥派生
/chat 上的一帧
         WebSocket 二进制消息
           └ WAE1 加密帧（16 字节头 + 16 字节标签，严格递增序号，libsodium XChaCha20-Poly1305）
               └ WFR3 帧（96 字节头，含 64 字节 transferId 字符串）
                   ├ type=message：JSON 的 MessageData（数据库行模型），控制消息再把 JSON 放进 content 字符串
                   └ fileData / clipboardData / browseData / browseWrite 等二进制载荷
```

`/chat` 一条连接上同时走：聊天、心跳和资料、所有子系统的控制消息、文件和文件夹的数据、剪贴板文件、挂载的读写。

各部分代码量（Dart，不含生成文件）：`lib/socket` 2.8 万行，`lib/state` 0.6 万，`lib/audio` 0.9 万，`lib/remote_input` 1.4 万，`lib/window_stream` 1.5 万，`lib/remote_files` 1.2 万，`lib/share_links` + `lib/web_transfer` 0.7 万，合计约 9.4 万行。

## 总的判断

**协议和安全层是扎实的，问题在结构上。** 认证、加密、配对码、认证前的限额、输入校验（`wire_input_policy.dart`）、重放保护、黄金字节测试都做得细，经过三轮攻防；UDP 通道和传输调速是按实测一步步做出来的。这些不需要推倒。

需要从根上动的是四件事，它们互相牵连，单独修任何一个症状都会再长回来：

1. **没有“一条连接”这个对象。** 一条连接的状态散在 `WsSvrManager` 的二十多张表里，靠代数和版本号互相核对；每个子系统的消息处理也写在 `WsSvrManager` 里。媒体那边反过来，三个子系统各写了一套连接管理（拨号、接受、登记、存活、重连）。结果是每加一个功能都要改这个 6900 行的文件，7 月拆下来的东西三周就长回去了（见“代码组织”）；而且所有东西和 `/chat` 同生共死，一个传输超时就能把声音、键鼠、窗口、挂载一起断掉。
2. **所有东西挤在一条 TCP 上，先进先出，没有优先级。** 控制消息要排在文件数据后面，而且应用层没有真实的背压。`TransferPacer`（935 行、7 种模式）里的切片和在途上限，就是在弥补这一点；它给 UDP 声音和键鼠让路的那部分是另一回事，分开连接也省不掉。
3. **能力协商是一个整数加一张封闭的白名单。** 对方资料里多一个不认识的能力或字段，整份资料就被拒，所以每个新能力都要升协议版本；版本协商靠断开重连、逐级往下试。
4. **发现和存活检测是“页面里的逻辑”，而且是单地址、单向的。** 发现、广播、启动服务、自动连接都写在首页 `DeviceListScreen` 的 State 里；广播只带一个 IPv4，网络变了不会重广播；拨出方的主连接没有存活检测。

下面先逐项说现状和问题，最后给出重构方向、顺序和代价。

## 分项评估

### 1. 发现和寻址

**现状**

- 广播和发现在 `lib/page/deviceList.dart` 的 `_DeviceListScreen`（`_broadcastService`、`_discoverService`）里，网络逻辑由 `mounted` 控制，每个发现事件直接写数据库（`upsertDevice`、`setDeviceDiscoveryPresence`）再触发自动连接。
- 服务记录里的端口固定写 `10004`，真正的端口放在 TXT 的 `port` 里；TXT 的 `host` 是 `getLocalIpAddress()`（`lib/helper/helper.dart`）从多块网卡里挑出的一个 IPv4。
- `resolveDiscoveryEndpointHost` 处理了 fake-IP、IPv6、安卓 NSD 名字等很多特例，最终只选出一个地址；`ReconnectTarget` 也只有一个 `host:port`。
- 广播只在资料或端口变化时重发（`_broadcastRestartTimer`），代码里没有监听网络变化的地方。
- 主服务绑定 `0.0.0.0`，只听 IPv4。TXT 里没有协议版本，旧版设备会被发现、能点，到握手才失败。
- `lib/state/discovery_identity.dart` 里有一个只暴露 `v` 和公钥哈希 `pkh` 的 `DiscoveryIdentity.txt`，但广播没有用它（只用到了它的 `isCanonicalPublicKeyHash`）。实际广播的是设备名、平台和 uid，局域网里谁都能看到。

**问题**

- 多网卡、VPN、虚拟网卡、换 Wi-Fi 这些最常见的“连不上”场景，都落在“只挑一个地址”上：挑错了就连不上，换网络后 TXT 里的地址是旧的，只能指望系统 mDNS 解析出的新地址刚好被选中。
- 发现逻辑跟着页面生命周期走，测试只能测零散的纯函数（解析器、限流器），整个发现到自动连接的流程测不到。
- 每个发现事件写一次库，设备多、事件抖动时是无谓的磁盘写。

**建议**

- 抽出 `DiscoveryService`（放 `lib/state/`），页面只订阅结果。
- 服务记录写真端口；TXT 改用已经写好的 `DiscoveryIdentity`，加上协议范围（`v=9-15` 这样），发现阶段就能标出“需要升级”和“身份变了”。设备名和平台要不要继续明文广播，是产品决定（去掉后陌生设备在列表里只能显示为哈希，认证后才有名字）。
- 每台设备保存一组候选地址（mDNS 解析出的全部 IPv4、TXT 里的、上次连上的），拨号时按“上次成功的优先、其余错开 250 ms 并发试”的方式，第一个握手成功的胜出。
- 监听网络变化（桌面轮询 `NetworkInterface.list` 的差异即可，安卓已有原生回调入口），变了就重广播、给已连接的设备重新探活。
- 是否支持 IPv6 可以晚做，但地址模型先做成列表，以后加 IPv6 不用再改结构。

### 2. 连接建立、认证和配对

**现状**

- 握手是五步：`hello`、`challenge`、`proof`、`approval`、`result`（`auth_protocol.dart`、`peer_socket_session.dart`），身份和临时密钥分开，配对码从握手记录导出，协议 15 加了 nonce 承诺防止磨配对码；认证前的字节上限、并发槽、每地址速率都有（`pre_auth_byte_cap.dart`、`socket_admission.dart`）。
- 互拨用 `resolveSimultaneousDial` 按 uid 裁决，只留一条。
- 版本协商：`_connectToServer` 从 15 开始，对方明确拒绝（或某些版本下认证前断开）就断开重连、版本减一，最多试到 9。
- 认证信封是 JSON，装在 `MessageData` 的 JSON 里，再装进 WFR3 帧。

**问题**

- 逐级降版本意味着对一台老设备最多要做 7 次完整的 TCP + HTTP 升级 + 握手，而且“认证前断开”在 14 以下也会触发降级，网络抖一下就可能一路降到 9。安全上已经处理了“降到 14 以下的纯配对码配对要提示”，但机制本身是绕路。
- 认证消息三层嵌套（JSON 套 JSON 套二进制帧），不影响安全，但让认证前的解析面比需要的大。

**建议**

- `hello` 直接带支持的版本区间和功能集合，服务端选出共同的最高版本和交集，一次握手完成。旧版对端仍走现在的降级路径，等最低支持版本过了 15 再删。
- 安全设计本身不建议改动。这一层是全项目最成熟的部分。

### 3. 会话和连接状态

**现状**

- `WsSvrManager` 用二十多张表记录连接：按 `WebSocketSink` 索引的 `_sessionsBySink`、`_peerIdsBySink`、`_authResultsBySink`、`_endpointsBySink`、`_outgoingAuthKeysBySink`、`_incomingAuthPeerIdsBySink`、`_identityPinPlansBySink`、`_clientTimersBySink`、`_socketCleanups`、`_socketCloseGuards`、`_terminalDisconnectCauses`、`_pendingOutgoingBySink`；按设备索引的 `_sessionsByPeerId`、`_remoteProfilesByPeerId`、`_reconnectControllers`、`_peerPolicyEpochs`、`_peerInvalidationRevisions`、`_peerPolicyDispositions`、`_peerAuthSuppressions`、`_peerAuthenticationTails` 等；再加 `_globalPolicyEpoch`、`_policyRevision`、每条连接的 `connectionGeneration`。
- 一致性靠到处调用 `_requireCurrentBusinessSession`、`_requireCurrentAuthenticationCommit`、`_isSessionPeerPolicyCurrent` 这类检查。
- `peer_connection.dart` 里的 `PeerConnection` 只是 send/close 两个闭包，真正的状态不在它身上。
- 还留着单设备时代的全局量：`receiver`、`_sink`、`_remoteProfile`、`_clientTimer`，`receiver` 在文件里出现 50 次；界面通过 `selectPeer` 改它，`_send`、`_heartBeat` 不带设备时就发给它。

**问题**

- 一条连接从拨号、认证、登记、断开到清理，状态分散在多处，任何一步漏清一张表就是泄漏或“幽灵连接”。历史上的真机回归（认证闸门泄漏、自动拨号占锁、旧会话吞消息）都是这一类。
- “当前选中的设备”属于界面，却决定了网络层默认发给谁。

**建议**

- 引入 `PeerLink`：一条已认证连接一个对象，持有会话、sink、端点、定时器、对方资料、协商出的功能集合、代数，以及显式的状态机（拨号中、认证中、等待确认、已连接、关闭中、已关闭）。关闭时由它自己清理自己。
- `PeerDirectory`：`peerId → 当前 PeerLink`，替换上面的大部分表；互拨裁决、顶替旧连接都在这里一处做。
- 子系统拿到的是 `PeerLink` 的一个作用域句柄，连接一换代句柄就失效，`_requireCurrent*` 这类检查不再需要散落各处。
- 删掉 `receiver`/`_sink`/`selectPeer`：所有发送都显式带设备，界面的选中状态留在界面。

### 4. 主连接的复用和传输

**现状**

- 发送：`BoundedOutboundQueue.chat` 是一个先进先出队列，64 条或 128 MiB；加密在出队时才做（`addLazy`），所以序号连续。出队后用 `sink.add` 交给 WebSocket（`_attachSocketTransport` 传的是 `add: sink.add`），交出去就算发出，不等 socket 写完。所以这个队列只管“等加密”的那一小段，真正的积压在 dart:io WebSocket 内部的缓冲里，那里没有上限。队列满了不会让发送方等，而是停止接收并断开连接（`_OutboundPolicy.failClosed`）。
- 接收：`BoundedReceiveQueue` 把每条消息串成一条链，一条处理完才轮到下一条；处理里有等待数据库（心跳写设备表）、读设置（每个剪贴板帧 `LocalSetting().instance()`）等。文件数据写盘已经拆到 `IncomingWritePipeline`，不挡后面的帧。
- 文件数据：桌面每帧 4 MiB、窗口 64 MiB；`TransferPacer` 把在途的未确认数据压在约 2 秒的链路量，有实时流量时再切成 10 ms 一片。Windows 上主连接的收发缓冲调到 16 MiB（`widenTransferBuffers`）。
- 存活：拨出方每 15 秒发一次心跳，心跳带完整资料，对方解析后写一次数据库，不回复；接入方的 WebSocket 每 45 秒 ping 一次。拨出方的 WebSocket 没有设 `pingInterval`，也没有收不到消息就判断断线的计时器。设备卡片的“网络”行另外每 2 秒新建一条 TCP 连接测往返（`PeerLinkQuality`）。

**问题**

- **控制消息排在文件数据后面。** 一句聊天、一次挂载的列目录、窗口流转或键鼠的控制消息，要等前面已排队的文件帧都发完。按调速器的设计，最坏等约 2 秒的链路量；在 2–3 MB/s 的 Wi-Fi 上，加上 Windows 16 MiB 的内核缓冲，可能更久（推算，未实测）。`transfer_pacer.dart` 开头的注释自己写了这一点：“on a slow link a whole file handed to the connection at once would hold up every message behind it for minutes”。
- **没有真正的背压。** 因为交给 `sink.add` 就算发出，应用里的队列几乎总是空的，有多少数据在排队、排在谁前面，应用都不知道也管不了；不经过调速器的生产者（旧版剪贴板帧一批最多 128 MiB，见第 7 节）能一次塞满 WebSocket 缓冲。反过来，加密跟不上时队列满了也不会让生产者等，而是断开整条连接，连同上面的挂载、传输一起断。
- **出错就断整条连接。** 队列溢出、单条消息超长、处理消息时抛出任何异常，都走 `_failSocketSession`，断的是承载所有功能的那一条。
- **接收串行。** 一条消息的处理卡住，后面所有子系统的消息一起等。
- **拨出方发现不了断线。** 对方睡眠、断 Wi-Fi 时，拨出方只能等 TCP 自己超时（Windows 几十秒，macOS、Linux 可到数分钟），这段时间界面显示已连接，发出去的东西堆在队列里。此前给 macOS 加的“睡前主动断开”（`WsSvrManager.prepareForSystemSleep`）就是在绕这个问题，只对本机睡眠有效，对方掉线的情况没有覆盖。接入方最长约 90 秒才发现。
- **同一件事三套做法。** 存活（心跳、WebSocket ping、传输看门狗 `TransferAckWatchdog`）、往返时间（`PeerLinkQuality` 的 TCP 建连、UDP 通道的时间戳、传输确认）各自一套，测的东西也不一样：建连往返不含应用里的排队，而用户感到的卡正是排队。

**建议**（按代价从小到大）

1. **先拿到真实的背压。** 改用 `addStream`（或在 `add` 之后等 socket 排空到低水位）把数据留在应用的队列里，否则下一条说的优先级无从谈起。各生产者按自己的流保持先进先出（文件浏览里“fetch 的 id 先于 offer 到达”依赖这个顺序）。**注意顺序**：现在队列几乎总是空的，64 条的上限碰不到；一旦有了真实背压，数据就会真的堆在这个队列里，而它满了是断线（`failClosed`）。所以必须先让大块数据的生产者等空位（下一条），再换成真实背压，否则这个修复本身就会造成断线。
2. **发送分优先级。** 既然加密在出队时做，可以把队列拆成“控制”“挂载读写”“大块数据（文件、文件夹、剪贴板）”三级，出队时按级别；大块数据的帧缩到 256 KiB 左右，控制消息最多等一帧。满了让大块数据的生产者等，只有控制队列异常增长才判定对方失控。这一条和上一条都不改线上格式。
3. **对称的应用层 ping。** 双方各自每 5 秒 ping 一次、对方立刻 pong（有媒体时更密），连续 3 次没回就断开；pong 的往返时间同时给设备卡片的“网络”行和调速器用，去掉 `PeerLinkQuality` 的建连测法。资料只在变化时发（带摘要），不再每 15 秒整份重发、整份写库。需要新消息类型，按功能协商门控。
4. **控制面和数据面分开（根上的做法）。** 文件、文件夹、剪贴板文件、挂载读写的字节走一条单独的认证连接（复用现在媒体路由的“一次性令牌 + MAC 证明”），`/chat` 只留控制消息。好处：内核和应用两层的队头阻塞都没了；数据连接可以放进工作 isolate，加密和磁盘不再占界面 isolate；数据连接断了重连，不会带走聊天和媒体会话。代价：多一条连接要协商和清理；在同一个 Wi-Fi 上，路由器队列仍是共享的，所以给声音和键鼠让路的调速还是要，但只需要“按排队延迟调速”（`TransferPacerMode.steered`）这一种，按计数的几种模式可以删掉。

第 1、2、3 条不依赖第 4 条，可以先做；第 4 条要等 `PeerLink` 落地后再做，否则只是再往 `WsSvrManager` 里加一套表。

### 5. 文件传输

**现状**

- WFR3 帧上的 offer/ready/data/ack/complete，带持久偏移和续传证明，SHA-256 校验，文件夹是一条连续的流（清单 + 每个文件 + 校验尾）。每台设备每个方向同时只跑一个传输（`PeerTransferRuntime`），其余排队。
- 发送端和接收端的流控参数分桌面、手机、共享链接三档（`FileTransferV3FlowParameters`），确认改成按时间回（`IncomingAckClock`），调速见上。
- 引擎 `FileTransferEngine` 一个类 4896 行。

**评价**

- 协议本身（续传、校验、发布前验证）是对的，速度在千兆有线上已接近链路（2026-10-18 的实测，Win↔Mac 87–92 MiB/s，链路 94）。
- 问题主要是两点：一是上一节的复用问题；二是引擎太大，单文件、文件夹、剪贴板文件、挂载里的复制都经过它，改一处要读全部。
- 一个方向只跑一个传输，在局域网上是合理的选择，不建议改成并行。

**建议**

- 引擎按职责拆：发送状态机、接收状态机、持久化（数据库行和续传点）、文件夹流适配、调速接口，各自一个文件。拆的时候顺便把 `WsSvrManager` 注入给它的二十多个回调（其中 `defaultPeerId: () => receiver`、`hasLegacySinkFor` 是单设备时代的遗留）换成一个 `PeerLink` 句柄。
- 数据面分开后（第 4 节第 4 条），引擎整个可以搬进数据连接所在的 isolate。

### 6. 媒体：声音、键鼠、窗口流转

这一节由子代理通读，我抽查了标“已核对”的几处。

**怎么连**

| | 控制消息 | 数据连接，谁拨谁 | UDP | 包格式 |
| --- | --- | --- | --- | --- |
| 声音（单播，旧对端兜底） | `/chat` | 来源拨接收端主端口 `/audio`，界面 isolate | 无 | WSA1 |
| 声音（组播） | `/chat`（含时钟探测、延迟报告、重新加入） | 桌面接收端：音频 isolate 自己的随机端口，来源先试 1.5 秒再退回主端口；安卓接收端：主端口、界面 isolate | 桌面之间有，每包带两帧 | WSG1 |
| 键鼠 | `/chat`（offer、accept、routes、release、stop） | 控制端拨被控端 `/input`，单向 | 只有跨屏模式 | WRI1（JSON 头 + JSON 载荷） |
| 窗口流转 | `/chat`（目录、图标和缩略图 base64、打开、暂停、关键帧请求、视口、反拨） | 观看端在流 isolate 里拨主机 `/window`；主机是手机且是 `/chat` 的拨出方时，主机反拨观看端，观看端界面 isolate 认证后经 SendPort 转给流 isolate | 无 | WWS1 |

共用的部分是真共用的（约 3400 行）：`packet_byte_transport.dart`、`bounded_outbound_queue.dart`、`bounded_binary_websocket_session.dart`、`media_upgrade_proof.dart`、`session_upgrade_token_registry.dart`、`datagram_seal.dart`、`datagram_endpoint.dart`、`link_delay.dart`、`framed_packet_codec.dart`。

照着抄的部分约 1500–1800 行：

- 接受媒体连接的握手两份：`WsSvrManager` 的 `handleMediaUpgrade` 和音频 isolate 的 `_MediaServer._handle`（后者跨 isolate 查令牌）。
- 拨号四处：`connectPacketWebSocket`、键鼠的 `_connectSocket`、窗口的 `_dialViewer`、`RemoteWindowWorker.start`，NODELAY、ping、超时各不相同。
- 通道登记和关闭四到五份：`AudioShareManager` 和 `RemoteInputManager` 的 `_channels`、`closeSupersededPeerChannels` 几乎逐行相同，另有 `_MediaChannel`、`_HostStream`、`_InboundWindow`。
- `WsSvrManager` 里 `sendAudioControlTo`、`sendAudioGroupControlTo`、`sendRemoteInputControlTo`、`sendWindowStreamControlTo` 加 `_releaseTerminalControl`，同一个结构写了四遍，约 350 行。
- 存活检测至少五种（WebSocket ping 45 s/5 s/45 s、手机控制 500 ms 心跳、窗口 30 ms tick + 1 s ping、UDP 250 ms 保活、组播 500 ms 健康检查）；时钟和往返三套（`AudioClockSyncEstimator` 用墙上时钟走 `/chat`、`RoundTrips` 用单调时钟、窗口 pong 的平滑）；断线重连三种策略（键鼠重新 offer、组播 1 秒后重新加入、窗口和单播声音不重连）。
- 两个 manager 里不做证明就直接接上的 `webSocketHandler` 没有调用者，是死代码。

**评价**

- 键鼠的 UDP 设计是好的：移动只走 UDP，按键这类不能丢的事件两条路都发、按序号围栏执行。
- 窗口视频在直连路径上的拥塞处理合理：在途两帧就让编码器跳帧，溢出时丢差分帧等关键帧，关键帧请求限频。缺的是码率自适应（只在视口变化时改码率）。
- 问题都在“媒体挂在 `/chat` 上”和“每个子系统各写一套连接管理”这两点。

**问题**

- **反拨的窗口流没有背压（高，已核对）。** `_InboundWindow._relay`（`remote_peer_source.dart`）在界面 isolate 里读 socket 从不暂停，收到就 `toWorker.send`；流 isolate 一侧 `_RelayChannel._incoming` 是无界的 `StreamController`。观看端处理不过来时数据堆在内存里，主机看不到拥塞，丢帧和关键帧机制都不起作用；每帧还在界面 isolate 多拷贝一次。
- **媒体和 `/chat` 同生共死（高）。** 文件传输的确认看门狗超时会经 `markPeerUnresponsive` → `_removeUnresponsivePeerIfCurrent` 摘掉整个设备（已核对构造参数），声音、键鼠、窗口一起断。键鼠的 `release`/`routes`、窗口的关键帧请求、声音的时钟探测都排在文件帧后面。
- **跨屏键鼠的被控端没有自己的存活判断（高，推断）。** 只有手机控制模式有 `_armManualDeadline`（已核对），跨屏模式靠服务端 45 秒的 WebSocket ping。控制端睡眠或崩溃时，按住的键或拖动可能卡 45–90 秒；UDP 保活现成，却没拿来判断存活。
- **调速信号是全局的（中，已核对）。** `LinkDelay.shared` 是一个进程一个，不分设备：发给 A 的文件按到 B 的键鼠通道的排队来调速；音频 isolate 里的通道也没计入。调速器的“实时流量”只认键鼠和组播声音，不含窗口流转和单播声音。
- **拨号方向写死（中）。** 声音和键鼠都是来源拨接收端，只有窗口流转能反拨。手机做接收端、又处在热点或 AP 隔离、VPN 下时，`/chat` 能通，媒体连不上。
- **窗口流转的声音和视频共用一个队列（中）。** 关键帧会堵住声音；声音包碰上满队列会触发溢出，关掉整个流。
- **会话被顶替时清理不一致（中，后果未验证）。** `_closeSupersededMediaChannels` 只关声音和键鼠，不关窗口流。
- **音频端口退回时可能用掉令牌（中，推断）。** 先试音频 isolate 端口 1.5 秒、失败再用同一个一次性令牌去主端口，如果超时的那次已经消费了令牌，主端口会回 401。
- **低：** 组播时钟用 `DateTime.now()`，系统校时会让播放调度跳；键鼠每包在界面 isolate 做 JSON 编解码；UDP 通道跟随最新来源地址，没有路径验证；重新加入靠 1 秒的固定定时器。

**建议**

- 抽一个 `MediaChannel`：拨号和接受、证明、每方向密钥、队列策略、关闭原因、存活检测都在里面；一张按（设备、代数、路由、会话）索引的表，三个子系统和音频 isolate 共用。`WsSvrManager` 只提供路由注册和一个通用的 `sendMediaControl`。这和第 3 节的 `PeerLink` 是同一件事在媒体上的一半。
- 看门狗只让那个传输失败，不再摘掉整台设备；媒体各自用自己的保活判断存活（UDP 保活、窗口 tick 都现成）。
- 拨号方向和角色解耦：把窗口流转的反拨推广到声音和键鼠，谁能拨通谁拨。
- 反拨转发改成按额度的流控；窗口流转的声音和视频分开队列。
- `LinkDelay` 按设备分。
- 视频要不要上 UDP（分片 + 重传请求 + 关键帧请求，相当于自己写半个 RTP）先不做，等 `MediaChannel` 落地后按实测决定。

### 7. 文件访问：浏览、挂载、共享链接、网页传输

这一节由子代理通读，我抽查了标“已核对”的几处。

**字节怎么走**

| 通路 | 走哪条连接 | 流控 | 续传 | 校验 |
| --- | --- | --- | --- | --- |
| 文件、文件夹（含文件管理器里的复制） | `/chat`，WFR3 | 确认窗口 + `TransferPacer` | 有 | SHA-256 |
| 挂载读（`browseData`） | `/chat` | 每个挂载 8 个 1 MiB 块在途（`MountReader`），主机全局 8 个并发读盘、排队不限 | 无 | 只靠 AEAD，回帧的 offset 不核对 |
| 挂载写（`browseWrite`） | `/chat` | 每个上传在途 8 MiB（`MountTree._sendBytes`） | 无，断开或空闲 30 分钟即丢 | 无 |
| 旧版剪贴板帧（`clipboardData`） | `/chat` | 无窗口、无确认、不经调速器，一批最多 128 MiB | 无 | 无 |
| 共享链接 | HTTP 10003，明文 | 真实 TCP 背压（`detachSocket` + `addStream`） | Range | 无 |
| 网页传输 | 同一 HTTP 服务器，`/w/ws` + PUT/GET，明文 | 每块最多 8 MiB | Content-Range | 本地快照用 SHA-256，不和浏览器比 |

“临时文件 + 原子替换 + 重名处理”有四份：`IncomingWritePipeline` 一路、`FsUploads`、`WebUpload`、`TransferPlacements.moveInto`。

**问题**

- **挂载和传输抢同一条队列（高）。** 挂载的列目录、读属性、读块都排在文件帧后面，接收端还要在每条 `FileBrowseControl` 上 `await _database.fetchDevice` 做信任检查。有传输或旧版剪贴板批量时，挂载可能撞上系统的超时（macOS 挂载用了 `deadtimeout=10`，NFS 服务端已经要靠 JUKEBOX 让系统重试，说明慢回复以前就出现过）。调速器只认声音和键鼠为“实时流量”，不知道有挂载。
- **断线即卸载（高）。** `/chat` 一断，`peerGone` 让在途读写失败并卸载，主机 `closePeer` 丢掉未提交的上传；被新连接顶替时也一样（`PeerConnectionRegistry.register` 先跑旧连接的 `afterRemove`，推断，未实测）。正在保存的文件会丢。
- **撤权不清理已登记的放置（中）。** `TransferPlacements` 的待放置表只按 transferId 记（已核对 `fs_placement.dart` 的 `_pending`），切只读、撤销“总是允许”、断开都不清，撤权后到的文件照样放进共享目录。
- **挂载写的控制和数据可能乱序（中，未复现）。** 控制消息先 `await permissions.isReadOnly` 再处理，`browseWrite` 帧另走 `unawaited(... handleWrite ...)`，后发的写帧可能先落地。客户端在 `writeSize`/`writeClose` 前会等写完，但多个内核操作并发时仍有可能。
- **网页上传可能卡住（中，未在真机验证）。** PUT 请求体没有读超时，半开连接会让 `WebUpload` 一直处在写入中，浏览器续传一直收到 409，直到会话结束。
- **读放大（低）。** 块固定 1 MiB，offset 0 还预读一块，缩略图和快速查看扫大文件时每个至少拉 2 MiB；预读和按需读共用 8 个槽。

**建议**

- 调度层统一，内容层不统一：挂载读是随机访问、看重延迟、不留记录，不要并进 `FileTransferEngine`；它需要的是第 4 节的分级发送（挂载单独一级），以及接收端按会话缓存信任检查。
- 挂载会话断线续接：主机按设备身份保留会话和上传一段宽限期，读写按 requestId 幂等重发，NFS 的 JUKEBOX 正好撑过重连。按功能协商区分新旧对端。用户能直接感到的改进。
- 放置记录绑定设备，`closePeer` 和撤权时清掉；`handleWrite` 和控制消息走同一条串行路径。
- 四份“临时文件 + 原子替换”合成一个原语。
- 旧版剪贴板帧在功能协商落地后可以按版本删掉，或者至少交给调速器。

### 8. 能力协商和版本

**现状**

- 一个协议整数（现在 15，最低 9）加资料里的 `PeerCapabilities`，后者是 18 个布尔，按协议版本给出一张允许的键名单，出现名单外的键整份资料就被拒（`PeerCapabilities.fromWireJson`）；资料的顶层字段同样严格（`WirePeerProfile._allowedKeys`）。
- 所以新字段要先升协议版本、再按对方版本决定发不发（`DeviceFormFactor.sinceProtocolVersion`、`AppVersionField`、`WakeTarget`）。另外还有第三种门控：消息里的可选字段，旧版忽略（`datagrams: 1`、`mediaPort`）。
- 按版本分支的地方不多，全项目 25 处，大多在 `peer_profile.dart`。

**问题**

- 能力集合本来就是为了不升版本也能加功能，现在被绑在版本上，失去了意义；一台设备落后一个版本，新功能在两台之间就全部关掉（这倒是安全的），但每个功能都要升版本，版本号涨得很快（7 月是 6，现在 15）。
- 三种门控混用，读代码时要分别查。

**建议**

- 功能改成字符串集合，`hello` 里交换，取交集存在 `PeerLink` 上，所有门控都问 `link.has(Feature.xxx)`。
- 对不认识的功能名**忽略而不是拒绝**，同时保留类型、数量（比如最多 64 个）、长度的严格检查。现在拒绝未知字段防的是畸形和超大输入，这些由数量和长度上限照样挡得住。资料摘要（`profileDigest`）要按收到的原始规范化 JSON 算，不能按解析后丢掉未知键的对象重算，否则签名覆盖不到未知字段，两端摘要也对不上（这一点是另一份评估提出的）。
- 协议整数只在帧格式或握手本身变化时才升。
- 明确兼容窗口（例如“支持往前两个发布版本”），写进 AGENTS.md，过了窗口就删对应分支。7 月时定的是“不兼容旧版本”，现在实际保留到 9，两种说法要统一。

### 9. 线程模型

**现状**：主连接的全部收发、加密（libsodium FFI，同步调用）、JSON 解析、数据库、传输编排都在界面 isolate；声音在单独的音频 isolate；挂载每个一个 isolate；文件夹的读写在工作 isolate。`TransferPacer` 里有一条“本机事件循环落后时让一半”，就是因为传输和界面、键鼠抢同一个事件循环。

**评价**：2026-10-18 剖析传输速度时的结论是，挪出界面 isolate 对吞吐只多 2–7 MiB/s，不值得为速度做；但对延迟有意义：键鼠的控制消息、窗口流转的控制、界面动画都和 4 MiB 帧的加密排在一个事件循环上。它不该单独做，应作为第 4 节第 4 条的附带收益。

注意 Dart 不能把已接受的 socket 交给另一个 isolate，所以数据面要放进工作 isolate，那个 isolate 得自己监听端口（音频 isolate 就是这么做的）。这和下一节“端口太多”有冲突，需要一起权衡：可以让数据面和声音共用一个工作 isolate 和一个端口。

### 10. 端口

**现状**：TCP 10002（主连接和三条媒体路由）；音频 isolate 一个随机 TCP 端口和同号 UDP；键鼠一个随机 UDP；共享链接 10003 起；DLNA 随机 HTTP + SSDP 1900；挂载的 NFS 只听回环。

**问题**：Windows 的防火墙按程序放行，随机端口没问题；Linux 上 ufw、firewalld 默认拒绝入站，用户只知道放行 10002，随机端口的 UDP 会静默退回 TCP（弱网又卡）；音频 isolate 的随机 TCP 端口被挡时，来源要先白等 1.5 秒再退回主端口，声音改由界面 isolate 收、也没有 UDP，而且退回时可能碰上第 6 节说的令牌已被用掉的问题。

**建议**：端口固定下来并写进排障指南，例如 10002 TCP/UDP 给主连接和键鼠 UDP，10005 TCP/UDP 给音频（和以后的数据面）isolate，被占用时再顺延并通过主连接告诉对方。

### 11. 代码组织

- `svrmanager.dart` 6904 行。7 月重构后是 1508 行，三周后 5868 行，之后一路涨到现在（按每月 1 日的提交统计）。`file_transfer_engine.dart` 同期从 1538 到 4896 行。
- `_listen` 一个方法约 700 行，窗口流转、文件浏览、声音组、键鼠的控制消息处理都写在里面，各 80–130 行。
- 子系统通过 `_startServer` 里给单例赋回调接上（`WindowStreamHost.shared..sender = ...`、`RemoteFilesClient.sender = ...`、`FileBrowseHost.shared..sendData = ...`）。
- 网络之外的 44 处直接 `WsSvrManager()`；界面里 12 个文件还在 import `lib/socket/` 的内部文件。
- 11-08 加的尺寸基线已经能挡住继续变大，但挡不住“新功能只能塞进去”的根因：没有路由注册表，新消息类型只能在 `_listen` 里加一个 `case`。

**建议**：`ChannelRouter`，子系统启动时注册自己处理的消息类型和帧类型，`WsSvrManager` 只做连接、认证和按类型转交；回调赋值改成子系统构造时拿到一个发送接口。这是第 3 节 `PeerLink` 的另一半，两者一起做。

## 问题清单

“核对”一列：我 = 我读代码确认；抽 = 子代理发现、我抽查过代码；子 = 只有子代理的结论；推 = 从代码推断，没有复现。

| # | 严重度 | 问题 | 证据 | 建议 | 核对 |
| --- | --- | --- | --- | --- | --- |
| 1 | 高 | 拨出方主连接没有存活检测，接入方最长约 90 秒 | `_connectOutgoingWebSocket` 没设 `pingInterval`；心跳不回复；`_serverPingInterval` 45 秒 | 对称 ping/pong，15 秒内判断断线 | 我 |
| 2 | 高 | 控制消息、挂载读写排在文件数据后面，且没有真正的背压 | `BoundedOutboundQueue.chat` 先进先出，出队即 `sink.add`；`TransferPacer` 在途约 2 秒；Windows 16 MiB 内核缓冲 | 先拿到背压，再分级发送，缩小大块帧；长期分开数据面 | 我 |
| 3 | 高 | 连接状态散在二十多张表里，单设备时代的全局量还在 | `WsSvrManager` 字段；`receiver` 50 处 | `PeerLink` + `PeerDirectory` | 我 |
| 4 | 高 | 反拨的窗口流转没有背压，内存和延迟无界 | `_InboundWindow._relay`、`_RelayChannel._incoming` | 按额度流控 | 抽 |
| 5 | 高 | 传输看门狗超时摘掉整台设备，声音、键鼠、窗口、挂载一起断 | `markPeerUnresponsive: _removeUnresponsivePeerIfCurrent` | 只让那个传输失败 | 我 |
| 6 | 高 | 断线或被顶替即卸载挂载，未提交的写入丢失 | `RemoteFilesClient.peerGone`、`FileBrowseHost.closePeer` | 挂载会话宽限期 + 幂等重发 | 子 |
| 7 | 高 | 跨屏键鼠被控端没有自己的存活判断，按键可能卡 45–90 秒 | `_armManualDeadline` 只用于手机控制 | 用 UDP 保活判断存活 | 抽、推 |
| 8 | 中 | 出错（队列满、超长、处理异常）一律断开整条 `/chat` | `_OutboundPolicy.failClosed`、`_failSocketSession` | 按子系统隔离错误，大块数据的生产者等空位 | 我 |
| 9 | 中 | 能力集合绑在协议版本上，未知键整份拒绝；消息级字段又是“旧版忽略”，两种策略相反 | `PeerCapabilities.fromWireJson`、`WirePeerProfile._allowedKeys`；`datagrams`、`mediaPort` | 字符串功能集合，忽略未知、限制数量和长度 | 我 |
| 10 | 中 | 版本协商逐级断开重连 | `_connectToServer` 循环 | `hello` 带版本区间 | 我 |
| 11 | 中 | 发现在页面里，只选一个地址，网络变化不重广播 | `_DeviceListScreen._broadcastService/_discoverService` | `DiscoveryService`，多地址并发拨号，监听网络变化 | 我 |
| 12 | 中 | 接收串行，处理里有数据库和设置读取 | `BoundedReceiveQueue`；心跳 `upsertDevice`；剪贴板帧读 `LocalSetting`；每条 `FileBrowseControl` 查 `fetchDevice` | 解密后按子系统分发到各自的队列，信任检查按会话缓存 | 我 |
| 13 | 中 | 媒体连接管理各写一套（握手 2、拨号 4、通道登记 4–5、控制发送 4、存活 5 种） | 见第 6 节 | `MediaChannel` + 共用注册表 | 子 |
| 14 | 中 | 调速信号全局不分设备，不含窗口流转和单播声音 | `LinkDelay.shared` | 按设备分，实时流量列全 | 抽 |
| 15 | 中 | 媒体拨号方向写死，手机做接收端时在热点/AP 隔离下连不上 | 来源拨接收端；只有窗口流转能反拨 | 推广反拨 | 子 |
| 16 | 中 | 撤权不清理已登记的放置 | `TransferPlacements._pending` 只按 transferId | 放置绑定设备，撤权时清 | 抽 |
| 17 | 中 | 挂载写的数据帧不等权限检查，可能比控制消息先落地 | `browseWrite` 走 `unawaited(handleWrite)` | 和控制消息同一条串行路径 | 抽、推 |
| 18 | 中 | 网页上传的请求体没有读超时，半开连接卡住续传 | `WebUpload` | 加读超时 | 子 |
| 19 | 中 | 窗口流转的声音和视频同一队列，声音包能触发溢出关掉整个流 | 见第 6 节 | 分队列 | 子 |
| 20 | 中 | 随机端口，Linux 防火墙下静默退化 | `RawDatagramSocket.bind(..., 0)`、音频 isolate `ServerSocket.bind('0.0.0.0', 0)` | 固定端口并写进排障指南 | 我 |
| 21 | 低 | 线上消息就是数据库行，控制消息 JSON 套 JSON | `encodeWireMessage(MessageData)` | 独立的线上类型，按消息种类定义 | 我 |
| 22 | 低 | 心跳每 15 秒发整份资料并写库 | `_heartBeat`、`_refreshRemoteProfileFromHeartbeat` | 变化时才发 | 我 |
| 23 | 低 | 存活、往返、时钟各有多套测法 | `PeerLinkQuality`、`LinkDelay`、`TransferAckWatchdog`、`AudioClockSyncEstimator` | 统一到 ping/pong 和 UDP 时间戳 | 我、子 |
| 24 | 低 | 旧版剪贴板帧一批最多 128 MiB，不经调速器 | `RemoteClipboardTransfer` 旧路径 | 按版本删，或交给调速器 | 子 |
| 25 | 低 | 挂载读固定 1 MiB 块加预读，读放大 | `MountReader` | 按访问模式调块大小 | 子 |
| 26 | 低 | 只听 IPv4 | `ServerSocket.bind('0.0.0.0', ...)` | 地址模型先做成列表，IPv6 以后加 | 我 |
| 27 | 低 | 死代码：不做证明的媒体 `webSocketHandler` | `AudioShareManager`、`RemoteInputManager` | 删掉 | 子 |

## 从根上怎么改

### 不建议做的

- **换 QUIC 或现成的点对点框架。** Dart 没有可用的 QUIC 实现，要用 FFI 接 msquic/quiche/ngtcp2，四个平台都要编译和打包；现成框架大多带公网中继和打洞，和“只在局域网、不加公网中继”的约束冲突。QUIC 的主要好处（不排队的数据报、多路流）现在用 UDP 通道和第 4 节的做法都能拿到大部分。等有 2.5G 链路或多流的真实需求再看。
- **推倒重写协议层。** 认证和加密是全项目最经得起检验的部分，重写只会把三轮攻防的成果作废。

### 建议做的，按顺序

1. **线上的功能协商（协议 16）。** `hello` 带版本区间和功能集合，能力改成可忽略未知的字符串集合，资料只在变化时发。先做它，是因为后面每一步都要改线上格式，有了它以后加功能不用再升版本、不用再要求所有设备一起升级。代价小，一两个文件为主，加一个新旧对端的互通测试。
2. **`PeerLink` + `PeerDirectory` + `ChannelRouter` + `MediaChannel`（基本不改线上格式）。** 把连接状态收进对象、子系统的消息处理搬回子系统、删掉单设备全局量；媒体三个子系统共用一套通道管理。这是最大的一块，但可以分批：先让 `PeerLink` 包住现有的表（新旧并存），再逐个子系统把 `_listen` 里的 `case` 搬走，再把声音和键鼠的通道管理并到 `MediaChannel`（两者几乎逐行相同，先合它们），最后删表。每批都能单独跑全量测试。现有的真实 socket 集成测试（`reconnect_integration_test.dart`、`typed_connection_handshake_integration_test.dart`、`folder_transfer_connection_integration_test.dart` 等）是这一步的安全网。
3. **背压、发送分级、对称存活检测，以及“故障不连坐”。** 先让大块数据的生产者等空位、再改成真实背压（顺序反了会断线，见第 4 节），然后分控制、挂载、大块三级；ping/pong 是协议 16 的功能；传输看门狗只让传输失败；媒体用自己的保活判断存活；反拨窗口流改成按额度转发。除 ping/pong 外都不改线上格式，可以和第 2 步交错做，其中“看门狗不摘设备”和“反拨背压”改动小、收益直接，可以最先做。
4. **连得上、断得起。** 发现服务从页面搬出来，TXT 加版本区间和身份摘要，多地址并发拨号，网络变化重广播；媒体拨号和角色解耦（谁能拨通谁拨，推广窗口流转的反拨）；挂载会话断线后保留一段宽限期，读写按 requestId 幂等重发。
5. **数据面分开、搬进工作 isolate。** 在 1–4 都落地后做；同时决定端口方案和声音 isolate 是否合并。调速器删掉按计数的模式，`LinkDelay` 按设备分。

线上格式的变化（第 1 步、第 3 步的 ping/pong、第 4 步的 TXT 字段、反拨推广和挂载续接、第 5 步的数据连接）都按功能协商门控，旧版本对端照旧走现在的路径。其余都是本机内部的重构，不改线上格式。

工作量粗估（只按代码量和牵涉面估，没有拆任务）：第 1 步几天；第 2 步最大，按批次做三到五周；第 3 步一到两周；第 4 步两周左右；第 5 步两到三周。

## 供互相核对的结论

下面每条都是我在代码里确认过的，可以直接核对或推翻。标“子”“推”的不在此列。

1. 拨出方的 `/chat` WebSocket 没有 `pingInterval`，心跳消息不被回复，拨出方没有应用层的断线检测（`WsSvrManager._connectOutgoingWebSocket`、`cappedClientWebSocket`、`_heartBeat`、`_ackMessage` 只确认 Text 和 File）。
2. `/chat` 的发送是单个先进先出队列，加密在出队时做，队列满即断开（`BoundedOutboundQueue.chat`、`PeerSocketSession.attachTransport`）。
3. `/chat` 的接收是每条连接一条串行链（`BoundedReceiveQueue._tail`）。
4. `svrmanager.dart` 在 7 月重构后约 1500 行，8 月 1 日已近 5900 行（`git show <rev>:lib/socket/svrmanager.dart | wc -l`）。
5. 能力和资料对未知键整份拒绝，新字段必须先升协议版本（`PeerCapabilities.fromWireJson`、`WirePeerProfile.fromJson`）。
6. 版本协商靠逐级断开重连（`WsSvrManager._connectToServer`）。
7. mDNS 广播和发现在 `lib/page/deviceList.dart`，服务记录端口是 10004，真端口在 TXT；没有网络变化监听。
8. 线上的消息是 Drift 的 `MessageData` 行模型直接 `toJson`（`encodeWireMessage`）。
9. `/chat` 发送队列出队后用 `sink.add`，交出去就算发出，应用层没有真实背压（`BoundedOutboundQueue._write`，`_attachSocketTransport` 传入 `add: sink.add`）。
10. 文件传输的确认看门狗超时会摘掉整台设备（`FileTransferEngine` 的 `markPeerUnresponsive` 接的是 `_removeUnresponsivePeerIfCurrent`）。
11. 反拨的窗口流转在界面 isolate 里读 socket 不暂停，流 isolate 一侧是无界的 `StreamController`（`_InboundWindow._relay`、`_RelayChannel`）。
12. `LinkDelay.shared` 是全进程一个，调速和键鼠通道共用，不分设备。
13. 跨屏键鼠的被控端只有手机控制模式才有截止计时（`RemoteInputCoordinator._armManualDeadline`）。
14. 挂载写帧走 `unawaited(FileBrowseHost.shared.handleWrite(...))`，控制消息先 `await permissions.isReadOnly`。

我的判断里最可能和别人不同的几处，值得重点对一下：

- 我认为数据面分开是根本做法，但排在 `PeerLink` 之后；如果别人主张先拆连接，分歧在于“先建对象再拆连接”还是“拆连接倒逼建对象”。
- 我不建议上 QUIC。
- 我认为一个方向只跑一个传输是对的，不必并行。
- 我把“拨出方无存活检测”排成最高，因为它直接造成“显示已连接但发不出去”，比吞吐问题更常被用户看到。
- 我主张挂载读不并进 `FileTransferEngine`，只统一调度层；如果别人主张“所有搬字节的路径统一成一个引擎”，分歧在于挂载读的随机访问和低延迟要求。
- 视频暂不上 UDP，也不引入 WebRTC。

## 没有覆盖到的

- 没有实测任何延迟和吞吐；文中“等约 2 秒”“卡 45–90 秒”都是从参数推的。
- `FileTransferEngine` 内部的状态机只看了结构；文件夹流、续传证明的细节没有重新审。
- 各平台原生代码（窗口流转的采集编码、键鼠注入、挂载的系统接口）、`android_agent/`、DLNA 投屏只看了和网络有关的接口。
- 安卓后台保活、系统休眠和唤醒对连接的影响没有专门看。
- 子代理只有结论、我没抽查的条目，在问题清单的“核对”一列标为“子”。

## 和另一份评估的对照（同日补充）

另一份是 [2026-11-27 网络架构、协议与各场景技术方案全局评估](2026-11-27-architecture-protocol-review.md)（下称“对方”）。它的范围比本文宽：还评了剪贴板同步、声音的状态机和各平台原生播放、键鼠的修饰键、电视投屏的安全。下面“已核对”是我读代码确认过的。

### 两份独立得出的相同结论

这些可以当作比较可靠的判断：

- `/chat` 混跑控制和大块数据，有队头阻塞；出队即 `sink.add`，应用层没有真实背压。根上的做法都是给大块数据开单独的认证连接（对方叫 `/transfer`），复用现在的令牌加证明，放进工作 isolate。
- 拨出方 `/chat` 没有 `pingInterval`，心跳不回复，每 15 秒整份资料写一次库。
- 资料和能力对未知键整份拒绝，每加一项都要升版本；版本协商逐级断开重连。都建议协议 16 在 `hello` 里带版本区间、忽略未知能力。
- `WsSvrManager` 和 `FileTransferEngine` 过大，`deviceList.dart` 实际是应用的生命周期宿主，子系统靠 `.shared` 赋回调接上；都建议拆成连接、拨号、认证、登记、路由几块，由子系统向路由注册。
- `LinkDelay.shared` 全局不分设备；音频 isolate 的 UDP 通道没接入调速。
- 挂载：每条请求查一次数据库；断线即卸载，都建议给 10–15 秒宽限期。
- 反拨的窗口流转经界面 isolate 转发。
- 不推倒重写，认证和加密保留。

### 对方提出、我漏掉的，已核对

| 结论 | 核对结果 | 对本文的影响 |
| --- | --- | --- |
| Windows、Linux 没有睡眠钩子 | 属实：`com.vireen.whisper/system_power` 只在 `macos/Runner/MainFlutterWindow.swift` 里实现，`windows/`、`linux/` 下没有 `WM_POWERBROADCAST` 或 `PrepareForSleep` | 和本文问题 1（拨出方没有存活检测）叠加：这两个平台睡眠时，自己不主动断，对方也发现不了 |
| 手动按地址拨号时，互拨裁决查不到 | 属实：出站按 `endpoint:host:port` 登记（`_authRequestKey`），`_handleServerProof` 按 `peer:<uid>` 查 `hasOutgoing`；判定 `acceptIncoming` 时也不取消自己的出站 | 两条都认证成功后靠顶替收场，而顶替会跑完整的断开清理（第 7 节的挂载卸载）。低到中 |
| 剪贴板文字在没开键鼠时只发给界面选中的设备 | 属实：`deviceList.dart` 的同步循环里 `targetIsCurrent` 落到 `socketManager.receiver == peerId` | 这是本文问题 3（单设备时代的 `receiver`）造成的、用户看得到的后果，应该一起改 |
| 网页传输页面的转义写错 | 属实：`web_transfer_routes.dart` 的 `.replaceAll('<', r'<')` 什么也没替换，注释写的是要防名字结束 script 块 | 名字是主机自己设的，危害小，但是一行就能修的真问题 |
| UDP 通道和调速器用墙上时钟 | 属实：`DatagramEndpoint` 的 `healthy` 和 `TransferPacer` 默认 `DateTime.now`；排队测量用的是单调的 `Stopwatch` | 系统校时或睡醒时通道健康判断和调速会跳。低到中 |
| UDP 端口被占时一直等原端口 | 属实：`DatagramEndpoint._rebind` 每秒在同一个端口号上重试，不换端口 | 低 |
| 能力宽容后摘要要按原始 JSON 算 | 是对的 | 已补进第 8 节 |
| 大块数据的 TCP 标低优先级 DSCP（如 CS1） | 合理，代价小 | 赞成，作为第 4 节的补充。Windows 没有组策略时忽略标记；在发送端自己的 Wi-Fi 网卡上，WMM 会按标记分队列，对 Mac、Linux、安卓发送端有用。不能代替调速 |
| 窗口流转主机端的编码、加密在界面 isolate | 属实（我的子代理也看到了，正文漏写） | 和第 9 节的结论一致：作为数据面搬家的一部分 |
| `closeGracefully` 绕过了几个子系统的断开清理 | 部分核对：`disconnectAll` 调 `disconnectCurrent` 时不传 `afterRemove`；之后 `_handlePeerSocketDoneQueued` 是否补上清理我没追完 | 列为待查 |
| `_handlePeerDisconnected` 不通知两个声音协调器 | 属实（只调 `_audioManager.closePeerChannels`，声音的控制会话是有意保留给重新加入的） | 对方说这导致睡醒后声音死锁，这个推论我没验证 |

对方范围内、我没有核对的：剪贴板四套防回声和 Windows `OpenClipboard` 竞争、声音双协调器无互斥和重新加入死锁、各平台原生播放的恢复、键鼠修饰键和热路径 JSON 次数、电视投屏的 SSRF 和 `/status`、挂载缺 `stat`、`FolderReceiveSession._queued` 无界、网页传输上传数和限流顺序。

### 对方结论里我认为不准的

- **“发现的 TXT 只暴露 `v` 和 `pkh`”不对。** 那是 `DiscoveryIdentity.txt`，写了但没接上；`_DeviceListScreen._broadcastService` 实际广播 `host`、`port`、`name`、`platform`、`uid`。所以“发现阶段能看到版本”的前提不成立，而且设备名和 uid 是明文广播的。已补进第 1 节。
- **“64 条上限极易撞上导致断线”现在不成立，修了背压之后才成立。** 现在出队即 `sink.add`，队列只在等加密时有东西，很难攒到 64 条。反过来，对方阶段 0 第 1 条“修复背压绕过”如果先做，数据就会真的堆进这个满了就断线的队列。必须先让生产者等空位，再换真实背压。我原文的顺序也有同样的问题，已在第 4 节改正。
- **“排除列表没传给扫描，导致整目录复制失败”是已记录的取舍。** `docs/internals/shared-folders.md` 写了“里面有排除的目录就整个拒绝，没有做成跳过”。要改成跳过是新需求，不是缺陷。
- **投屏 5 秒自动允许是待你拍板的产品决定。** `docs/records/2026-11-13-security-audit.md` 的待确认第 7 条，不是新发现。

### 本文有、对方没提的，请对方核对

- 文件传输的确认看门狗超时摘掉整台设备（`markPeerUnresponsive: _removeUnresponsivePeerIfCurrent`），声音、键鼠、窗口、挂载连带断开。
- 反拨窗口流转不只是多一跳拷贝：界面 isolate 读 socket 不暂停，流 isolate 一侧是无界的 `StreamController`，背压整个丢了。
- 跨屏键鼠被控端只有手机控制模式才有截止计时，跨屏模式靠 45 秒的 WebSocket ping。
- 媒体拨号方向写死（来源拨接收端），只有窗口流转能反拨。
- 媒体连接管理的重复：接受握手 2 份、拨号 4 处、通道登记 4–5 份、控制发送 4 遍。
- 撤权不清理已登记的放置；挂载写帧不等权限检查。
- 能力门控三种机制混用：资料严格拒绝，消息字段（`datagrams`、`mediaPort`、`dialBack`）却靠“旧版忽略”。
- 发现只选一个地址、网络变化不重广播；随机端口在 Linux 防火墙下静默退化。
- `PeerLinkQuality` 每 2 秒新建一条 TCP 测往返，和 ping/pong、UDP 时间戳是三套测法。

### 顺序上的分歧和合并建议

对方先做用户看得到的子系统重塑（剪贴板 #7、声音 #8），再做通道隔离和拆大文件；我先做协议 16 和连接对象化。两种顺序各有道理：对方的直接对着在开的 issue，我的是为了让后面的每次线上改动不再要求所有设备一起升级。合并起来：

1. **止血**（一到两周，不改线上格式）：对方阶段 0 里核对属实的几条（转义、互拨裁决、挂载查库改缓存、拨出方 `pingInterval`），加上本文的“看门狗不摘整台设备”“反拨窗口流转加背压”。背压修复按上面说的顺序做。
2. **协议 16**（几天，可以和第 3 步并行）：版本区间、宽容能力（摘要按原始 JSON）、资料只在变化时发、对称 ping/pong。
3. **对方阶段 1**：睡眠事件总线（补 Windows、Linux）、剪贴板重做、声音状态机重做。剪贴板改的时候顺带去掉对 `receiver` 的依赖。
4. **连接对象化和路由**（本文第 2 步，对方阶段 2 第 3 条）。
5. **数据面分开、窗口流转主机端搬进 isolate、调速器按设备精简**（双方都排在后面）。

### 对方留下的六个问题，我的看法

1. **隔离粒度**：先在 `/chat` 上做分级发送当过渡（按正确的背压顺序），等连接对象化之后再开 `/transfer`。直接先开 `/transfer` 也行，但在 `WsSvrManager` 拆开之前做，只会再多一套表。
2. **调速器的去留**：保留按排队延迟调速（`steered`）一种并按设备分，删掉按计数的几种。DSCP 不能代替它：Windows 默认忽略标记，路由器往下发时也常不看标记。
3. **挂载的投入产出**：要不要收窄写入、要不要继续维护三套系统接口，是产品决定，要你定。网络层面不管怎么定，都该做宽限期续接和分级发送。
4. **多设备剪贴板**：发给“所有已连接、且在设备设置里开了剪贴板的设备”更合理。代码已经逐台检查 `target.clipboard`，现在只是又多卡了一道“界面选中”。这也是产品决定。
5. **协议 16 的取舍**：同意借协议 16 做单次协商和宽容能力；同时定下兼容窗口和旧声音单播、旧剪贴板帧的退役版本。
6. **投屏默认信任**：倾向改成默认手动允许，但这是 11-13 就挂着的待决定项，由你定。
