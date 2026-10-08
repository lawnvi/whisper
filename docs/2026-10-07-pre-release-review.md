# 下个版本发布前检查与打磨建议

日期：2026-10-07。代码基线：`dev` / `585d872`，当前 `pubspec.yaml` 版本 `0.0.53`。

先完成审查，再按用户反馈实施日常操作与 UI 打磨。下文 R1–R10 保留审查时的证据，代码行号对应审查基线；当前实施状态见下表。优先级是发布安排建议，不代表所有项目都已完成。

## 本次实施范围

用户明确要求先不修改 dev CI，并把重点放在操作体验和 UI。本次不修改 CI、发布工作流、签名资产或依赖版本。

**最新反馈与处理：用户试用后要求撤回本轮 UI 重设计。** 已恢复原来的紧凑设备列表，移除新增的分组、搜索框、第三行身份信息和操作弹层；设备设置恢复从会话顶部直接打开。按具体反馈，仅将移动端历史搜索移入设备设置，并将“传输助手”更名为“搜索聊天记录”；删除“我的二维码”页的长说明。此前连接校验、历史分页和错误说明等修复保留。下表反映回退后的实际范围。

| 项目 | 实施状态 |
| --- | --- |
| R1 连接表单 | 恢复原表单外观，保留地址/端口校验、行内错误和输入法焦点切换；无效输入保留弹窗 |
| R2 历史分页 | 统一补载文件传输状态、并发请求保护、分页结束/重试、消息去重与退出检查 |
| R3 dev CI | 按用户要求暂缓 |
| R4 发布版本来源 | 保留在发布准备清单，本轮集中打磨产品体验 |
| R5 候选包验收 | 本轮验证 Android 覆盖安装；完整多平台发布验收仍待执行 |
| R6 失败说明 | 文件传输和手机控制区分原因，并提示下一步操作 |
| R7 设备辨认 | 新增展示已按用户要求撤回；没有合并或删除设备身份与历史 |
| R8 列表/会话 | 恢复原紧凑列表与直接设置入口。移动端历史搜索移入设置并改名；删除二维码长提示 |
| R9 剪贴板 | 关闭自动同步时避免移动端主动读取；补充 Android 前台与桌面工作区说明。首次权限请求时机尚未重构 |
| R10 平台说明/iOS | 保留为后续专项，本轮没有扩展 iOS 功能或宣称完成 iOS 验收 |

已确认的手机控制页布局保持：图标工具栏、对称左右键、中间滚轮、竖屏键盘。没有修改连接协议或远程输入注入逻辑。

保留独立的手动连接校验、历史分页状态与错误文案映射；新增移动设备列表与操作弹层组件已删除。回退后的验证日志使用 `/tmp/whisper-ui-revert-*.log`，此前 UI 重设计的日志不代表回退后的验证结果。

## 检查范围与结论

检查了连接与会话入口、历史消息分页、传输状态展示、手机控制器、设备列表、设置、各平台能力声明、原生平台实现片段、CI 和发布工作流。通过已连接的 Android 手机查看了设备列表、会话页和手动连接弹窗，并复现了空端口输入异常。

认证、传输恢复、远程输入生命周期、主题和组件测试已有较完整基础。本轮发现集中在入口校验、历史状态恢复、错误解释、移动端信息层级及发布校验。建议以小范围修复和组件收敛为主，不在发布前重写连接或输入协议。

| 验证 | 修改前的审查基线结果 |
| --- | --- |
| Flutter / Dart | 使用与 CI 一致的 Flutter 3.44.9 |
| `flutter analyze --no-pub` | 通过，无问题 |
| `flutter test --no-pub --reporter expanded` | 1746 通过，3 跳过，约 5 分 35 秒 |
| Android 实机界面抽查 | 设备列表、会话工具栏、手动连接弹窗 |
| 空端口输入 | 实机复现未处理的 `FormatException`，弹窗关闭且无行内提示 |
| 本轮原生构建 / 跨机输入与文件验收 | 未运行；既有记录只作为历史证据 |
| iOS | 代码核查；未构建、未做模拟器或真机验收 |

本轮没有对大文件吞吐、输入延迟、长期内存或电量消耗作新测量，不据此提出性能达标结论。当前工作副本不存在 `whisper-web/`，网站未纳入检查。已有未跟踪的 macOS SwiftPM 目录保持原样。

## P1：发布前修复或验证

### R1. 手动连接补齐输入校验（实机确认）

- 现象：清空端口后点“连接”，弹窗关闭，日志出现 `FormatException: Invalid number`；调用栈落在 `deviceList.dart:2898` 的 `int.parse`。连接请求还未发起。
- 代码：`lib/page/deviceList.dart:2885` 的 `_showManualConnectDialog`；同文件 `4084` 附近的 `showInputAlertDialog` 包装器没有为字段传入 validator。
- 同一入口还预填了本机地址，容易让第一次手动连接的用户误以为这是目标地址；两个输入框也用初始值充当标签。
- 建议：直接使用已有 `showValidatedInputDialog`，显示“电脑地址 / 端口”固定标签；校验空值、端口 1–65535 和现有地址规则，使用 `int.tryParse`。目标地址用示例占位或上次成功目标，避免默认填本机地址。
- 验收：空值、0、65536、超长数字、带空格地址均不抛异常；无效输入保留弹窗并显示行内说明；合法非默认端口可以连接。

### R2. 历史消息分页补载传输状态并收紧异步边界（代码确认，动态回归待补）

