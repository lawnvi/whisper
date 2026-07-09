# Whisper 网络安全与可靠性加固 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留 Shelf WebSocket 与现有业务协议分层的前提下，为 Whisper 建立可证明的设备身份、逐 socket 授权、文件与媒体通道防护，以及可恢复且有背压的 LAN 传输。

**Architecture:** chat WebSocket 先经过 admission 和 Ed25519 challenge-response，再把已验证 peerId 绑定到 `PeerSocketSession`；所有消息、transfer 与媒体 token 都只消费该授权上下文。文件引擎补齐路径/哈希/proof/ACK watchdog，连接层补齐 per-socket queue、awaited lifecycle 与指数重连；mDNS 和平台配置只负责发现 endpoint，不再承担信任传播。设计依据：`docs/superpowers/specs/2026-07-10-network-security-hardening-design.md`。

**Tech Stack:** Flutter/Dart 3.11、Drift、Shelf WebSocket、Bonsoir、`cryptography ^2.9.0`、flutter_test、Android Kotlin、iOS plist。

## Global Constraints

- 保留 Shelf WebSocket；不做 QUIC、TLS、公网中继或 payload 加密重写。
- 协议最低版本为 5；旧 auth、匿名 media 和 checksum=none 均 fail closed，不提供降级。
- Ed25519 证明长期身份；临时 X25519 + HKDF-SHA256 只派生每包完整性 key。payload 仍为明文，产品文案不得称为端到端加密或“不可信 LAN 上安全”。
- 首次配对必须在两端显示由双方公钥和 nonce 派生的同一 6 位码并分别确认；旧 trust 无 pin 必须重配。
- chat/file/audio/input 的固定收发限额与 TTL 必须逐字采用 spec 数值，不在实现中另设隐式默认值。
- 鉴权后所有 chat/file/control/media payload 必须先验证方向性 HMAC 与严格递增 sequence；业务 parser 不得接收未认证 bytes。
- 新用户文案只改 `lib/l10n/app_*.arb`，随后运行 `flutter gen-l10n`；不手改生成的 localizations。
- Drift 只改源表后运行 build_runner；不手改 `lib/model/LocalDatabase.g.dart`。
- 每个任务遵循 red -> green -> focused regression -> `flutter analyze` -> 原子 commit；commit 为 Conventional Commit，type/scope 英文、subject 简洁中文且结尾无标点。
- 共享 worktree 中若遇到 UI 审美任务的并行改动，保留对方修改，只在本计划列出的协议/权限接口上做最小合并。

---

### Task 1: Ed25519 身份原语、pin 存储与 uid 唯一迁移

**Files:**
- Create: `lib/socket/device_identity.dart`
- Create: `lib/socket/auth_transcript.dart`
- Create: `lib/socket/auth_protocol.dart`
- Create: `lib/socket/auth_session_keys.dart`
- Create: `lib/socket/authenticated_frame.dart`
- Modify: `pubspec.yaml`, `pubspec.lock`
- Modify: `lib/helper/local.dart`
- Modify: `lib/model/device.dart`, `lib/model/LocalDatabase.dart`
- Generate: `lib/model/LocalDatabase.g.dart`
- Test: `test/device_identity_test.dart`, `test/auth_protocol_test.dart`, `test/auth_session_keys_test.dart`, `test/authenticated_frame_test.dart`, `test/local_database_device_identity_test.dart`

**Interfaces:**
- Produces `DeviceIdentityStore.loadOrCreate(): Future<DeviceIdentity>`，`DeviceIdentity.publicKeyBase64Url`，`DeviceIdentity.sign(Uint8List): Future<String>`，`verifyDeviceSignature(...)`。
- Produces `AuthTranscript.challengeBytes/proofBytes/resultBytes(...)` 与 `pairingCode(...): String`；所有字段使用 domain + length-prefix canonical encoding，digest byte order/modulo 由 golden vector 固定。
- Produces `AuthEnvelope` 与 `AuthAction { hello, challenge, proof, result }`，JSON decode 对缺字段、非 32-byte nonce、非法 base64 和未知 action 抛 `FormatException`。
- Produces `AuthSessionKeys.derive(...)` 的方向性 chat/media key，以及 `AuthenticatedFrameCodec` 的 uint64 sequence + plaintext payload + HMAC-SHA256 验证。
- Produces DB API `fetchPinnedIdentityKey(uid)`, `pinDeviceIdentity(uid, publicKey)`, `hasPinnedIdentity(uid, publicKey)`。

- [ ] **Step 1: 写失败测试**

