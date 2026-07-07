# B 组:文件传输引擎抽离 — 设计

> 网络架构重构第 2 组(共 3 组)。前置:A 组(wire 字符串化+互拨裁决)已合入 dev(0641ea2..453ce26)。

## 背景(2026-07-07 架构评审 + 探查结论)

`lib/socket/svrmanager.dart`(~4200 行)内并存三套文件传输实现:

- **a) legacy signal**:`MessageEnum.File`/`FileSignal` JSON 消息 + 裸二进制写 `_ioSink`。无 capability 门控,是最老的兜底。
- **b) WSP2 resumable**:`TransferChunkFrame`(magic `WSP2`)+`TransferControl`/`TransferAction`,`fileResumeV1` 门控,含 `_listen` 头部的裸分帧重组缓存(`_pendingIncoming*ByPeer`)。
- **c) V3**:`WhisperFrameV3`(magic `WFR3`)+`FileTransferV3Control`,`fileTransferV3` 门控,窗口/校验/断线恢复完整。

**关键事实**(探查证据):发送路径 `sendFileTo`/`sendAndroidContentUriTo` 只判 `fileTransferV3`,**无 fallback 链**,不支持直接拒发;`retryTransfer`/`cancelTransfer` 同样只操作 V3。同版本设备之间 a、b 完全不可达;a 栈零测试保护、不写 `FileTransferData` 状态机。

## 全局决策

- **删除 a、b 两套栈**(用户确认,2026-07-07,"可以,我相信你"):不兼容旧版本,同版本设备群里它们是死代码。断线续传不受影响——`waitingReconnect` 恢复逻辑属于 V3。
- **`MessageEnum` 的值一个都不删、不重排**:`type` 以 `intEnum` 序号持久化在 DB 历史行里,删值会错位解码历史消息。只删处理分支;残余 `File`/`FileSignal`/`TransferControl` JSON 消息(仅可能来自旧版对端)落到忽略。
- **V3 栈抽成 `FileTransferEngine`**,依赖全部构造注入,首次可构造、可 mock、可真单测。
- **外部 API 面零改动**:`sendFile`/`sendFileTo`/`sendPickedFileTo`/`retryTransfer`/`cancelTransfer` 留在 `WsSvrManager` 作 facade 转发,`conversation.dart`/`deviceList.dart` 不动。
- 源级测试与代码**同批更新**(约 6 个 `*_source_test.dart` grep svrmanager 特定串,删/迁代码会连带失效)。

## 删除清单

### a 栈
- 字段:`_ioSink`、`_receivingFile`、`_sendingFile`、`_currentSize`、`_currentFileTimestamp`、`_currentLen`、`_sendingFiles`。
- 方法:`_sendFileChunk`、`_handleFileMsg`、`_finalizeReceivedFile`、`_prepareIOSink`、`_freeIoSink`、`_sendFileSignal`、`_sendFile`。`_freeIoSink` 在 `closeGracefully` 有调用点,删除时一并清理调用处。
- `_listen` 分支:`MessageEnum.FileSignal` case、`MessageEnum.File` case 的 legacy 子分支、`default` 分支写 `_ioSink` 的裸二进制段。
- `lib/model/message.dart`:`FileSignal` 类(仅 a 栈使用)。

### b 栈
- 方法:`_handleResumableFileMsg`、`_handleTransferControl`、`_handleResumeProbe`、`_handleReady`、`_handleRestart`、`_handleTransferProgress`、`_handleTransferComplete`、`_handlePeerPause`、`_handlePeerCancel`、`_handlePeerError`、`_sendNextTransferChunkSafely`、`_sendNextTransferChunk`、`_handleTransferChunk`。
- 字段:`_pendingIncomingChunkHeadersByPeer`/`_pendingIncomingRawOffsetsByPeer`/`_pendingIncomingRawRemainingByPeer`(含 `_handlePeerDisconnected` 里上一批加的清理三行与 `_clearPendingIncomingChunk`);窗口/序列 map(`_outgoingWindowSentAt`/`_outgoingWindowEndOffsets`/`_outgoingTransferSequences`/`_incomingWindowEndOffsets` 等)**逐个甄别**:删完 a+b 后仅被已删代码引用的删除,仍被 V3 引用的保留随 V3 迁移。
- `_listen`:头部裸分帧重组块、`MessageEnum.TransferControl` case、`default` 的 `TransferChunkFrame.looksLikeFrame` 段。
- capability:`fileResumeV1` 字段从 `PeerCapabilities` 删除(constructor/field/toJson/fromJson 四处)+ svrmanager 广告位与 `_supportsResumableTransfer*` 全部 getter。
- `lib/model/message.dart`:`TransferChunkFrame`/`TransferControl`/`TransferAction`(确认无 V3 引用后删)。
- 孤儿:svrmanager 对 `lib/state/resumable_transfer_window.dart` 的 import 未见调用;确认后删 import,若 `TransferFrameRange` 全仓无引用则删文件与其测试。
- 测试:`resumable_transfer_protocol_test.dart`、`resumable_transfer_window_test.dart`、`resumable_transfer_interleave_source_test.dart` 删除;`socket_multi_peer_auth_source_test.dart` 的 pending-buffers 清理断言删除;`multi_peer_transfer_routing_source_test.dart` 甄别更新(runtime 为 b/c 共用)。