- 代码：`lib/page/conversation.dart:355` 首次读取 20 条消息后调用 `_loadTransferSnapshotsForMessages`；`412` 的 `_scrollListener` 后续读取 12 条，却仅调用 `_insertItems`。
- 影响：重新打开会话后，翻到较早的失败、暂停或等待重连文件，没有补载对应 `TransferSnapshot`。`_fileStatusText` 在 snapshot 为空时只显示文件大小，`_buildFileMessage` 的重试入口又要求 snapshot 非空；旧文件状态与最新一页不一致。
- 同一分页路径在数据库 await 后没有 mounted / 会话代次检查，也没有加载中保护、批量去重、空列表与已到末尾保护。这些是可见的时序缺口；本轮未动态复现重复消息或退出后更新。
- 建议：分页统一补载状态，增加请求去重、游标与结束标记、按 UUID 合并、await 后生命周期检查；临近顶端预取，提供轻量加载反馈。
- 验收：准备超过 32 条记录，早期包含失败/暂停/完成文件；退出并重进后翻页，状态和重试入口一致。连续触顶、分页中返回、分页中收到新消息，都不重复、不漏消息、不产生异步异常。

### R3. 把同一提交的测试结果接入发布流程（配置确认）

- 代码：`.github/workflows/ci.yml:3` 只在 `main` 推送、PR 和手动触发运行；当前主要工作分支为 `dev`。`.github/workflows/release.yml` 的构建只依赖版本检查，发布只依赖各平台构建。
- 影响：直接推送 dev 或从没有经过测试的提交打 tag，现有工作流仍可构建并发布；编译成功不能代替协议和状态机回归。
- 建议：dev 推送运行基础 CI；抽取可复用检查，或在发布工作流先执行 analyze/test，再让构建与发布依赖它。保持现有 Flutter 3.44.9、锁文件和包源。
- 验收：故意让测试失败时不能进入发布；分析、测试和制品对应相同提交。检查逻辑本身不触发实际发布。

### R4. 统一手动重打包的版本来源（配置确认）

- 代码：`release.yml:360` 的 Linux/Android job 与 Intel job 接受 `inputs.version`，但 Flutter build 没有传入 `--build-name`；macOS ARM 和 Windows job 的版本步骤还忽略该输入。`script/build_and_run.sh:249` 同样直接构建 pubspec 版本。
- 触发：在 `pubspec` 是 0.0.53 的提交上，手动请求重打包另一个版本。文件名或安装包外层版本可取请求值，程序内部版本仍取 pubspec；macOS ARM / Windows 文件名则可能取工作流运行号。tag 路径已有版本匹配检查，本问题主要影响手动路径。
- 建议：在统一前置步骤解析版本、构建号、渠道及源码引用；选择校验请求版本必须等于源码版本，或一致地传入构建参数。发布前读取 APK/应用/安装包内版本，与文件名和目标 release 核对。
- 验收：手动 target=all 和单平台构建得到相同版本语义；不允许把内部版本不符的制品替换到旧 release。

### R5. 用最终候选安装包补一次跨平台冒烟验收（验证缺口）

- 现有证据：`docs/lan-transfer-results.md` 是此前 Mac/Windows 引擎测试；10 月 6 日手机控制记录确认过 Android→Windows/Ubuntu 的输入。它们不能代表当前候选版本的完整安装与异常退出流程。
- Ubuntu 既有测试使用了 `/tmp` 依赖路径和本机构建警告选项；发行工作流另有准备依赖和打包 libei 的路径。需要证明发行包在普通启动环境可用，而不只是在开发终端中运行。
- 建议最小矩阵：Android→macOS/Windows/Ubuntu，旧桌面→桌面；每条覆盖重连、按住左键/修饰键时停止或断网、后台/锁屏、中文和 emoji、文件传输完成与失败重试。Ubuntu 分别记录 X11 / GNOME Wayland 与 portal 授权结果，不外推所有桌面环境。
- 使用正式候选包验证 macOS 签名和权限延续、Windows 安装升级、Linux 动态库加载、Android 覆盖安装和原数据保留。`./script/build_and_run.sh --verify` 本轮未执行，留在发布验收中。
- 体感漂移和延迟单独记录实测。已有一次校准后静置结果和普通操作反馈不能替代多设备手感与 p95 测量。

## P2：本版值得一起打磨的体验

### R6. 失败提示给出原因和可执行的下一步（代码确认）

- 文件传输：`conversation.dart:523` 把所有 failed 状态映射到“失败，可重试”，没有使用 `TransferSnapshot.lastError`。协议已区分 storage、source、integrity、queueFull 等原因。
- 手机控制：`mobile_control_screen.dart:88` 已区分权限、忙碌、信任和不支持，但 transport、protocol、injection 等原因最终仍显示“连接失败”。
- 建议：复用现有错误分类形成一致的本地化展示层。存储类错误提示检查空间/目录权限，源文件类错误提示重新选择，通道超时提示电脑在线状态，版本不支持提示升级；不要把粗粒度 storage 原因直接断言为“磁盘已满”。
- 行内保留简短原因和一个主要恢复操作，详情再展示排查步骤。保留文字提交失败后不自动重发的现有语义，避免重复输入。
- 验收：各类错误有不同且准确的文案，重试过程中防重复操作，成功后错误状态消失，中英西均覆盖。

### R7. 同名设备更容易辨认，控制目标更明确（实机与代码确认）

- 手机列表实际出现两台同名电脑，目前主要靠在线颜色和时间区分。不能据同名认定它们是重复身份，更不能自动合并或删除。
- 控制页选择器 `mobile_control_screen.dart:495` 只有设备名称和统一电脑图标；多个同名在线设备时尤其难选。
- 建议：加入本地备注名，或在同名时显示平台与短地址/身份后缀；为不同平台使用现有平台图标。在控制页保持“一次控制一台、切换后手动开始”的现有规则；列表就能看出当前目标。
- 文案保持简短，只在存在歧义时补信息，不重新增加大块说明卡。
- 验收：两台同名 Mac、长设备名、IP 变化和断线设备都可辨认；备注不改变认证身份，切换仍释放旧设备按下状态。

### R8. 收敛移动端会话工具栏和列表视觉（实机与代码确认）

