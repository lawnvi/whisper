# Android → macOS 手机应急控制器实现记录

日期：2026-10-06。分支：`codex/mobile-air-mouse-spike`。

## 使用与边界

Android 与 Mac 在同一局域网完成双向信任、连接后，从电脑会话右上角的“控制电脑”进入，点击“开始控制”。Mac 需要已登录、Whisper 正在运行并具有辅助功能权限。Mac 侧栏显示控制来源和停止按钮。

- 默认体感模式，按住中央区域转腕移动；松手停止，下一次按住从新姿态开始。
- 左右键按钮发送完整按下/抬起。按住左键即可转腕拖拽；按钮变化后抑制 80ms 的体感运动。
- 按住滚动按钮，上下转腕滚动；另有屏幕滑动滚动区。
- 触控板支持单指相对移动、轻点左击及双指滚动。缺少陀螺仪或重力传感器、传感器失败时使用触控板。
- 虚拟键盘包含主键、符号、F1–F12 和导航键。Command、Control、Option、Shift 在手机本地选中，下一次按键组合结束后解除。方向键/退格长按 400ms 开始重复，间隔 60ms。键盘可横向滚动，滚动不会发送按键。
- “文字输入”使用手机输入法编辑，再显式提交最多 4KiB UTF-8。发送期间禁用其他输入；确认成功后清空草稿，失败/超时保留草稿，不自动重发。
- 旋转屏幕、切换模式/键盘页先释放当前操作；返回、后台、锁屏、停止、断连结束控制。恢复前台或重新连接后需要手动开始。
- 控制期间保持手机屏幕亮起。体感灵敏度 0.5–3 倍本地保存，提供静止校准。页面文案覆盖中、英、西三种语言。

无屏幕回传、唤醒或登录界面控制。iOS、Windows、Linux 不声明手机手动控制能力；已有桌面共享继续使用原协议模式。

## 协议与实现

`RemoteInputMode.edgeTraversal` 是省略 mode 时的默认值；`manual` 不要求屏幕布局，不启动桌面捕获，也不进行边缘回切。未知 mode 拒绝解析。设备协议版本为 11，连接按 11 → 10 → 9 回退；仅原有协议不匹配/尚未取得对端 profile 的连接关闭允许回退，认证拒绝不触发回退。

`remoteInputManualSourceV1` 仅 Android 声明，`remoteInputManualSinkV1` 仅 macOS 声明；两字段在版本 9、10 的 wire profile 中移除。控制与输入复用现有信任、认证加密会话、coordinator、manager、`/input` 通道和共享生命周期所有权。

Android Kotlin 插件以 100Hz 为目标采集陀螺仪与重力方向及单调时间戳。纯 Dart 映射器投影到重力轴/水平手机右向轴，校准偏置并应用死区和滤波；无效值、不递增时间、超过 100ms 间隔或暂停重置积分。默认增益、死区、滤波时间常量集中在 `MobileMotionMapper`，目前仍需真机调参。

手机侧以约 60Hz 合并移动，按钮、按键和滚动类别变化前刷新。手动模式的相对移动在有界发送队列中可靠排队，避免旧桌面逻辑替换移动包、跨越点击顺序；队列过载沿用断开和释放机制。

Mac 从当前光标位置开始，指针限制在实际显示器区域。虚拟键盘通过共享键表发送明确语义和 Mac 键码，手动接收不猜测来源键盘平台。手动会话不启用文件剪贴板联动，Command+V 使用 Mac 当前剪贴板。

`textCommit` 与鼠标/键盘共用有序注入队列。Mac 以 Unicode scalar 边界分成不超过 20 个 UTF-16 单元的原生事件，换行按 Enter 处理，不改写剪贴板。`textResult` 关联会话和事件序号；成功只表示交给系统，不保证目标应用接收。发送端等待结果最多 5 秒，迟到回复不清除后续草稿。

源端每 500ms 发送认证 heartbeat。接收端首次输入前有 5 秒启动期限，随后 2 秒内没有有效的新序号输入/心跳就终止并释放全部按钮、按键。错误、离线和所有权切换均复用生命周期清理。

## 主要文件

