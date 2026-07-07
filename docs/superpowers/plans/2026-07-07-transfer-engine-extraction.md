# B 组:文件传输引擎抽离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除 legacy signal(a)与 WSP2 resumable(b)两套死代码传输栈,把 V3 栈从 WsSvrManager 抽离为依赖注入、可单测的 `FileTransferEngine`。

**Architecture:** 先删后抽:Task 1 删 a、Task 2 删 b(含 capability/UI/l10n/测试连带),使迁移面最小;Task 3 把 V3 整体机械迁入新引擎(方法体零改动,仅按映射表替换协作点),svrmanager 留 facade 与帧路由;Task 4 补引擎注入式单测。spec:`docs/superpowers/specs/2026-07-07-transfer-engine-extraction-design.md`。

**Tech Stack:** Flutter/Dart、Drift、flutter_test;源级测试与代码同批更新。

## Global Constraints

- **`MessageEnum` 的值一个都不删、不重排**(DB 以 intEnum 序号持久化历史行);只删处理分支。
- **外部 API 面零改动**:`sendFile`/`sendFileTo`/`sendPickedFileTo`/`retryTransfer`/`cancelTransfer` 签名与语义不变,`conversation.dart`/`deviceList.dart` 的调用点不动(Task 2 删除的两处死 UI 分支除外)。
- **迁移体零行为变化**:Task 3 中 V3 方法体原样迁移,只按映射表替换协作点符号;任何方法体直接引用 `sink`/`_sink` 而映射表未覆盖的,实现者停下报 NEEDS_CONTEXT,不许自行发挥。
- 每个 Task 结束:`flutter analyze` 无告警 + 全量 `flutter test` 通过 + 独立 commit。
- ARB 改动后必须 `flutter gen-l10n`;不得手改 `lib/l10n/app_localizations*.dart` 与 `LocalDatabase.g.dart`。
- Conventional Commits,scope `socket`;commit 尾行:`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。
- 删除判据机械化:删完某栈后,仅被已删代码引用的字段/常量/类 = analyzer unused + 全仓 grep 零引用,即删;仍被 V3 引用的保留。

---

### Task 1: 删除 legacy signal 栈(a)

**Files:**
- Modify: `lib/socket/svrmanager.dart`、`lib/model/message.dart`
- Test: 全量既有 suite(a 栈零专属测试)

**Interfaces:**
- Consumes: 无。
- Produces: svrmanager 中不再存在下列符号(Task 2/3 假设它们已消失)。

- [ ] **Step 1: 清点现场**

Run:
```bash
grep -n "_sendFileChunk\|_handleFileMsg\|_finalizeReceivedFile\|_prepareIOSink\|_freeIoSink\|_sendFileSignal\|_ioSink\|_receivingFile\b\|_sendingFile\b\|_sendingFiles\|_currentSize\|_currentFileTimestamp\|_currentLen" lib/socket/svrmanager.dart
grep -rn "FileSignal" lib/ --include="*.dart"
```
Expected: 命中仅分布于 svrmanager.dart 与 model/message.dart(`MessageEnum.FileSignal` 枚举值除外)。若出现其他文件命中,停下报 NEEDS_CONTEXT。

- [ ] **Step 2: 删除方法与字段**

svrmanager.dart 中整体删除以下方法(以方法签名为锚,连同方法体):`_sendFile`、`_sendFileChunk`、`_handleFileMsg`、`_finalizeReceivedFile`、`_prepareIOSink`、`_freeIoSink`、`_sendFileSignal`。
整体删除字段声明:`_ioSink`、`_receivingFile`、`_sendingFile`、`_sendingFiles`、`_currentSize`、`_currentFileTimestamp`、`_currentLen`。

- [ ] **Step 3: 删除 `_listen` 与生命周期中的 a 栈分支**

- `case MessageEnum.FileSignal:` 整个 case 删除(枚举值保留)。
- `case MessageEnum.File:` 内调用 `_handleFileMsg` 的 legacy 子分支删除(`_handleResumableFileMsg` 子分支本任务保留,Task 2 再删)。
- `default:` 分支中写 `_ioSink` 的裸二进制接收段删除。
- `closeGracefully` 中 `await _freeIoSink(freeAll: true);` 删除,`hadActiveConnection` 条件里的 `_ioSink != null ||` 一项删除;其余 `_freeIoSink`/`_ioSink` 引用点全部随删(先 grep 再删,不留悬空引用)。

- [ ] **Step 4: 删除 `FileSignal` 类**

`lib/model/message.dart` 中删除 `class FileSignal { ... }` 全部(约 :44-61)。`enum MessageEnum` 的 `FileSignal` 值不动。

- [ ] **Step 5: 验证**

Run: `flutter analyze && flutter test`
Expected: analyze 无告警(含无 unused 残留);全量测试通过。若有源级测试因删除失败,更新该测试中引用已删符号的断言(只删断言,不改测试其余语义),并在报告列出改了哪些。

- [ ] **Step 6: Commit**

```bash
git add lib/socket/svrmanager.dart lib/model/message.dart
# 如 Step 5 更新了测试,一并 add
git commit -m "refactor(socket): 删除 legacy signal 文件传输路径"
```

---

### Task 2: 删除 WSP2 resumable 栈(b)与 fileResumeV1 能力

**Files:**
- Modify: `lib/socket/svrmanager.dart`、`lib/state/peer_profile.dart`、`lib/model/message.dart`、`lib/page/conversation.dart`、`lib/l10n/app_en.arb`/`app_es.arb`/`app_zh.arb`
- Delete: `test/resumable_transfer_protocol_test.dart`、`test/resumable_transfer_interleave_source_test.dart`;确认孤儿后:`lib/state/resumable_transfer_window.dart`、`test/resumable_transfer_window_test.dart`
- Modify(测试): `test/socket_multi_peer_auth_source_test.dart`、`test/multi_peer_transfer_routing_source_test.dart`

**Interfaces:**
- Consumes: Task 1 已删 a 栈。
- Produces: `fileResumeV1`、`supportsResumableTransfer` 等符号全仓消失;`_listen` 中仅剩 V3 帧探测与 JSON switch。

- [ ] **Step 1: 删除 svrmanager 的 b 栈方法**

整体删除:`_handleResumableFileMsg`、`_handleTransferControl`、`_handleResumeProbe`、`_handleReady`、`_handleRestart`、`_handleTransferProgress`、`_handleTransferComplete`、`_handlePeerPause`、`_handlePeerCancel`、`_handlePeerError`、`_sendNextTransferChunkSafely`、`_sendNextTransferChunk`、`_handleTransferChunk`、`_recoverIncomingTransferChunk`、`_clearPendingIncomingChunk`。

- [ ] **Step 2: 删除 `_listen` 与断连清理中的 b 栈分支**

- `_listen` 头部裸分帧重组块(以 `final pendingHeader = _pendingIncomingChunkHeadersByPeer[streamPeerKey];` 起、到该 if 块 `return;` 结束的整段,及其上方 `supportsResumableTransferForStream` 相关局部量)。
- `TransferChunkFrame.looksLikeFrame` 探测分支(`_listen` 中段与 `default:` 内各一处,grep 全删)。
- `case MessageEnum.TransferControl:` 整个 case;`case MessageEnum.File:` 剩余的 `_handleResumableFileMsg` 子分支(此时该 case 应变为纯忽略或整体删除,枚举值保留)。
- `_handlePeerDisconnected` 中 `_pendingIncoming*ByPeer.remove(peerId)` 三行及其注释。
- 字段:`_pendingIncomingChunkHeadersByPeer`、`_pendingIncomingRawOffsetsByPeer`、`_pendingIncomingRawRemainingByPeer` 声明删除。

- [ ] **Step 3: 删除 capability 与 getters**

`lib/state/peer_profile.dart` 四处删除(constructor 默认参数 `this.fileResumeV1 = false,`、字段 `final bool fileResumeV1;`、`toJson` 的 `'fileResumeV1': fileResumeV1,`、`fromJson` 的 `fileResumeV1: json['fileResumeV1'] as bool? ?? false,`)。

svrmanager.dart 删除:广告位 `fileResumeV1: true,`(`_localPeerProfile` 内)、`bool get supportsResumableTransfer => _supportsResumableTransfer;`、`bool get _supportsResumableTransfer => ...;`、`bool _supportsResumableTransferFor(String peerId) { ... }` 及全部残余调用点(grep `supportsResumableTransfer` 清零,`fileResumeV1` 清零)。

- [ ] **Step 4: 删除 conversation.dart 两处死 UI 分支与 l10n 词条**

- `_fileStatusText` 内删除:
```dart
      if (_isConnectedSession &&
          !socketManager.supportsResumableTransfer &&
          !message.acked) {
        return l10n.fileTransferLegacyInProgress;
      }