- 实机：会话页顶部同时放控制、历史搜索、连接和设置，连接说明已经截断；普通移动端操作按钮在 `conversation.dart:879` 被限制为 36×48dp，横向触摸区域偏窄。
- 列表：`deviceList.dart:3130/3158` 使用 white38 / black38 与 white54 / black45；浅色白底上 black38 和 black45 的理论文字对比分别约 2.68:1、3.35:1，低于普通文字 4.5:1 目标。
- 建议：保留常用控制入口，低频动作收入“更多”；连接详情放到点按设备名称后的信息面板。移动端普通工具按钮保证至少 48dp 触摸区域；采用 `WhisperPalette.textMuted` 等语义色，让首页、会话页与新控制页风格衔接。
- 保留已经确认的控制页纯图标工具栏、对称左右键、中间滚轮、竖屏键盘；本项不撤回这些设计。
- 验收：360dp 窄屏、大字号、中英西长文案、深浅主题；检查可点击区域、语义标签和弹层动画中间帧。不能仅以“没有 overflow”认定易用。

### R9. 权限按用途解释，剪贴板行为符合用户预期（代码确认）

- `deviceList.dart:274/354` 在入口初始化时请求 Android 通知和存储权限，并读取移动端剪贴板；后者在这条路径上没有按自动同步开关过滤。
- 设置页 `settings.dart:602` 使用统一的 `clipboardAutoSyncDesc`。当前文案只说“同步到当前可信设备”，没有说明 Android 10+ 前台限制，也未说明桌面键鼠工作区的多设备同步范围。README 已有这些解释，应用内尚未对齐。
- 建议：先让用户看到用途，在启用保活/接收通知或选择保存方式时请求相应权限；拒绝后给出可用的替代操作。将启动读取、监听和主动粘贴的条件梳理清楚，避免自动同步关闭时仍发生无必要读取。
- 设置说明按平台和当前功能展示：Android 明确“回到 Whisper 后同步”；桌面说明工作区范围。详细解释放二级说明，保持页面紧凑。
- 验收：新安装、首次拒绝、从系统撤销后返回、只使用键鼠控制等场景；同步关闭不发生非用户发起的剪贴板读取/发送，主动粘贴仍可用。

### R10. 发布说明和平台能力表跟上实现，iOS 分阶段处理（代码与文档确认）

- README 的功能段落尚未介绍 Android 手机控制电脑；仍写 Linux 键鼠需要 X11，而原生代码和此前 Ubuntu 记录已有 GNOME Wayland portal 路径。应准确说明所测环境和依赖，不能直接改成“所有 Wayland 支持”。
- Linux 文字提交在部分布局下不能注入中文/emoji，已有预检拒绝与保留草稿，也有控制页说明；发布说明需要同步这一边界。
- Android 项目最低声明为 API 24（Android 7.0），体感还取决于陀螺仪/重力传感器；无传感器可用触控板。最低声明不等于所有版本和机型均完成验收。
- iOS 仍没有手动输入源声明和 CoreMotion 桥接，iPad 当前锁定竖屏和全屏。建议本轮先做模拟器构建、配对/文本/文件基础回归并明确“实验性/待验证”；完整控制器与 iPad 自适应作为有独立验收范围的功能项。
- 验收：README 中英、发布说明、应用入口三者一致；用户能分清已支持、依赖系统条件、尚未实现的功能。

## P3：随修复逐步整理

- `deviceList.dart` 约 4100 行，`conversation.dart` 约 2700 行，`svrmanager.dart` 约 6000 行。按本轮实际修改点拆出手动连接表单、历史分页和错误展示；避免只按文件长度开展大规模重构。
- `chat_connection_banner.dart` 的旧展示组件、`device_workspace.dart` 中部分卡片没有当前调用者；核实后移除，并把仍使用的数据类型与展示组件分离。不要把这些未使用组件中的硬编码文案误报成当前用户一定会遇到的问题。
- 现有原生 source tests 对契约有价值，但字符串存在不能证明系统实际注入、权限弹窗或安装包能运行；保留它们，同时补关键平台的行为验收。

## 建议实施批次

1. **连接与历史可靠性**：R1、R2；先补失败复现用例，再修复与回归。
2. **发布一致性**：R3、R4；校验同一提交、版本、渠道和制品元数据，禁止用发布动作测试工作流。
3. **日常使用打磨**：R6–R9；复用现有主题与组件，保留已经确认的手机控制交互。
4. **平台收尾**：R5、R10；用同一候选包记录多平台结果，完成说明更新，明确 iOS 本版支持边界。

每批独立提交；功能修改后运行针对性测试，合入候选版本前统一运行 analyze、全量测试及相关原生构建/验收。正式发布仍需单独授权。

## 本地证据

日志与截图仅存于本机临时目录，未上传或加入仓库：

- `/tmp/whisper-pre-release-analyze.log`
- `/tmp/whisper-pre-release-tests.log`
- `/tmp/whisper-pre-release-manual-port-error.log`
- `/tmp/whisper-audit-android-current.png`（设备列表）
- `/tmp/whisper-audit-android-conversation.png`（会话工具栏）
- `/tmp/whisper-audit-manual-connect.png`（手动连接初始状态）
- `/tmp/whisper-audit-port-submitted.png`（空端口提交后返回列表，无输入错误提示）

## UI 重设计的验证结果（回退前历史记录）

使用 Flutter 3.44.9，不更换包源或更新锁文件。

| 验证 | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | 通过，无问题 |
| `flutter test --no-pub --reporter expanded` | 1763 通过，3 跳过，约 6 分 12 秒 |
| `flutter build apk --debug --target-platform android-arm64 --no-pub` | 通过；已覆盖安装至 MI 6 / Android 13，保留原有数据 |
| 组件与状态回归 | 中英西、深浅主题、360dp/大字号、设备搜索、分页并发/取消/失败重试、同名同地址辨认、表单校验与软键盘焦点切换 |
| Android 实机 | 查看首页分组、同名同地址的标识区分、会话菜单、连接弹窗；确认空端口保留弹窗并显示范围说明 |
| 既有测试适配 | 将桌面信任图标检查指向实际设备行组件；文件消息检查适配有类型的分页函数签名，保留原有行为断言 |

