# A 组:wire 协议字符串化与互拨确定性 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** wire 上顶层消息 `type` 从枚举序号改为枚举名字符串,并以纯函数裁决消除同 peer 互拨时的 last-writer-wins 不确定性。

**Architecture:** 新增两个小而纯的模块:`wire_message_codec.dart`(编解码包装层,不动 Drift 生成代码)与 `dial_tiebreaker.dart`(互拨裁决纯函数);`svrmanager.dart` 只做机械换点与 Auth 分支一处集成。spec:`docs/superpowers/specs/2026-07-07-wire-protocol-and-dial-determinism-design.md`。

**Tech Stack:** Flutter/Dart,flutter_test;测试遵循仓库惯例(纯函数真行为单测 + svrmanager 源级断言)。

## Global Constraints

- **不兼容旧版本**(spec 决策):编码只发字符串名;解码保留 int 序号回退仅为缓解开发期混装,不写进 capabilities。
- 不改 `MessageEnum.UNKONWN` 拼写;不改 `PeerConnectionRegistry` "新连接替换旧连接"语义。
- `PeerProfile.toJsonString()` 两处(auth/心跳载荷)**不动**——它们不是 MessageData。
- 全部用户可见文案走 ARB(本计划无 UI 文案)。
- 每个任务结束:`flutter analyze` 无告警 + 指定测试通过;Task 3 额外跑全量 `flutter test`。
- Conventional Commits,scope 用 `socket`。commit 尾行:`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

---

### Task 1: wire message codec 与全部换点

**Files:**
- Create: `lib/socket/wire_message_codec.dart`
- Test: `test/wire_message_codec_test.dart`(真行为)、`test/wire_codec_source_test.dart`(源级)
- Modify: `lib/socket/svrmanager.dart`(5 处编码 + 6 处解码 + import)

**Interfaces:**
- Consumes: `MessageData`(`package:whisper/model/LocalDatabase.dart`)、`MessageEnum`(`package:whisper/model/message.dart`)。
- Produces: `String encodeWireMessage(MessageData message)`、`MessageData decodeWireMessage(Map<String, dynamic> json)`、`MessageEnum messageEnumFromWire(Object? raw)` — Task 3 的源级断言依赖这些确切名字。

- [ ] **Step 1: 写失败测试**

`test/wire_message_codec_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/wire_message_codec.dart';

MessageData _message(MessageEnum type) {
  return MessageData(
    id: 1,
    deviceId: null,
    sender: 'peer-a',
    receiver: 'peer-b',
    name: '',
    clipboard: false,
    size: 0,
    type: type,
    content: 'hello',
    message: '',
    timestamp: 1,
    uuid: 'msg-1',
    acked: true,
    path: '',
    md5: '',
    fileTimestamp: 0,
  );
}

