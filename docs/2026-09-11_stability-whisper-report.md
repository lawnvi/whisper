# 键鼠与剪贴板共享稳定性审查

审查日期：2026-09-11；基线：`dev` 分支 `2e82e77` 加本轮工作区修复。

后续调整：单设备与工作区已接入统一的会话生命周期和资源清理，具体职责与交接规则见[会话归属与退出](remote-input-lifecycle.md)；以下保留首次稳定性审查的验证记录。

结论：局域网内由控制端统一路由输入、剪贴板先通知再传输、平台层负责键鼠注入的方案可以保留，当前主要缺陷在异步取消、会话所有权和缓存生命周期；这些已确认的问题已修复，但当前构建仍是验收候选版，尚未发布。

## 设计判断

| 范围 | 判断 | 本轮处理 |
| --- | --- | --- |
| 控制与输入通道 | 分开传输有利于低延迟，但退出输入通道必须立即结束被控状态 | 通道开始关闭时释放会话，不等待接收队列排空 |
| 单设备与工作区状态 | 两套协调器职责有重叠，容易在停止、重连和角色切换时互相干扰 | 增加异步任务代次检查、停止去重和控制角色互斥 |
| 剪贴板传输 | 元数据通知、分块传输、大小限制和按需下载合理 | 图片预下载不占住接收队列，并发粘贴复用下载，旧任务只清理自身资源 |
| 输入框粘贴 | 本地按键和远端原生快捷键应进入同一粘贴处理流程 | 接入 `PasteTextIntent`，同时让已粘贴草稿独立于共享缓存 |
| 原生输入层 | 会话编号已经随调用传入，但 macOS、Windows 的停止入口此前未核对它 | 仅停止匹配的会话，防止迟到的停止操作影响新会话 |

不建议在这次稳定性修复中重写整个键鼠模块；后续应逐步合并两套协调器的会话生命周期管理，并继续审查慢速剪贴板下载期间的输入排队体验及临时文件清理策略。

## Evidence → Finding → Path

下表的“复现”是自动化用例中的受控时序，并不等同于三台桌面的人工操作验收。

| 证据 | 发现与状态 | 调用路径及修复位置 |
| --- | --- | --- |
| E1：[图片下载队列回归](../test/remote_clipboard_transfer_test.dart) | F1：截图预下载等待同一接收队列中的数据，会拖住后续控制；已修复并通过回归 | P1：收到 offer → 后台准备图片 → 独立处理 data/complete；[传输引擎](../lib/remote_input/remote_clipboard_transfer.dart) |
| E2：`a failed old request cannot remove its replacement`，修复前超时，修复后通过 | F2：旧请求发送失败会移除新请求；已复现、已修复 | P2：旧请求等待发送 → 新 offer 替换 → 旧发送失败；同一传输引擎按对象身份清理，并在等待文件操作前分离旧状态 |
| E3：`stopping during native injection startup cannot reactivate the session`，修复前变回 active，修复后保持 idle | F3：停止后，迟到的原生启动回调仍会启用注入；已复现、已修复 | P3：开始注入 → 停止 → 启动返回；[单设备协调器](../lib/remote_input/remote_input_coordinator.dart) 使用任务代次取消旧流程 |
| E4：`stopping while transport connects cannot restart capture`，修复前变回 armed，修复后保持 idle 并关闭迟到连接 | F4：连接中的工作区停止后仍可能重新启动；已复现、已修复 | P4：连接输入通道 → 停止工作区 → 连接完成；[工作区协调器](../lib/remote_input/remote_input_workspace_coordinator.dart) 检查代次、目标身份和在线状态 |
| E5：[输入通道独立断开回归](../test/bounded_binary_websocket_session_test.dart) | F5：仅输入通道断开时，被控端缺少主动结束通知；已修复，用例验证通知发生在慢速关闭完成之前 | P5：通道关闭 → `onClosing` → `onSessionClosed` → 停止注入、取消粘贴；[通道](../lib/socket/bounded_binary_websocket_session.dart)、[输入管理器](../lib/remote_input/remote_input_manager.dart) |
| E6：[输入框原生粘贴回归](../test/chat_composer_test.dart)、[草稿保留回归](../test/desktop_clipboard_image_test.dart) | F6：远端粘贴绕过图片处理，且草稿可能随着共享缓存一起被删除；已修复，原生粘贴入口此前已有失败复现 | P6：原生粘贴意图 → [输入框](../lib/widget/chat_composer.dart) → [保留草稿文件](../lib/helper/desktop_clipboard_image.dart) |