最终日志：`/tmp/whisper-ux-analyze-final.log`、`/tmp/whisper-ux-all-tests-final.log`、`/tmp/whisper-ux-android-build-final.log`。
实机截图：`/tmp/whisper-ux-phone-home-final.png`、`/tmp/whisper-ux-phone-conversation.png`、`/tmp/whisper-ux-phone-actions.png`、`/tmp/whisper-ux-phone-port-error.png`。

本轮未重新执行 macOS `./script/build_and_run.sh --verify`、Windows `flutter build windows`、Linux `flutter build linux` 或 iOS 构建。共享 Dart 逻辑经过全量测试；各桌面平台原生窗口/输入权限和安装升级仍需候选包验收，不能以此次 Android 界面验证替代。没有修改原生输入、认证或传输协议，也没有对体感延迟、漂移和耗电作新的性能结论。

## 按试用反馈回退 UI

用户要求撤回本轮界面重设计，恢复紧凑、直接的操作路径。设备列表和手机控制器的展示已恢复到 `585d872` 基线；移动端会话顶部保留控制、连接和直接设置入口，历史搜索按用户建议放到设备设置中，并统一改名为“搜索聊天记录”。“我的二维码”页删除长说明，二维码、地址、身份指纹和复制功能保持原样。

连接地址/端口校验、历史分页状态补载、分页去重与生命周期检查、具体失败原因提示以及剪贴板开关修复保留。没有修改 dev CI、签名和依赖，没有删除或合并设备/消息数据。

Android 回退版已构建并覆盖安装。实机确认两行设备列表、顶部设置直接进入、从设置进入历史搜索，以及二维码长提示消失；静态分析通过。截图位于 `/tmp/whisper-ui-revert-home.png`、`/tmp/whisper-ui-revert-conversation.png`、`/tmp/whisper-ui-revert-settings.png`、`/tmp/whisper-ui-revert-history.png`、`/tmp/whisper-ui-revert-qr.png`。回退后没有重新构建其他平台原生安装包。

回退后全量 `flutter test --no-pub --reporter expanded`：**1756 通过，3 跳过**，约 6 分 23 秒。最终日志：`/tmp/whisper-ui-revert-analyze.log`、`/tmp/whisper-ui-revert-all-tests.log`、`/tmp/whisper-ui-revert-android-build.log`。

## 按最新反馈单独打磨历史搜索页

修改集中在 `lib/page/transfer_assistant.dart`，首页、设备列表、设置层级和手机控制页保持回退后的结构。中、英、西文案同步调整，生成的本地化文件由 `flutter gen-l10n` 更新。

- 搜索框固定在顶部，最近消息使用单一紧凑列表；收藏改为筛选按钮，不再重复展示两个分组与空卡片。
- 按最新反馈取消消息详情弹层。短消息在条目内完整展示并可选择文字；长消息原地展开、收起，保留换行与关键词高亮。
- 时间/收发方向、复制和收藏直接放在条目下方。复制始终取原始全文，收藏失败回滚状态并提示重试。
- 复用 `AppTheme` / `WhisperPalette`，统一返回图标、圆角与间距，操作按钮使用 48dp 触摸范围，展开动画尊重减少动画设置。
- 数据库结构、网络协议、CI、签名资产和依赖锁文件均未修改。

使用 Flutter 3.44.9，页面与数据库相关测试 19 项通过，覆盖直接收藏/取消、短文本选择、长文本原地展开与收起、精确复制、关键词定位、失败重试、三语言、深浅主题、320dp 小屏、横屏、大字号、减少动画和键盘遮挡。多条模拟消息的折叠与展开状态已渲染检查，样例只存在于临时内存数据库；临时预览脚本已删除。本轮没有重复全量测试或其他平台原生构建。

本次日志：`/tmp/whisper-history-inline-tests.log`、`/tmp/whisper-history-inline-analyze.log`、`/tmp/whisper-history-inline-build.log`；预览截图：`/tmp/whisper-history-inline-collapsed.png`、`/tmp/whisper-history-inline-expanded.png`。此前 `/tmp/whisper-history-ui-*` 的详情弹层截图代表上一轮方案，不代表当前界面。

当前条目内展示版本的 `flutter analyze --no-pub` 与 Android arm64 debug 构建通过，已通过 `adb install -r` 覆盖安装到 MI 6。短/长消息的视觉验收使用临时内存样例渲染完成；此轮未再次操作手机上的真实消息。

### 搜索页图标与动效打磨

复制、收藏与收藏筛选统一改为 Material 圆角图标。收藏的轮廓/填充与复制成功对勾采用 180ms 淡入和轻微缩放；展开箭头使用同速旋转，与原地展开正文同步。保持 48dp 点击范围，支持减少动画设置。

修正输入查询或切换收藏时列表先清空的问题：新结果返回前保留上一批结果及其高亮，用轻微减淡与顶部进度条表示等待，新旧结果短暂交替显示。等待中的内容与退出过渡中的旧结果禁止指针、键盘焦点和无障碍操作；保留请求代次检查，迟到的搜索结果不会覆盖新查询。

相关测试现为 22 项通过，新增覆盖等待时保留内容、过渡中的旧按钮不触发动作、快速查询乱序回复，以及减少动画下的收藏/复制反馈。`flutter analyze --no-pub` 无问题，Android arm64 debug 构建通过。检查了浅色/深色、收藏/复制成功、展开和筛选过渡的渲染中间帧；使用临时内存样例，预览脚本已清理。本轮未重跑全量测试。

证据：`/tmp/whisper-history-motion-tests.log`、`/tmp/whisper-history-motion-analyze.log`、`/tmp/whisper-history-motion-build.log`、`/tmp/whisper-history-motion-*.png`。