```
(保留其后的 `return formatSize(message.size);`)
- actions 构建处删除 `if (_isConnectedSession && !socketManager.supportsResumableTransfer) { actions.add(IconButton(...)); }` 整块(tooltip 为 `peerDoesNotSupportResumableTransfer` 的那个 IconButton)。
- 三份 ARB 删除词条:`fileTransferLegacyInProgress`、`peerDoesNotSupportResumableTransfer`、`connectedPeerDoesNotSupportResumableTransfer`(先 grep 确认无其他引用;有则停下报 NEEDS_CONTEXT)。
- Run: `flutter gen-l10n`

- [ ] **Step 5: 删除 wire 类型与孤儿文件**

- `lib/model/message.dart`:grep 确认 `TransferChunkFrame`/`TransferControl`/`TransferAction` 在 lib/ 已无引用后整体删除三者。
- svrmanager 顶部 `import 'package:whisper/state/resumable_transfer_window.dart';`(如仍在)删除;`grep -rn "TransferFrameRange\|resumable_transfer_window" lib/ test/` 确认仅剩自身文件与其测试后,删除 `lib/state/resumable_transfer_window.dart` 与 `test/resumable_transfer_window_test.dart`。若发现其他引用,保留文件并在报告注明。
- 常量甄别:`transferRawFramePayloadSize` 等仅被已删代码引用的 static const 删除(analyzer unused + grep 为据)。

- [ ] **Step 6: 更新/删除测试**

- 删除:`test/resumable_transfer_protocol_test.dart`、`test/resumable_transfer_interleave_source_test.dart`。
- `test/socket_multi_peer_auth_source_test.dart`:删除 `'peer disconnect clears per-peer pending chunk buffers'` 整个 test(它断言的清理逻辑已随 b 栈消失)。
- `test/multi_peer_transfer_routing_source_test.dart`:删除引用 `supportsResumableTransfer`/b 栈符号的断言,保留 V3/`_transferRuntime` 相关断言。

- [ ] **Step 7: 验证**

Run: `flutter analyze && flutter test`
Expected: 全绿。另跑 `grep -rn "fileResumeV1\|supportsResumableTransfer\|TransferChunkFrame\|TransferAction\b" lib/` Expected: 零命中。

- [ ] **Step 8: Commit**

```bash
git add -A lib/ test/
git status --short   # 确认无 .claude/、CLAUDE.md 被误加,有则 git reset 掉
git commit -m "refactor(socket): 删除 WSP2 可续传传输栈与 fileResumeV1 能力"
```

---

### Task 3: V3 抽离为 FileTransferEngine

**Files:**
- Create: `lib/socket/file_transfer_engine.dart`
- Modify: `lib/socket/svrmanager.dart`
- Modify(测试,同批): `test/file_transfer_v3_source_test.dart`、`test/multi_peer_transfer_routing_source_test.dart` 及其他因迁移失败的 `*_source_test.dart`

**Interfaces:**
- Consumes: Task 1/2 之后的 svrmanager(仅剩 V3 栈)。
- Produces(Task 4 依赖,签名逐字):

```dart
/// 与 svrmanager `_buildMessage` 现签名逐字对应(msg/fileName/path/uid/fileTimestamp 原本未标类型)。
typedef TransferMessageBuilder = MessageData Function(
  MessageEnum type,
  String content,
  dynamic msg,
  dynamic fileName,
  int size,
  bool clipboard, {
  String md5,
  dynamic path,
  dynamic uid,
  dynamic fileTimestamp,
  String? receiverOverride,
});

