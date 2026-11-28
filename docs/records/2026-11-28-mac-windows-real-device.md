# 2026-11-28 Mac 和 Windows 真机：构建、全量测试、跨机器传输、放着测

网络治理做完后，第一次在 Windows 真机上跑。两台机器：开发用的 Mac（macOS 27）和一台 Windows 11 笔记本，都走 Wi-Fi。前半段在一个慢网络上（Windows 网卡协商 72 Mbps），后半段两台一起换到一个快网络（Mac 量到的链路约 60–75 MB/s）。

## Windows 构建和全量测试

- `flutter build windows --release` 通过，含 `packages/window_stream_native` 的 Windows 源码。之前这些只用 zig 做过编译检查。
- 全量 `flutter test`：1474 过、30 败。29 条是 Windows 上原本就挂的：Linux/macOS 专用的测试、读源码文本的测试、CRLF、临时文件被占用删不掉、加载阶段的偶发。
- 新的那一条是 `typed_connection_handshake_integration_test` 里的坏帧测试，二分定位到“/chat 出站队列按控制、挂载、大块三级调度”那次提交起，它在 Windows 上必挂。原因是调试入口直接 `sink.add`，而出站队列的 `addStream` 还在写，被 dart:io 拒掉。已改成走出站队列（“调试用的坏帧也走出站队列”），只影响测试入口。

## 跨机器传输（测试实例）

两边各起一个 `WsSvrManager.forTesting`，Mac 监听、Windows 拨入，传完核对字节数，用完删掉。慢网络：

| 通道 | Windows→Mac | Mac→Windows |
| --- | --- | --- |
| `/chat`，64 MiB | 2.4 MiB/s | 3.0 MiB/s |
| `/transfer` 修复前 | 1.7 MiB/s；1 GiB 那次卡在 889 MB | 约 1 MiB 后断开 |
| `/transfer` 修复后，64 MiB | 3.7 MiB/s | 3.9 MiB/s |
| `/transfer` 修复后，256 MiB | 3.5 MiB/s | 4.0 MiB/s |

同一台 Mac 上两个进程走回环传 1 GiB：`/transfer` 250–295 MiB/s，`/chat` 35–37 MiB/s。

## 找到的两个问题：确认先于"已发出"到达

一帧交给 `/transfer` 以后，要等 worker 回执，发送方才把它记为已发出。接收方可能在这之前就收到并确认了这一帧。确认处理（现在在 `lib/socket/file_transfer_outgoing_ack.dart`）以前只认窗口里记着的范围，于是把这条确认当成错误，`/chat` 按协议错误断开，传输停在暂停。引擎里一直有这个竞态，J1 让交帧变慢以后才常见。它有两种形态：

1. **慢网络**：上一个窗口在下一帧交出途中被确认，这一帧就没有窗口，随后对它的确认被判成过期会话（`session_not_current`）。测试实例上开头几帧必中。
2. **快网络**：确认超出窗口，被判越界（`transfer_offset_invalid`）。测试实例上没碰到，是在真实程序里约 60 MB/s 传 399 MB 时撞上的，两次断开。

两种形态在同一个提交里修掉（“确认先于已发出到达时按进度收下”）：交给连接就算已发出，交出失败才退回；没有窗口或超出窗口的确认，只要在已交出的范围内，就按进度收下；发送途中窗口变了，这一轮就退出。

回归测试在 `test/file_transfer_engine_test.dart`，名为 "an ACK for a frame still being handed over is progress"，用 5 帧覆盖三种时序。撤掉修复后，它报的就是上面两种错误。

## 真实程序放着测

Mac 跑调试版，Windows 跑覆盖进安装目录的 release 版。Mac 控制 Windows 的键鼠，声音从 Mac 放到 Windows。两边每分钟采样一次连接状态。

- 放了约 7.5 小时，没断，Windows 那边几条 TCP 的端口一直没变。
- 两台一起换 Wi-Fi 时断开一次，十秒内经发现重新连上。
- 修复之前，快网络上传大文件断了两次，就是上面的第 2 个问题。
- 换上修复后：之前暂停的 399 MB 续传完成；又传了 293 MB 两个、399 MB 一个，每个约 10 秒（30–36 MB/s），没有断开，日志里也没有再出现这两种错误。
- 重启 Windows 那边的 Whisper：Mac 自动连回，键鼠和声音不用手动开，自己接上。

## 没测的

- 有线千兆上的跨机器速度。
- 快网络上 Windows→Mac 方向的真实程序传输，以及文件夹传输。
- 窗口流转、反拨、Linux。
- 已知没改：Mac 锁屏或关屏时打开声音共享，屏幕亮了也不会自己出声，要关掉再开一次。原因是采集失败只重试三次（2、5、10 秒），原生侧"亮屏后重开"只管已经开起来的流。
