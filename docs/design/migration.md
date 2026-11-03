# 实现步骤

代码还没有开始迁移。本文说明差距、顺序、每步怎么算做完、数据从哪来。规则在 [`DESIGN.md`](../../DESIGN.md)，界面规格在 [`surfaces.md`](surfaces.md)，可用的代码在 [`flutter.md`](flutter.md)。

**不动协议。** 下面所有内容都用现有的协调器和协议。要改协议的两件事（接收端发起声音、按设备调音量）没有设计进来，见 `decisions.md` 待定项 7。

## 现状基线（2026-11-02）

从 `lib/page` 和 `lib/widget` 数出来的。

| 项 | 现在 | 目标 |
|---|---|---|
| 颜色 token 体系 | 4 套（`WhisperPalette`、`FlowSpaceColors`、`FinderColors`、`IslandColors`） | 1 套 |
| 字号 | 18 种 | 6 个角色 |
| 圆角 | 19 种 | 4 级加胶囊 |
| 动画时长 | 38 种 | 4 个弹簧 |
| 按钮类 | 17 个 | 1 个组件 |
| 宽度断点 | 9 个 | 2 个 |
| `showAppToast` 调用 | 82 处 | 只留瞬时结果 |
| Golden 测试 | 0 个 | 关键页面都有 |
| 直接读 UI 源码的测试文件 | 59 个（其中 54 处引用 `deviceList.dart`） | 改成行为测试 |

## 怎么过渡

**不要先换主题。** 2026-07-10 只换主题，当天就回退了。token 新旧并存，新界面用新 token，旧界面不动，直到它被重做。最后一步才删旧 token。

**新界面在开关后面开发**，比如 `--dart-define=WHISPER_NEW_UI=true`。外壳、对话、设置都做好，用户试过认可后再把默认值打开。这样中途的半成品不会发布，也可以随时对比新旧。

旧 token 删除时对应到：

| 新 token | 旧 token |
|---|---|
| `accent` | `colorScheme.primary` |
| `ink` | `colorScheme.onSurface` |
| `ink2` | `palette.textMuted` |
| `canvas` | `palette.surfaceCanvas` |
| `content` `group` | `colorScheme.surface` |
| `raised` | `palette.surfaceElevated` |
| `fill` | `palette.surfaceMuted` |
| `sep` | `palette.borderSubtle` |
| `bubble` | `palette.messageIncoming` |
| `accent` 白字（我发的消息） | `palette.messageOutgoing` |
| `ok` / `warn` / `bad` | `palette.trusted` / `warning` / `danger` |
| 并入 `accent` | `palette.connected` |
| 设备图和壁纸 | `FlowSpaceTokens.deviceHue()`（取消） |
| `WhisperSprings` | `WhisperMotion`、`FlowSpaceTokens.spring`、`SpringCurve` |
| `WhisperGlass` | `FlowGlass`、`glass_dialog`、`glass_bottom_sheet` |

## 步骤

**已完成：文档和原型。**

### 0 · 地基

1. 把 `flutter.md` 的代码放进 `lib/theme/`。
2. 给现有关键页面补 golden，至少：设备列表、对话、设置，手机和桌面各一张。
3. 把读源码的测试改成行为测试，优先改 `deviceList.dart` 相关的。不先做这步，拆文件时会大面积失败。
4. 加界面规范检查（见下）。
5. 做设备图：照原型 `art()` 的几何（`flutter.md`「设备图」）。这是质感的主要来源之一。

**完成标准**：外观完全没变，`flutter analyze` 和 `flutter test` 通过，新 token 有测试。

### 1 · 技术验证

这些决定质感能到什么程度，**先验证，别等到最后**：

- macOS：`NSVisualEffectView` 加透明 Flutter 窗口，侧栏能不能透出桌面，性能如何。
- Windows 11：**云母本身已经验证可行**（`flutter.md`「隐藏标题栏和云母」）。还要和 `window_manager` 一起跑：顺序、上边缘缩放、最大化、DPI 变化、贴靠布局。这台机器要先打开开发者模式才能构建带插件的 Windows 工程。
- Linux：`flutter.md` 里的改法没有编译过。GNOME 和 KDE 都要看：隐藏标题栏后的阴影、边缘缩放、圆角、`gtk-decoration-layout` 的三种写法。托盘菜单、没有 AppIndicator 时的退路。WSL 的 Ubuntu 能跑 WSLg，但缺 clang、cmake 这些构建依赖，真实桌面更可靠。
- Android：`BackdropFilter` 和分页切换的模糊（`ImageFiltered`）会不会掉帧。
- 托盘：`desktop_multi_window` 当面板窗口，和主引擎怎么通信（`surfaces.md`「托盘」风险表）。

**完成标准**：每项写明结果和决定，更新 `DESIGN.md`「平台」和 `decisions.md`。做不到透明窗口时退回实色 `sidebar-solid`，先告诉用户，让用户看效果再决定。

### 2 · 外壳和设备页

