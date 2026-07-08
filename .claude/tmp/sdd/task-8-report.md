# Task 8 Report: 协调器 sink 暂停/重加入

## 改动文件

- `lib/audio/audio_group_coordinator.dart`
  - 新增 sink 端公开 API:
    - `bool get isPlaybackActive`
    - `bool get canRejoinAsSink`
    - `Future<void> pausePlaybackAsSink()`
    - `Future<bool> requestRejoinAsSink()`
  - 新增 `_SinkRejoinContext`,保存暂停前的 group/stream/session/source/local/role/latency/sendControl。
  - sink 收到 offer 成功开播后清空 rejoin context。
  - `stopLocal()` 清空 rejoin context;`_stopPlaybackOnly()` 不清 context。
  - 源端收到 sink 的 `groupStop` 时调用 `_fanout.detachAndClose(message.sinkPeerId)` 后标记 stopped。
  - 源端收到 `sinkJoinRequest` 时复用 `updateGroup` 的 terminal sink fresh-offer 路径。
  - `updateGroup` 允许仍保留 terminal sinks 的 stopped session 进入 re-offer,并在非 live session re-offer 后把 session state 恢复为 `offering`。
- `test/audio_group_coordinator_test.dart`
  - 追加 4 个协调器用例:
    - `pausePlaybackAsSink` 发送 `groupStop`、停止本地播放、保留 rejoin context。
    - `requestRejoinAsSink` 无 context 返回 false,暂停后发送 `sinkJoinRequest`,成功新 offer 后清空 context。
    - source 收到 `sinkJoinRequest` 后向 stopped sink 重新发送 `groupOffer`。
    - source 收到 sink `groupStop` 后关闭 fanout transport 并标记 sink stopped。
  - 新增 `_offerSinkPlayback` 测试辅助函数。

## TDD 记录

1. 先读现有测试 helper 与 `audio_group_session.dart`。
2. 确认 `AudioGroupSink.isTerminal` 包含 `AudioGroupSinkState.stopped`。
3. 先追加真实可执行测试并运行:
   - `flutter test test/audio_group_coordinator_test.dart`
   - RED 摘要: `isPlaybackActive`、`canRejoinAsSink`、`pausePlaybackAsSink`、`requestRejoinAsSink` 不存在。
4. 实现 sink pause/rejoin 与 source stop/join 处理。
5. 协调器测试转绿后,补充 session state 断言,确认单 sink stopped 后 re-offer 不能保持 `AudioGroupState.stopped`:
   - RED 摘要: expected `AudioGroupState.offering`, actual `AudioGroupState.stopped`。
6. 修复 `updateGroup` 非 live terminal re-offer 的 state 恢复。

## isTerminal 走向

- `AudioGroupSinkState.stopped` 已经是 terminal。
- 因此源端 `sinkJoinRequest` 走 brief 的主路径:复用 `updateGroup` 中 terminal sink 的 fresh-offer 分支。
- 额外处理:单 sink 停止会让 session state 变为 `stopped`,所以 `updateGroup` 放行带 terminal sinks 的 stopped session,并在 re-offer 后恢复 `AudioGroupState.offering`。

## 验证命令与输出摘要

- `flutter test test/audio_group_coordinator_test.dart`
  - RED: 退出码 1,新公开 API 不存在。
- `flutter test test/audio_group_coordinator_test.dart --plain-name "AudioGroupCoordinator source re-offers a sink on sinkJoinRequest"`
  - RED: 退出码 1,session state 仍为 `stopped`。
- `flutter test test/audio_group_coordinator_test.dart && flutter analyze && flutter test`
  - 退出码: 0。
  - 协调器测试: `All tests passed!`,共 20 项通过。
  - analyze: `No issues found!`
  - full test: `All tests passed!`,共 504 项通过。
- `git diff --check`
  - 退出码: 0。

## 自审

- 只修改协调器和协调器测试,未动 UI、协议 enum、原生层或 l10n。
- source 端 `groupStop` 现在会真正断开对应 sink 的 fanout transport。
- sink 端暂停不销毁 rejoin context;彻底 `stopLocal()` 和成功收到新 offer 后会清空。
- 新增测试覆盖了单 sink 重加入,避免 session state 停在 `stopped` 后无法继续作为 live group。

## Concerns

- 无。

## Review Fix: sinkJoinRequest 不唤醒其他 terminal sink

## 改动文件

- `lib/audio/audio_group_coordinator.dart`
  - `sinkJoinRequest` 只把非 terminal sinks 与请求方 `message.sinkPeerId` 纳入新 offer 的 `sinkPeerIds`。
  - 请求方是 terminal sink 时,直接只向请求方发送 fresh `groupOffer`,避免复用 `updateGroup` 对被排除 terminal sinks 发送 `groupStop`。
  - 保留其他 terminal sink 的状态,不自动恢复播放。
- `test/audio_group_coordinator_test.dart`
  - 新增回归用例:`sinkJoinRequest does not re-offer other terminal sinks`。
  - 覆盖 A=failed、B=stopped、B 发起 `sinkJoinRequest` 时,只有 B 收到新 `groupOffer`,A 不收到任何消息。

## TDD 记录

1. 先新增回归测试。
2. 运行:
   - `flutter test test/audio_group_coordinator_test.dart --plain-name "AudioGroupCoordinator sinkJoinRequest does not re-offer other terminal sinks"`
   - RED: 退出码 1,expected length 1,actual length 2,证明旧实现会连带给 failed sink A 发消息。
3. 最小修复 `sinkJoinRequest` 分支,过滤 terminal sinks 并只 direct offer 请求方。
4. 重新运行同一回归用例转绿。

## 验证命令与输出摘要

- `flutter test test/audio_group_coordinator_test.dart --plain-name "AudioGroupCoordinator sinkJoinRequest does not re-offer other terminal sinks"`
  - 退出码: 0。
  - 输出摘要:`All tests passed!`
- `flutter test test/audio_group_coordinator_test.dart`
  - 退出码: 0。
  - 输出摘要:`All tests passed!`,共 21 项通过。
- `flutter test`
  - 退出码: 0。
  - 输出摘要:`All tests passed!`,共 505 项通过。
- `dart format --set-exit-if-changed lib/audio/audio_group_coordinator.dart test/audio_group_coordinator_test.dart`
  - 退出码: 0,`Formatted 2 files (0 changed)`。
- `git diff --check`
  - 退出码: 0。
- `flutter analyze`
  - 退出码: 0。
  - 输出摘要:`No issues found!`

## 自审

- 旧的“只过滤 sinks 后调用 `updateGroup`”仍会给被排除的 failed sink 发送 `groupStop`,不满足 A 没有任何消息的回归要求。
- 因此修复使用 direct offer 请求方,同时用过滤后的 sink 集合生成 offer 上的 `sinkPeerIds`;这样不会唤醒或触达其他 terminal sink。

## Concerns

- 无。
