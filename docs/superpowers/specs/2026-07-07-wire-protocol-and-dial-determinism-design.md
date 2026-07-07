# A 组:wire 协议字符串化与互拨确定性 — 设计

> 网络架构重构第 1 组(共 3 组)。第 2 组:传输引擎抽离(删 legacy);第 3 组:packet transport 收敛。

## 背景(2026-07-07 架构评审结论)

1. **顶层消息 `type` 以枚举序号上线**:wire 格式直接复用 Drift 行 JSON,`type` 经
   `EnumIndexConverter` 编码为 int(`LocalDatabase.g.dart:994`)。重排 `MessageEnum`
   或收到越界序号即错路由/降级,位置脆弱。子协议(`TransferAction` 等)早已用字符串名
   + `orElse` 容错,顶层是唯一的例外。
2. **互拨不确定**:A、B 同时向对方拨号时,`PeerConnectionRegistry.register` 对同
   peerId 采取 last-writer-wins(`peer_connection.dart:69-75`),幸存连接由消息到达
   时序决定,可能误杀正在承载传输的连接。

## 全局决策

- **不兼容旧版本**(用户确认,2026-07-07):wire `type` 直接改字符串名,无双字段过渡、
  无能力协商。旧版本对端与新版本互连会失败,可接受。
- 解码端保留 int 序号回退(约 3 行):仅缓解开发期新旧 debug 包混装窗口,
  **不是兼容承诺**,不写进 capabilities。
- 不改 `MessageEnum.UNKONWN` 拼写(会同时改动 wire 名,纯外观收益,不做)。
- 不改 registry"已建立连接被新入站替换"的语义——那是断线重连的正确行为。

## A1 — wire message codec

### 新文件 `lib/socket/wire_message_codec.dart`

```dart
/// wire 上 type 以枚举名字符串传输;解码容忍旧 int 序号与非法值(降级 UNKONWN)。
String encodeWireMessage(MessageData message);
MessageData decodeWireMessage(Map<String, dynamic> json);
MessageEnum messageEnumFromWire(Object? raw); // String name 优先 / int 序号回退 / 否则 UNKONWN
```

- `encodeWireMessage`:`message.toJson()` 得到 map 后覆写 `json['type'] = message.type.name`,
  `jsonEncode` 返回。不动 Drift 生成代码。
- `decodeWireMessage`:先 `messageEnumFromWire(json['type'])` 求出枚举,再把
  `json['type']` 规整回该枚举的合法 index,交给 `MessageData.fromJson`(其序列化器
  只认 int)。任何异常降级为 UNKONWN 消息由调用方现有兜底处理。
- `messageEnumFromWire`:`String` → `MessageEnum.values` 按 `.name` 匹配,miss 则
  UNKONWN;`int` 且在 `[0, values.length)` → 序号;其余 → UNKONWN。

### 改动点(svrmanager.dart)

- **编码出口**:`MessageData` 的 `toJsonString()` 直发处全部换 `encodeWireMessage`。
  已知 5 处(`:855`、`:864`、`:1531`、`:1975`、`:2151`);`PeerProfile.toJsonString()`
  两处(`:1595`、`:1759`)是 profile 载荷,**不动**。计划阶段以
  `grep 'message.toJsonString\|newMessage.toJsonString'` 复核全量。
- **解码入口**:`MessageData.fromJson(json)` 的 wire 入口(`:905`、`:1029`、`:2251`、
  `:3053`)换 `decodeWireMessage`;`:1518`/`:1714` 为本地构造 map,同样换以保持一致。
- `_listen` 现有 `catch (_)` 降级保留为最后防线,正常路径不再触发。

## A4 — 互拨裁决(dial tiebreaker)

### 关键洞察

last-writer-wins 只在"双方**同时**互拨"窗口内是错的;"已有连接时对端重新拨入"场景下
新连接优先是**正确**的(对端拨入意味着它认为旧连接已死,拒绝它会毁掉断线重连)。
因此只堵互拨竞态,不改 registry 语义。

### 新文件 `lib/socket/dial_tiebreaker.dart`(纯函数)

```dart
enum SimultaneousDialDecision { keepOutgoing, acceptIncoming }

/// 双方各自独立计算,结论互补:uid 字典序小的一方保留自己的出站拨号,
/// 大的一方放弃出站、接受对方拨入。恰好一条连接存活。
SimultaneousDialDecision resolveSimultaneousDial({
  required String localUid,
  required String remoteUid,
}) =>
    localUid.compareTo(remoteUid) <= 0
        ? SimultaneousDialDecision.keepOutgoing
        : SimultaneousDialDecision.acceptIncoming;
```

### svrmanager 集成(Auth 分支,server 侧收到入站 auth 时)

判定条件:对同一 peer 存在**在途出站拨号**(`AuthRequestGate` 的 outgoing claim,
按 peerId 匹配)且入站 auth 到达:

- `keepOutgoing`(本机 uid 小,赢):`await sink?.close()` 关闭这条入站 socket,
  日志注明"互拨裁决:保留出站"。对端(输方)会接受我方的出站拨入,连接经我方出站建立。
- `acceptIncoming`(本机 uid 大,让):对入站照常走信任/确认流程;我方在途出站 socket
  会被对端(赢方)关闭,经 `_handlePeerSocketDone` 自然释放 outgoing gate,无需主动清理。

时序安全:裁决发生在入站 `_registerPeerConnection` 之前,双 register 窗口不存在。
`localUid` 取 `sender`(本机 uid),`remoteUid` 取 auth 消息中的对端 uid。

### 边界

- `localUid == remoteUid`(自连/uid 冲突):按 `keepOutgoing` 关闭入站,防自我连接。
- 出站 gate 无该 peer 的 claim(非互拨,普通入站):不进裁决,走现有流程。
- 出站 claim 键已有两种形态(`svrmanager.dart:456-466`):已知 peerId 用
  `peer:<peerId>`,手输 IP 无 peerId 用 `endpoint:<host>:<port>`。裁决按
  `peer:<peerId>` 键查询,需给 `AuthRequestGate` 增加只读查询
  `bool hasOutgoing(String requestKey)`。`endpoint:` 形态不参与裁决——互拨竞态
  实际来自发现驱动的自动连接,该路径必有 peerId;手输 IP 场景维持现状。

## 测试

| 对象 | 方式 | 要点 |
|---|---|---|
| wire codec | 真行为单测 | name 编解码往返;int 序号回退;非法字符串/越界 int/null → UNKONWN;`typeName` 不引入(确认 wire 只有 `type` 一个字段) |
| tiebreaker | 真行为单测 | 对称互补(A/B 视角恰一方 keepOutgoing);相等 uid → keepOutgoing |
| svrmanager 集成 | 源级测试(仓库惯例) | 编码出口不再有 `message.toJsonString()` 直发;wire 解码入口走 `decodeWireMessage`;Auth 分支引用 `resolveSimultaneousDial` |
| 回归 | `flutter analyze` + 全量 `flutter test` | 全绿为准 |

## 风险与残留

- 互拨窗口真机复现概率低,集成路径靠源级断言 + 日常使用回归;裁决逻辑本身由单测穷举。
- 新旧版本互连断裂为已接受决策;设备全部升级后无影响。
