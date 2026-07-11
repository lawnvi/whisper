# Whisper 网络安全与可靠性加固设计

## 背景与结论

Whisper 的产品边界是可信设备之间的局域网协作。现有 Shelf WebSocket + mDNS 架构适合这一边界，文件、音频和键鼠控制也已经分别形成协议层与协调器层，因此本轮保留 `shelf`、`shelf_web_socket`、`bonsoir` 和现有 WFR3/WSA1/WSG1/WRI1 帧，不重写 QUIC，也不引入公网中继。

当前主要风险不是 WebSocket 本身，而是连接身份、路由授权、输入限额和恢复语义不完整：任意客户端可以声明任意 `uid`，鉴权前帧能触达业务分支，消息和传输主要相信载荷里的 `sender`/`transferId`；`/audio` 与 `/input` 可匿名升级；文件默认无校验且最终落盘会删除同名文件；单一全局 receive queue 会让一个慢 peer 阻塞所有 peer；mDNS TXT 暴露设备及信任关系；匿名读写 FTP 绕过主协议全部信任边界。

本设计采用保守演进：先建立可证明的设备身份与每 socket 授权上下文，再让消息、文件、媒体通道全部依赖该上下文；同时补齐背压、超时、重连、路径安全和平台权限。双端并行确认配对的协议修订硬切到 v6，低版本对端显示“需要升级”，不提供不安全降级。

## 目标与非目标

### 目标

- 每条 chat WebSocket 独立经历 pre-auth 状态机，鉴权后永久绑定一个已验证 peerId。
- 使用长期 Ed25519 设备密钥、临时 X25519、nonce challenge-response、TOFU 公钥 pin 与 6 位配对码证明身份。
- 用 X25519 + HKDF-SHA256 派生方向性会话 MAC key；鉴权后的每个 chat/file/control/media 包都带单调序号与 HMAC-SHA256，payload 保持明文但不能被在途篡改或重放。
- 所有消息和文件帧校验其实际 socket 来源，不能用载荷伪装其他 peer。
- 严格限制路由、Origin、连接数、帧大小、排队量、文件大小与失败次数。
- 文件名、transferId、临时路径和最终路径都不能目录穿越，也绝不覆盖已有用户文件。
- 文件使用 SHA-256 全量校验，续传使用已落盘尾段的 SHA-256 proof。
- `/audio` 与 `/input` 只接受控制通道签发的短期、单次 token，并绑定 session。
- 文件 ACK 超时可重传并在失活后触发重连；取消、失败和错误均可靠推进队列。
- server restart/close 全部 await；数据库对非空 `Device.uid` 建立唯一约束。
- mDNS 使用 SRV 的 host/port，TXT 不再发布 uid、名称、平台、IP、信任列表或自动连接偏好。
- 网络日志默认不包含消息内容、通知正文、文件路径、content URI、IP、token、配对码或完整身份指纹。
- iOS 与 Android 在开始监听、发现或连接前具备正确的本地网络声明与拒绝态处理。

### 非目标

- 本轮不实现 payload 加密或端到端加密。临时 X25519 只为会话完整性 key 提供前向保密；chat、文件、音频和输入事件仍可被同网监听者读取。
- 本轮不引入 TLS 证书基础设施、公网账号、云中继、NAT 穿透或 QUIC。
- Ed25519 私钥防护以应用沙箱为边界，不承诺抵抗已控制本机账号或进程的攻击者。
- 不把“局域网”描述为对不可信同网设备安全；配对码未被用户比对时，首次主动 MITM 仍可能成功。

## 威胁模型

防护对象包括同一 LAN 内主动扫描端口、伪造 uid、重放旧鉴权消息、在途篡改、跨 peer 注入 transferId、浏览器跨站 WebSocket、匿名连接媒体通道、恶意文件名/路径、超大输入和资源耗尽。长期 pin 建立后，攻击者无法仅靠复制 uid 冒充已配对设备；在途攻击者只能转发或丢弃已认证包，不能改写或重放。被动监听者仍能读取明文 payload，但看不到可复用私钥或会话 MAC key。

