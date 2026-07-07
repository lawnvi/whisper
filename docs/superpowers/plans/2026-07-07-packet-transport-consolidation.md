# C 组:packet transport 收敛 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 三套复制粘贴的 packet transport / frame codec / URI 构造收敛为共享实现,wire 字节逐位不变。

**Architecture:** 先落黄金字节测试锁死 wire(Task 1),再抽共享 frame codec(Task 2),最后抽共享 byte transport + connect + URI(Task 3)。子系统对外类型名与协调器注入签名不变(薄壳委托)。spec:`docs/superpowers/specs/2026-07-07-packet-transport-consolidation-design.md`。

**Tech Stack:** Flutter/Dart、web_socket_channel、flutter_test。

## Global Constraints

- **wire 字节逐位不变**:魔数(WSA1/WSG1/WRI1)、header JSON 字段插入序、uint32BE 长度、FormatException 文案全部保持;黄金字节测试(Task 1)是硬门,后续任务不许改其断言。
- 三个对外类型名(`AudioPacketByteTransport`/`AudioGroupPacketByteTransport`/`RemoteInputPacketByteTransport`/`RemoteInputObservablePacketTransport`)与协调器注入的工厂签名不变。
- `AudioFanoutTransport` 的 1:N 广播与异常传播语义不变。
- 不加自动重连/版本号/checksum;不动 svrmanager/FileTransferEngine。
- 迁移体遇到计划未覆盖的行为差异(如 APT/AFT 是否监听 channel.stream、诊断调用点位)以**现状为准**保持,拿不准停下报 NEEDS_CONTEXT。
- 每 Task:`flutter analyze` 无告警 + 全量 `flutter test` 通过 + 独立 commit;Conventional Commits scope `socket`(涉及子系统文件仍用 socket,因主体是共享传输层);尾行 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

---

### Task 1: 黄金字节测试(先于一切重构落地)

**Files:**
- Test: `test/framed_packet_golden_test.dart`(新)

**Interfaces:** Consumes 现有三个 Frame 类;Produces wire 锁(Task 2 重构后必须原样通过)。

- [ ] **Step 1: 写测试(对现状应直接全过)**

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

/// wire 黄金字节锁:magic + uint32BE len + JSON header(字段插入序)+ payload。
/// 本文件断言在 transport/codec 收敛重构(C 组)前后必须逐字节成立,不许修改。
void _expectLayout(
  Uint8List bytes, {
  required String magic,
  required String headerJson,
  required List<int> payload,
}) {
  expect(ascii.decode(bytes.sublist(0, 4)), magic);
  final headerLen = ByteData.sublistView(bytes, 4, 8).getUint32(0);
  expect(headerLen, utf8.encode(headerJson).length);
  expect(utf8.decode(bytes.sublist(8, 8 + headerLen)), headerJson);
  expect(bytes.sublist(8 + headerLen), payload);
}