覆盖：并发 loadOrCreate 只生成一把 key；签名可验且错误 key/修改 transcript 失败；challenge/proof/result domain 不可互换；X25519 两端导出相同方向 key；MAC 篡改/重放/错序/反向 key 均失败；双方得到同一 6 位码 golden；Auth JSON 严格解析；fresh schema 与 schema 5 升 6 后均有唯一索引，二次 reopen 幂等、并发 upsert 不清空 `auth` 与 pin；旧 `auth=true` 且 pin 空不算可自动认证。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/device_identity_test.dart test/auth_protocol_test.dart test/auth_session_keys_test.dart test/authenticated_frame_test.dart test/local_database_device_identity_test.dart`

Expected: FAIL，三个新模块、`identityPublicKey` 和 DB API 尚不存在。

- [ ] **Step 3: 实现最小身份与迁移**

加入 `cryptography: ^2.9.0`。`DeviceIdentityStore` 用进程锁保护首次生成；`LocalSetting` 只保存本机 Ed25519 seed。`Device.identityPublicKey` 为 `NOT NULL DEFAULT ''`，`uid` 在 fresh Drift schema 定义 unique；schema 设为 6。升级事务去除空/重复 uid 后创建唯一索引；`upsertDevice` 使用 uid conflict target并保留 `auth`/pin。握手每次生成临时 X25519 key；HKDF 输入完整 transcript hash 并派生方向 key。auth result 前只收 raw Auth，result 验证后所有 payload 走 `AuthenticatedFrameCodec`。

- [ ] **Step 4: 生成代码并转绿**

Run: `flutter pub get`

Run: `dart run build_runner build --delete-conflicting-outputs`

Run: `flutter test test/device_identity_test.dart test/auth_protocol_test.dart test/auth_session_keys_test.dart test/authenticated_frame_test.dart test/local_database_device_identity_test.dart`

Expected: PASS；迁移后第二次 reopen 仍幂等。

- [ ] **Step 5: 静态检查并提交**

Run: `dart format lib/socket/device_identity.dart lib/socket/auth_transcript.dart lib/socket/auth_protocol.dart lib/helper/local.dart lib/model/device.dart lib/model/LocalDatabase.dart test/device_identity_test.dart test/auth_protocol_test.dart test/local_database_device_identity_test.dart`

Run: `flutter analyze`

```bash
git add pubspec.yaml pubspec.lock lib/helper/local.dart lib/model/device.dart lib/model/LocalDatabase.dart lib/model/LocalDatabase.g.dart lib/socket/device_identity.dart lib/socket/auth_transcript.dart lib/socket/auth_protocol.dart lib/socket/auth_session_keys.dart lib/socket/authenticated_frame.dart test/device_identity_test.dart test/auth_protocol_test.dart test/auth_session_keys_test.dart test/authenticated_frame_test.dart test/local_database_device_identity_test.dart
git commit -m "feat(auth): 增加设备签名身份与公钥绑定"
```

---

### Task 2: Challenge-response、逐 socket pre-auth 状态与配对码 UI

**Files:**
- Create: `lib/socket/peer_socket_session.dart`
- Create: `lib/state/pairing_request.dart`
- Create: `lib/widget/pairing_dialog.dart`
- Modify: `lib/socket/svrmanager.dart`
- Modify: `lib/state/peer_profile.dart`
- Modify: `lib/page/deviceList.dart`, `lib/page/conversation.dart`
- Modify: `lib/l10n/app_zh.arb`, `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Generate: `lib/l10n/app_localizations*.dart`
- Test: `test/peer_socket_session_test.dart`, `test/socket_auth_handshake_test.dart`, `test/pairing_dialog_test.dart`, `test/socket_multi_peer_auth_source_test.dart`

**Interfaces:**
- `PeerSocketSession` 按 role 暴露 server phases `awaitingHello/awaitingProof/awaitingLocalApproval/authenticated/closing` 与 client phases `awaitingChallenge/awaitingLocalApproval/awaitingResult/authenticated/closing`，并持有 connection generation、候选 Ed25519/X25519 key、MAC codec 与 30 秒 timer。
- `PairingRequest` 包含 `device`, `pairingCode`, `reason { newDevice, identityChanged, legacyTrustWithoutPin }`, `canApprove`。
- `ISocketEvent.onPairing(PairingRequest, void Function(bool) resolve)`：未知/变更/legacy pin 时两端都必须明确确认；callback 绑定 generation，超时/关闭后无效。
- `connectToServer` 在本任务暂保 callback 外形，但只能在 signed result 验签并注册连接后 callback success。

- [ ] **Step 1: 写失败测试**

