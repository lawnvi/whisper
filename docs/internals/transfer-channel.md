# 大块数据的独立通道（`/transfer`）

文件传输、文件夹传输和远程目录挂载的数据帧（`fileData`、`browseData`、`browseWrite`）不再和聊天、心跳、各子系统控制信令挤在 `/chat` 的同一条 TCP 连接上，而是按用途各自走独立的认证 WebSocket 通道 `/transfer`，收发和加解密跑在独立工作 isolate（`TransferDataIsolate`）里。

控制面（`fileOffer` / `fileReady` / `fileAck` / `fileVerify` / `fileComplete` / `fileCancel` / `fileError`，以及挂载的 `open` / `list` / `stat` / `read` / `writeOpen` / `writeSize` / `writeClose`）仍走 `/chat`，由主 isolate 的 `FileTransferEngine`、`FileBrowseHost`、`RemoteFilesClient` 和 `TransferPacer` 驱动。

## 两条独立连接：文件与挂载互不阻塞

每对已认证的 `/chat` 连接按需建立最多两条 `/transfer` 连接（`TransferChannelKind`）：

| 用途（`kind`） | 承载的帧类型 | Socket 选项 |
| --- | --- | --- |
| `bulk` | 仅 `WhisperFrameType.fileData` | Windows 16 MiB 收发缓冲（`widenTransferBuffers`）、macOS/Linux/Android `TCP_NOTSENT_LOWAT`（256 KiB）、POSIX 尽力而为 DSCP CS1（`IP_TOS = 0x20`） |
| `browse` | 仅 `WhisperFrameType.browseData` 与 `WhisperFrameType.browseWrite` | 默认内核缓冲、`TCP_NODELAY`、macOS/Linux/Android `TCP_NOTSENT_LOWAT`（256 KiB），不标 CS1 |

两条连接各自独立成条 TCP，避免远程目录挂载的读写在内核缓冲里排在几秒的文件数据后面。工作 isolate 在解密后立刻按 `kind` 核对帧类型和长度上限，任何控制帧或跨 `kind` 帧都会立即关闭该 `/transfer` 连接，绝不注入 `/chat` 路由。

## 端口、能力协商与建连流程

- **能力名**：`PeerCapabilities.transferChannelV1`（协议 16 增量能力字段）。对端未声明该能力时，大块数据自动走 `/chat`。
- **端口**：`WhisperPorts.transferData(main)`，默认为服务端口 +3（`10005` TCP），被占用时顺延尝试 8 个端口，最后回退任意可用端口；实际端口通过 `/chat` 上的 `MessageEnum.TransferChannelControl`（`TransferChannelControlMessage`）通告。
- **令牌、证明与双向密钥**：复用 `SessionUpgradeTokenRegistry`（route `/transfer`，namespace `bulk-transfer`）、`MediaUpgradeServer` 与 `dialMediaChannel`，做法见 [media-channels.md](media-channels.md)。证明通过后，双方各自用本机 `mediaSendKey` 建 `AuthenticatedMediaPacketEncoder`、用本机 `mediaReceiveKey` 建 `AuthenticatedMediaPacketDecoder`（绑定同一令牌），两方向密钥独立，无 nonce 复用。
- **同时发起（glare）**：同一 `(peerId, kind)` 双方同时发出 `open` 时，按 `localPeerId.compareTo(remotePeerId) < 0` 裁决；胜者保留自己的 `open`，败者取消自己的 `open` 并 `accept` 对方。
- **反拨与回退**：正向拨号遇 `mediaPeerUnreachable` 时，发起方签发 `reverse: true` 令牌并发 `dialBack` 请对方反拨本机工作 isolate 端口（地址一律取 `/chat` 对端地址 `_mediaDialHost`）。正向与反拨均失败时，该 `(peerId, localGeneration, kind)` 回退 `/chat`，直到下一次重连换代；`/chat` 保留原有的 Windows 16 MiB 缓冲以保回退吞吐。

## 调速、背压与跨连接一致性