拆开 `lib/page/deviceList.dart`（4119 行）。建窗口外壳、侧栏（顶部是搜索、声音、键鼠）、左下角（连接新设备、共享链接、设置）。隐藏系统标题栏，放上 `WindowButtons`，定最小尺寸（`surfaces.md`「窗口外壳」）。**这一步三个桌面平台要一起做**，不是最后再适配。设备页用 `LiquidSegmented` + `WhisperTabView`，把现有页面嵌进三个分页：`SendMessageScreen`（已有 `embedded`）、`RemoteFilesPage`、`FlowSpacePage`（已有 `focusPeerId`）。此时分页内部还是旧样子。设备卡片替换 `ClientSettingsScreen`。

手机同时改成页面栈：`_buildDeviceItemOld` 换成新列表，连接设备页基于 `lib/page/pairing_qr.dart`，设备页和设置变成页面。共享链接从「文件」首页（`lib/page/remote_files/files_phone.dart`）移到设置。

平板和折叠屏**和手机同一步做**，不然手机的页面栈写死后要再拆一次（`surfaces.md`「平板和折叠屏」）：

- 所有骨架判断换成 `WhisperLayout`。删掉 `usesSplitDeviceWorkspace` 和 `usesRetainedTabletWorkspace`，安卓也要有侧栏，iPad 分屏时要变成页面栈。`isDesktop()` 只留给功能判断，不再决定骨架。
- 放开方向：`lib/main.dart` 启动时把安卓锁成竖屏，iOS 只在启动时判断一次；`android/app/src/main/AndroidManifest.xml` 里主界面写死了 `portrait`；窗口查看页（`lib/page/window_stream/flow_switcher.dart`、`lib/page/window_stream/flow_window_viewer_page.dart`）退出时锁回竖屏。都改成按当前窗口判断，折叠状态变化时重新判断。
- `detectLocalFormFactor`（`lib/helper/device_form_factor.dart`）按启动时的屏幕算，折叠屏打开着启动就报成平板，合上启动又是手机，别的设备上的图会变。可折叠的设备固定报手机：安卓查 `android.hardware.sensor.hinge_angle`。

**完成标准**：所有功能都能到达，一个不少。切分页、推页面的动效到位，长设备名不乱。在安卓折叠屏模拟器上连续折叠和展开，设备、分页、草稿都在。

### 3 · 对话

气泡、文件卡、输入框。修气泡宽度（`surfaces.md`「对话」的现状要修）。

### 4 · 设置

按 `surfaces.md`「设置」的表重组。逐项对照，一项不多一项不少。滑块用 `whisperSliderTheme`。

**到这里可以把新界面默认打开，请用户试用。**

### 5 · 时刻

`IslandHost` 接到桌面。流转送达、文件请求、投屏请求、配对请求接入。减少 toast：屏幕上看得出的不提示，进行中的走灵动岛。

### 6 · 声音和键鼠

声音页合并两个设置面板。键鼠页替换三栏工作区，复用吸附和路由逻辑。设备选取器。

### 7 · 文件、应用、共享链接

文件去线、操作胶囊、`FinderColors` 并入。应用页去掉设备架和光晕。共享链接页重做。

### 8 · 托盘

面板和剪贴板历史，Linux 是结构相同的菜单（`surfaces.md`「各平台的托盘」）。依赖第 1 步的验证、第 5 步的时刻数据、第 6 步的会话状态。

### 9 · 收尾

共享元素动画。删除旧 token 和没接入的 `lib/widget/device_workspace.dart`。更新 `docs/user-guide.md`、`docs/user-guide_en.md` 和 README 截图。去掉开关。

## 数据从哪来

多数是现成的，类名和方法都核对过，不是现成的列在表后面。