## FileTransferEngine

### 新文件 `lib/socket/file_transfer_engine.dart`

```dart
class FileTransferEngine {
  FileTransferEngine({
    required bool Function(String peerId, Object bytes) sendBytesToPeer,
    required void Function(TransferSnapshot snapshot) emitTransferUpdated,
    required void Function(String message) notify,
    required PeerProfile? Function(String peerId) remoteProfileFor,
    required String Function() localUid,
    LocalDatabase Function() database = LocalDatabase.new,
  });
}
```

- 迁入:V3 全部方法(`_handleFileTransferV3Offer/Data/Control/Ready/Ack/Complete/Cancel/Error`、`_sendFileTransferV3*`、`sendFileTo`/`sendPickedFileTo`/`sendAndroidContentUriTo`/`retryTransfer`/`cancelTransfer` 的实现体)、V3 持有字段(`_receivingTransferWritersV3`、`_receivingTransfers`、`_receivingChecksums`、`_receivingTransferOffsets`、`_incoming*SinceProgress`、`_incomingWindowStartedAt`、存活的窗口/序列 map、`_transferRuntime`、`_sendFileLock`)、持久化助手(`_updateTransfer`/`_persistTransfer`/`_emitTransferById`)、断线恢复(`_markPeerTransfersWaitingReconnect`→`handlePeerDisconnected(peerId)`、`_resumeRecoverableOutgoingTransfers`→`resumeRecoverableOutgoing()`)、全局关闭(`closeAll()`,承接 `closeGracefully` 里的 transfer 清理)。
- 注入语义:`sendBytesToPeer` 包装 svrmanager 的 `_sendBytesToPeer`;`emitTransferUpdated` 包装 `_dispatchToAll((e) => e.onTransferUpdated(...))`;`notify` 包装 `onNotice` 分发;`remoteProfileFor` 用于 `fileTransferV3` capability 判断;`localUid` 取 `sender`。沿用 audio coordinator `handleControlMessage(sendControl:)` 的回调注入既有模式。
- WakelockPlus、编解码(`wire_message_codec`)随迁入代码保留原样。

### svrmanager 残留(facade + 路由)

- 单例持有 `late final FileTransferEngine _transferEngine`(构造时注入回调)。
- 公开 API 原签名转发:`sendFile`/`sendFileTo`/`sendPickedFileTo`/`retryTransfer`/`cancelTransfer` → engine 同名方法。
- `_handleWhisperFrameV3` 将 `fileOffer`/`fileData`/`fileControl` 帧转发 engine;`_handlePeerDisconnected` 调 `engine.handlePeerDisconnected`;`closeGracefully` 调 `engine.closeAll()`。
- `ISocketEvent` fan-out、帧嗅探、鉴权、心跳等一概不动。

## 测试策略

| 阶段 | 内容 |
|---|---|
| 删 a | 全量 suite 保持绿(a 零测试,理论无连带);`flutter analyze` 无告警 |
| 删 b | 删除/更新上述测试文件,同 commit;全量绿 |
| 抽引擎 | `file_transfer_v3_source_test.dart` 等源级测试同批改指向 `file_transfer_engine.dart`;全量绿 |
| 新增 | 引擎注入式单测:可用全 fake 依赖构造;`sendFileTo` 对无 `fileTransferV3` capability 的 peer 拒发且 `notify` 被调;`handlePeerDisconnected` 将非终态传输置 `waitingReconnect`(用注入 database 的既有测试基建,若 house 无内存 DB 惯例则退化为源级断言并在报告注明) |

## 执行顺序与风险

1. 删 a → 2. 删 b → 3. 抽引擎 → 4. 引擎单测补强。每步独立 commit、全量绿。先删后抽使迁移面最小。
- 风险 1:`_listen` default 分支 a/b 逻辑纠缠——删除后确认 V3 帧探测之外无任何裸字节流依赖。
- 风险 2:b/c 共享字段甄别错误——以"删完 a+b 后 analyzer 报 unused + grep 零引用"为删除依据,机械可验。
- 风险 3:迁移是大 diff——纯机械搬迁(方法体不改),靠全量 suite + 源级断言 + 终审把关。

## 不做

- 不动 `PeerConnectionRegistry`/鉴权/音频/remote-input;不做 C 组(packet transport 收敛)。
- 不给引擎设计新的传输行为;方法体原样迁移,行为零变化。
- 不删 `MessageEnum` 值;不动 DB schema。