用两套确定性 Ed25519/X25519 test keys 驱动 hello -> challenge -> 两端确认 -> proof -> signed result。未知候选允许 intendedPeerId 为空但 intendedPkh 必须匹配 challenge key。断言 nonce 重放、乱序、profile digest 不一致、错 key、篡改 result、超时和迟到 callback 均不 pin/注册；legacy、未知与任一侧 key change 都触发正确 reason，两端各有确认/拒绝且显示同一 6 位码。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/peer_socket_session_test.dart test/socket_auth_handshake_test.dart test/pairing_dialog_test.dart`

Expected: FAIL，状态类、事件与 UI 不存在。

- [ ] **Step 3: 实现握手并移除旧 trust 泄露**

把 `MessageEnum.Auth` content 改为严格 `AuthEnvelope`。server proof/client signed result 验证前不得注册。允许后双方 pin 并启用 MAC codec。新增白名单 `WirePeerProfile`，只含 uid/name/platform/capabilities/topology，其 canonical digest 纳入签名；删除 Drift profile 的 password/auth/clipboard/host/id/lastTime/around 及 trust/auto 设置。协议版本设 5，低版本回复 `upgrade_required` 后关闭。

- [ ] **Step 4: 接入配对 UI 与本地化**

`pairing_dialog.dart` 统一 device list/conversation 两处提示；两端均有拒绝/确认，显示分组数字但语义值仍为 6 位码。增加新设备、身份变化、旧信任重配、比对两台设备、版本过低文案并运行 `flutter gen-l10n`。同步更新旧 `connect_prompt_device_list_source_test.dart`，不再钉住 `onAuth/showCupertinoDialog` 结构。

- [ ] **Step 5: 转绿与回归**

Run: `flutter test test/peer_socket_session_test.dart test/socket_auth_handshake_test.dart test/pairing_dialog_test.dart test/socket_multi_peer_auth_source_test.dart test/remote_input_mutual_trust_source_test.dart test/connect_prompt_device_list_source_test.dart`

Run: `flutter analyze`

Expected: PASS；source test 不再允许 `self.auth || localTemp.auth` 直接注册 peer。

- [ ] **Step 6: 提交**

```bash
git add lib/socket/peer_socket_session.dart lib/socket/svrmanager.dart lib/state/pairing_request.dart lib/state/peer_profile.dart lib/widget/pairing_dialog.dart lib/page/deviceList.dart lib/page/conversation.dart lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/app_localizations.dart lib/l10n/app_localizations_zh.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_es.dart test/peer_socket_session_test.dart test/socket_auth_handshake_test.dart test/pairing_dialog_test.dart test/socket_multi_peer_auth_source_test.dart test/remote_input_mutual_trust_source_test.dart
git commit -m "feat(auth): 实现挑战应答与配对码确认"
```

---

### Task 3: 路由 admission、per-socket 背压与 awaited server lifecycle

**Files:**
- Create: `lib/socket/socket_admission.dart`
- Create: `lib/socket/bounded_receive_queue.dart`
- Create: `lib/socket/bounded_outbound_queue.dart`
- Modify: `lib/socket/peer_socket_session.dart`, `lib/socket/svrmanager.dart`
- Modify: `lib/socket/file_transfer_engine.dart`, `lib/socket/packet_byte_transport.dart`
- Modify: `lib/audio/audio_share_manager.dart`, `lib/remote_input/remote_input_manager.dart`
- Modify: `lib/page/deviceList.dart`, `lib/page/conversation.dart`
- Test: `test/socket_admission_test.dart`, `test/bounded_receive_queue_test.dart`, `test/bounded_outbound_queue_test.dart`, `test/socket_server_lifecycle_test.dart`, `test/ws_event_dispatch_test.dart`

**Interfaces:**
- `SocketAdmissionController.tryOpen(address, now)` 返回 `AdmissionLease` 或拒绝原因；固定执行 32 chat、8 pre-auth、2/IP、30 upgrades/IP/minute。
- `BoundedReceiveQueue.add(byteLength, Future<void> Function())` 每 socket 有序且计入正在执行项；达到 8 MiB/64 项 pause，下一项拒绝，降到 4 MiB resume；`closeAndDrain()` 可 await。
- `BoundedOutboundQueue` 用 `addStream` 串行写；chat/control 64项/8MiB fail closed，audio 32包/512KiB drop-oldest，mouse move/scroll coalesce-latest，key/button/release 128项/256KiB overflow 时停止 session。
- `WsSvrManager.startServer(int): Future<ServerStartResult>`；`closeGracefully` 幂等；移除 fire-and-forget `close()` 或改为返回同一个 Future。

- [ ] **Step 1: 写失败测试**

断言 chat lease 到 socket close 才释放，markAuthenticated 只释放 pre-auth/IP 配额；32 个已鉴权连接拒绝第 33 个，IPv4-mapped IPv6 规范化。一 socket 阻塞不影响另一 socket；同 socket 保序；收发 pause/resume、drop/coalesce/fail-close 确定。close 等待 action、outbound drain、transfer recoverable 状态落库及 chat/audio/input subscription/sink 关闭。loopback 覆盖 GET/non-GET、非 upgrade 400、畸形 upgrade、非空 Origin 403、未知路径 404、超限 429；连续 start 先释放旧端口。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/socket_admission_test.dart test/bounded_receive_queue_test.dart test/bounded_outbound_queue_test.dart test/socket_server_lifecycle_test.dart`

Expected: FAIL，新类不存在且当前任意路径会落到 chat handler。

- [ ] **Step 3: 实现路由、queue 与生命周期**

client URL 改为 `/chat`。只接受缺失 Origin；Auth/普通 message 分别限制 256 KiB/1 MiB，WFR3 fileData 保持 512 KiB。session 持有 receive/outbound queue 与 subscription；所有 chat/file send await outbound credit，audio/input manager 保存 subscription/sink 并使用实时队列。删除全局 `_receiveQueue`。start/close 串行；`FileTransferEngine.closeAll` await recoverable 状态落库，随后 close await subscriptions、queues、transfer/media/input、registry 和 server 才清状态。

- [ ] **Step 4: 转绿与回归**

Run: `flutter test test/socket_admission_test.dart test/bounded_receive_queue_test.dart test/bounded_outbound_queue_test.dart test/socket_server_lifecycle_test.dart test/ws_event_dispatch_test.dart test/app_shutdown_test.dart`

Run: `flutter analyze`

Expected: PASS；`rg "unawaited\(closeGracefully|void startServer|_receiveQueue" lib/socket lib/page` 无命中。

- [ ] **Step 5: 提交**

```bash
git add lib/socket/socket_admission.dart lib/socket/bounded_receive_queue.dart lib/socket/bounded_outbound_queue.dart lib/socket/peer_socket_session.dart lib/socket/svrmanager.dart lib/socket/file_transfer_engine.dart lib/socket/packet_byte_transport.dart lib/audio/audio_share_manager.dart lib/remote_input/remote_input_manager.dart lib/page/deviceList.dart lib/page/conversation.dart test/socket_admission_test.dart test/bounded_receive_queue_test.dart test/bounded_outbound_queue_test.dart test/socket_server_lifecycle_test.dart test/ws_event_dispatch_test.dart test/app_shutdown_test.dart
git commit -m "fix(socket): 限制升级请求并隔离连接接收队列"
```

---

### Task 4: 业务消息与 transfer 来源绑定

**Files:**
- Create: `lib/socket/wire_input_policy.dart`
- Modify: `lib/socket/svrmanager.dart`, `lib/socket/file_transfer_engine.dart`, `lib/socket/file_transfer_v3.dart`, `lib/socket/whisper_frame_v3.dart`
- Test: `test/wire_input_policy_test.dart`, `test/socket_peer_binding_test.dart`, `test/file_transfer_peer_binding_test.dart`, `test/file_transfer_guard_test.dart`

