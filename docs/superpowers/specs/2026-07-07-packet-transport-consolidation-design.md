# C 组:packet transport 收敛 — 设计

> 网络架构重构第 3 组(最后一组)。前置:A 组(wire 字符串化+互拨裁决)、B 组(传输引擎抽离)已合入 dev。

## 背景(探查证据)

- 三个 `*ByteTransport`(`audio_packet_transport.dart`、`audio_fanout_transport.dart:15-42`、`remote_input_packet_transport.dart:19-46`)去类型名后**逐行 identical**;差异仅:audio 版多诊断钩子(`AudioShareDiagnostics`),remote_input 版多 `done` 流,三者的 WS `connect` 健壮性不一(audio 版有 try/catch+日志,另两个裸 await)。
- 三个 `*PacketFrame`(WSA1/WSG1/WRI1)共用同一编解码骨架(magic 4B + uint32 len + JSON header + payload),仅 header 字段集不同(4/9/5 个);`_enumByName` 在 audio_protocol 与 remote_input_protocol 逐字节重复,后者另有 `_nullableEnumByName`/`_intJson`/`_doubleJson`。
- URI 构造三份重复(`_audioUri` ×2、`_inputUri`,仅默认 path 不同)。
- 死代码:APT/AFT 的 `.stream` getter 在 lib 内零调用。
- 三者均无自动重连(断线靠上层控制通道重新 offer)——**保持不变**。

## 全局决策

- **wire 字节逐位不变**:同版本设备互通,编解码重构后输出必须与现状 byte-identical。JSON header 的字段插入序决定字节序,因此共享 codec 只抽"magic+len+jsonEncode+payload"骨架,header map 仍由各帧按**原有插入顺序**构建。魔数不变(WSA1/WSG1/WRI1)。
- **transport 不做泛型**:transport 只见字节(帧在调用前已 encode),`PacketByteTransport<F>` 是伪需求;规避探查风险①(typedef/mock 签名连锁改动)。
- **fanout 不合并**:`AudioFanoutTransport`(1:N 广播、per-sink 失败隔离)语义独占,保留原文件,仅其内部 per-sink 发送壳委托共享类。
- **能力做并集、默认零开销**:共享 transport 同时提供可选诊断钩子(默认 no-op)与 `done` 广播流(无订阅者零成本);audio 侧不订阅 done,remote_input 侧不传诊断,行为与现状一致。
- **connect 统一取最健壮实现**(audio 版的 try/catch + 日志钩子),消除 remote_input/fanout 裸 await 的静默失败面。
- 各子系统对外类型名(`AudioPacketByteTransport` 等)与协调器注入签名**保持不变**(薄壳继承/委托共享类),协调器零改动或仅 import 级改动。

## 组件

### 1. `lib/socket/packet_byte_transport.dart`(新)

```dart
/// 三个子系统共用的 WebSocket 字节传输核心:
/// send(已编码帧字节)、close 幂等、close 后 send 静默丢弃(可选计数钩子)。
class PacketByteTransport {
  PacketByteTransport({
    required void Function(Object bytes) sendBytes,
    required Future<void> Function() closeSink,
    void Function()? onPacketSent,      // 诊断:成功发送(audio 用)
    void Function()? onPacketDropped,   // 诊断:closed 后丢弃(audio 用)
  });

  bool get isClosed;
  Stream<void> get done;                // 连接结束广播流(remote_input 用;无订阅零开销)
  void send(Object bytes);
  Future<void> close();
}

/// 统一 WS 连接:try/catch + 可选日志钩子,连接失败 rethrow(与现 audio 版一致)。
Future<PacketByteTransport> connectPacketWebSocket(
  Uri uri, {
  void Function(String message)? log,
});

/// 三份重复的 peer WS URI 构造收敛。
Uri buildPeerPacketUri({required String host, required int port, required String path});
```

### 2. `lib/socket/framed_packet_codec.dart`(新)

```dart
/// magic(4B ASCII) + uint32BE len + JSON header + payload 的共享骨架。
Uint8List encodeFramedPacket(String magic, Map<String, dynamic> header, Uint8List payload);
({Map<String, dynamic> header, Uint8List payload}) decodeFramedPacket(String magic, Uint8List bytes);
bool looksLikeFramedPacket(String magic, Uint8List bytes);

/// 从 audio/remote_input 两份重复中上收的 JSON 助手。
T enumByName<T extends Enum>(List<T> values, Object? raw, T fallback);
T? nullableEnumByName<T extends Enum>(List<T> values, Object? raw);
int intJson(Object? raw, [int fallback = 0]);
double doubleJson(Object? raw, [double fallback = 0]);
```

### 3. 三个子系统薄壳化

- `AudioPacketByteTransport`/`AudioGroupPacketByteTransport`/`RemoteInputPacketByteTransport`:类型名与公开签名不变,内部委托 `PacketByteTransport`;audio 版把 `AudioShareDiagnostics` 接到诊断钩子;`RemoteInputObservablePacketTransport` 的 `done` 直接用共享流。删除 APT/AFT 死代码 `.stream` getter(grep 零引用为据)。
- 三个 `*PacketFrame.encode/decode`:改为调用 `encodeFramedPacket`/`decodeFramedPacket`,header map 构建保持原字段与插入序;`_enumByName` 等本地助手删除,改用共享版。
- 协调器的 `_audioUri`/`_inputUri` 改调 `buildPeerPacketUri`(默认 path 作为调用参数保留)。

## 测试策略

| 对象 | 方式 |
|---|---|
| **wire 等价(核心)** | 每个 Frame 一组黄金字节测试:固定输入 → 断言 encode 输出的 magic/len/header JSON 串/payload 逐段与重构前布局一致(重构前先跑一次采集期望字节写进测试,同 commit 落地),外加 roundtrip |
| 共享 transport | 单测:close 幂等、closed 后 send 丢弃且钩子计数、done 流在 close/onDone 时发射 |
| connect | 现有 audio_packet_transport_test 迁移适配;connect 失败 rethrow 语义保留断言 |
| 既有测试 | `audio_packet_transport_test`(3)、`audio_fanout_transport_test`(4)、`audio_protocol_test`/`audio_group_protocol_test`、`remote_input_platform_test:312-330` 全部保持通过(签名不变则应零改;有改动逐个报告) |
| 回归 | `flutter analyze` + 全量 `flutter test` |

## 不做

- 不加自动重连、不加版本号/checksum 等新 wire 特性(YAGNI;断线恢复仍归上层控制通道)。
- 不改 `AudioFanoutTransport` 的异常传播语义(探查风险③)。
- 不动 svrmanager/FileTransferEngine(V3 帧另有 WFR3 体系,非本组范围)。
- 不统一三个 Frame 的 header 字段集(4/9/5 差异是协议事实)。

## 风险

- 黄金字节测试是 wire 等价的唯一硬门,必须**先采集后重构**(Task 顺序保证)。
- `done` 流上收后 remote_input 的断线通知路径改走共享实现,`remote_input_platform_test` 若有行为断言需逐一核对。