## 全应用轻量动效

在 `66ece62` 提交保存前一轮搜索、连接提示和历史分页改动后，按用户确认的六处范围补充动效，保持现有布局、设备列表密度和操作入口：

- 发送区的附件、发送、等待状态采用短暂淡入淡出与轻微缩放；草稿和输入焦点保留，旧操作退出时立即失效。
- 普通文件消息的进度环、校验、失败和文件图标使用固定 40dp 区域，状态切换平滑过渡；百分比更新沿用原有平滑进度，不逐次切换文字。
- 多选框横向展开，底部多选栏与输入区同步收放。展开组件只保留一份内容，快速反向切换不重复创建输入框或复用同一焦点节点的两个实例。
- 设备列表状态圆点渐变、连接文字与会话连接图标淡入淡出，保持行高。
- 手机左右键和滚轮按下立即高亮，松开 120ms 淡回；开始/停止和控制状态同步过渡。鼠标事件发送与动画完全独立。
- 桌面粘贴图片和文件的预览区域平滑展开、移除后收起，输入区域持续保留。

共享过渡位于 `lib/widget/subtle_motion.dart`：常规时长 180ms、进入 easeOutCubic / 退出 easeInCubic；遵循系统减少动画设置。退出内容的指针、键盘焦点和无障碍操作立即停用。新增行为测试覆盖旧操作失效、快速反转时草稿与焦点安全、减少动画下的图标尺寸，以及鼠标按下/抬起/取消不等待动画。

相关组件测试 76 项通过。使用临时样例渲染了发送按钮、附件、多选和手机控制器的浅色/深色及中间帧，样例不写入真实数据库，临时预览测试已移除。截图位于 `/tmp/whisper-app-motion-*.png`。没有更改协议、原生输入后端、依赖、dev CI 或签名资产。

最终验证使用 Flutter 3.44.9：

- `flutter analyze --no-pub` 通过，无问题。
- 完整 `flutter test --no-pub --reporter expanded`：**1777 通过、3 跳过**，约 7 分 8 秒。磁盘压力中断过的上一轮不计为完整验证。
- Android arm64 debug 构建通过，最终 APK 已 `adb install -r` 覆盖安装成功；手机处于锁屏状态，本轮未完成真实设备上的交互检查。
- macOS `./script/build_and_run.sh --verify` **未通过**：本机可用空间不足，在 Flutter framework / native library 的 `lipo` 打包阶段失败。使用与默认值一致的 `WHISPER_UPDATE_CHANNEL=preview` 绕过本机 Bash 3 对空数组的限制，没有更改脚本。清理了临时 SDK 中可重新下载的缓存以及 macOS 构建中间产物后仍不足以完成打包；原来已签名的桌面应用已重新启动，当前桌面实例仍为旧版。
- 本轮未执行 Windows、Linux 或 iOS 原生构建；共享 Dart 界面通过组件与全量测试，各平台安装包的实际交互仍需验证。

日志：`/tmp/whisper-app-motion-tests.log`、`/tmp/whisper-app-motion-all-tests.log`、`/tmp/whisper-app-motion-analyze.log`、`/tmp/whisper-app-motion-build.log`、`/tmp/whisper-app-motion-install.log`。macOS 构建日志仅保留在本机，未纳入仓库。

## 删除确认与连接入口整合

按最新反馈统一会话中的单条和多选删除：菜单只保留“删除”，确认弹窗默认不勾选“保留接收的文件”。只有接收的文件进入文件删除路径，发送源文件及传输助手里的本地源文件始终保留；这一限制同时在界面和文件删除函数中执行。文件已经不存在时仍可删除消息，其他删除错误保留消息与选择状态并显示失败提示。删除正在接收的文件前先取消对应传输。桌面 Esc 优先关闭确认弹窗，再按一次退出多选；删除执行期间不会提前退出。

连接弹窗整合“二维码 / 扫一扫 / IP、端口”，桌面仅显示二维码与地址两个标签。地址输入复用 `PeerEndpoint` 校验，切换标签保留草稿；扫码页面离开时销毁原生相机视图，忽略过期扫描，二维码仍携带并校验原有设备身份信息。本机暂时没有可用于二维码的局域网地址时，手动地址入口仍然可用。移动端二维码按钮移到原“＋”位置，桌面去掉“＋”并让搜索框增加对应宽度。二维码仅减少外层多余边距，保留识别所需白边；弹层沿用现有淡入、缩放与退出动效，标签切换遵循减少动态效果设置。

本轮主要涉及 `chat_message_list.dart`、`conversation.dart`、`message_deletion.dart`、`message_deletion_dialog.dart`、`pairing_qr.dart`、`manual_connection_dialog.dart`、`deviceList.dart` 和中英西本地化。保留上一轮尚未提交的细节动画修改，没有修改 dev CI、依赖锁文件或签名资产。

- Flutter 3.44.9：`flutter analyze --no-pub` 通过；全量 `flutter test --no-pub --reporter expanded` **1789 通过，3 跳过**。
- 新增行为覆盖默认删除/保留文件、源文件保护、取消、混合多选、缺失文件、错误提示、Esc 焦点及执行中状态；连接覆盖三种语言校验、软键盘、草稿保持、扫码原生视图销毁、二维码路由所有权。
- 组件预览检查窄屏、大字号和深浅主题。Android debug 构建通过，已覆盖安装到 MI 6 / Android 13，保留原有数据；手机仍锁屏，尚未完成这轮实机点击与扫码验收。
- 日志：`/tmp/whisper-delete-connect-analyze.log`、`/tmp/whisper-delete-connect-all-tests.log`、`/tmp/whisper-delete-connect-android-build.log`、`/tmp/whisper-delete-connect-install.log`；组件预览截图位于 `/tmp/whisper-qr-phone.png`、`/tmp/whisper-address-phone.png`、`/tmp/whisper-address-keyboard.png`、`/tmp/whisper-qr-small-dark.png`。
- macOS 本轮重新执行 `./script/build_and_run.sh --verify`，编译通过；随后系统钥匙串授权完成，签名校验及启动验证通过。日志：`/tmp/whisper-delete-connect-macos.log`。本轮未构建 Windows、Linux、iOS；这些平台的原生窗口交互仍需对应设备验证。