**Interfaces:**
- `WireInputPolicy.validateMessage(message, authenticatedPeerId, localPeerId)` 返回 typed result/reason。
- `isCanonicalTransferId(String)` 只接受 canonical UUID；`FileTransferEngine.handleFrame(String authenticatedPeerId, WhisperFrameV3 frame)` 成为唯一 file frame 入口。

- [ ] **Step 1: 写失败测试**

覆盖 HMAC 篡改、sequence 重放/跳号/倒退、sender/receiver 不匹配、旧 socket 被 registry 替换、pre-auth message/file frame、offer uuid/header transferId 不一致、frame type/action 不匹配、control payload/header offset 不一致、data/control 查到其他 peer 的 transfer、空/超长/带路径 transferId；全部不得改 DB、不得 ACK、不得派发 UI。fileData 还覆盖 payload >512 KiB、offset <0、offset 不等于 expected、`offset + payload.length > declaredSize` 与非法 sequence/flags，确认检查发生在任何写入之前。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/wire_input_policy_test.dart test/socket_peer_binding_test.dart test/file_transfer_peer_binding_test.dart`

Expected: FAIL，当前 file engine 不接收 authenticatedPeerId。

- [ ] **Step 3: 实现 fail-closed 绑定**

在 `_listen` switch 前先用当前 session 的方向性 key 验证 `AuthenticatedFrame` HMAC 与严格递增 sequence，再校验 authenticated session；只有握手期 Auth 使用未绑定入口。file offer/data/control 每次把 socket peer 与持久化 `peerUid` 对比；fileData 在写前校验 512 KiB 上限、连续 offset、声明总长和 flags，control 同时校验 frame type/action/header/durableOffset 一致。违规返回稳定 reason code 并关闭当前 socket。ACK 只能更新 `uuid` 对应且 sender/receiver 与原消息相反的本机记录。

- [ ] **Step 4: 转绿、回归与提交**

Run: `flutter test test/wire_input_policy_test.dart test/socket_peer_binding_test.dart test/file_transfer_peer_binding_test.dart test/file_transfer_guard_test.dart test/file_transfer_v3_control_test.dart`

Run: `flutter analyze`

```bash
git add lib/socket/wire_input_policy.dart lib/socket/svrmanager.dart lib/socket/file_transfer_engine.dart lib/socket/file_transfer_v3.dart lib/socket/whisper_frame_v3.dart test/wire_input_policy_test.dart test/socket_peer_binding_test.dart test/file_transfer_peer_binding_test.dart test/file_transfer_guard_test.dart
git commit -m "fix(socket): 绑定已鉴权消息与传输来源"
```

---

### Task 5: 文件名、路径、不覆盖、SHA-256 与 resume proof

**Files:**
- Create: `lib/socket/file_path_policy.dart`
- Modify: `lib/helper/file.dart`, `lib/socket/file_transfer_source.dart`, `lib/socket/file_transfer_v3.dart`, `lib/socket/file_transfer_engine.dart`, `lib/socket/peer_transfer_runtime.dart`, `lib/model/LocalDatabase.dart`
- Test: `test/file_path_policy_test.dart`, `test/file_transfer_integrity_test.dart`, `test/file_transfer_source_test.dart`, `test/file_transfer_engine_test.dart`, `test/android_received_file_visibility_source_test.dart`

**Interfaces:**
- `validateIncomingFileName`, `safeTransferTempPath(root, transferId)`, `reserveUniqueDownloadFile(root, fileName)` 与 `publishTempWithoutOverwrite(temp, reservation)`。
- `FileTransferV3Control` 增加 `resumeProofSha256`, `resumeProofLength`；proof window 固定 1 MiB。
- metadata 固定 `checksumAlgorithm='sha256'`；单文件上限 100 GiB；每 peer 32、全局 128 queued offers。

- [ ] **Step 1: 写失败测试**

覆盖 `../`、Windows separator、绝对路径、控制字符、Windows 禁止字符 `< > : \" | ? *`、`.`/`..`、保留名、尾随点/空格、超 240 bytes；temp path 必须留在 root。严格拒绝 size 不在 `0..100 GiB`、非 `sha256`、非 64 位 hex digest、改变固定 chunk/window 的 offer；content URI 提前 EOF 必须抛错而非计算短内容 digest。预先存在 `report.pdf` 时发布为 `report-1.pdf` 且原内容不变；并发同名预留得到不同路径。完整 SHA-256 成功发布、单 byte 篡改失败且不发布；尾段 proof 只作快速错误探测，最终仍验证完整文件；proof 不同只允许一次清零重试，清零后 temp 长度与 checksum state 都归零；offer wire path/content URI 必须为空。并在任何 DB/message/temp side effect 前原子拒绝 per-peer 第 33 个、global 第 129 个非终态 incoming+outgoing transfer，返回 `queue_full`。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/file_path_policy_test.dart test/file_transfer_integrity_test.dart test/file_transfer_source_test.dart`

Expected: FAIL，当前 finalize 会删除同名文件且 checksum 为 none。

- [ ] **Step 3: 实现安全落盘和哈希**

offer 前对 path/content source 计算 SHA-256；接收端从零开始 streaming，续传先对现有 prefix 初始化 checksum。ready 附尾段 proof，sender 用它快速筛掉明显错误 prefix 后才接受 durableOffset，但发布仍依赖完整 SHA-256。最终校验通过后用 exclusive reservation 发布，禁止 `finalFile.delete()` 和会覆盖的 rename；在同一完成流程更新 `FileTransfer.finalPath` 与关联 `Message.path`，再触发 UI/Android visibility 通知。完整性失败删除不可信 temp、状态置 failed、发送 `integrity`。

- [ ] **Step 4: 转绿与回归**