首次配对通过双方公钥与双方 nonce 派生同一个 6 位配对码。发起端与接收端必须并行显示：主动拨号本身代表发起端的连接意图，发起端只可取消；接收端负责比对数字并明确确认或拒绝。它提供主动 MITM 的人工检测，但不是加密信道；接收端跳过比对仍会接受风险。已信任但没有 pinned key 的旧数据库记录不得自动放行，必须重新确认。已 pin 公钥发生变化时显示明确的身份变更警告，并再次确认后才替换 pin。

## 协议与组件

### 1. 设备身份和签名握手

新增 `device_identity.dart`、`auth_protocol.dart` 与 `auth_transcript.dart`，依赖 `cryptography ^2.9.0`：

- 首次运行生成 Ed25519 key pair，私钥 seed 保存在现有应用偏好存储，公钥用无 padding base64url 表示。
- `Device` 增加 `identity_public_key`；`uid` 增加唯一索引。公钥只在明确允许配对或验证既有 pin 后写入。
- 签名输入不是临时 Map 的 JSON 字符串，而是带 `whisper-auth-v1` domain separator 的长度前缀字段序列，字段固定为协议版本、双方 uid、双方 Ed25519/X25519 公钥、发现 `pkh`、双方 32-byte nonce、白名单 profile digest 和消息阶段，杜绝字段重排、能力篡改与分隔符歧义。
- client 发送 `hello(profile, publicKey, ephemeralKey, clientNonce, intendedPeerId?, intendedPkh?)`；未知 mDNS 候选允许 `intendedPeerId` 为空，但必须核对 challenge 的 Ed25519 fingerprint 等于发现 `pkh`。server 构造完整 transcript，回签名的 `challenge(serverPublicKey, serverEphemeralKey, serverNonce, clientNonce)` 并立即显示配对码；client 验签后也显示只带取消操作的配对码。主动拨号视为 client 默认允许，client 立即发送 `proof(clientSignature)` 与独立签名的 `approval(allow=true, reason)`；取消会终止握手且不提交 pin。server 只有在本地允许、proof 验证通过且 client approval 允许后才提交 pin，并发送覆盖完整 transcript、allow/reason 的 signed result。server 拒绝时发送 reason 为 `pairing_rejected` 的签名 result，由 client 消费后关闭连接；任一拒绝或取消都不提交 pin。
- challenge、proof、approval、result 分别有不同 domain，nonce 只使用一次，握手 30 秒超时。result 验签成功之前，client 不进入 authenticated。
- 配对码为 `SHA-256(canonical transcript)` 映射到 `000000..999999` 的零填充十进制值。日志和通知不得记录该值。
- `PeerProfile` 改为白名单 wire DTO，只传 uid/name/platform/capabilities/topology，不传 Drift 的 id/password/auth/clipboard/host/lastTime/around；其 canonical digest 纳入 proof/result。远程输入信任判断改为“socket 已验签且双方 pin 已建立”。

signed result 验证后，双方以 X25519 shared secret、完整 transcript hash 和 HKDF-SHA256 派生 client->server、server->client 两把 chat MAC key。`AuthenticatedFrame` 使用固定 domain、uint64 sequence、payload length、payload 与 32-byte HMAC；sequence 必须严格递增。媒体通道另由 chat key 派生 route+session 专用 MAC key。不得把 X25519 shared secret、MAC key 或完整 transcript 写入 DB/日志。

### 2. 每 socket 状态与来源绑定

每条 chat socket 创建 `PeerSocketSession`，按角色使用不同阶段：

- server：`awaitingHello -> awaitingProof -> awaitingLocalApproval -> authenticated -> closing`
- client：`awaitingChallenge -> awaitingLocalApproval -> awaitingResult -> authenticated -> closing`

session 持有 sink、connection generation、连接角色、remote address 的不可逆摘要、nonce、候选公钥、ephemeral key、已绑定 peerId、握手 timer、方向性 MAC key、收发 sequence、该 socket 的 receive/outbound queue 与 heartbeat timer。鉴权前只允许下一步合法 Auth envelope；鉴权后只允许验证通过的 `AuthenticatedFrame`。任何 message/file/media control、重复或乱序 Auth、错序/错 MAC/超限帧都关闭当前 socket，不触碰其他 peer。迟到的 UI callback 必须检查 session generation，关闭或超时后不得 pin 或注册。