## 圆角与页面动效进一步调整

- `message_deletion_dialog.dart` 的保留文件选项改为圆形勾选框，删除默认值和文件保护规则不变。
- `pairing_qr.dart` 在宽桌面窗口固定左侧二维码，右侧切换本机信息与 IP/端口表单；窄窗口保持紧凑布局。分段标签使用胶囊形指示器、圆角裁切与按压/悬停状态，防止状态底色溢出四角。`manual_connection_dialog.dart` 将手机输入区适当下移，键盘弹出时平滑收起额外留白；表单草稿保留。
- `whisper_motion.dart` 与 `app_theme.dart` 统一 macOS/Windows/Linux 的页面过渡：底层工作区静止，新页面以短距离位移、轻微缩放回弹和淡入出现，返回时更快收回。页面子树使用重绘边界，过渡不逐帧重建页面内容。`glass_dialog.dart` 的公共弹窗使用相同的轻回弹节奏，位移/缩放与透明度分别使用曲线。开启减少动态效果时停止这些可见位移与缩放。iOS 原有侧滑返回保留。
- 验证：Flutter 3.44.9 全量测试 **1795 通过、3 跳过**；新增测试覆盖桌面三平台底层侧边栏位置不变、快速反向退出、减少动态效果、二维码切换时位置不变和表单草稿保留。最后调整退出曲线后，导航/公共弹窗的 9 项测试再次通过。
- Android debug 构建并覆盖安装成功。手机当时处于 `com.miui.screenshot` 系统截图编辑界面，没有代替用户退出编辑，因此本轮未完成手机的实际点击点验。已检查深浅主题的桌面左右分栏、手机输入区及圆形选项组件预览。
- macOS `./script/build_and_run.sh --verify` 通过，签名有效，新进程已启动。Windows、Linux、iOS 本轮未重新构建；桌面路由经过对应平台配置的组件测试，尚无真实帧耗时或高刷屏性能结论。
- 证据：`/tmp/whisper-round-motion-all-tests.log`、`/tmp/whisper-round-motion-navigation.log`、`/tmp/whisper-round-motion-macos.log`、`/tmp/whisper-round-motion-android.log`、`/tmp/whisper-round-motion-install.log`；截图 `/tmp/whisper-round-address-desktop-light.png`、`/tmp/whisper-round-address-desktop-dark.png`、`/tmp/whisper-round-address-phone-light.png`。

## 连接弹窗尺寸与按钮一致性

- `pairing_qr.dart` 的手机二维码改为按宽度布局：常见 360dp 屏幕由原先最多 176dp 放大到 280dp，保留扫码白边。二维码和 IP/端口页按当前内容收紧高度，底部仅保留正常内边距；切换使用淡入与高度过渡。表单保留挂载以保存草稿，隐藏页不接受焦点；扫码仍只在对应标签激活后创建原生视图。
- `manual_connection_dialog.dart` 保留手机输入区上方适当间距，取消随弹窗高度扩大的留白；由弹窗外层传入软键盘状态，避免 Dialog 移除 viewInsets 后无法收起额外间距。桌面复制连接信息和连接按钮统一为 48dp 最小高度与标准视觉密度。
- Flutter 3.44.9：连接相关 13 项测试及 `flutter analyze --no-pub` 通过；覆盖扫码释放、三语言校验、草稿保留、键盘提交、窄屏、大字号、内容高度与桌面二维码位置稳定。另检查了手机深浅主题、横屏与桌面组件预览，临时预览脚本已移除。
- Android arm64 debug 构建、覆盖安装成功；macOS `./script/build_and_run.sh --verify` 通过，签名有效且新进程已启动。手机当前锁屏，本轮未完成实机点击和扫码验收。此次没有重跑全量测试或 Windows、Linux、iOS 构建。
- 日志：`/tmp/whisper-qr-fit-focused.log`、`/tmp/whisper-qr-fit-analyze.log`、`/tmp/whisper-qr-fit-preview.log`、`/tmp/whisper-qr-fit-android.log`、`/tmp/whisper-qr-fit-install.log`、`/tmp/whisper-qr-fit-macos.log`。预览截图：`/tmp/whisper-qr-fit-phone-qr.png`、`/tmp/whisper-qr-fit-phone-address.png`、`/tmp/whisper-qr-fit-small-dark-qr.png`、`/tmp/whisper-qr-fit-desktop-qr.png`、`/tmp/whisper-qr-fit-desktop-address.png`。

## 二维码留白与桌面 Esc 焦点修复

- 按后续反馈将 `pairing_qr.dart` 的手机二维码最大尺寸从 280dp 调整到 240dp，增加上、下及信息区间距；底部仍随内容收紧。已检查深浅主题预览，窄屏与大字号测试通过。
- 核实上一轮本机确已于 22:34 启动新版。新增桌面右键多选回归，在 macOS/Windows/Linux 平台配置下均复现了焦点切到侧栏搜索框后 Esc 无效。`chat_message_list.dart` 现在仅在多选期间注册工作区级键盘处理，退出或销毁时移除；当前页面不在前台、有弹窗、或正在删除时不取消多选。移动端保留列表内的硬件键盘响应。
- `message_deletion_flow_test.dart` 覆盖右键菜单、输入区收起、搜索框焦点、弹窗和新页面优先响应、销毁清理；连接与消息组件相关 **32 项测试通过**，`flutter analyze --no-pub` 无问题。Android debug 已覆盖安装，macOS `--verify` 通过，并于 22:49 启动修复版（本次 PID 78985）。手机已打开更新后的连接弹窗；桌面 Esc 的本轮验证为组件测试，未代替用户操作真实消息。本次未重复全量测试及 Windows/Linux/iOS 原生构建。
- 证据：`/tmp/whisper-esc-before.log`、`/tmp/whisper-esc-qr-focused.log`、`/tmp/whisper-esc-qr-analyze.log`、`/tmp/whisper-esc-qr-android.log`、`/tmp/whisper-esc-qr-install.log`、`/tmp/whisper-esc-qr-macos.log`；二维码预览 `/tmp/whisper-qr-spacing-light.png`、`/tmp/whisper-qr-spacing-dark.png`，临时预览脚本已移除。