Run: `flutter test test/file_path_policy_test.dart test/file_transfer_integrity_test.dart test/file_transfer_source_test.dart test/file_transfer_engine_test.dart test/android_received_file_visibility_source_test.dart`

Run: `flutter analyze`

Expected: PASS；`rg "defaultTransferChecksumAlgorithm = 'none'|finalFile.delete\(\)" lib` 无命中。

- [ ] **Step 5: 提交**

```bash
git add lib/socket/file_path_policy.dart lib/helper/file.dart lib/socket/file_transfer_source.dart lib/socket/file_transfer_v3.dart lib/socket/file_transfer_engine.dart lib/socket/peer_transfer_runtime.dart lib/model/LocalDatabase.dart test/file_path_policy_test.dart test/file_transfer_integrity_test.dart test/file_transfer_source_test.dart test/file_transfer_engine_test.dart test/android_received_file_visibility_source_test.dart
git commit -m "fix(transfer): 校验路径完整性并启用续传证明"
```

---

### Task 6: ACK watchdog、失败队列推进与指数重连

**Files:**
- Create: `lib/socket/transfer_ack_watchdog.dart`
- Create: `lib/state/peer_reconnect_controller.dart`
- Modify: `lib/socket/file_transfer_engine.dart`, `lib/socket/peer_transfer_runtime.dart`, `lib/socket/peer_connection.dart`, `lib/socket/svrmanager.dart`
- Modify: `lib/state/connection_coordinator.dart`, `lib/page/deviceList.dart`, `lib/page/conversation.dart`
- Test: `test/transfer_ack_watchdog_test.dart`, `test/peer_reconnect_controller_test.dart`, `test/file_transfer_queue_progression_test.dart`, `test/file_transfer_state_machine_test.dart`, `test/multi_peer_connection_registry_test.dart`

**Interfaces:**
- watchdog 为每 window 15 秒；timeout 1/2 调 `retransmit(lastDurableOffset)`，第 3 次调 `markPeerUnresponsive(peerId)`；任何终态 `cancel(transferId)`。
- `PeerReconnectController` 使用 `ReconnectTarget(peerId,host,port)`，delay 序列 `1,2,4,8,16,30,60` 秒并加注入式 20% jitter；`connected` 重置，`manualDisconnect/revoke/close` 取消。
- `connectToServer` 改为 `Future<ConnectionAttemptResult>`，成功只代表 signed auth 完成。

- [ ] **Step 1: 写失败测试**

用 fake clock/timer 断言两次重发、第三次 waitingReconnect + socket close、合法 ACK 清 timer；ACK 倒退、超过已发送 window、声明 size 不符均 fail closed。watchdog/timer 绑定 connection generation，旧 timer 不得关闭新 socket；registry 通过 `removeIfCurrent(connectionId)` 保证旧 socket `onDone` 不删除替代连接。active outgoing 在 local cancel、源失败、remote cancel/error、异常 throw 后都恰好启动下一个；queued cancel 不碰 active。重连退避、endpoint 刷新、成功重置、手动断开和关闭取消均确定性测试。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/transfer_ack_watchdog_test.dart test/peer_reconnect_controller_test.dart test/file_transfer_queue_progression_test.dart`

Expected: FAIL，当前 `_outgoingWindowSentAt` 无 timer 且多个失败分支忽略 next id。

- [ ] **Step 3: 实现 watchdog 和统一 release helper**

删除裸 `_outgoingWindowSentAt`，所有 outgoing 终态进入 `_releaseOutgoingAndStartNext`；incoming 使用对称 helper。校验 ACK monotonic/window/size 后才更新 durable offset。第三次 timeout 仅对其 generation 调 `removeIfCurrent`/disconnect，让既有 `handlePeerDisconnected` 标记可恢复传输，再由 authenticated reconnect 的 `resumeRecoverableOutgoing` 发 offer。

- [ ] **Step 4: 实现 reconnect 接线**

只对 DB 中 pin 匹配且 auto-connect 开启的 peer 调度；mDNS 新 endpoint 更新 target；连接尝试仍走完整签名握手。UI 调用点 await `ConnectionAttemptResult`，不再轮询 WebSocket ready。

- [ ] **Step 5: 转绿与提交**

Run: `flutter test test/transfer_ack_watchdog_test.dart test/peer_reconnect_controller_test.dart test/file_transfer_queue_progression_test.dart test/file_transfer_state_machine_test.dart test/multi_peer_connection_registry_test.dart test/auto_connect_planner_test.dart`

Run: `flutter analyze`

```bash
git add lib/socket/transfer_ack_watchdog.dart lib/state/peer_reconnect_controller.dart lib/socket/file_transfer_engine.dart lib/socket/peer_transfer_runtime.dart lib/socket/peer_connection.dart lib/socket/svrmanager.dart lib/state/connection_coordinator.dart lib/page/deviceList.dart lib/page/conversation.dart test/transfer_ack_watchdog_test.dart test/peer_reconnect_controller_test.dart test/file_transfer_queue_progression_test.dart test/file_transfer_state_machine_test.dart test/multi_peer_connection_registry_test.dart
git commit -m "fix(socket): 增加确认超时与指数重连"
```

---

### Task 7: Audio/Input 短期单次 upgrade token

**Files:**
- Create: `lib/socket/session_upgrade_token_registry.dart`
- Modify: `lib/socket/svrmanager.dart`, `lib/socket/packet_byte_transport.dart`
- Modify: `lib/audio/audio_protocol.dart`, `lib/audio/audio_share_manager.dart`, `lib/audio/audio_share_coordinator.dart`, `lib/audio/audio_group_coordinator.dart`, `lib/audio/audio_packet_transport.dart`, `lib/audio/audio_fanout_transport.dart`
- Modify: `lib/remote_input/remote_input_protocol.dart`, `lib/remote_input/remote_input_manager.dart`, `lib/remote_input/remote_input_coordinator.dart`, `lib/remote_input/remote_input_workspace_coordinator.dart`, `lib/remote_input/remote_input_packet_transport.dart`
- Test: `test/session_upgrade_token_registry_test.dart`, `test/media_websocket_authorization_test.dart`, `test/audio_protocol_test.dart`, `test/audio_group_protocol_test.dart`, `test/remote_input_protocol_test.dart`

**Interfaces:**
- registry `issue(route,sessionId,peerId,mediaMacKey,now)` 与 `consume(route,sessionId,token,now): SessionUpgradeClaim?`；claim 带 peer/session/fixed route/media key，32 random bytes、30 秒、单次、128 项，比较使用 constant-time bytes。
- 三类 control 增加 `transportToken`；token 只出现在成功 accept，不进入 error/reject/stop 或 packet frame。
- `buildPeerPacketUri` 接收 query map；日志端必须用 `redactedPacketUri(uri)` 去掉 query。

- [ ] **Step 1: 写失败测试**

断言正常一次消费并返回准确 claim；缺失、过期、重复、错误 route/session/token 均失败；容量淘汰过期项后仍有上限。signed control 的 sourcePeerId/sinkPeerId 必须与 authenticated peer/local 一致，stream/group/input UUID 与 fixed route 绑定；reject/error/stop JSON 不含 token。loopback `/audio` `/input` 无 token 401、非空 Origin 403；合法 token 只允许 claim 对应 session，packet 还必须通过 media HMAC 与单调 sequence，其他 peer/session 或篡改 packet 均丢弃并关闭。协议 JSON roundtrip 保持成功 accept token。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/session_upgrade_token_registry_test.dart test/media_websocket_authorization_test.dart`