class FileTransferEngine {
  FileTransferEngine({
    required bool Function(String peerId, Object bytes) sendBytesToPeer,
    required void Function(TransferSnapshot snapshot) emitTransferUpdated,
    required void Function(String message) notify,
    required PeerProfile? Function(String peerId) remoteProfileFor,
    required String Function() localUid,
    required bool Function(String peerId) isConnectedTo,
    required Set<String> Function() connectedPeerIds,
    required String Function() defaultPeerId,
    required bool Function(String peerId) hasLegacySinkFor,
    required TransferMessageBuilder buildMessage,
    required void Function(MessageData message) dispatchOutgoingMessage,
    required void Function(MessageData message) ackMessage,
    LocalDatabase Function() database = LocalDatabase.new,
  });

  Future<bool> sendFileTo(String peerId, String path);
  Future<bool> sendPickedFileTo(String peerId, PickedTransferFile item);
  Future<bool> sendAndroidContentUriTo(/* 与现 svrmanager 同参数表 */);
  Future<void> retryTransfer(String transferId);
  Future<void> cancelTransfer(String transferId);
  Future<void> handleFrame(WhisperFrameV3 frame);      // fileOffer/fileData/…/fileError
  Future<void> handlePeerDisconnected(String peerId);  // 原 _markPeerTransfersWaitingReconnect 入口
  Future<void> resumeRecoverableOutgoing();            // 原 _resumeRecoverableOutgoingTransfers
  Future<void> closeAll();                             // 原 closeGracefully 内 transfer 清理段
}
```

- [ ] **Step 1: 建引擎骨架**

新建 `lib/socket/file_transfer_engine.dart`,构造函数与注入字段:

```dart
class FileTransferEngine {
  FileTransferEngine({
    required bool Function(String peerId, Object bytes) sendBytesToPeer,
    required void Function(TransferSnapshot snapshot) emitTransferUpdated,
    required void Function(String message) notify,
    required PeerProfile? Function(String peerId) remoteProfileFor,
    required String Function() localUid,
    LocalDatabase Function() database = LocalDatabase.new,
  })  : _sendBytesToPeer = sendBytesToPeer,
        _emitTransferUpdated = emitTransferUpdated,
        _notify = notify,
        _remoteProfileFor = remoteProfileFor,
        _localUid = localUid,
        _database = database;