void main() {
  final payload = Uint8List.fromList([1, 2, 3]);

  test('WSA1 audio packet frame golden bytes', () {
    final bytes = AudioPacketFrame(
      sessionId: 'sess-1',
      sequence: 7,
      captureTimeMicros: 123456,
      payload: payload,
    ).encode();
    _expectLayout(
      bytes,
      magic: 'WSA1',
      headerJson:
          '{"sessionId":"sess-1","sequence":7,"captureTimeMicros":123456,"payloadLength":3}',
      payload: [1, 2, 3],
    );
    final decoded = AudioPacketFrame.decode(bytes);
    expect(decoded.sessionId, 'sess-1');
    expect(decoded.sequence, 7);
    expect(decoded.captureTimeMicros, 123456);
    expect(decoded.payload, [1, 2, 3]);
  });

  test('WSG1 audio group packet frame golden bytes', () {
    final bytes = AudioGroupPacketFrame(
      groupId: 'g-1',
      streamId: 'st-1',
      sessionId: 'sess-1',
      sourcePeerId: 'peer-a',
      sequence: 7,
      captureTimeMicros: 123456,
      targetPlaybackTimeMicros: 234567,
      durationMicros: 20000,
      channelMask: AudioChannelMask.stereo,
      payload: payload,
    ).encode();
    _expectLayout(
      bytes,
      magic: 'WSG1',
      headerJson:
          '{"groupId":"g-1","streamId":"st-1","sessionId":"sess-1","sourcePeerId":"peer-a","sequence":7,"captureTimeMicros":123456,"targetPlaybackTimeMicros":234567,"durationMicros":20000,"channelMask":"stereo","payloadLength":3}',
      payload: [1, 2, 3],
    );
    final decoded = AudioGroupPacketFrame.decode(bytes);
    expect(decoded.groupId, 'g-1');
    expect(decoded.channelMask, AudioChannelMask.stereo);
    expect(decoded.payload, [1, 2, 3]);
  });

  test('WRI1 remote input packet frame golden bytes', () {
    final bytes = RemoteInputPacketFrame(
      sessionId: 'sess-1',
      sequence: 7,
      timestampMicros: 123456,
      eventType: RemoteInputEventType.release,
      payload: payload,
    ).encode();
    _expectLayout(
      bytes,
      magic: 'WRI1',
      headerJson:
          '{"sessionId":"sess-1","sequence":7,"timestampMicros":123456,"eventType":"release","payloadLength":3}',
      payload: [1, 2, 3],
    );
    final decoded = RemoteInputPacketFrame.decode(bytes);
    expect(decoded.eventType, RemoteInputEventType.release);
    expect(decoded.payload, [1, 2, 3]);
  });

  test('decode errors keep exact messages', () {
    expect(
      () => AudioPacketFrame.decode(Uint8List.fromList([1, 2])),
      throwsA(predicate((e) =>
          e is FormatException && e.message == 'audio packet frame too short')),
    );
    final wrongMagic = Uint8List.fromList([...ascii.encode('XXXX'), 0, 0, 0, 0]);
    expect(
      () => AudioGroupPacketFrame.decode(wrongMagic),
      throwsA(predicate((e) =>
          e is FormatException &&
          e.message == 'invalid audio group packet magic')),
    );
    expect(
      () => RemoteInputPacketFrame.decode(wrongMagic),
      throwsA(predicate((e) =>
          e is FormatException &&
          e.message == 'invalid remote input packet magic')),
    );
  });
}
```

- [ ] **Step 2: 跑测试**

Run: `flutter test test/framed_packet_golden_test.dart`
Expected: 4/4 PASS(它测的是现状;若有 FAIL 说明我对现状的断言有误,停下报 NEEDS_CONTEXT 附输出)。

- [ ] **Step 3: Commit**

```bash
git add test/framed_packet_golden_test.dart
git commit -m "test(socket): 三协议帧黄金字节锁,收敛重构前置门"
```

---

### Task 2: 共享 frame codec

**Files:**
- Create: `lib/socket/framed_packet_codec.dart`
- Modify: `lib/audio/audio_protocol.dart`、`lib/remote_input/remote_input_protocol.dart`
- Test: `test/framed_packet_codec_test.dart`(新);黄金字节测试与既有 protocol 测试保持通过

**Interfaces:**
- Produces(Task 3 无依赖,子系统内部使用):

```dart
Uint8List encodeFramedPacket({
  required String magic,
  required Map<String, dynamic> header,
  required Uint8List payload,
});

({Map<String, dynamic> header, Uint8List payload}) decodeFramedPacket({
  required String magic,
  required String label, // 'audio packet' / 'audio group packet' / 'remote input packet'
  required Uint8List bytes,
});

T enumByName<T extends Enum>(List<T> values, Object? raw, T fallback);
T? nullableEnumByName<T extends Enum>(List<T> values, Object? raw);
int intJson(Object? raw, [int fallback = 0]);
double doubleJson(Object? raw, [double fallback = 0]);
```

(spec 里的 `looksLikeFramedPacket` 无现存调用方,YAGNI 不实现。)

- [ ] **Step 1: 写失败测试**

`test/framed_packet_codec_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/framed_packet_codec.dart';

enum _Fruit { apple, banana }