Expected: FAIL，当前两个 media route 可匿名升级。

- [ ] **Step 3: 实现 token 签发、消费和 session 绑定**

先验证 signed control 的 inner peer/session/UUID/route 绑定；sink 仅在成功接受 offer 时签发。source 从 accept 构造带 query URI。Shelf router 在调用 manager handler 前消费 token，并把完整 `SessionUpgradeClaim` 传给 `attachChannel`；媒体 packet 使用 claim 的方向性 media key 验证 HMAC/sequence。停止/拒绝/超时清 registry 项；URI diagnostics 永不输出 query。

- [ ] **Step 4: 转绿与回归**

Run: `flutter test test/session_upgrade_token_registry_test.dart test/media_websocket_authorization_test.dart test/audio_protocol_test.dart test/audio_group_protocol_test.dart test/audio_share_coordinator_test.dart test/audio_group_coordinator_test.dart test/remote_input_protocol_test.dart test/remote_input_coordinator_test.dart test/remote_input_workspace_coordinator_test.dart`

Run: `./script/test_remote_input_keys.sh`

Run: `flutter analyze`

- [ ] **Step 5: 提交**

```bash
git add lib/socket/session_upgrade_token_registry.dart lib/socket/svrmanager.dart lib/socket/packet_byte_transport.dart lib/audio/audio_protocol.dart lib/audio/audio_share_manager.dart lib/audio/audio_share_coordinator.dart lib/audio/audio_group_coordinator.dart lib/audio/audio_packet_transport.dart lib/audio/audio_fanout_transport.dart lib/remote_input/remote_input_protocol.dart lib/remote_input/remote_input_manager.dart lib/remote_input/remote_input_coordinator.dart lib/remote_input/remote_input_workspace_coordinator.dart lib/remote_input/remote_input_packet_transport.dart test/session_upgrade_token_registry_test.dart test/media_websocket_authorization_test.dart test/audio_protocol_test.dart test/audio_group_protocol_test.dart test/remote_input_protocol_test.dart
git commit -m "fix(media): 为音频与键鼠通道增加短期令牌"
```

---

### Task 8: mDNS 最小披露、SRV endpoint 与 iOS/Android 本地网络权限

**Files:**
- Create: `lib/state/discovery_identity.dart`
- Create: `lib/state/peer_endpoint.dart`
- Create: `lib/helper/local_network_permission.dart`
- Create: `android/app/src/main/kotlin/com/vireen/whisper/LocalNetworkPermissionPlugin.kt`
- Modify: `lib/page/deviceList.dart`, `lib/state/auto_connect_planner.dart`, `lib/state/connection_coordinator.dart`, `lib/state/peer_profile.dart`, `lib/helper/helper.dart`, `lib/socket/svrmanager.dart`
- Modify: `lib/audio/audio_share_coordinator.dart`, `lib/audio/audio_group_coordinator.dart`, `lib/remote_input/remote_input_coordinator.dart`, `lib/remote_input/remote_input_workspace_coordinator.dart`
- Modify: `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt`
- Modify: `ios/Runner/Info.plist`
- Modify: `lib/l10n/app_zh.arb`, `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Generate: `lib/l10n/app_localizations*.dart`
- Test: `test/discovery_identity_test.dart`, `test/device_discovery_address_source_test.dart`, `test/device_broadcast_service_name_test.dart`, `test/local_network_platform_config_test.dart`, `test/auto_connect_planner_test.dart`

**Interfaces:**
- `DiscoveryIdentity.fromPublicKey` 产生 `pkh` 与 `whisper-<8 chars>`；TXT 只能 `{v:'5', pkh:<hash>}`。
- resolved endpoint 强制来自 `ResolvedBonsoirService.host` + `service.port`；不读 TXT host/port。
- `PeerEndpoint` 统一 chat/audio/input 的 host、port 与 scoped IPv6 URI 构造；支持 10/8、172.16/12、192.168/16、IPv6。
- `LocalNetworkPermission.ensureGranted()`：Android 返回 granted/denied/restricted；iOS 初始为 unknown，由 Bonsoir/NW error 推断 denied，拒绝时 server、broadcast、discovery 均不启动。

- [ ] **Step 1: 写失败测试**

断言先实际 bind `startServer(0)` 再广播其返回端口，TXT key 集合精确为 `v,pkh`，源码不含 trustedPeers/autoConnect/uid/name/platform/host/port attributes。resolved path 仅接受 `service is ResolvedBonsoirService && host != null`，按 instance key 缓存 endpoint，lost 原始事件也能清缓存；null host 不进入候选。known pin fingerprint 可映射旧设备；unknown 只显示通用候选。统一 endpoint 覆盖 10.x、172.16/31、192.168、IPv6 与 scoped link-local，所有 URL 使用结构化 `Uri`。plist 的 ATS 为 dict 且 Bonjour/usage keys 正确；Android normal、16 compat、API 37 三分支权限声明/请求正确，拒绝、撤销、resume 与 socket `SecurityException` 都停止 server/discovery。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/discovery_identity_test.dart test/device_discovery_address_source_test.dart test/local_network_platform_config_test.dart`

