# 声音共享：谁负责接着放

协议 16 起只有组播放：一台来源（`AudioGroupCoordinator` 里 `sourcePeerId` 是本机的那一端）把声音放给一台或多台播放端。本文说明连接出问题之后由谁、在什么时候把声音接回来。代码在 `lib/audio/audio_group_coordinator.dart` 和 `lib/audio/audio_group_recovery.dart`。

## 来源说了算

以前每台播放端自己记着要不要重连（五个标志），断线后发 `sinkJoinRequest`。来源如果还没发现旧连接断了，会把这个请求当成多余的丢掉，那台音箱就一直不响，直到有人重开整个组。现在播放端不再自己重连，只有来源决定：

| 发生了什么 | 来源怎么做 |
| --- | --- |
| 播放端的设备断开（`WsSvrManager` 调 `peerDisconnected`） | 标成失败，记进 `AudioGroupRecovery`；不发任何东西 |
| 那台设备重新连上（`peerConnected`，资料刷新也会调到） | 立刻用新会话号重新 `groupOffer`，重试次数清零；已经在等应答的不重复发 |
| 设备还连着，但媒体通道断了，或 offer 没人应答 | 等 1、3、8 秒各重发一次；用完后等它重新连上 |
| 播放端暂停或断开（收到它的 `groupStop`），或来源这边取消勾选 | 从恢复名单里删掉，不再主动放过去 |
| 收到 `sinkJoinRequest`（那边用户点了继续） | 一律重新 offer，即使来源以为它还在放：先断掉旧的媒体通道 |
| 收到不认识的组的 `sinkJoinRequest` | 回 `groupStop`，那边清掉“可以继续”的状态 |

播放端断线时只停播放、保留 `_sinkRejoinContext`，界面上仍能点继续。

## 交错到达的 offer

播放端暂停或断开后，来源可能已经发出了一个 offer（应答更早的继续，或刚好在重新放）。播放端在暂停后 5 秒内收到同一组的第一个 offer 时回 `groupStop` 拒掉，避免回到“在放但没声音”；超过 5 秒的 offer 是来源那边的人又勾选了它，照常接受。用的是单调时钟，改系统时间不影响。

## 一台准备好就开始

来源在任意一台播放端完成时钟同步（`rttMicros > 0`）后就开始采集，延迟按已同步的那些算。以前要等所有勾选的设备都同步，一台连不上，其余的也都不响。

## 测试

`test/audio_group_coordinator_test.dart` 的“the source alone brings a lost sink back”一组覆盖断开再连上、暂停后不主动放、`sinkJoinRequest` 总被应答、不认识的组回停止。没在真机上测：电脑睡眠醒来后声音自动接回、Wi-Fi 短暂断开、Android 做播放端。