其他收紧：连接失败退出工作区目标状态、被控端拒绝恢复旧控制计划、原生输入报错通知对端停止；已有回归同时覆盖按键顺序、移动合并、队列上限、注入超时及边缘释放。

## 截图操作

在截图模式下，单击选中鼠标下方的可见窗口，拖动仍然选择区域，选完后可移动或调整边缘，按 Enter 或确认按钮复制，Esc 取消。

窗口列表在遮罩出现前取得，避免选中截图遮罩本身；点击容忍轻微手抖，拖动后回到起点仍按拖动处理，超出桌面的窗口边界会裁剪到桌面内。

实现覆盖 macOS、Windows 和 Linux X11；Wayland 使用系统截图门户，其交互由桌面环境提供。

窗口边界依据系统接口：[Apple 窗口列表](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:))、[GTK 窗口堆叠](https://docs.gtk.org/gdk3/method.Screen.get_window_stack.html)、[GTK 窗口边界](https://docs.gtk.org/gdk3/method.Window.get_frame_extents.html)、[Windows DWM 边界](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute)。

## 已完成的验证

| 环境 | 结果 | 实机操作状态 |
| --- | --- | --- |
| 本机 macOS arm64 | Release 编译、原证书签名、安装文件校验和进程启动通过 | 已更新；完整跨机流程未完成 |
| 另一台 macOS x86_64 | Release 编译、原证书签名、安装文件校验和进程启动通过 | 已更新；完整跨机流程未完成 |
| Linux X11 x86_64 | 421 个同步文件校验一致，69 项相关测试通过，Release 构建及进程启动通过 | 已更新测试构建；完整跨机流程未完成 |
| Windows | 原生代码已修改，共享 C++ 选区几何检查通过 | 本轮未进行 Windows 编译和桌面验证 |

本机 `flutter analyze --no-pub` 无问题；完整 `flutter test --no-pub` 为 **1633 通过、3 跳过**，截图选区 C++ 检查通过。

本轮自动化桌面工具返回过旧窗口信息及 `noWindowsAvailable`，未能可靠执行完整的点击截图与跨机粘贴，因此没有将尝试操作记作通过，也没有据此认定应用界面卡死。

## 发布前剩余验收

使用合成图片和无敏感信息的测试窗口，分别交换两台设备的控制与被控角色；每条连续完成五次并记录实际结果。

1. 截图时单击窗口、拖动区域、调整边缘、确认和取消，多屏时检查负坐标与不同缩放比例。
2. 在任一端用 Whisper、微信或 QQ 截图，到另一端的 Whisper 输入框及系统应用粘贴，确认图片预览与鼠标返回都正常。
3. 粘贴图片后继续截图、复制或停止共享，确认输入框中原来的草稿仍可读取。
4. 在图片准备中、连接中、按住修饰键时分别停止共享或关闭对端，确认双方状态退出且本机键鼠恢复。
5. 断线重连、休眠唤醒、切换控制角色和增减显示器后重试，确认旧会话不会复活、屏幕排列能刷新。

需完成 Windows 原生构建以及上述双向实机验收后，再确定正式版本号并发布；现有测试结果不能证明所有平台上的操作体验已经稳定。

## 复跑命令

在仓库根目录、Flutter SDK 已在 PATH 中的环境执行：

```sh
flutter analyze --no-pub
flutter test --no-pub
clang++ -std=c++17 -Wall -Wextra -Werror test/native/screenshot_selection_test.cc -o /tmp/whisper-screenshot-selection-test
/tmp/whisper-screenshot-selection-test
```

其中前三个取消竞态用例的失败现象记录于本轮修复前的运行日志；当前代码应全部通过，如需独立复现旧故障，应将对应修复前实现与同一用例配对运行。