鉴权完成后，非 Auth `MessageData` 必须同时满足：

- `message.sender == session.peerId`
- `message.receiver == localPeerId`
- socket 仍是 registry 中该 peer 的当前连接

FileTransferEngine 的入口改为 `handleFrame(String authenticatedPeerId, WhisperFrameV3 frame)`。offer 的 `message.sender`、`message.receiver`、`message.uuid` 与 frame transferId 必须一致；data/control 查询到的 transfer 必须属于同一 `peerUid`，control payload transferId 必须等于 frame header transferId。失败只记录无敏感信息的原因码并关闭违规 socket。

### 3. 路由、Origin 和资源限额

Shelf server 只开放 `GET /chat`、`GET /audio`、`GET /input` 三个 WebSocket upgrade；其他路径 404，非 upgrade 400。原生客户端不发送 Origin，因此 `Origin` 缺失时允许，任何非空 Origin 均 403，阻止浏览器跨站 WebSocket。

固定限额如下：

| 对象 | 限额 |
|---|---:|
| 同时 chat sockets | 32 |
| pre-auth sockets | 全局 8、每 IP 2 |
| 同 IP upgrade | 30 次/分钟 |
| Auth/普通 message payload | 256 KiB / 1 MiB |
| fileData payload | 512 KiB（保持现协议） |
| `/audio` 单包 | 256 KiB |
| `/input` 单包 | 64 KiB |
| 每 socket receive queue | 64 项或 8 MiB；高水位 pause，降至 4 MiB resume |
| 单文件 | 100 GiB |
| 每 peer 排队传输 | 32 |
| 全局排队传输 | 128 |

`BoundedReceiveQueue` 按 socket 串行执行，跨 socket 并行；正在执行项计入 64 项/8 MiB，高水位等于该阈值时 pause，下一项拒绝，降到 4 MiB resume。`BoundedOutboundQueue` 用 `StreamSink.addStream` 串行写：chat/control 为 64 项/8 MiB，溢出 fail closed；audio 为 32 包/512 KiB 并丢弃最旧未发送包；mouse move/scroll 合并为每 session 最新值，key/button/release 队列 128 项/256 KiB，可靠事件溢出时停止 session 以避免卡键。文件发送必须 await outbound credit，并继续受 16 MiB ACK window 约束。

### 4. 文件路径、完整性和续传

- incoming 文件名必须是单一组件：非空、UTF-8 不超过 240 bytes，不含 `/`、`\\`、NUL/控制字符或 Windows 非法字符 `< > : " | ? *`，不是 `.`/`..`，不以空格或点结尾，也不是 Windows 保留名。非法 offer 以 `invalid_name` 拒绝。
- transferId 只接受规范 UUID，临时文件始终为 `<download>/.whisper/transfers/<uuid>.part`；join 后 canonical path 必须仍在该目录内。
- sender 的本地 `path` 与 content URI 只存本地 DB，fileOffer wire 上强制为空。
- 最终文件名在落盘时再次分配；使用进程锁和 `File.create(exclusive: true)` 预留 `name.ext`、`name-1.ext` 等目标，再把 temp 内容写入自己预留的文件。不得删除或 rename 覆盖既有路径。
- metadata 固定 `checksumAlgorithm=sha256`，offer 前计算完整来源 SHA-256。receiver 在写入时维护 streaming SHA-256，完成后先比对再发布文件；不匹配标记 failed、删除不可信 temp 并发 `integrity` error。
- resume ready 在 `durableOffset > 0` 时附带最后 `min(1 MiB, durableOffset)` bytes 的 SHA-256 与 proof length。sender 对源文件相同区间验证；不匹配发 `resume_proof_mismatch`，receiver 只自动清零一次并重新 ready，防止把其他文件前缀拼接进传输。
- offer 在任何 DB/message/temp 副作用前验证 size 在 `0..100 GiB`、checksum 为 64 hex SHA-256、chunk/window 为协议固定值，并原子执行 per-peer 32/global 128 非终态队列限额。fileData 写前要求 payload <=512 KiB、offset 非负且严格等于期望、`offset + payload.length <= size`、sequence/flags 合法；control 的 frame/action/header offset/durableOffset 必须一致。
- 1 MiB tail proof 只是快速探测，不能证明整个 prefix；最终完整 SHA-256 才是发布门。reset 必须同时 truncate temp、清 checksum state 与 durable offset。发布成功在同一事务更新 `FileTransfer.finalPath` 与对应 `Message.path`，之后才通知 UI/Android picker。