Expected: FAIL，当前 TXT 广播完整 uid、name、IP 和 trustedPeers，SRV 端口固定 10004。

- [ ] **Step 3: 实现 discovery 与 auto-connect 调整**

未知服务以 pkh 临时候选存在，signed auth 后才替换为真实 uid/profile。auto-connect 只依据本地 pin fingerprint 和设置，不再依赖远端 TXT 信任列表；未 pin 候选必须手动发起配对。

- [ ] **Step 4: 实现平台配置和拒绝态**

Android normal 模式不额外请求；Android 16 仅在 LNP compat 测试模式请求 `NEARBY_WIFI_DEVICES`；API 37+ 通过原生 string 请求 `ACCESS_LOCAL_NETWORK`，并添加 multicast/network state 权限。自定义 plugin 实现 `ActivityAware`、permission-result callback 与并发请求合并，在 app resume/撤销/`SecurityException` 时停服务并更新状态。iOS 修正 ATS dict，不伪造授权 preflight：初始 unknown，让 Bonsoir 触发系统提示并将明确 policy error 映射为 denied。三语言增加本地网络用途、拒绝与打开设置文案，运行 `flutter gen-l10n`。

- [ ] **Step 5: 转绿与提交**

Run: `flutter gen-l10n`

Run: `flutter test test/discovery_identity_test.dart test/device_discovery_address_source_test.dart test/device_broadcast_service_name_test.dart test/local_network_platform_config_test.dart test/auto_connect_planner_test.dart`

Run: `flutter build apk --debug`

Run: `flutter analyze`

```bash
git add lib/state/discovery_identity.dart lib/state/peer_endpoint.dart lib/helper/local_network_permission.dart lib/helper/helper.dart lib/socket/svrmanager.dart lib/page/deviceList.dart lib/state/auto_connect_planner.dart lib/state/connection_coordinator.dart lib/state/peer_profile.dart lib/audio/audio_share_coordinator.dart lib/audio/audio_group_coordinator.dart lib/remote_input/remote_input_coordinator.dart lib/remote_input/remote_input_workspace_coordinator.dart android/app/src/main/AndroidManifest.xml android/app/src/main/kotlin/com/vireen/whisper/LocalNetworkPermissionPlugin.kt android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt ios/Runner/Info.plist lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/app_localizations.dart lib/l10n/app_localizations_zh.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_es.dart test/discovery_identity_test.dart test/device_discovery_address_source_test.dart test/device_broadcast_service_name_test.dart test/local_network_platform_config_test.dart test/auto_connect_planner_test.dart
git commit -m "fix(discovery): 收敛广播隐私并补齐本地网络权限"
```

---

### Task 9: 移除匿名读写 FTP

**Files:**
- Delete: `lib/helper/ftp.dart`
- Modify: `lib/page/settings.dart`, `lib/helper/local.dart`, `lib/global.dart`
- Modify: `pubspec.yaml`, `pubspec.lock`
- Modify: `lib/l10n/app_zh.arb`, `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Generate: `lib/l10n/app_localizations*.dart`
- Test: `test/anonymous_ftp_removed_source_test.dart`, `test/settings_navigation_source_test.dart`

**Interfaces:** 无替代服务；文件共享只走 authenticated FileTransferEngine。

- [ ] **Step 1: 写失败 source test**

断言 pubspec/lock（包含注释）无 `ftp_server`，全 `lib/` 无 `SimpleFtpServer`/`ServerType.readAndWrite`/`ftp://`/`defaultFtpPort`，settings 无 FTP switch/port/dir，LocalSetting 无 ftp keys/API。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/anonymous_ftp_removed_source_test.dart`

Expected: FAIL，现有依赖、helper 和设置均命中。

- [ ] **Step 3: 删除实现和用户入口**

删除 helper、`global.dart` 端口常量、pubspec 注释依赖、设置 section/硬编码标题、偏好 getter/setter 和三份 ARB 的 `ftpService`；运行 pub get 与 gen-l10n。保留用户磁盘中的旧 SharedPreferences key 不做数据删除，代码不再读取即可。

- [ ] **Step 4: 转绿与提交**

Run: `flutter pub get`

Run: `flutter gen-l10n`

Run: `flutter test test/anonymous_ftp_removed_source_test.dart test/settings_navigation_source_test.dart`

Run: `flutter analyze`

