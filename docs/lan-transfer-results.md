# macOS / Windows 局域网验证记录

日期：2026-09-05。代码基线 `49da292` 加本轮工作区改动，Windows 在独立测试 worktree 中运行。

## 环境与范围

- macOS：Flutter 3.41.7，Dart 3.11.5。
- Windows：系统版本 10.0.26200，Xeon E5-2698B v3，Flutter 3.41.9，Dart 3.11.5，D 盘为 NTFS。
- 两台实体机器通过局域网连接，运行 `test/manual/lan_transfer_peer.dart`，认证协议版本 10、原生加密加速开启。
- 测试使用正式 WebSocket、身份验证、加密、文件传输引擎、SQLite 和磁盘，配置独立身份、端口、数据库及下载目录；预先固定对端测试公钥。
- 不包含 App 界面、首次配对提示、mDNS 发现、关闭 Wi-Fi、系统休眠、手机平台或长时间压力测试。

## 大文件耗时

每个文件为 2 GiB，即 2147483648 字节。总耗时取发送端首个传输状态到完成，收尾取接收端 `verifying` 到 `completed`；均使用同一进程的单调时钟，不跨机器相减。

| 场景 | 发送端总耗时 | 接收端收尾 | 结果 |
| --- | ---: | ---: | --- |
| Mac → Windows，Windows 仍走复制保存 | 84.65 s | 34.11 s | 两端完成，独立 SHA-256 一致 |
| Windows → Mac，Mac 走排他移动 | 41.03 s | 0.091 s | 两端完成，独立 SHA-256 一致 |
| Mac → Windows，新增 NTFS 免复制保存 | 59.26 s | 0.700 s | 两端完成，独立 SHA-256 一致；原同名文件保留 |

Windows 同机同文件的收尾由 34.11 秒降至 0.700 秒，单次测量约减少 98%。网络阶段有波动，这些数据不是所有设备、磁盘或网络的性能承诺；修改前一行已经包含后台校验队列优化，差别主要是 Windows 的保存方式。

SHA-256 使用 macOS `shasum -a 256` 和 Windows `Get-FileHash` 独立核对，未仅依赖 App 自己的完成状态：

- Mac 发出的 2 GiB 文件：`5f1b0e99d41d3553b488a0b115e12a4088bde23abb256714020b96bb0649f857`。
- Windows 发出的 2 GiB 文件：`25d78e8871e6ee5bd2855d5aab055a22638b063c86da0aadf75ce7494b2cc8a8`。

## 异常与后续使用

| 场景 | 操作与观察 | 结果 |
| --- | --- | --- |
| 接收进程被强制结束 | Windows 收到 800 MiB 时强制结束独立 `flutter_tester.exe`，发送端转为等待重连；接收端以原数据库重启，恢复到 838860800 字节，重连后暂停待重试 | 通过；显式重试后从已有进度继续，两端完成，最终 SHA-256 与原文件一致 |
| 同名但不同内容的文件 | 接收目录先生成 1 MiB 的 `collision.bin`，使用与发送文件不同的内容，再发送同名文件 | 通过；原文件摘要保持预期，新文件为 `collision-1.bin` 且摘要与发送源一致 |
| 完成后的继续使用 | 大文件、强制中断恢复和同名文件用例后，两端互发测试文本 | 通过；两端收到文本，发送消息都收到确认 |
| 暂存文件清理 | 检查新增免复制传输对应的暂存文件，并在完整性用例中断言完成后暂存路径不存在 | 通过 |

这证明了所测两机组合的引擎层传输与进程重启恢复，不代表已验证 Wi-Fi 开关或整个 GUI 的异常恢复体验。

## 本次修复和回归检查

1. Windows 使用 `CreateHardLinkW` 给已校验的暂存文件建立不覆盖目标的最终文件名，数据库提交后关闭句柄并删除暂存名称，避免再复制整份文件；不支持时仍回退到原复制路径。[Microsoft API 文档](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createhardlinkw)
2. 修复 Windows 失败清理时，额外读取句柄被自身文件锁阻挡、导致部分目标无法确认归属的问题。
3. 完成后先关闭校验快照，再清理暂存文件，避免 Windows 拒绝删除仍被打开的文件。
4. 修复测试的句柄清理，并对 Windows 由系统阻止的重命名攻击验证“重命名被拒绝”，保留 Unix 的路径替换检查。

验证结果：本机 `flutter analyze` 无问题；完整 `flutter test` 通过 1581 项，3 项 Windows 专用用例在 macOS 跳过；Windows 的校验、发布、完整性和路径策略四个测试文件通过 51 项，6 项 Unix 专用用例跳过；macOS 签名构建、启动验证通过。

Windows 原生构建通过（`flutter build windows --debug --no-pub`，约 245 秒）。最初被依赖 Cargokit 的路径解析脚本阻挡：它无法读取隐藏的 `AppData` 缓存目录；改用单独的 `PUB_CACHE=D:\dev\whisper-lan-pub-cache-20260906` 后成功，不修改系统目录属性或原项目配置。

测试副本为 `D:\dev\whisper-lan-test-20260906`，Windows 构建产物为该目录下的 `build\windows\x64\runner\Debug\whisper.exe`，运行时需保留同目录依赖文件。七个核心传输源文件已逐一比较 SHA-256，与本机一致；原来的 `D:\dev\whisper` 工作区仍干净。Windows 构建已通过，但未通过远程 GUI 验证该可执行文件的界面启动。

复现入口、命令和尚需进行的界面验收见 [两台设备的手工验收](manual-reliability-check.md)。