- **调速器留主 isolate**：`TransferPacer`（`TransferPacing`）留在主 isolate，与 `LinkDelay.shared` 同处一处；同设备的 `/transfer` 与 `/chat` 回退天然共用调速器。拨出和接受端都使用 `BackpressureWebSocketChannel`，worker 的写出回执（`_SendAck`）严格在 `WebSocket.addStream` 真正完成后发出，不合并也不切分帧；限速态下主→worker 每设备最多 2 帧在途，避免突发。
- **入站串行与背压**：worker 统计每条连接的未确认入站字节，达到 8 MiB 时 `subscription.pause()` 施加 TCP 窗口反压；主 isolate 在 `TransferChannelManager` 按 `(peerId, kind)` 串行成 Future 链逐帧交付（保证 `fileData` 序号推进和 `browseWrite` 落盘在后台数据库/磁盘 `await` 让出事件循环时也不会并发交错），单帧处理完成后再向 worker 归还信用，降至 4 MiB 以下恢复。
- **同代重开与旧帧丢弃**：每条 `/transfer` 连接在 worker 中分配全局单调递增的 `channelId`。通道关闭或新连接接管时，`TransferChannelManager` 立即清除/推进该 `(peerId, kind)` 的活跃 `channelId`，旧 `channelId` 残留入站帧在进入业务引擎前一律丢弃。
- **中途断线恢复**：`bulk` 通道意外断开而 `/chat` 仍存活时，`FileTransferEngine.handleBulkChannelDropped` 立即取消当前发送窗口并转入 `waitingReconnect` 退避重协商（文件和文件夹均从接收端持久化断点安全续传）；`browse` 断开时 `RemoteFilesClient.failInflightDataForPeer` 立即结束在途读写请求避免干等超时。
- **跨连接先后约束**：
  - `/chat` 上的 `fileCancel` / `fileError` 可能早于 `/transfer` 上的尾包 `fileData` 到达，已终止/非活跃传输的迟到 `fileData` 静默丢弃，不关 `/transfer` 也不关 `/chat`。
  - 挂载写由 `RemoteFilesClient` 在发出 `writeSize` / `writeClose` 前强制等待同一 `uploadId` 的全部在途 `write()` 回复，按客户端实际发出的写入边界记录 `size` 并在 `writeClose(commit: true)` 中携带（若任意写失败则拒绝提交并清理远端临时文件）；主机 `FsUploads.close` 提交前核对临时文件长度，不等则拒绝提交并删临时文件。

## 代码位置

- `lib/socket/transfer_channel_protocol.dart`：`TransferChannelKind`、`TransferChannelAction`、`TransferChannelControlMessage`
- `lib/socket/transfer_data_isolate.dart`、`transfer_data_worker.dart`、`transfer_data_server.dart`：工作 isolate、worker 服务端、双向加密与背压
- `lib/socket/transfer_channel_manager.dart`：每设备分用途通道状态机、glare、反拨、回退、`channelId` 隔离与在途额度
- `lib/socket/file_transfer_bulk_recovery.dart`：`bulk` 通道中途断开时的传输恢复
- `lib/socket/svrmanager_media.dart`、`svrmanager_control.dart`、`svrmanager_hosts.dart`：`WsSvrManager` 接线与令牌代理

## 测试与未验证项

- `test/transfer_channel_integration_test.dart` 在真实 socket + 真实工作 isolate + 后台数据库（`NativeDatabase.createInBackground`）上覆盖了：文件/文件夹走 `bulk`、32 MiB 大文件传输全程 `bulk` `channelId` 不变、入站帧按 `(peerId, kind)` 严格串行、挂载读写走独立 `browse`（不排在文件后）、挂载 `writeClose` 截断拒交与客户端在途写屏障、`bulk` 中途断开同代重开与新 `channelId` 续传、未授权/带 `Origin` 升级拒绝、非法控制帧关闭 `bulk`、反拨、同时 `open` glare、无能力回退 `/chat`。
- **尚未在真机实测的**：Windows 与 Linux 防火墙下 `10005` TCP 放行与反拨、千兆/弱 Wi-Fi 真机下与键鼠/声音并发时的吞吐和指针延迟实测、DSCP CS1 在物理路由器上的实际标记效果。