```bash
git add pubspec.yaml pubspec.lock lib/global.dart lib/helper/ftp.dart lib/helper/local.dart lib/page/settings.dart lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/app_localizations.dart lib/l10n/app_localizations_zh.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_es.dart test/anonymous_ftp_removed_source_test.dart test/settings_navigation_source_test.dart
git commit -m "refactor(ftp): 移除匿名读写服务"
```

---

### Task 10: 网络日志隐私、全量验证与文档回写

**Files:**
- Create: `lib/helper/privacy_log.dart`
- Modify: `lib/socket/svrmanager.dart`, `lib/socket/file_transfer_engine.dart`, `lib/socket/packet_byte_transport.dart`
- Modify: `lib/audio/audio_share_diagnostics.dart`, `lib/audio/audio_share_coordinator.dart`, `lib/audio/audio_group_coordinator.dart`
- Modify: `lib/remote_input/remote_input_coordinator.dart`, `lib/remote_input/remote_input_workspace_coordinator.dart`
- Modify: `lib/page/deviceList.dart`, `lib/page/conversation.dart`, `lib/helper/file.dart`, `lib/helper/helper.dart`, `lib/model/LocalDatabase.dart`
- Modify: `docs/superpowers/specs/2026-07-10-network-security-hardening-design.md`（只在实现与设计发生已验证偏差时追加“落地修订”）
- Test: `test/network_log_privacy_source_test.dart`, `test/privacy_log_test.dart`

**Interfaces:**
- `PrivacyLog.shortId`, `redactUri`, `errorType`, `event(name, fields)`；fields 只允许布尔、数字、枚举和已短哈希 id；log sink 可注入供行为测试捕获。
- 禁止字段：消息/通知正文、clipboard、文件名以外的路径、content URI、IP/host、token/query、签名、公钥、pairing code、完整 uid、trusted peer list。

- [ ] **Step 1: 写失败测试**

用注入 sink 做真行为断言，URI query/path、绝对路径、content URI、uid、公钥、远端 errorMessage 都不会出现在输出；source test 扫描全 `lib/` 的已知泄露模式：`message.content` 日志、`文本消息：$str`、`path=$path`、`uri=$uri`、`remoteAddress=`、`trustedPeers=`、`Serving at ws://`、`printLogs: true`。`WHISPER_REMOTE_INPUT_TRACE` 未开启的 release 分支不得调用逐事件 logger。

- [ ] **Step 2: 确认红灯**

Run: `flutter test test/privacy_log_test.dart test/network_log_privacy_source_test.dart`

Expected: FAIL，当前 socket、transfer、discovery 和 remote input 存在明文日志。

- [ ] **Step 3: 接入脱敏日志**

错误只记录 runtime type + 本地 stable reason code，远端 `errorMessage` 不直接写日志或 UI；stack trace 仅 debug。packet diagnostics 不记录完整 URI；transfer 只记录短 transfer id、size/state；discovery 不打印 service serialization；remote input trace 即使 opt-in 也不含 endpoint、path、reason 文本或 key payload。

- [ ] **Step 4: focused 与全量验证**

Run: `flutter test test/privacy_log_test.dart test/network_log_privacy_source_test.dart`

Run: `dart run build_runner build --delete-conflicting-outputs`

Run: `flutter gen-l10n`

Run: `flutter analyze`

Run: `flutter test`

Run: `./script/test_remote_input_keys.sh`

Run: `flutter build apk --debug`

Expected: 全部 exit 0；若本机无法执行 iOS 签名构建，在最终报告列出 `ios/Runner/Info.plist` 仅由 source test 覆盖，真机授权/撤销仍需手测。

- [ ] **Step 5: 最终安全检查**

Run: `rg -n "ftp_server|SimpleFtpServer|trustedPeers.*attributes|defaultTransferChecksumAlgorithm = 'none'|finalFile.delete\(\)|unawaited\(closeGracefully|message\.content.*logger|token=.*logger" lib pubspec.yaml`

Expected: 无命中。

Run: `git diff --check`

Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add lib/helper/privacy_log.dart lib/socket/svrmanager.dart lib/socket/file_transfer_engine.dart lib/socket/packet_byte_transport.dart lib/audio/audio_share_diagnostics.dart lib/audio/audio_share_coordinator.dart lib/audio/audio_group_coordinator.dart lib/remote_input/remote_input_coordinator.dart lib/remote_input/remote_input_workspace_coordinator.dart lib/page/deviceList.dart lib/page/conversation.dart lib/helper/file.dart lib/helper/helper.dart lib/model/LocalDatabase.dart test/privacy_log_test.dart test/network_log_privacy_source_test.dart docs/superpowers/specs/2026-07-10-network-security-hardening-design.md
git commit -m "fix(log): 清理网络日志中的敏感数据"
```

## 实施完成后的人工验证

1. 两台全新设备配对：两端 6 位码相同；拒绝不写 pin；允许后重连不再提示。
2. 备份后清除一台设备身份 seed：另一台显示身份变化，不能自动连接；重新确认后更新 pin。
3. 用浏览器页面尝试连接 `/chat`、无 token 连接 `/audio`/`/input`：分别得到 403/401。
4. 同时与两台 peer 传文件，让其中一台暂停读：另一台消息和传输仍前进。
5. 接收同名文件两次：原文件不变，新文件使用递增后缀；中断后篡改 `.part`，恢复必须从零而非拼接。
6. 传输中断网络再恢复：ACK watchdog 触发断开，退避重连后从已验证 offset 继续；取消当前项立即开始队列下一项。
7. iOS 拒绝再授权 Local Network、Android 16 compat restriction 下拒绝/允许 Nearby devices：server/discovery 状态和提示与权限一致。
8. 在同网抓包确认 TXT 只含 `v`/`pkh`，同时确认业务 payload 仍为明文，并在发布说明中保持这一限制说明。
