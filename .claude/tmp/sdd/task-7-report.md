# Task 7 Report: 音频协议扩展

## 改动文件

- `lib/audio/audio_protocol.dart`
  - `AudioGroupControlAction` 新增 `sinkJoinRequest`,放在 `error` 之前。
- `lib/state/peer_profile.dart`
  - `PeerCapabilities` 新增 `audioGroupRejoinV1`,默认 `false`。
  - 构造参数、字段、`toJson`、`fromJson` 四处按现有 capability 模式补齐。
- `lib/socket/svrmanager.dart`
  - 本机 `PeerCapabilities` 声明新增 `audioGroupRejoinV1: true`。
- `lib/audio/audio_group_coordinator.dart`
  - 为新增 enum 在现有 `switch` 中补 no-op 分支,保持 analyze exhaustive switch 通过。
  - 本任务不实现重加入行为,仅作为协议动作占位。
- `test/audio_protocol_test.dart`
  - 追加 `sinkJoinRequest` action roundtrip 测试,并锚定 unknown action fallback 到 `error`。
- `test/peer_profile_test.dart`
  - 新建 `audioGroupRejoinV1` capability roundtrip 与默认 false 测试。

## TDD 记录

1. 先追加 `test/audio_protocol_test.dart` 和新建 `test/peer_profile_test.dart`。
2. 运行 `flutter test test/audio_protocol_test.dart test/peer_profile_test.dart`。
   - 预期失败。
   - 失败摘要:
     - `AudioGroupControlAction.sinkJoinRequest` 不存在。
     - `PeerCapabilities(audioGroupRejoinV1: true)` 参数/字段不存在。
3. 最小实现 enum、capability 字段和本机 profile 声明。
4. 初次验证中目标测试通过,但 `flutter analyze` 报:
   - `AudioGroupControlAction` switch 未覆盖 `sinkJoinRequest`。
5. 读取对应 switch 后补 no-op 分支,因为 Task 7 只引入协议动作,后续任务再实现 join 行为。

## 验证命令与输出摘要

- `flutter test test/audio_protocol_test.dart test/peer_profile_test.dart`
  - RED: 退出码 1,缺少 enum/字段导致编译失败。
- `flutter test test/audio_protocol_test.dart test/peer_profile_test.dart && flutter analyze`
  - 第一次: 目标测试 9 项通过,analyze 失败于 exhaustive switch。
  - 第二次: 退出码 0。
  - 目标测试: `All tests passed!`,共 9 项通过。
  - analyze: `No issues found!`
- `git diff --check`
  - 退出码: 0。

## 自审

- 未新增 pub 依赖。
- `error` 仍保留为 unknown action fallback。
- `audioGroupRejoinV1` legacy/default 行为为 `false`。
- 本机能力声明为 `true`,供后续 Task 8/10 消费。

## Concerns

- 无。