### 5. 媒体通道 capability token

`SessionUpgradeTokenRegistry` 生成 32-byte 随机 base64url token，绑定 `route + sessionId + peerId`，有效期 30 秒、只消费一次、最大 128 项。sink 在签名 chat 控制通道接受 audio/audio-group/input offer 时签发 token，通过 accept control 返回；source 以 `?session=<id>&token=<token>` 升级对应路径。

router 在 WebSocket upgrade 前消费 token，返回含 peerId/sessionId/route/MAC context 的 claim；manager 校验 inner control 的 source/sink/group/stream 均与 authenticated peer/local/session 一致，并只接受带正确 sequence+HMAC 的包。token 只出现在成功 accept，缺失、过期、重复、route/session 不符均 401；reject/error/stop 不携带 token。URI 诊断先去掉 query。实时监听者可以抢先消费 token造成拒绝服务，但没有 X25519 派生的 media MAC key，不能伪造音频或输入包。

### 6. 传输活性、队列与重连

- 每个 outgoing window 在最后一帧发送后启动 15 秒 ACK timer；前两次超时从最后 durable offset 重发，第三次把传输置为 waitingReconnect 并通知 socket manager 将该 peer 判为失活。ACK 必须单调、不超过已发送 window、size 匹配，并绑定 connection generation；旧 timer/onDone 只能 `removeIfCurrent(connectionId)`，不得关闭替换后的新连接。
- ACK、complete、cancel、error、disconnect 与 close 都取消对应 timer/retry state。
- active outgoing 的本地取消、源读取失败、远端 error 和异常路径统一调用一个 async release helper，并立即启动返回的 next transfer；queued 取消只移除自己，不重启当前 active。incoming 对称推进。
- `PeerReconnectController` 对已 pin 且允许自动连接的 peer 使用 `1,2,4,8,16,30,60` 秒上限 60 秒、20% jitter 的退避；成功清零，手动断开/应用关闭/撤销信任永久取消。新 mDNS resolve 可刷新 endpoint 并提前下一次尝试。
- `connectToServer` 直到 signed result 验证并注册 peer 后才返回成功，不能把 TCP/WebSocket ready 当作鉴权成功。

### 7. Server 生命周期

`startServer` 改为 `Future<ServerStartResult>`，先 await 前一个 `closeGracefully(closeServer:true)`，再 bind 新端口。并发 start 通过单一 lifecycle future 串行化。`close` 返回 Future 或移除，所有调用方必须 await；`FileTransferEngine.closeAll` 必须 await recoverable 状态落库，audio/input manager 保存并关闭 subscription/sink。close 等待 subscriptions、收发 queues、transfer handles、media/input session、peer registry 与 `HttpServer.close`，再清状态和发 onClose。禁止 `unawaited(closeGracefully(...))` 的重启竞态。

### 8. mDNS 与平台权限

mDNS service 必须等待 server bind 完成后发布，SRV port 直接等于实际端口；连接 host 使用非空 `ResolvedBonsoirService.host`，lost event 按稳定 instance key 清缓存，不再从 TXT 读取自报 IP。instance name 使用 `whisper-<public-key-fingerprint 前 8 位>`，TXT 仅保留 `v=6` 与稳定但可关联的 `pkh`；移除 uid、name、platform、host、port、trustedPeers、autoConnect。已知设备通过 pinned public key fingerprint 关联，未知设备先显示通用附近设备，鉴权后才显示 signed profile。

