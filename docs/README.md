# 文档

每类文档只有一个位置。写之前先看这张表，放错地方的文档会过时也没人发现。

| 位置 | 写给谁、写什么 | 什么时候改 |
| --- | --- | --- |
| `README.md`、`README_en.md` | 第一次来的人：是什么、下载哪个包、快速开始、平台支持、安全说明 | 功能、平台支持或安装方式变了 |
| `docs/user-guide*.md` | 用户：每项功能怎么用 | 行为或界面变了，和代码同一个提交 |
| `docs/troubleshooting*.md` | 用户：出问题时按什么顺序查 | 加了新的诊断或发现了常见原因 |
| `DESIGN.md`、`docs/design/` | 改界面的人：界面规则、各屏规格、决定 | 见 [design/README.md](design/README.md) |
| `docs/internals/` | 开发者：一个子系统现在怎么工作、为什么这样做、怎么验证、还有什么没验证 | 和代码同一个提交；做法废弃了就删掉 |
| `docs/records/` | 带日期的记录：实测数据、审查、调研、实验 | 写完不再改；结论过时，在开头加一句指向新文档 |
| `docs/superpowers/` | 早期的设计稿和实施计划 | 只读的历史，不再往里加 |
| `AGENTS.md`、`CLAUDE.md` | 写代码的人和工具：命令、代码规范、测试规则、架构总览 | 规则或架构变了 |

## 规则

- **用户文档中英两份内容一致。** 改了 `user-guide.md` 就要改 `user-guide_en.md`，README 和排障指南也一样。开发文档和记录只写中文。
- **同一件事只写在一处。** 别处要提就链接过去，不要复制一段。README 只写概要，细节链接到使用指南。
- **文件名用小写英文和连字符。** `docs/records/` 下的文件以日期开头：`2026-11-10-udp-weak-wifi.md`。
- **写路径和类名，不写行号。** 行号一改代码就错了；要指向某个时刻的代码，写提交号。
- **写清楚没做的和没验证的。** 哪个平台没测、哪种情况会退回旧路径，比测过的部分更要写。
- **新功能的设计**写进 `docs/internals/<功能>.md`；实现过程中的实测和比较写进 `docs/records/`，两者互相链接。
- **记录不是承诺。** `docs/records/` 里提到的方案和数字只代表当时，不能当成功能说明引用给用户。
- **用户文档里不写内部名词。** 不出现类名、协议字段和测试文件；用界面上的叫法。
- **不写和别的项目的对比，也不点名别的项目。**

## 目录

**给用户**

- [使用指南](user-guide.md) · [User guide](user-guide_en.md)
- [排障指南](troubleshooting.md) · [Troubleshooting](troubleshooting_en.md)

**开发者：现在怎么工作**

- [键鼠和声音的 UDP 通道](internals/udp-lane.md)
- [键鼠共享的会话归属与退出](internals/remote-input-lifecycle.md)
- [电视投屏（DLNA）](internals/cast-receiver.md)
- [两台设备的手工验收](internals/manual-reliability-check.md)
- 界面：[design/README.md](design/README.md)

**记录**

- [2026-09-05 macOS / Windows 局域网验证](records/2026-09-05-lan-transfer-results.md)
- [2026-09-05 大文件完成阶段优化](records/2026-09-05-transfer-completion.md)
- [2026-09-11 键鼠与剪贴板共享稳定性审查](records/2026-09-11-remote-input-stability-review.md)
- [2026-09-17 AirPlay 与 Wi-Fi Direct 投屏实验](records/2026-09-17-cast-experiments.md)
- [2026-10-07 发布前检查与打磨建议](records/2026-10-07-pre-release-review.md)
- [2026-10-09 iOS 与 iPad 验证](records/2026-10-09-ios-validation.md)
- [2026-11-08 手机摄像头、麦克风和电话的方案调研](records/2026-11-08-camera-mic-calls-research.md)
- [2026-11-10 弱 Wi-Fi 上的 UDP 键鼠和声音](records/2026-11-10-udp-weak-wifi.md)
- [2026-11-11 共享声音或键鼠时传输越来越慢](records/2026-11-11-transfer-pacing-live.md)
- [2026-11-12 传文件时给声音和键鼠留一成带宽](records/2026-11-12-transfer-pacing-headroom.md)

各子系统的设计稿和计划在 [superpowers/specs](superpowers/specs) 和 [superpowers/plans](superpowers/plans)，按日期命名。它们记录的是当时的打算，代码和上面的开发文档以现在为准。