## 手机连接标签统一高度与手动连接提示

- `pairing_qr.dart` 的三个手机标签改为共用一个外框高度，根据屏幕宽度、字号与当前可用高度计算，切换标签期间保持尺寸和位置稳定。二维码保留 240dp 上限与留白，扫码区填满中间区域；软键盘及横竖屏变化仍可调整整体可用空间。
- `manual_connection_dialog.dart` 在固定内容区域内分配提示、输入区和底部连接按钮的间距；空间不足时滚动，表单校验和草稿保留。手机 IP/端口页增加简短提示：在对方 Whisper 首页查看地址与端口，两台设备需在同一局域网。中英西 ARB 与生成的本地化代码已同步。
- Flutter 3.44.9：连接相关 **15 项测试通过**，包含三个标签切换中间帧的外框一致性、320dp 大字号、横屏、相机释放、三语言校验与软键盘提交；`flutter analyze --no-pub` 无问题。检查了三语言、深浅主题的组件预览，临时预览脚本已移除。
- Android arm64 debug 构建、覆盖安装及启动成功。此次未重跑全量测试或桌面/iOS 原生构建；桌面分栏与按钮尺寸的组件回归通过。
- 日志：`/tmp/whisper-qr-stable-focused.log`、`/tmp/whisper-qr-stable-analyze.log`、`/tmp/whisper-qr-stable-preview.log`、`/tmp/whisper-qr-stable-android.log`、`/tmp/whisper-qr-stable-install.log`；预览 `/tmp/whisper-qr-stable-phone-{qr,address,scan}.png`、`/tmp/whisper-qr-stable-small-dark-address.png`、`/tmp/whisper-qr-stable-spanish-address.png`。组件预览的扫码相机使用测试视图替身，不代表真实取景画面。

## 扫码边距、复制反馈与标签过渡

- `pairing_qr.dart` 的手机扫码取景区、IP/端口提示及表单统一与标签栏外缘对齐，收紧标题与内容间距。常见 360dp 屏幕的共用弹窗高度由 480dp 调整为 464dp；三个标签切换时保持同一外框，二维码仍保留 240dp 上限和留白。
- 复制连接信息不再显示 SnackBar，等待系统剪贴板写入成功后原位切换为圆角对勾，2 秒后恢复；失败使用错误图标和本地化提示，允许重试。处理中禁用重复点击，销毁页面时取消反馈计时器。手机与桌面复制按钮共用此反馈。
- 手机标签内容增加 240ms 先淡出、再轻移淡入的过渡，避免二维码透到表单文字下面。表单保留草稿，退出内容立即停用点击、焦点与无障碍操作；扫码相机仍只在当前标签激活时创建，离开后立即释放。减少动态效果设置下直接切换。
- Flutter 3.44.9：连接相关 **21 项测试通过**，`flutter analyze --no-pub` 无问题。覆盖复制成功确认、失败重试与销毁、快速反向切换、旧操作失效、统一外框和边缘对齐，以及原有相机释放、三语言校验和软键盘提交。检查了深浅主题及过渡中间帧的组件预览，临时预览脚本已移除。
- Android arm64 debug 构建、覆盖安装及启动成功；macOS `./script/build_and_run.sh --verify` 通过，签名有效，新进程已启动（本次 PID 83642）。本轮未重新执行全量测试或 Windows/Linux/iOS 原生构建，扫码画面与复制交互采用组件验证，未据此宣称真机交互验收完成。依赖锁文件、CI 和签名资产未修改。
- 证据：`/tmp/whisper-qr-polish-focused.log`、`/tmp/whisper-qr-polish-analyze.log`、`/tmp/whisper-qr-polish-preview.log`、`/tmp/whisper-qr-polish-android.log`、`/tmp/whisper-qr-polish-install.log`、`/tmp/whisper-qr-polish-macos.log`；预览 `/tmp/whisper-qr-polish-{light,dark}-{qr,copied,address,scan,transition}.png`。扫码组件预览使用测试视图替身。

## 历史搜索复制反馈统一

- `transfer_assistant.dart` 的搜索结果、最近消息及收藏列表复制操作去掉 SnackBar；系统剪贴板写入成功后，按钮以淡入和轻微缩放切换为绿色圆角对勾，2 秒后恢复。失败原位显示错误图标及本地化提示，允许重试；保留无障碍反馈和减少动态效果支持。
- 更新现有页面测试，覆盖等待写入确认、无 Toast、按钮尺寸稳定、失败重试、收藏列表与减少动画。Flutter 3.44.9：18 项页面测试及 `flutter analyze --no-pub` 通过，Android arm64 debug 已构建并覆盖安装，macOS `--verify` 的构建、签名与启动验证通过。本轮未重复全量测试或 Windows/Linux/iOS 原生构建，复制交互以组件测试验证。
- 日志：`/tmp/whisper-search-copy-tests.log`、`/tmp/whisper-search-copy-analyze.log`、`/tmp/whisper-search-copy-android.log`、`/tmp/whisper-search-copy-install.log`、`/tmp/whisper-search-copy-macos.log`。

