# 两台设备的手工验收

已开始用 macOS 与 Windows 两台实体机器执行独立的局域网传输验证，结果与范围见 [本次验证记录](lan-transfer-results.md)。下面的界面操作仍用于补测 Wi-Fi 开关、系统休眠和实际 App 界面；传输引擎测试不能代替这些场景。

## 先准备

选你最常用的手机和电脑，安装同一个版本，连接同一个 Wi-Fi；准备一个可丢弃的 2 GiB 测试文件、一个小文件，以及一组约 100 个文件，每次只改变一个条件。

记录两端系统、Whisper 版本、文件大小、发送方向、总耗时、进度到 100% 后的等待时间。先用小文件确认已配对并能互传。

## 按顺序操作

| 用例 | 怎么做 | 通过标准 |
| --- | --- | --- |
| 大文件双向互传 | 发送 2 GiB 文件，完成后交换发送方向 | 两端最终都显示完成；文件可打开，大小与 SHA-256 一致；分别记录总耗时和收尾耗时 |
| 网络中断 | 传到约一半时关闭一端 Wi-Fi，等待 10 秒后恢复，再按界面提示继续 | 没有提前报告成功；能够继续或明确提示重试；最终文件摘要一致 |
| 应用重新打开 | 传到约一半时退出接收端，再打开并重连 | 不把未完成文件当成成功；能恢复或明确重试；不留下两个相互冲突的“已完成”记录 |
| 已存在同名文件 | 接收目录先放一个不同内容的同名测试文件，再发送 | 原文件内容不变；新文件以不同名称保存且摘要正确 |
| 连续使用 | 连续发送一组文件，再发送文本和一个大文件 | 没有卡住、漏文件或错误的成功提示；完成后的设备仍可正常收发 |

先把这五项在常用设备组合各做一次，有问题就记录，暂时不需要搭复杂的测试平台。

## 核对 SHA-256

macOS：`shasum -a 256 "/路径/测试文件"`。

Linux：`sha256sum "/路径/测试文件"`。

Windows PowerShell：`Get-FileHash -Algorithm SHA256 "C:\路径\测试文件"`。

如果手机没有现成的摘要工具，可把收到的文件再传回电脑并另存，与原文件在电脑上比较摘要；这是往返核对，不能单独定位哪一段出错。

## 出问题时只需留下这些信息

复制这个模板：`版本 / 两端系统 / 发送方向 / 文件大小 / 操作步骤 / 卡住阶段与时长 / 界面错误 / 是否可重试 / 摘要是否一致`。

出现文件内容不一致或覆盖已有文件时，先保存测试现场与这条记录，暂停该场景重复操作；不用发送文件正文或完整本地数据库。

## 可重复运行的两机测试

仓库提供 `test/manual/lan_transfer_peer.dart` 与 `tool/lan_transfer_check.py`。前者使用正式的认证、加密、传输引擎、SQLite 和文件系统；仅使用独立身份、测试数据库和下载目录，不启动发现服务或 App 界面，也不读取正式 App 的身份。文件名刻意不以 `_test.dart` 结尾，不会混入日常测试。

先在两端使用同一份代码并执行 `flutter pub get`，再在本机生成两份配置，把示例 IP 和数据路径换成自己的；每轮选择新的目录，端口不要与正式 App 重复：

```sh
python3 tool/lan_transfer_check.py prepare --output /tmp/whisper-lan-config \
  --local-root /tmp/whisper-lan-data --remote-root D:/dev/whisper-lan-data \
  --local-host 192.168.1.10 --remote-host 192.168.1.20
```

将 `remote.json` 复制到 Windows，本机保留 `local.json`。配置包含仅供本轮使用的身份种子，不要提交 Git；数据目录必须是绝对路径。两端各运行下面的命令并保持终端打开，把路径替换为本机对应配置：

```sh
flutter test --no-pub test/manual/lan_transfer_peer.dart --reporter expanded \
  --dart-define=WHISPER_LAN_TEST_CONFIG=/tmp/whisper-lan-config/local.json
```

Windows PowerShell 请把命令写成一行，使用 `D:/.../remote.json`；`python3` 可换成本机的 `python`。启动后在另一终端发命令，使用 `status` 确认上条命令已经结束，再提交下一条，避免覆盖尚未处理的命令。

```sh
python3 tool/lan_transfer_check.py command --config /tmp/whisper-lan-config/local.json connect
python3 tool/lan_transfer_check.py command --config /tmp/whisper-lan-config/local.json create --path send/test-2g.bin --mib 2048
python3 tool/lan_transfer_check.py command --config /tmp/whisper-lan-config/local.json send --path send/test-2g.bin --transfer-id 01234567-89ab-4cde-8fab-0123456789ab
python3 tool/lan_transfer_check.py status --config /tmp/whisper-lan-config/local.json
```

任一端建立连接后即可双向发送；如 Windows 入站端口受限，可在 Windows 端执行 `connect`，无需关闭防火墙。成功收到文件后，在两端按上面的系统命令独立核对 SHA-256。

`disconnect` 主动断开测试连接，重连后用 `retry --transfer-id ...` 继续。测试进程意外结束后，使用原配置重新启动以保留数据库与暂存进度；旧的发送命令不会被自动重放。`stop` 正常结束测试。完整状态记录保存在各自数据目录的 `events.jsonl`，进程内 `ms` 是单调计时，不能拿不同机器的时间戳直接相减。