void main() {
  test('encode/decode roundtrip preserves header order and payload', () {
    final bytes = encodeFramedPacket(
      magic: 'TST1',
      header: <String, dynamic>{'b': 2, 'a': 1, 'payloadLength': 2},
      payload: Uint8List.fromList([9, 8]),
    );
    final result =
        decodeFramedPacket(magic: 'TST1', label: 'test packet', bytes: bytes);
    expect(result.header.keys.toList(), ['b', 'a', 'payloadLength']);
    expect(result.payload, [9, 8]);
  });

  test('decode error messages follow the shared pattern', () {
    expect(
      () => decodeFramedPacket(
          magic: 'TST1',
          label: 'test packet',
          bytes: Uint8List.fromList([1])),
      throwsA(predicate((e) =>
          e is FormatException && e.message == 'test packet frame too short')),
    );
  });

  test('json helpers tolerate bad input', () {
    expect(enumByName(_Fruit.values, 'banana', _Fruit.apple), _Fruit.banana);
    expect(enumByName(_Fruit.values, 'nope', _Fruit.apple), _Fruit.apple);
    expect(nullableEnumByName(_Fruit.values, 'nope'), isNull);
    expect(intJson('42'), 42);
    expect(intJson(null, 7), 7);
    expect(doubleJson(1, 0), 1.0);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**(文件不存在 → 编译错)

- [ ] **Step 3: 实现 codec**

`lib/socket/framed_packet_codec.dart`:骨架与现有三份 encode/decode 完全一致(magic ascii 4B、`ByteData(4)..setUint32(0, len)` 大端、`BytesBuilder(copy: false)`、payloadLength 校验),错误文案模板:`'$label frame too short'`、`'invalid $label magic'`、`'$label header truncated'`、`'$label payload length mismatch'`(与现有 12 条文案逐字吻合)。四个 JSON 助手从 remote_input_protocol.dart 的实现原样上收(`_enumByName`/`_nullableEnumByName`/`_intJson`/`_doubleJson` 去下划线)。

- [ ] **Step 4: 三个 Frame 改为委托**

`encode()` → `encodeFramedPacket(magic: magic, header: <原样的有序 map>, payload: payload)`;`decode()` → `decodeFramedPacket(...)` 后按原字段名/默认值读取(含 `enumByName` 替代本地 `_enumByName`)。删除 audio_protocol.dart 与 remote_input_protocol.dart 的本地 `_enumByName`(及 RIP 的 `_nullableEnumByName`/`_intJson`/`_doubleJson`,其在协议其他类中的调用点改用共享版)。header map 字段与插入序**一个字符都不许动**。

- [ ] **Step 5: 验证**

Run: `flutter test test/framed_packet_golden_test.dart test/framed_packet_codec_test.dart test/audio_protocol_test.dart test/audio_group_protocol_test.dart && flutter analyze && flutter test`
Expected: 黄金字节 4/4 原样通过(不许改断言),全量绿。

- [ ] **Step 6: Commit**

```bash
git add lib/socket/framed_packet_codec.dart lib/audio/audio_protocol.dart lib/remote_input/remote_input_protocol.dart test/framed_packet_codec_test.dart
git commit -m "refactor(socket): 三协议帧编解码收敛为共享 framed codec,wire 字节不变"
```

---

### Task 3: 共享 byte transport + connect + URI

**Files:**
- Create: `lib/socket/packet_byte_transport.dart`
- Modify: `lib/audio/audio_packet_transport.dart`、`lib/audio/audio_fanout_transport.dart`、`lib/remote_input/remote_input_packet_transport.dart`、`lib/audio/audio_share_coordinator.dart`、`lib/audio/audio_group_coordinator.dart`、`lib/remote_input/remote_input_coordinator.dart`、`lib/remote_input/remote_input_workspace_coordinator.dart`(仅 URI 构造处)
- Test: `test/packet_byte_transport_test.dart`(新);既有 `audio_packet_transport_test`(3)、`audio_fanout_transport_test`(4)、`remote_input_platform_test`(含 :312-330 一例)保持通过

**Interfaces(核心类逐字):**

```dart
import 'dart:async';

/// 三个子系统共用的字节传输核心:close 幂等、closed 后 send 静默丢弃(可选钩子)、
/// done 广播一次性通知(无订阅零开销)。
class PacketByteTransport {
  PacketByteTransport({
    required void Function(Object bytes) sendBytes,
    required Future<void> Function() closeSink,
    this.onPacketSent,
    this.onPacketDropped,
  })  : _sendBytes = sendBytes,
        _closeSink = closeSink;

  final void Function(Object bytes) _sendBytes;
  final Future<void> Function() _closeSink;
  final void Function()? onPacketSent;
  final void Function()? onPacketDropped;
  final StreamController<void> _done = StreamController<void>.broadcast();
  bool _closed = false;
  bool _doneNotified = false;

  bool get isClosed => _closed;
  Stream<void> get done => _done.stream;

  void send(Object bytes) {
    if (_closed) {
      onPacketDropped?.call();
      return;
    }
    _sendBytes(bytes);
    onPacketSent?.call();
  }

  /// WS onDone/onError 或 close() 时触发,一次性。
  void notifyDone() {
    if (_doneNotified) {
      return;
    }
    _doneNotified = true;
    if (!_done.isClosed) {
      _done.add(null);
    }
    unawaited(_done.close());
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _closeSink();
    notifyDone();
  }
}

Uri buildPeerPacketUri({
  required String host,
  required int port,
  required String path,
});
```

外加 `Future<PacketByteTransport> connectPacketWebSocket(Uri uri, {void Function(String message)? log, void Function()? onPacketSent, void Function()? onPacketDropped})`:**channel 建立与 stream 监听方式取现 `audio_packet_transport.dart` connect 实现原样**(含 try/catch + rethrow),诊断调用泛化为 `log` 回调;stream 的 onDone/onError 接 `transport.notifyDone`。

- [ ] **Step 1: 写失败测试**

`test/packet_byte_transport_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

void main() {
  test('send after close drops with hook, close is idempotent', () async {
    final sentBytes = <Object>[];
    var dropped = 0;
    var closes = 0;
    final transport = PacketByteTransport(
      sendBytes: sentBytes.add,
      closeSink: () async => closes++,
      onPacketDropped: () => dropped++,
    );
    transport.send([1]);
    await transport.close();
    await transport.close();
    transport.send([2]);
    expect(sentBytes, [
      [1]
    ]);
    expect(dropped, 1);
    expect(closes, 1);
    expect(transport.isClosed, isTrue);
  });

  test('done fires exactly once across notifyDone and close', () async {
    final transport = PacketByteTransport(
      sendBytes: (_) {},
      closeSink: () async {},
    );
    var doneCount = 0;
    transport.done.listen((_) => doneCount++);
    transport.notifyDone();
    await transport.close();
    await Future<void>.delayed(Duration.zero);
    expect(doneCount, 1);
  });

  test('buildPeerPacketUri composes ws uri', () {
    final uri = buildPeerPacketUri(host: '192.168.1.2', port: 9200, path: '/audio');
    expect(uri.scheme, 'ws');
    expect(uri.host, '192.168.1.2');
    expect(uri.port, 9200);
    expect(uri.path, '/audio');
  });
}
```

(`buildPeerPacketUri` 的具体组装取现 `_audioUri`/`_inputUri` 实现——三份几乎重复,以 `audio_share_coordinator.dart:391-404` 版为准;若三份有实质差异(不止默认 path),停下报 NEEDS_CONTEXT 列出差异。)

- [ ] **Step 2: 跑测试确认失败** → **Step 3: 实现共享类**(上面逐字代码 + connect + URI)

- [ ] **Step 4: 三个 transport 薄壳化**

- 类型名与公开成员(含 `connect` 工厂签名、诊断字段、`RemoteInputObservablePacketTransport.done`)不变,内部委托 `PacketByteTransport`;audio 版诊断(`audioPacketSent`/`audioPacketSendDropped`/`transportConnecting`/`transportConnected`/`transportConnectFailed`)接到钩子/log 回调,调用点位与现状一致。
- 删除 APT/AFT 的死代码 `.stream` getter(先 grep 零引用)。
- `AudioFanoutTransport` 文件保留,仅内部 per-sink 发送壳改用共享类;1:N 失败隔离(per-sink try/catch → detach+回调)逻辑一字不动。
- 协调器四处 URI 构造(`_audioUri` ×2、`_inputUri` ×1、workspace 若有)改调 `buildPeerPacketUri`,签名不变。
- 任何现状行为与本计划描述不符处(如 APT/AFT 原本不监听 stream、诊断时序不同)以现状为准,拿不准 NEEDS_CONTEXT。

- [ ] **Step 5: 验证**

Run: `flutter test test/packet_byte_transport_test.dart test/audio_packet_transport_test.dart test/audio_fanout_transport_test.dart test/remote_input_platform_test.dart test/framed_packet_golden_test.dart && flutter analyze && flutter test`
Expected: 全绿;既有测试若需改动,仅限构造/注入适配,断言语义不变并逐个报告。

- [ ] **Step 6: Commit**

```bash
git add -A lib/socket/packet_byte_transport.dart lib/audio/ lib/remote_input/ test/
git status --short   # 确认无 .claude/、CLAUDE.md
git commit -m "refactor(socket): 三套 packet transport 收敛为共享字节传输与连接"
```

---

## 残留风险(终审关注)

- wire 等价由黄金字节测试硬锁;transport 行为等价由既有 7+1 例测试 + 新单测覆盖,但 WS connect 实路径与 audio/remote-input 真机链路无自动化——用户真机回归(音频共享、键鼠共享)。
- `done` 流一次性语义(`notifyDone` once-guard)与 RIT 现状的等价性依赖 `remote_input_platform_test` 与实现者对现状的核对;差异即熔断。