| 界面 | 用什么 |
|---|---|
| 设备列表 | `ChatSessionListBuilder`（`lib/state/chat_session_list.dart`）提供已连接、附近和历史，排序换成 `StableDeviceOrder` |
| 连接、配对 | `PairingQrDialog`（`lib/page/pairing_qr.dart`），扫码用 `qr_code_scanner_plus` |
| 对话 | `SendMessageScreen`、`ChatMessageList`、`ChatComposer`、`ScreenshotButton` |
| 文件 | `RemoteFilesPage`，协议在 `lib/remote_files/` |
| 挂载 | `lib/remote_files/mount/remote_mounts.dart`，只有桌面 |
| 应用 | `FlowSpacePage`、`lib/window_stream/window_stream_coordinator.dart` |
| 声音（来源） | `AudioGroupCoordinator.shared` 的 `startGroup`、`updateGroup`、`stopGroup`。候选来自 `WsSvrManager` 的 `connectedAudioGroupSinkDevices`，能力判断 `supportsAudioGroupSinkFor`。旧设备走 `AudioShareCoordinator.startSharingToConnectedPeer` |
| 声音（成员状态） | `AudioGroupSink` 的 `channelRole`、`lastError`，状态 `AudioGroupSinkState`。同步文案有现成 ARB：`audioGroupSyncCalibrating`、`audioGroupSyncGood`、`audioGroupSyncFair`、`audioGroupSyncUnstable`。行内的数字要新加一个键，见 `surfaces.md`「声音」 |
| 声音（接收端） | `AudioGroupCoordinator` 的 `pausePlaybackAsSink`、`requestRejoinAsSink`、`disconnectPlaybackAsSink`，灵动岛已有 `AudioIslandSource` |
| 键鼠 | `RemoteInputWorkspaceCoordinator` 的 `startControllerWorkspace`、`updateControllerWorkspaceRoutes`。状态 `RemoteInputWorkspaceSnapshot`（`status`、`activePeerId`、`targets`）；被控状态看 `RemoteInputCoordinator` 的 `state`，停止用 `stopSharing`。布局 `RemoteInputWorkspaceGraph`、`RemoteInputWorkspaceSnapper`、`RemoteInputWorkspaceMagnetizer`、`RemoteInputWorkspaceLayoutValidator` |
| 共享链接 | `ShareLinkStore.shared` 的 `create`、`setEnabled`、`remove`、`setServiceOn`、`retry`、`refreshAvailability`。数据 `ShareLink`、`ShareAvailability`。不依赖连接 |
| 灵动岛 | `IslandHost`、`IslandSource`、`IslandActivity` |
| 托盘 | `tray_manager`（`lib/page/deviceList.dart:528`），`DesktopQuickSendHotKeyController.captureClipboard` |
| 设置 | `SettingsScreen`，逐项见 `surfaces.md`「设置」 |
| 提示 | `showAppToast` |

**新做的**（现在没有）：剪贴板历史；托盘面板；桌面灵动岛的布局；语言选择的「跟随系统」；设备图；声音页的总开关（`stopGroup` 后保留选择，这是界面状态）；组播放增益实时生效；手机连接页默认二维码；屏幕不悬空的自动贴回；开启键鼠前按目标过滤（现在一台不合格就整体失败）；隐藏系统标题栏和窗口按钮；云母；最小窗口；读 GTK 的按钮布局；Linux 的托盘菜单；没有托盘时的退路；`RemoteFilesPage` 拆出不带外壳的内容组件；剪贴板历史的敏感内容判断。

## 文案

所有文案走 ARB（`lib/l10n/`），改完跑 `flutter gen-l10n`。能复用现有键就复用。新词的译法：

| 中文 | English | Español |
|---|---|---|
| 这台（设备） | This device | Este dispositivo |
| 声音 | Sound | Sonido |
| 键鼠 | Keyboard & mouse | Teclado y ratón |
| 放到 iMac | Play on iMac | Reproducir en iMac |
| 拿回来 | Bring back | Recuperar |
| 送到 iMac | Send to iMac | Enviar a iMac |
| 应用（分页） | Apps | Apps |
| iMac 可以 | iMac can | iMac puede |
| 在附近 | Nearby | Cerca |
| 最近的剪贴板 | Recent clipboard | Portapapeles reciente |

英语和西语比中文长，分段控件和行内控件要验证放得下。

## 防止再次走样

第 0 步加一个检查。仓库已经习惯用测试读源码，这是它最合适的用途：

- 扫 `lib/page` 和 `lib/widget`，统计裸 `Color(0x…)`、`fontSize:` 字面量、`Duration(milliseconds:)`、`BorderRadius.circular(数字)`。
- 把现状存成棘轮：**数量只能减少，不能增加**。
- 新增的文件数量必须是 0。
- 违反时报错信息直接指向 `DESIGN.md` 对应章节。

这个检查只防止走样，不保证好看。质感要靠人看截图，和 `reference/` 比较。

## 没有验证的

- 当前版本没有实际运行过。现状判断来自代码、文档和 5 月的截图。
- 原型是 HTML，只在 Windows 上的无头 Chrome 里看过，没有在真实屏幕上看过，也没有在 Flutter 里实现过。`flutter.md` 的组件编译和测试过，但没有放到真实页面里。
- 窗口材质：Windows 云母和窗口内玻璃在 Flutter 里跑过（`windows-real-mica-light.jpg`）。macOS 系统材质、Windows 的托盘面板、Linux 全部没有试过。质感很依赖这一项。
- GNOME 和 KDE 的外观只在原型里看过，**没有在真实的 Linux 桌面上看过**，原型用的字体也不是这两个桌面的默认字体。
- 拖动手感、弹簧参数要在 Flutter 里再调。
- 西班牙语长文案和 200% 文字在原型里没有试过。
- 平板和折叠屏只在原型里按估算的尺寸看过，**没有在任何真机或模拟器上跑过**。折痕和姿态只有 `WhisperLayout` 的单元测试，桌面姿态的手感要真机试。iOS 工程本身也没有验证过（`CLAUDE.md`）。
- 三类划分没有做过用户测试。
- `whisper-web/` 不在当前仓库里，产品站的配色没有核对。