收藏的选中颜色随后统一为主题主色，与顶部收藏筛选一致：浅色模式使用蓝色，深色模式使用浅蓝色。18 项页面测试、静态分析、Android debug 构建安装和 macOS `--verify` 再次通过，日志位于 `/tmp/whisper-favorite-color-*.log`。

## Windows 字体与小字号可读性（2026-10-09）

- 真机确认测试窗口为 1200×800、96 DPI（100% 缩放）。设置页原先在 Windows 取消标题字重，且中文依赖系统逐字回退；仅加粗后的系统字体仍有字形不协调的主观反馈，因此最终采用内置 Noto Sans SC 可变字体，统一中英文与标点，并使用真实的连续字重。
- `app_theme.dart` 为 Windows 全局指定该字体及缺字/emoji 的系统后备字体；其他平台保持原有系统字体。`settings.dart` 去掉页面内的 `SF Pro Display` 和 Windows 空字重特例，设置项为 16/600，说明为 13/400，分组标题为 13/600；统一行高，保留原来的列表宽度和布局。页面标题明确为 22/600，避免未合并字号的主题样式退回 14。
- `app_typography.dart` 在首帧前加载字体，`main.dart` 的主窗口及独立播放窗口共用此初始化；异常时记录错误类型并回退系统字体，不阻止启动。`pubspec.yaml` 使用平台资源过滤，仅 Windows 包含字体和 OFL 许可，运行时无需下载或安装系统字体。字体原始体积 17,772,300 字节，未做裁剪，当前中文 ARB 中的 524 个汉字全部覆盖；来源、固定提交和 SHA-256 记录在 `assets/fonts/README.md`。
- 在 `192.168.31.41` 的 `D:\dev\whisper` 使用 Flutter **3.44.9**：`flutter analyze --no-pub` 无问题，主题、字体加载/许可、设置、公共弹窗、连接、历史搜索和手机控制共 **112 项相关测试通过**；包含深浅主题、100%–200% 文字缩放、其他平台不加载 Windows 字体、手机小屏/横屏回归。Windows debug 构建成功，新进程已启动，实际截图检查了 100% 缩放下的设置页。调整测试中的滚动后等待，确保点击关于入口时它已进入视口。
- 使用 Flutter 3.44.9 的实际 `AssetBundle` 构建器核对 Windows、Android、macOS、Linux、iOS 五种目标：字体及许可只出现在 Windows 资源表中；Windows 成品包的字体 SHA-256 与仓库一致。`flutter build bundle --target-platform=android-arm64` 因该 Windows 测试机未安装 Android SDK 未完成，资源过滤验证由上述资源构建器单独完成，不能等同于 Android APK 验证。
- 本轮没有重新执行全量 Flutter 测试、Android APK、macOS `./script/build_and_run.sh --verify`、Linux/iOS 原生构建，也没有修改 CI、依赖版本/锁文件或签名资产。Windows 构建仍输出既有 `super_native_extensions` 读取隐藏 AppData 目录的提示，但最终退出码为 0、生成可执行文件；本轮没有为此改动依赖缓存或插件。
- Windows 日志：`D:\dev\whisper-typography-{analyze,tests,build}.log`；实机截图：`/tmp/whisper-typography-noto-settings.png`。本轮深色及大字号验证来自组件测试，未将远程截图过程中的其他页面操作当作完整原生验收。

后续按用户要求删除本轮新增的 5 个测试用例及 `app_typography_test.dart` 文件，撤去仅供新用例使用的测试参数和断言；仅保留原有“关于”用例在滚动后等待进入视口的两行修正。Windows 上复验原有主题/设置测试 **29 项通过**，字体与界面实现保持不变。字体文件实际覆盖 30,890 个 Unicode 码位，并非仅包含界面上的 524 个汉字；现有中英西 ARB 文本全部覆盖。新增语言仍需检查对应文字系统与地区字形，缺字依赖系统后备字体，不能保证全部 Unicode 字符可用。按现有 NSIS 默认 zlib 方式，单独字体压缩实测 11,276,551 字节，预计安装包增量约 11 MB；安装后的字体占用 17,772,300 字节（约 16.95 MiB）。这不是发布安装包前后对比值，本轮未重新制作发布安装包。

### Windows 字体体积精简

- 按后续体积反馈，将全量字体替换为 `NotoSansSC-Compact.ttf`。仅限制 400–700 字重时，zlib 压缩体积仍为 10,588,157 字节，因此最终保留 100–900 连续字重，改为完整 GB2312 的 6,763 个汉字加上原字体全部 2,990 个非汉字码位，共 9,753 个字符。字符集不从当前界面文案提取；现有中英西文案全部覆盖。生僻字及许多繁体字需要系统回退，未来语言仍需检查字库与地区字形，不能保证与内置字体完全一致。
- 新字体为 **4,669,224 字节**（原 17,772,300）；单文件 zlib 压缩为 **2,974,995 字节**（原 11,276,551），减少约 **74%**。预计 Windows 安装包增量约 3 MB、安装后增量约 4.7 MB；这仍是字体压缩估算，没有制作发布安装包前后对照。Android、macOS、Linux、iOS 不包含该字体资产。
- `script/build_windows_font.py` 固定上游 SHA-256，以开发环境中的 `fonttools==4.61.1` 可重复生成；不增加应用依赖或运行时下载。来源、修改范围、许可、生成方法与成品 hash 更新在 `assets/fonts/README.md`。逐字比较了 9,753 个保留字符的轮廓、水平指标及可变字重数据，均与原文件一致。
- Windows 测试机使用 Flutter 3.44.9：原有主题/设置 **29 项测试通过**，`flutter analyze --no-pub` 通过，Windows debug 构建及启动成功（本次 PID 3552）。成品字体 hash 匹配，资源目录只含精简字体与许可，没有遗留全量字体；五平台 `AssetBundle` 核对再次确认仅 Windows 包含字体。未新增测试用例，未重跑全量测试及其他平台原生构建，未修改 CI、锁文件或签名资产。