| 文件/目录 | 改动 |
| --- | --- |
| `lib/remote_input/remote_input_protocol.dart`、`remote_input_manager.dart`、`remote_input_coordinator.dart` | 模式、文字回复、会话、心跳、队列和清理 |
| `lib/remote_input/remote_input_packet_transport.dart`、`remote_input_workspace_coordinator.dart` | 手动移动可靠排队、桌面路由隔离 |
| `lib/socket/peer_socket_session.dart`、`svrmanager.dart`、`lib/state/peer_profile.dart` | 协议 11、回退、平台能力及入口校验 |
| `android/app/src/main/kotlin/com/vireen/whisper/MobileMotionPlugin.kt` | Android 传感器与生命周期桥接 |
| `lib/remote_input/mobile_motion.dart`、`mobile_input_controller.dart`、`remote_input_key_translation.dart` | 体感、触控、键盘映射与重复控制 |
| `lib/remote_input/mobile_control_screen.dart`、`manual_control_receiver_banner.dart` | 手机控制页与 Mac 来源/停止界面 |
| `lib/page/conversation.dart`、`deviceList.dart`、`lib/helper/local.dart`、`lib/l10n/` | 页面入口、偏好与三语文案 |
| `macos/Runner/MainFlutterWindow.swift` | 当前光标起点、显示器边界、Unicode 注入 |
| `test/manual_remote_input_test.dart`、`mobile_input_controller_test.dart`、`mobile_control_screen_test.dart` | 新功能的协议、算法和界面测试 |

## 提交

1. `237becc`：手动协议、版本协商、认证通路、Mac 注入、心跳及协议测试。
2. `36375ed`：Android 传感器、体感映射、触控/按键事件控制器、共享键表、灵敏度及测试。
3. `7a46ae1`：手机入口、完整控制页面、虚拟键盘/文字输入、Mac 来源横幅、三语文案及界面测试。
4. 最后收尾提交：首个心跳发送失败后的计时器防护、失败会话横幅清理、回归验证和本记录。

## 自动与构建验证

使用独立 Flutter 3.44.9 / Dart 3.12.2，包源保持 `https://pub.dev`。锁文件仅因 SDK 约束更新 `meta` 1.17.0 → 1.18.0、`test_api` 0.7.10 → 0.7.11；没有新增 Flutter 传感器依赖。Android 保留 Flutter 3.44.9 自动加入的旧 Kotlin/DSL 兼容开关。

专项测试覆盖版本回退与能力过滤、手动模式无原生捕获、桌面所有权互斥、启动/失联期限、无效与重复输入、移动/按钮队列顺序、组合键释放、重复按键取消、80ms 拖拽抑制、坐标投影/校准/暂停、文字成功/失败/超时。界面测试覆盖无传感器、信任/权限错误、键盘横向滚动不发键、断连草稿、指针取消/后台释放、小屏/横屏、深色主题及大字号。

| 检查 | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | 通过，无问题 |
| `flutter test --no-pub --concurrency=2` | 1696 通过，3 项按测试配置跳过 |
| `./script/test_remote_input_keys.sh` | 100 项通过 |
| 手动会话/可靠传输专项复测 | 15 项通过，包含首个心跳发送失败 |
| 体感映射/手机界面专项复测 | 15 项通过 |
| Android ARM64 debug 构建 | `flutter build apk --debug --no-pub --target-platform android-arm64 --split-per-abi` 通过；产物 `build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk` |
| macOS debug 构建 | 通过，产物 `build/macos/Build/Products/Debug/whisper.app` |
| macOS `./script/build_and_run.sh --verify` | 构建通过后，在缺少稳定签名凭据处停止；未验证签名/启动 |

本地 macOS 脚本使用已安装的 CocoaPods 1.16.2 路径，并设置 `WHISPER_UPDATE_CHANNEL=stable`，绕过系统 Ruby 的 CocoaPods 依赖缺失及旧版 Bash 对空数组的限制。未改动构建脚本或签名资产。

最初磁盘写满导致 NDK 下载与 Gradle 缓存索引损坏，已清理本次未完成下载，并将损坏的索引备份后重建。空间恢复后使用 Flutter 默认 NDK 重试；临时 NDK 29 尝试没有保留任何项目配置变更。通用 APK 在合并多架构原生库时再次因磁盘不足失败；清理本次生成的编译中间缓存后，ARM64 独立 APK 构建成功。正式 Gradle 配置保持默认，NDK 28 用于应用构建，既有插件还自动安装了 NDK 27。

真机验收结果不由单元测试或构建结果代替。

## 尚需人工真机验收

- 连续 20 次点击/双击及 20 次拖拽，确认无漏抬起；静置手机 10 秒记录漂移，目标 ≤5 个桌面逻辑像素。
- 用高帧率录像测量端到端延迟，目标 p95 <100ms。当前滤波参数尚未取得实测数据。
- TextEdit、浏览器和终端中验证字母与当前输入法、全部功能/导航键、Command/Control/Option/Shift 组合、中英文、emoji、多行及文字后 Enter。
- 真机后台、锁屏、断网和重新连接：远端无残留按下状态，必须再次手动开始；多显示器及边界不退出控制。
- 三种语言的真机布局与无传感器机型的触控板体验。

未改动签名证书、密钥或 keystore。macOS debug 编译已通过，但仓库脚本的稳定签名/启动验证需要已有签名凭据；本次用 `WHISPER_MACOS_REQUIRE_STABLE_SIGNING=1` 禁止脚本自动创建本地证书，执行在缺少凭据处停止。