新增统一 `PeerEndpoint(host,port)`，chat/media URI 必须用 `Uri(scheme:'ws', host: host, port: port, path: ...)` 构造。地址选择支持 RFC1918 10/8、172.16/12、192.168/16、IPv6 ULA/global 与 scoped link-local，不再回退广播 `127.0.0.1`；media 复用已验证 peer endpoint，不从 profile 自报 host 连接。多网卡按已解析 service endpoint 保存，并在网络切换时刷新。

iOS 保留 `NSLocalNetworkUsageDescription` 与 `_whisper._tcp` 的 `NSBonjourServices`，并把当前错误类型的 `NSAppTransportSecurity` 字符串改成包含 `NSAllowsLocalNetworking=true` 的字典。iOS 没有通用 preflight 查询 API：初始状态为 unknown，由 Bonjour/NWBrowser 操作触发系统提示并将 policy-denied 映射为 denied；不能在启动前声称 granted。[Apple Local Network Privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

Android manifest 增加 `ACCESS_NETWORK_STATE`、`ACCESS_WIFI_STATE`、`CHANGE_WIFI_MULTICAST_STATE`、带 `neverForLocation` 的 `NEARBY_WIFI_DEVICES`，并声明未来 API 37 的 `ACCESS_LOCAL_NETWORK`。正常 API 33-36 不额外请求；Android 16 仅在 LNP compat 测试启用时请求 Nearby devices；target API 37 后运行时请求 ACCESS_LOCAL_NETWORK。plugin 必须 ActivityAware、串行 permission request，并在 resume 撤销或 socket SecurityException 时停止 server/discovery并显示设置入口。[Android Local Network Permission](https://developer.android.com/privacy-and-security/local-network-permission)

### 9. FTP 与日志

匿名 read-write FTP 与主连接身份体系无法共享授权，直接删除 `ftp_server` 依赖、`SimpleFtpServer`、设置入口和遗留偏好 API，不提供兼容开关。

新增网络日志脱敏助手并扫描全 `lib/`。默认只记录事件名、受限本地 reason code、错误类型、字节数、状态和短哈希；禁止记录正文、远端 errorMessage、路径/URI、IP、token、签名、公钥、配对码和完整 uid。`WHISPER_REMOTE_INPUT_TRACE=1` 仍可打开协议诊断，但输出也必须脱敏；release 默认不写逐包日志。

## 数据迁移与兼容性

- schema 5 -> 6：新增 `identity_public_key`，删除空 uid 行；同 uid 重复行按 `auth desc, last_time desc, id desc` 选 keeper，合并 `auth`/`clipboard` 后删除其余，再创建 uid unique index。
- `upsertDevice` 使用 uid 冲突目标，发现更新不得清空 `auth` 或 pinned key。
- `auth=true` 但 pin 为空的旧记录视为 legacy trust，只能触发重新配对，不能自动连接或自动批准。
- 协议 v6 无 legacy auth、匿名 media 或 checksum=none fallback。旧版本得到明确 upgrade_required 后关闭。

## 测试与发布门

核心使用真行为单测：Ed25519/X25519 transcript、HKDF golden vector、frame MAC/sequence/重放、client/server 状态机乱序与迟到 callback、pairing code 对称性、来源绑定、收发限额/backpressure、token TTL/单次消费/media MAC、路径穿越、overrun、队列上限、同名不覆盖与 DB path、SHA-256、resume proof、ACK generation、队列推进、退避、fresh/upgrade DB 迁移和 10/172/IPv6 endpoint。Shelf handler 用内存请求与本地 loopback integration test；平台 manifest/plist 与全 `lib/` 敏感日志禁用使用仓库现有 source-test 惯例。

每个原子任务先红后绿并独立 commit；最终必须通过 `dart run build_runner build --delete-conflicting-outputs`、`flutter gen-l10n`、`flutter analyze`、`flutter test`、`./script/test_remote_input_keys.sh`。Android 另跑 debug APK 构建；iOS 本机若不能签名，至少执行 plist/source tests 并记录真机本地网络授权为残留风险。