void main() {
  test('encodes type as enum name string on the wire', () {
    final json =
        jsonDecode(encodeWireMessage(_message(MessageEnum.Text)))
            as Map<String, dynamic>;
    expect(json['type'], 'Text');
  });

  test('roundtrip keeps type and payload fields', () {
    final wire = encodeWireMessage(_message(MessageEnum.TransferControl));
    final decoded =
        decodeWireMessage(jsonDecode(wire) as Map<String, dynamic>);
    expect(decoded.type, MessageEnum.TransferControl);
    expect(decoded.uuid, 'msg-1');
    expect(decoded.content, 'hello');
    expect(decoded.sender, 'peer-a');
  });

  test('decodes legacy int index as fallback', () {
    final json = jsonDecode(encodeWireMessage(_message(MessageEnum.Text)))
        as Map<String, dynamic>;
    json['type'] = MessageEnum.Text.index;
    expect(decodeWireMessage(json).type, MessageEnum.Text);
  });

  test('unknown name, out-of-range index and null degrade to UNKONWN', () {
    expect(messageEnumFromWire('NotAType'), MessageEnum.UNKONWN);
    expect(messageEnumFromWire(999), MessageEnum.UNKONWN);
    expect(messageEnumFromWire(-1), MessageEnum.UNKONWN);
    expect(messageEnumFromWire(null), MessageEnum.UNKONWN);
    expect(messageEnumFromWire(MessageEnum.Auth.name), MessageEnum.Auth);
  });
}
```

`test/wire_codec_source_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// wire 编解码必须统一走 wire_message_codec,svrmanager 不得再有
/// MessageData 的 toJsonString 直发与 MessageData.fromJson 直收。
void main() {
  final source = File('lib/socket/svrmanager.dart').readAsStringSync();

  test('all MessageData wire encodes go through encodeWireMessage', () {
    expect(source.contains('message.toJsonString()'), isFalse,
        reason: 'MessageData 编码必须走 encodeWireMessage');
    expect(source.contains('encodeWireMessage('), isTrue);
    // PeerProfile 载荷不受影响
    expect(source.contains('profile.toJsonString()'), isTrue);
  });

  test('all MessageData wire decodes go through decodeWireMessage', () {
    expect(source.contains('MessageData.fromJson('), isFalse,
        reason: 'MessageData 解码必须走 decodeWireMessage');
    expect(source.contains('decodeWireMessage('), isTrue);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/wire_message_codec_test.dart test/wire_codec_source_test.dart`
Expected: FAIL(codec 文件不存在 → 编译错误;源级断言 false)

- [ ] **Step 3: 实现 codec**

`lib/socket/wire_message_codec.dart`:

```dart
import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

/// wire 上顶层消息 type 以枚举名字符串传输(2026-07-07 spec:不兼容旧版本)。
/// 解码容忍旧 int 序号与非法值,降级 UNKONWN;int 回退仅为缓解开发期新旧
/// debug 包混装窗口,不是兼容承诺。
MessageEnum messageEnumFromWire(Object? raw) {
  if (raw is String) {
    for (final value in MessageEnum.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return MessageEnum.UNKONWN;
  }
  if (raw is int && raw >= 0 && raw < MessageEnum.values.length) {
    return MessageEnum.values[raw];
  }
  return MessageEnum.UNKONWN;
}

String encodeWireMessage(MessageData message) {
  final json = message.toJson();
  json['type'] = message.type.name;
  return jsonEncode(json);
}

MessageData decodeWireMessage(Map<String, dynamic> json) {
  final normalized = Map<String, dynamic>.from(json);
  normalized['type'] = messageEnumFromWire(json['type']).index;
  return MessageData.fromJson(normalized);
}
```

- [ ] **Step 4: svrmanager 换点**

`lib/socket/svrmanager.dart` 顶部 import 区加:

```dart
import 'package:whisper/socket/wire_message_codec.dart';
```

编码出口(用编辑器全量替换,共 5 处命中):
- `utf8.encode(message.toJsonString())` → `utf8.encode(encodeWireMessage(message))`(2 处::855 `_sendMessageData` 的 V3 帧载荷、:2151 fileOffer 帧载荷)
- `_send(message.toJsonString());` → `_send(encodeWireMessage(message));`(3 处::864 `_sendMessageData` 回退、:1531 `_sendFileSignal`、:1975 通知发送)

解码入口(共 6 处):
- :926-928 fileOffer:`MessageData.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>)` → `decodeWireMessage(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>)`
- :1050 `_listen`:`message = MessageData.fromJson(json);` → `message = decodeWireMessage(json);`
- :1549 收文件后本地重建:`MessageData.fromJson(msgTemp)` → `decodeWireMessage(msgTemp)`
- :1745 `_ackMessage`:`MessageData.fromJson(json)` → `decodeWireMessage(json)`(该函数上一行 `json["type"] = MessageEnum.Ack.index` 保留——内部 map 用 index,codec 兼容)
- :2282、:3084:`MessageData.fromJson(json)` → `decodeWireMessage(json)`

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/wire_message_codec_test.dart test/wire_codec_source_test.dart && flutter analyze`
Expected: 全 PASS;analyze 无告警

- [ ] **Step 6: 回归受影响的既有测试**

Run: `flutter test test/ws_event_dispatch_test.dart test/socket_multi_peer_auth_source_test.dart`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/socket/wire_message_codec.dart lib/socket/svrmanager.dart test/wire_message_codec_test.dart test/wire_codec_source_test.dart
git commit -m "feat(socket): wire 顶层消息 type 改字符串名,解码容忍序号回退"
```

---

### Task 2: 互拨裁决纯函数与出站 claim 查询

**Files:**
- Create: `lib/socket/dial_tiebreaker.dart`
- Modify: `lib/socket/auth_request_gate.dart`
- Test: `test/dial_tiebreaker_test.dart`(新)、`test/auth_request_gate_test.dart`(扩展)

**Interfaces:**
- Consumes: 无(纯函数)。
- Produces: `enum SimultaneousDialDecision { keepOutgoing, acceptIncoming }`、`SimultaneousDialDecision resolveSimultaneousDial({required String localUid, required String remoteUid})`、`bool AuthRequestGate.hasOutgoing(String requestKey)` — Task 3 依赖这些确切签名。

- [ ] **Step 1: 写失败测试**

`test/dial_tiebreaker_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/dial_tiebreaker.dart';

void main() {
  test('both sides independently reach complementary decisions', () {
    const pairs = [
      ['aaa', 'bbb'],
      ['device-1', 'device-2'],
      ['Z', 'a'], // 大写 ASCII 序小于小写
    ];
    for (final pair in pairs) {
      final a = resolveSimultaneousDial(localUid: pair[0], remoteUid: pair[1]);
      final b = resolveSimultaneousDial(localUid: pair[1], remoteUid: pair[0]);
      expect(a == SimultaneousDialDecision.keepOutgoing,
          b == SimultaneousDialDecision.acceptIncoming,
          reason: '恰好一方保留出站: $pair');
    }
  });

  test('smaller uid keeps its outgoing dial', () {
    expect(resolveSimultaneousDial(localUid: 'aaa', remoteUid: 'bbb'),
        SimultaneousDialDecision.keepOutgoing);
    expect(resolveSimultaneousDial(localUid: 'bbb', remoteUid: 'aaa'),
        SimultaneousDialDecision.acceptIncoming);
  });

  test('equal uids keep outgoing to block self-connection', () {
    expect(resolveSimultaneousDial(localUid: 'same', remoteUid: 'same'),
        SimultaneousDialDecision.keepOutgoing);
  });
}
```

`test/auth_request_gate_test.dart` 追加(文件已存在,在 `main()` 末尾加 test):

```dart
  test('hasOutgoing reflects claim lifecycle', () {
    final gate = AuthRequestGate();
    expect(gate.hasOutgoing('peer:abc'), isFalse);
    expect(gate.tryClaimOutgoing('peer:abc'), isTrue);
    expect(gate.hasOutgoing('peer:abc'), isTrue);
    expect(gate.hasOutgoing(' peer:abc '), isTrue); // trim 一致
    gate.releaseOutgoing('peer:abc');
    expect(gate.hasOutgoing('peer:abc'), isFalse);
    expect(gate.hasOutgoing(''), isFalse);
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/dial_tiebreaker_test.dart test/auth_request_gate_test.dart`
Expected: FAIL(dial_tiebreaker.dart 不存在;hasOutgoing 未定义)

- [ ] **Step 3: 实现**

`lib/socket/dial_tiebreaker.dart`:

```dart
/// 同 peer 互拨(双方同时向对方拨号)的确定性裁决。
///
/// 双方各自独立计算,结论互补:uid 字典序小(含相等)的一方保留自己的
/// 出站拨号并关闭对方拨入,大的一方放弃出站、接受对方拨入。
/// 恰好一条连接存活,零抖动;相等 uid(自连)一律关闭拨入。
enum SimultaneousDialDecision { keepOutgoing, acceptIncoming }

SimultaneousDialDecision resolveSimultaneousDial({
  required String localUid,
  required String remoteUid,
}) {
  return localUid.compareTo(remoteUid) <= 0
      ? SimultaneousDialDecision.keepOutgoing
      : SimultaneousDialDecision.acceptIncoming;
}
```

`lib/socket/auth_request_gate.dart` 在 `releaseOutgoing` 后加:

```dart
  bool hasOutgoing(String requestKey) {
    final key = requestKey.trim();
    if (key.isEmpty) {
      return false;
    }
    return _outgoingRequestKeys.contains(key);
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/dial_tiebreaker_test.dart test/auth_request_gate_test.dart && flutter analyze`
Expected: 全 PASS;analyze 无告警

- [ ] **Step 5: Commit**

```bash
git add lib/socket/dial_tiebreaker.dart lib/socket/auth_request_gate.dart test/dial_tiebreaker_test.dart test/auth_request_gate_test.dart
git commit -m "feat(socket): 互拨裁决纯函数与出站 claim 查询"
```

---

### Task 3: Auth 分支集成互拨裁决

**Files:**
- Modify: `lib/socket/svrmanager.dart`(Auth case,约 :1058 后)
- Test: `test/socket_multi_peer_auth_source_test.dart`(扩展,文件已有 `section()` 帮助函数)

**Interfaces:**
- Consumes: Task 2 的 `resolveSimultaneousDial` / `SimultaneousDialDecision` / `AuthRequestGate.hasOutgoing`;既有 `_authRequestKey({String? peerId, required String host, required int port})`(peerId 非空时返回 `peer:<peerId>`,host/port 传占位)。
- Produces: 无下游依赖。

- [ ] **Step 1: 写失败测试**

`test/socket_multi_peer_auth_source_test.dart` 的 `main()` 末尾追加:

```dart
  test('simultaneous dials are resolved deterministically by uid', () {
    final authCase = section(
      'case MessageEnum.Auth:',
      'case MessageEnum.Ack:',
    );
    expect(authCase.contains('hasOutgoing'), isTrue,
        reason: '入站 auth 需检测对同一 peer 的在途出站拨号');
    expect(authCase.contains('resolveSimultaneousDial'), isTrue,
        reason: '互拨时必须走确定性裁决而非 last-writer-wins');
    expect(authCase.contains('SimultaneousDialDecision.keepOutgoing'), isTrue,
        reason: '赢方需关闭入站连接保留出站');
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/socket_multi_peer_auth_source_test.dart`
Expected: 新增 test FAIL,其余 PASS

- [ ] **Step 3: 集成实现**

`lib/socket/svrmanager.dart` 顶部 import 区加:

```dart
import 'package:whisper/socket/dial_tiebreaker.dart';
```

Auth case 中,在 `logger.i("AUTH message: ${message.sender} + $sender");` 之后、`if (asServer) {`(信任自动通过分支)之前插入:

```dart
          // 互拨裁决:双方同时向对方拨号时,按 uid 字典序确定唯一存活连接,
          // 防止 last-writer-wins 误杀承载传输的连接。
          if (asServer && peerId.isNotEmpty) {
            final outgoingKey =
                _authRequestKey(peerId: peerId, host: '', port: 0);
            if (_authRequestGate.hasOutgoing(outgoingKey)) {
              final decision = resolveSimultaneousDial(
                localUid: sender,
                remoteUid: peerId,
              );
              if (decision == SimultaneousDialDecision.keepOutgoing) {
                logger.i('互拨裁决: 保留本机出站拨号,关闭来自 $peerId 的入站');
                await sink?.close();
                return;
              }
              logger.i('互拨裁决: 让步接受来自 $peerId 的入站,在途出站将被对端关闭');
            }
          }
```

时序说明(实现者参考,不是代码):赢方关闭的入站 socket 即输方的出站 socket,输方经 `_handlePeerSocketDone` 自动释放 outgoing gate;两侧无论消息到达先后,收敛结果一致——唯一连接为"uid 小的一方的出站"。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/socket_multi_peer_auth_source_test.dart && flutter analyze`
Expected: 全 PASS;analyze 无告警

- [ ] **Step 5: 全量回归**

Run: `flutter test`
Expected: 全部通过(基线 532 + 本计划新增)

- [ ] **Step 6: Commit**

```bash
git add lib/socket/svrmanager.dart test/socket_multi_peer_auth_source_test.dart
git commit -m "fix(socket): 互拨时按 uid 裁决保留唯一连接"
```

---

## 残留风险(实现者需在报告中确认知晓)

- 互拨窗口无法在单测中端到端复现(需两台真机同时拨号);裁决逻辑由单测穷举,集成路径由源级断言覆盖。
- 输方 `connectToServer` 的 `callback(true)` 已在 auth 响应前触发,其出站被赢方关闭时 UI 可能闪一次断开再经赢方出站重连——既有 F1/F2 去重逻辑已覆盖提示层,不另做处理。