  final bool Function(String peerId, Object bytes) _sendBytesToPeer;
  final void Function(TransferSnapshot snapshot) _emitTransferUpdated;
  final void Function(String message) _notify;
  final PeerProfile? Function(String peerId) _remoteProfileFor;
  final String Function() _localUid;
  final LocalDatabase Function() _database;

  bool _supportsFileTransferV3For(String peerId) =>
      _remoteProfileFor(peerId)?.capabilities.fileTransferV3 == true;
}
```

- [ ] **Step 2: 机械迁移(方法体零改动)**

从 svrmanager.dart **整体剪切**到 engine(含各自的 doc 注释):
- 公开实现:`sendFileTo`、`sendPickedFileTo`、`sendAndroidContentUriTo`、`retryTransfer`、`cancelTransfer`(svrmanager 的 `sendFile` 不迁,见 Step 3)。
- V3 私有:`_sendFileTransferV3Offer`、`_sendFileTransferV3ControlTo`、`_sendFileTransferV3ReadyTo`、`_sendFileTransferV3AckTo`、`_sendFileTransferV3Window`/`Safely`、`_handleFileTransferV3Offer`、`_handleFileTransferV3Control`、`_handleFileTransferV3Ready`、`_handleFileTransferV3Ack`、`_handleFileTransferV3Complete`、`_handleFileTransferV3Cancel`、`_handleFileTransferV3Error`、`_handleFileTransferV3Data`、`_handleIncomingFileTransferV3Error` 及 grep `FileTransferV3` 命中的其余私有助手。
- 持久化/恢复:`_updateTransfer`、`_persistTransfer`、`_emitTransferById`、`_markPeerTransfersWaitingReconnect`(引擎内公开为 `handlePeerDisconnected`)、`_resumeRecoverableOutgoingTransfers`(公开为 `resumeRecoverableOutgoing`)、`_clearActiveIncomingTransfer`、`_clearIncomingTransferPerf`、`_dispatchTransferProgress` 及 grep 后仅被上述方法引用的其余助手。
- 字段:`_transferRuntime`、`_sendFileLock`、`_receivingTransferSinks`、`_receivingTransferWritersV3`、`_receivingTransfers`、`_receivingChecksums`、`_receivingTransferOffsets`、`_incomingBytesSinceProgress`、`_incomingFramesSinceProgress`、`_incomingWindowStartedAt`、`_outgoingWindowSentAt`、`_outgoingTransferSequences`、`_incomingWindowEndOffsets`、`_outgoingWindowEndOffsets`(存活到此时即 V3 所有)。
- 常量:`transferFramePayloadSize`、`defaultTransferChecksumAlgorithm`、`_transferChunkSize` 等仅被迁移体引用的 static const。
- **确认删除(不迁移,Task 2 评审已核实零写入/零引用)**:`_incomingBytesSinceProgress`、`_incomingFramesSinceProgress`、`_incomingWindowStartedAt`、`_incomingWindowEndOffsets` 四个死 map 及 `_clearIncomingTransferPerf`(随之成空壳)与其调用点、`_closeResumableHandles` 中对四 map 的 clear;`_streamPeerKey`;`shouldUseTransferChecksum`/`_shouldStreamChecksum`/`_hasExpectedChecksum`(零引用死岛);`_formatTransferRate`(零引用)。删除以 grep 零引用为最终判据,若 grep 发现引用则保留并报告。

**符号映射表**(迁移后在 engine 内全量替换,仅此清单,其余零改;**表达式级规则先于裸符号规则应用**):

| svrmanager 原文 | engine 替换为 |
|---|---|
| `peerId == receiver && _sink != null`(canUseLegacySink 右值,3 处逐字一致) | `_hasLegacySinkFor(peerId)` |
| `_dispatchToAll((event) => event.onTransferUpdated(<X>))` | `_emitTransferUpdated(<X>)` |
| `_dispatchToAll((event) => event.onNotice(<X>))` 与 `_dispatchToPrimary((event) => event.onNotice(<X>))` | `_notify(<X>)` |
| `_dispatchToAll((event) => event.onMessage(<X>))` | `_dispatchOutgoingMessage(<X>)` |
| `LocalDatabase()` | `_database()` |
| `sender`(裸引用本机 uid) | `_localUid()` |
| `receiver`(裸引用,上面表达式规则处理后的残余) | `_defaultPeerId()` |
| `isConnectedTo(` | `_isConnectedTo(` |
| `connectedPeerIds`(裸 getter 或 `_peerConnections.connectedPeerIds`) | `_connectedPeerIds()` |
| `_supportsFileTransferV3For(` | 不变(engine 内已定义) |

`_sendBytesToPeer(`、`_buildMessage(`、`_dispatchOutgoingMessage(`、`_ackMessage(` 调用原样保留(注入字段同名)。迁移体中若出现映射表外的 svrmanager 成员引用(如 `sink`、`_sink` 裸引用、`_peerConnections` 其他成员),**停下报 NEEDS_CONTEXT**,列出符号与所在方法,不许自行改写。

- [ ] **Step 3: svrmanager 接线(facade + 路由)**

字段区加:

```dart
  late final FileTransferEngine _transferEngine = FileTransferEngine(
    sendBytesToPeer: _sendBytesToPeer,
    emitTransferUpdated: (snapshot) =>
        _dispatchToAll((event) => event.onTransferUpdated(snapshot)),
    notify: (message) => _dispatchToAll((event) => event.onNotice(message)),
    remoteProfileFor: (peerId) =>
        _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null),
    localUid: () => sender,
    isConnectedTo: isConnectedTo,
    connectedPeerIds: () => _peerConnections.connectedPeerIds,
    defaultPeerId: () => receiver,
    hasLegacySinkFor: (peerId) => peerId == receiver && _sink != null,
    buildMessage: _buildMessage,
    dispatchOutgoingMessage: _dispatchOutgoingMessage,
    ackMessage: _ackMessage,
  );
```

公开 facade(原方法位置,签名不变):

```dart
  Future<bool> sendFile(String path) async {
    return sendFileTo(receiver, path);
  }

  Future<bool> sendFileTo(String peerId, String path) =>
      _transferEngine.sendFileTo(peerId, path);

  Future<bool> sendPickedFileTo(String peerId, PickedTransferFile item) =>
      _transferEngine.sendPickedFileTo(peerId, item);

  Future<void> retryTransfer(String transferId) =>
      _transferEngine.retryTransfer(transferId);

  Future<void> cancelTransfer(String transferId) =>
      _transferEngine.cancelTransfer(transferId);
```

(`sendAndroidContentUriTo` 若原本仅被 `sendPickedFileTo` 内部调用则不留 facade,随迁移体成为 engine 私有入口;grep 确认。)

路由与生命周期:
- `_handleWhisperFrameV3` 的 `case WhisperFrameType.message:` 保留;其余全部 file* case 改为转发 `await _transferEngine.handleFrame(frame);`(engine 的 `handleFrame` 承接原 switch 非 message 分支的完整逻辑,含 fileData 的 try/catch 错误处理)。
- `_handlePeerDisconnected` 中原 `_markPeerTransfersWaitingReconnect(peerId)` 调用改 `await _transferEngine.handlePeerDisconnected(peerId);`。
- Auth 成功路径的 `unawaited(_resumeRecoverableOutgoingTransfers());`(两处)改 `unawaited(_transferEngine.resumeRecoverableOutgoing());`。
- `closeGracefully` 中 transfer 相关清理(`_markRecoverableTransfersWaitingReconnect`、`_closeResumableHandles`、`_receivingTransferSinks` 判断等)整段职责移交 `await _transferEngine.closeAll();`;`hadActiveConnection` 中 `_receivingTransferSinks.isNotEmpty` 一项由 engine 暴露 `bool get hasActiveTransfers` 替代或直接删除该项(实现者按迁移后实际情况二选一,报告注明)。

- [ ] **Step 4: 源级测试同批改指向**

Run: `flutter test` 找出全部失败的 `*_source_test.dart`;对每个:把 `File('lib/socket/svrmanager.dart')` 改为 `File('lib/socket/file_transfer_engine.dart')`(或按断言语义拆分两文件读取),断言语义不变,只换文件/锚点。报告列出每个测试文件的改动内容。

- [ ] **Step 5: 验证**

Run: `flutter analyze && flutter test`
Expected: 全绿。`wc -l lib/socket/svrmanager.dart` Expected: 明显低于 3000 行(基线 ~4200,删除+迁出后)。

- [ ] **Step 6: Commit**

```bash
git add lib/socket/file_transfer_engine.dart lib/socket/svrmanager.dart test/
git status --short   # 确认无多余文件
git commit -m "refactor(socket): V3 文件传输抽离为可注入 FileTransferEngine"
```

---

### Task 4: FileTransferEngine 注入式单测

**Files:**
- Test: `test/file_transfer_engine_test.dart`(新)

**Interfaces:**
- Consumes: Task 3 的 `FileTransferEngine` 构造签名与 `sendFileTo`。

- [ ] **Step 1: 写失败测试**

`test/file_transfer_engine_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/file_transfer_engine.dart';

FileTransferEngine _engine({
  bool Function(String, Object)? sendBytesToPeer,
  void Function(String)? notify,
}) {
  return FileTransferEngine(
    sendBytesToPeer: sendBytesToPeer ?? (_, __) => true,
    emitTransferUpdated: (_) {},
    notify: notify ?? (_) {},
    remoteProfileFor: (_) => null, // 无 profile ⇒ 无 fileTransferV3 能力
    localUid: () => 'local-uid',
    isConnectedTo: (_) => true,
    connectedPeerIds: () => <String>{},
    defaultPeerId: () => '',
    hasLegacySinkFor: (_) => false,
    buildMessage: (type, content, msg, fileName, size, clipboard,
            {md5 = '', path = '', uid, fileTimestamp = 0, receiverOverride}) =>
        throw UnimplementedError('buildMessage 不应被本测试触达'),
    dispatchOutgoingMessage: (_) {},
    ackMessage: (_) {},
  );
}

void main() {
  test('engine is constructible with injected fakes only', () {
    expect(_engine(), isNotNull);
  });

  test('sendFileTo rejects peer without fileTransferV3 and notifies', () async {
    final notices = <String>[];
    var sent = false;
    final engine = _engine(
      sendBytesToPeer: (_, __) {
        sent = true;
        return true;
      },
      notify: notices.add,
    );

    final ok = await engine.sendFileTo('peer-x', '/tmp/whisper-test-nonexistent.bin');

    expect(ok, isFalse);
    expect(sent, isFalse, reason: '能力不满足时不得发出任何字节');
    expect(notices, isNotEmpty, reason: '拒发必须通过 notify 告知');
  });
}
```

前提核对:`sendFileTo` 的能力检查先于文件 IO 与 DB 访问(迁移前 svrmanager 即如此)。若迁移后测试因 default `database` 触发 DB 初始化而失败,参照 `test/file_transfer_store_test.dart` 的 DB 构造方式注入测试库,并在报告注明;不许为过测试改引擎逻辑。

- [ ] **Step 2: 跑测试确认当前状态**

Run: `flutter test test/file_transfer_engine_test.dart`
Expected: 若 Task 3 实现正确应直接 PASS(本任务是补测,非改代码);若 FAIL,按失败信息判断是测试前提错误还是 Task 3 缺陷——后者停下报 BLOCKED 附失败输出。

- [ ] **Step 3: 全量回归**

Run: `flutter analyze && flutter test`
Expected: 全绿。

- [ ] **Step 4: Commit**

```bash
git add test/file_transfer_engine_test.dart
git commit -m "test(socket): FileTransferEngine 注入式单测"
```

---

## 残留风险(终审关注)

- Task 3 是大 diff 机械迁移,行为等价性靠:方法体零改动纪律 + 映射表白名单 + NEEDS_CONTEXT 熔断 + 全量 suite + 终审逐段抽查。
- `closeGracefully`/`hadActiveConnection` 的职责切分是唯一允许实现者二选一的点,报告必须注明选择与理由。
- 传输全链路(offer→data→complete、断线 waitingReconnect、retry/cancel)无端到端自动化,真机回归由用户执行;终审需确认迁移前后 grep 级等价(方法体 diff 仅映射表内替换)。
