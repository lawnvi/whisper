# 手机控制器：多电脑切换、设置与 Windows / Ubuntu 接收

日期：2026-10-06。分支：`codex/mobile-air-mouse-spike`。

后续状态：Ubuntu 的连接端口与 portal 滚轮问题已修复，手机连接、键鼠操作和最终键盘过渡已复测，用户也已确认 Windows、Ubuntu 控制正常。详见[修复与实机验证记录](2026-10-06-mobile-controller-ubuntu-connection-fix.md)。当前代码职责划分见[手机手动控制](../../remote-input-lifecycle.md#手机手动控制)；下面的验证清单保留本次平台扩展提交时的记录。

## 界面和交互

- 会话入口使用与现有线性图标一致的显示器与指针图形，沿用应用主题。
- 点控制页顶部电脑名称查看已连接且支持手动控制的设备。一次只控制一台；切换先释放旧会话，新设备需要再次点“开始控制”。停止消息按实际目标发送，避免误发给进入页面时的会话设备。
- 体感和触控板都能打开设置。触控板移动速度、滚动速度、体感灵敏度分别保存，范围均为 0.5–3 倍。体感移动不重复乘触控板速度。
- 体感右侧是手指上下滑动的滚动区，改为滑动图形和文字说明；不是两个上下按钮。
- 键盘切换先停止输入、淡出，等待方向和窗口尺寸更新后淡入；Android 使用交叉淡化旋转，避免旋转旧键盘截图。遵循减少动画设置。Windows/Linux 键帽显示 Win/Super、Alt，Mac 显示 Cmd、Opt。
- 中、英、西文案同步更新。继续保留免长按体感、大触控板和双指轻点右击。

主要文件：`mobile_control_screen.dart`、`mobile_input_controller.dart`、`conversation.dart`、`computer_control_icon.dart`、`local.dart`、Android `MainActivity.kt` 和本地化资源。

## 桌面接收和兼容性

Windows/Linux 现在声明协议 11 的手动接收能力，沿用认证、加密、输入通道、所有权、心跳和失联释放；协议 9/10 的能力过滤与桌面工作区入口保留。iOS 不新增能力。

Windows 原生接收从当前光标开始、保留细微位移余数、限制到真实显示器范围；手动模式不执行跨屏边缘回切。Unicode 文本通过 `SendInput` 注入，处理 UTF-16 代理对和换行，不改剪贴板。

Linux 沿用 X11 或 RemoteDesktop portal 接收。手动 portal 会话使用 NotifyPointer/Keyboard 接口；原有桌面 EIS 路径保留。精确滚动保留像素幅度，停止释放已记录的按钮与按键。

**Linux 文本限制：** GNOME 对当前键盘映射不存在的 Unicode keysym 可能确认成功但丢弃字符。现在发送前检查整段文字；发现不支持的字符就失败并保留完整草稿，不发送部分文字，不覆盖剪贴板或改全局键盘映射。中文/emoji 的直接文字发送尚不支持所有 Linux 布局；可用直接按键配合电脑输入法。手机 Linux 文字页明确提示该限制。

Windows/Ubuntu 需要本轮接收端；macOS 原生接收没有修改。本轮没有修改依赖、锁文件或签名资产。

## 自动验证

Flutter 3.44.9 / Dart 3.12.2；包源保持 pub.dev。

- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub --concurrency=2`：1,720 通过，3 跳过。
- 完整测试后补充三个原生源码契约回归检查；`./script/test_remote_input_keys.sh` 101 通过，Linux 原生源码测试 20 通过。
- 手机控制页与控制器最终针对性测试 33 通过，包含多目标释放/手动开始、设置保存、方向过渡时禁用输入、速度独立缩放和事件顺序。
- Android ARM64 debug 构建成功，已安装 MI 6，保留应用数据。
- Windows debug 构建成功；测试后已恢复并启动正常应用。
- Ubuntu debug 构建成功；测试后已恢复并启动正常应用，监听局域网端口 10002。

Ubuntu 构建机缺少部分开发库且无免密 sudo，开发/运行库解包到 `/tmp/whisper-linux-deps`，通过 PKG_CONFIG_PATH、LIBRARY_PATH、LD_LIBRARY_PATH 引用。Clang 26 对既有 hotkey_manager_linux 依赖的警告以本机构建选项 `-Wno-error=sometimes-uninitialized` 降为警告；未修改该依赖或仓库 CMake。不能将其表述为全新系统无需准备即可通过的标准构建。

本轮未重新执行 macOS `./script/build_and_run.sh --verify`：没有 Mac 原生改动，沿用此前运行的接收端；本机没有可用稳定签名身份，未创建、导入或修改签名资产。

## 实机验证和剩余验收

Windows 的独立测试窗口调用生产原生桥接：中文、emoji、多行文本完全一致；文字后 Enter/A 正确；Ctrl 和拖拽在停止后释放；五次 1.25 像素移动累计为 6 像素；移动到外边缘不触发回切。用户随后确认手机实际控制 Windows 键鼠看起来正常。

Ubuntu 当前为 GNOME Wayland/Xwayland。独立窗口验证英文多行文本、Enter/A、停止释放 Ctrl；包含不支持的中文/emoji 的段落被整段拒绝，窗口原内容保持不变。一次原生探测收到成对的左键与右键按下/抬起；后续精确位移/滚轮探测受 Xwayland 光标读数及窗口焦点影响，没有形成可靠的精度/滚轮通过结论，留给手机实际连接验收。

手机已实际检查新图标、三项速度设置、设备选择页；键盘能进入 1920×1080 横屏并返回竖屏，控制会话保持。最后的 Android 交叉淡化修正已构建安装，但尚未完成新录像逐帧复核。旧版本旋转截图问题的录像不能作为修正后通过的证据。

真机握持手感、受控静置漂移和高帧率 p95 延迟仍需人工验收。自动测试和原生注入探测不能替代端到端测量。

## 测试环境收尾

远端使用同一分支同步代码，Windows 的旧测试文件已按授权清理；Ubuntu 原目录部分文件不属于登录用户，保留在 `whisper-before-mobile-control-20261006`，当前路径使用可构建的用户所有副本。临时原生探测应用已退出，Windows 的两个临时计划任务已删除，避免定时重跑。正常 Whisper 保持运行供用户测试。
