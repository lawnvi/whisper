# 大文件完成阶段优化

文件到达 100% 后，接收端仍需排空磁盘写入、取得完整 SHA-256、发布文件并提交数据库；发送端收到完成确认后才结束。

本次保留完整 SHA-256 校验，改动两处：

- `ParallelStreamingChecksum.add()` 现在需要等待，后台待校验数据默认限制在 8 MiB 附近，避免整份文件排队到最后才处理；单个大块可临时超过该值。
- 流式校验完成后，在支持的同一文件系统上使用“不覆盖目标”的排他移动或硬链接，无需再把暂存文件完整复制到下载目录。

## 本机复测

运行 `dart run tool/transfer_completion_benchmark.dart 1024`，使用相同的 1 GiB 数据和系统临时目录；工具会删除自己生成的测试文件。

| 阶段 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 模拟接收、写入并提交校验 | 766.37 ms | 2102.96 ms |
| 最后一次刷新与关闭写入 | 13.66 ms | 10.25 ms |
| 等待校验队列结束 | 1238.45 ms | 4.49 ms |
| 封存已校验文件 | 2.35 ms | 2.52 ms |
| 发布到最终路径 | 799.05 ms | 7.22 ms |
| 写完后的收尾合计 | 2053.51 ms | 24.48 ms |

这是 2026-09-05 在本机 macOS 上的单次前后基线，不是网络或手机性能承诺；接收阶段变长是因为等待校验跟上，省掉复制才减少了实际工作量。

两次摘要均为 `188e43c2f1b607dc07b58ee779b9b58fb176a51d79a7abfa70c80a16947b692c`。基准不包含数据库提交或系统文件可见性通知。

另用 `2048` 参数运行了 2 GiB 文件：模拟接收与写入 4082.76 ms，写完后的收尾 22.48 ms，最终大小为 2147483648 字节，仍采用排他移动。

## 支持边界与回退

macOS 使用 `renamex_np(RENAME_EXCL)`，Linux/Android 尝试 `renameat2(RENAME_NOREPLACE)`；Windows 在支持的同卷 NTFS 上使用 `CreateHardLinkW` 创建最终名称，提交数据库并关闭文件句柄后移除暂存名称，不复制内容。符号、文件系统不支持、权限限制或者跨文件系统时回退到原复制路径，iOS 当前保留复制路径，所有平台都使用有界校验队列。

同名文件与符号链接不会被覆盖；保存时间戳或数据库提交失败时，尝试把属于本次传输的文件移回暂存路径；如果路径已被其他文件占用，保留文件，避免覆盖或误删。

移动路径只用于完整接收后得到流式摘要的快照；需要重新读取内容验证的旧接口继续使用原发布逻辑。

随后增加了 macOS / Windows 双机实传验证：Windows 接收 2 GiB 后的收尾从约 34.11 秒降至 0.700 秒，完整 SHA-256 一致；也验证了强制结束接收进程后的续传和同名文件保护。环境、边界和构建检查见 [验证记录](lan-transfer-results.md)，Android、Linux、iOS 仍需按手工验收文档确认。

## 代码位置

| 模块 | 职责 |
| --- | --- |
| `lib/helper/parallel_streaming_checksum.dart` | 后台 SHA-256 与生产者等待 |
| `lib/helper/atomic_file_move.dart` | 原生排他移动与不支持时的回退结果 |
| `lib/helper/exclusive_file_link.dart` | Windows 同卷硬链接保存与回退结果 |
| `lib/socket/transfer_file_name.dart` | 跨平台文件名校验 |
| `lib/socket/file_path_policy.dart` | 暂存路径约束与兼容导出 |
| `lib/socket/verified_file_publisher.dart` | 快照、唯一命名、发布与回退 |
| `lib/socket/file_transfer_engine.dart` | 传输状态与数据库提交的编排 |

对应回归测试：`parallel_streaming_checksum_test.dart`、`verified_file_publisher_test.dart`、`file_path_policy_test.dart`、`file_transfer_integrity_test.dart`。
