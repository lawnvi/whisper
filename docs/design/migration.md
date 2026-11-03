# 实现步骤

第 0 步做完了，第 1 步写完了代码、等真机验证（2026-11-02），现有界面还没有开始迁移。本文说明差距、顺序、每步怎么算做完、数据从哪来。规则在 [`DESIGN.md`](../../DESIGN.md)，界面规格在 [`surfaces.md`](surfaces.md)，可用的代码在 [`flutter.md`](flutter.md)。

**不动协议。** 下面所有内容都用现有的协调器和协议。要改协议的两件事（接收端发起声音、按设备调音量）没有设计进来，见 `decisions.md` 待定项 7。

## 现状基线（2026-11-02）

从 `lib/page` 和 `lib/widget` 数出来的。

| 项 | 现在 | 目标 |
|---|---|---|
| 颜色 token 体系 | 4 套（WhisperPalette、`FlowSpaceColors`、`FinderColors`、`IslandColors`） | 1 套 |
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

**结果（2026-11-02，已完成）：**

- 代码在 `lib/theme/whisper_ui.dart`、`lib/theme/whisper_device_art.dart`。`test/whisper_tokens_test.dart` 直接读 `DESIGN.md` 文件头核对 token。`AppTheme` 注册了 `WhisperColors`，旧界面没有用它。
- 旧界面的 golden 在 `test/goldens/old_ui/`，8 张，只在 macOS 上比较，别的系统文字渲染不同，自动跳过，所以 CI 不跑。改了要重新生成：`flutter test --update-goldens test/old_ui_golden_test.dart`。为了能渲染整页，加了只给测试用的入口：`DeviceListScreen.debugPreview`、`LocalDatabase.debugOverride`、`debugIsDesktopOverride`。
- 棘轮：`test/ui_design_ratchet_test.dart`，现状 589 处裸值，61 个文件。减少后用 `UPDATE_UI_RATCHET=1` 锁定。拆文件时手动把计数挪到基线的新文件上，总数不能增加。
- 读源码的测试：引用 `deviceList.dart` 的都改走 `test/support/source_reading.dart`，按方法名取方法体，不依赖文件布局。在副本里把 `deviceList.dart` 切成两半跑过，32 个文件 212 项全过。
- 改成真正行为测试的：设备合并、信任身份、快速发送目标、键鼠是否在进行、服务器只启动一次（逻辑抽到 `lib/state/device_list_rules.dart`），侧栏和手机列表的行为（`test/device_list_behavior_test.dart`）。**其余 32 个文件还是读源码**，它们测的多是 Android 服务、退出顺序、认证流程这些要真实平台或连接的东西，第 2 步之后随代码重写再改。

### 1 · 技术验证

这些决定质感能到什么程度，**先验证，别等到最后**：

- macOS：`NSVisualEffectView` 加透明 Flutter 窗口，侧栏能不能透出桌面，性能如何。
- Windows 11：**云母本身已经验证可行**（`flutter.md`「隐藏标题栏和云母」）。还要和 `window_manager` 一起跑：顺序、上边缘缩放、最大化、DPI 变化、贴靠布局。这台机器要先打开开发者模式才能构建带插件的 Windows 工程。
- Linux：`flutter.md` 里的改法没有编译过。GNOME 和 KDE 都要看：隐藏标题栏后的阴影、边缘缩放、圆角、`gtk-decoration-layout` 的三种写法。托盘菜单、没有 AppIndicator 时的退路。WSL 的 Ubuntu 能跑 WSLg，但缺 clang、cmake 这些构建依赖，真实桌面更可靠。
- Android：`BackdropFilter` 和分页切换的模糊（`ImageFiltered`）会不会掉帧。
- 托盘：`desktop_multi_window` 当面板窗口，和主引擎怎么通信（`surfaces.md`「托盘」风险表）。

**完成标准**：每项写明结果和决定，更新 `DESIGN.md`「平台」和 `decisions.md`。做不到透明窗口时退回实色 `sidebar-solid`，先告诉用户，让用户看效果再决定。

**结果（2026-11-02，还没有完成）：** 探针在 lib/new_ui/probe/，开关打开时代替首页，用示例数据按 `surfaces.md` 排版，第 2 步删除。跑在 Apple M4、macOS 27 上。性能和面板是屏幕锁定时测的；窗口的画面 2026-11-02 晚上解锁后实拍过。

| 项 | 结果 | 状态 |
|---|---|---|
| macOS 材质 | 实拍浅、深两种主题，桌面透过侧栏模糊出来，四角是圆的。`flutter-*.png` 只有 Flutter 这一层，侧栏 alpha 是 0，在看图软件里显示成黑色或白色，不能拿来判断材质 | 实拍过，等用户看 |
| macOS 工具栏点击 | AppKit 默认吞掉这一条的点击，实测修好，见 `flutter.md`「macOS」。用的是 App 自己发的合成事件，不是真鼠标 | 等真机 |
| macOS 拖动、双击、平铺、圆角 | 没有真鼠标，没测 | 等真机 |
| macOS 红绿灯 | 距边 16，距顶 19，直径 14，圆心距 23，比设计写的 12 大，是系统画的。实拍发现切主题时 AppKit 重排标题栏，红绿灯跑到距顶 -1，已修：监听标题栏的 frame。切 4 次主题、进出全屏后都是 19 | 已量 |
| macOS 性能 | 下表。显示器睡着，不含系统合成，帧的节奏也不能看 | 等真机 |
| Windows 云母 + `window_manager` | 代码写好，zig 和 mingw 编过。没有用 MSVC 编，没有运行。贴靠布局没有做 | 等真机 |
| Linux | 代码写好，对着 GTK 头文件查过语法，X11 分支没覆盖。没有编译和运行 | 等真机 |
| Android 模糊 | profile APK 编过，没有设备，没有运行 | 等真机 |
| 托盘面板（macOS） | 独立窗口和引擎可行。隐藏创建到能应答 1.4 到 1.9 秒（调试版），往返 p50 0.15 ms、p99 不到 0.7 ms，整份状态约 1 ms，显示 3 到 49 ms。面板的画面没看到 | 等真机 |
| 托盘面板（Windows） | 亚克力的通道写好了，没有运行。系统圆角固定 8，做不到设计的 24 | 等真机 |

**决定**：面板窗口启动时隐藏创建，不要点了才建，1.4 秒等不起。状态走 `WindowController.invokeMethod`，这个延迟不用再做缓存。

M4 上 Flutter 的耗时（profile，毫秒）：

| 阶段 | 帧数 | raster p50 | raster p99 | 超过 16 ms |
|---|---|---|---|---|
| 切分页，带模糊 | 526 | 2.9 | 10.8 | 0 |
| 切分页，不带模糊 | 523 | 2.9 | 7.7 | 3 |
| 第一次进分页（要建页面） | 128 | 2.8 | 81.9 | 14 |
| 玻璃下滚动 | 221 | 2.4 | 3.6 | 帧节奏受显示器睡眠影响，不算数 |

第一次进分页会卡一下（raster 最高 151 ms），要在真机上再看，可能要提前建好页面或预热。

**在真机上看：**

```bash
# macOS，解锁屏幕后。结果和实拍写到 /tmp/whisper-probe
mkdir -p /tmp/whisper-probe
WHISPER_NEW_UI=true WHISPER_DART_DEFINES=WHISPER_PROBE_AUTORUN=true \
  WHISPER_PROBE_OUT=/tmp/whisper-probe \
  env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy ./script/build_and_run.sh

# macOS，只是手动试
WHISPER_NEW_UI=true env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy ./script/build_and_run.sh

# macOS 性能。Xcode 27 下 flutter build macos --profile 过不了通用二进制检查，要这样编
echo 'use_precompiled_binaries: true' > cargokit_options.yaml
flutter build macos --profile --no-pub --config-only -t tool/perf/new_ui_perf.dart
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Profile \
  -destination "platform=macOS,arch=arm64" -derivedDataPath /tmp/whisper-dd \
  MACOSX_DEPLOYMENT_TARGET=12.0 ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build
rm cargokit_options.yaml
open -n --env WHISPER_PROBE_OUT=/tmp/whisper-probe /tmp/whisper-dd/Build/Products/Profile/whisper.app

# Windows 11，先确认开发者模式开着：start ms-settings:developers
flutter pub get
flutter run -d windows --dart-define=WHISPER_NEW_UI=true
flutter run --profile -d windows -t tool/perf/new_ui_perf.dart

# Linux，GNOME 和 KDE 各一次
flutter pub get
WHISPER_NEW_UI=1 flutter run -d linux --dart-define=WHISPER_NEW_UI=true
gsettings set org.gnome.desktop.wm.preferences button-layout 'close,minimize,maximize:'
gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:close'
gsettings set org.gnome.desktop.wm.preferences button-layout ':minimize,maximize,close'
gsettings reset org.gnome.desktop.wm.preferences button-layout

# Android，看输出里的 probe: 那几行，比 tabs 和 tabsNoBlur 的 over16ms
flutter run --profile -d <设备> -t tool/perf/new_ui_perf.dart
```

| 平台 | 要看什么 |
|---|---|
| macOS | 侧栏透出桌面，文字清楚；窗口四角是圆的，内容没有方角；拖动工具栏空白处能移动窗口，分页和按钮不会带着窗口走；双击空白最大化；红绿灯能点，绿灯悬停的平铺菜单和「窗口」菜单的移动项还在；上边缘能缩放；深色；左键托盘图标出现面板 |
| Windows | 侧栏是云母，失去焦点退成纯色；上边缘能缩放；最大化没有被裁掉一圈，按钮贴到屏幕右上角；在 100% 和 150% 的显示器之间拖动不糊；Win+Z 能出贴靠布局；Windows 10 上侧栏是实色；左键托盘出面板 |
| Linux | 隐藏标题栏后阴影还在，四边能缩放，四角是否方的（方的就用方角）；三种按钮布局实时跟着变；Breeze 下的阴影协调；输出里 trayHost 说有没有托盘 |
| Android | 切分页不掉帧，玻璃输入框下滚动不掉帧 |

探针 lib/new_ui/probe/、tool/perf/new_ui_perf.dart 当时只用来量性能，第 9 步删了。等 Android 和 Windows 的性能量完再和 `macos/Runner/WindowProbeHooks.swift` 一起删。

### 第 2 到 8 步的结果（2026-11-02，新界面仍在开关后面）

代码在 `lib/new_ui/`（`shell`、`settings`、`sound`、`input`、`share`、`apps`、`tray`），业务生命周期还在 `_DeviceListScreen`，通过 `ShellData`、`ShellActions` 接到外壳。`tool/preview/new_ui_shell.dart` 用示例数据跑真实外壳，不碰数据和密钥，可以放心在别的机器上跑。

| 平台 | 验证到哪 |
|---|---|
| macOS | 真实窗口实拍过外壳、对话、设备卡片、声音、键鼠、共享链接、设置、搜索、托盘面板、这台的文件、输入地址连接、这台面板，包括 720×480 最小窗口。创建链接、传输列表只有离屏渲染。真鼠标只由用户试过 |
| Windows | 预览入口（示例数据）上用真鼠标测过：窗口按钮的提示、最大化、还原、最小化、拖动、四条边缩放、双击工具栏、弹层打开时的窗口按钮、拖动后第一次点击。真实入口和预览入口 MSVC 编译通过，真实入口没有运行过（从 ssh 启动会丢密钥） |
| Linux | 只做了代码检查：`linux/my_application.cc` 用真实的 GTK 3 和 Flutter Linux 头文件过了语法检查（Homebrew 的 GTK 没有 X11 分支，X11 那几行没检查到）。没有编译成程序，没有运行，GNOME 和 KDE 的窗口按钮、托盘菜单都没见过 |
| Android | 见下面「平板和折叠屏的结果」。手机尺寸（合上的折叠屏）和两台模拟器之间的配对、对话、文件都真实跑过，手机真机没有 |
| iOS | 预览入口在 iPad 模拟器上跑过，状态栏和安全区正确。真实入口没有跑过，旋转、分屏没有试 |

没验证的：灵动岛请求的回答，流转动画，「拿回来」，声音和键鼠连真实电脑。

在 Windows 测出的问题值得记住：窗口按钮在导航器之上，那一层原本没有 `Overlay`，悬停就抛异常，发布版画成一块灰。macOS 不画这些按钮，单测也没有悬停，所以只有真鼠标才测得出。

打开开关跑全部测试时有一批旧测试失败：它们断言旧界面的键、文案和尺寸，或者装的是没有 `WhisperColors` 和本地化的主题。第 9 步删旧界面时一起处理，不是新界面的行为问题。

### 平板和折叠屏的结果（2026-11-03，同样在开关后面）

代码在 `lib/new_ui/shell/shell_touch.dart`，判断用 `WhisperLayout`（`lib/theme/whisper_ui.dart`），旋转用 `WhisperOrientation`（`lib/helper/orientation_policy.dart`）。usesSplitDeviceWorkspace 和 usesRetainedTabletWorkspace 第 9 步一起删了。

在安卓 35 的折叠屏模拟器（`pixel_fold`）和平板模拟器（`pixel_tablet`）上真实跑过，两台真实配对：

| 看了什么 | 结果 |
|---|---|
| 打开和合上，真实的 `emu fold`、`unfold` | 设备、分页、草稿都在，设备页和卡片互相变化 |
| 书本姿态，`emu posture 2` | 侧栏的边在折痕上 |
| 桌面姿态，旋转后半开 | 控制页折痕以上是设备，以下是触控板和按键，侧栏收起 |
| 高度不够，`wm size 2208x1400` | 按键到触控板右边 |
| 旋转 | 打开时能转，竖着侧栏 240 |
| 配对、发消息、键盘顶起输入框、文件浏览、文件访问请求、拷贝大文件、灵动岛 | 都走的真实协议，灵动岛在内容正中 |

后来加的（设备卡片悬浮滑出、灵动岛在窗口正中、灵动岛按 `IslandHome` 让位）也在模拟器上看过。桌面版只有几何测试，**还没有实拍**：当时显示器休眠，抓不到窗口。

模拟器测不了的：这个系统镜像**没有状态栏和导航栏**，安全区只在 iPad 模拟器和组件测试里看过；它还把铰链传感器写死成所有配置都有，所以模拟的平板也报成手机，平板的设备图只在预览入口和单元测试里看过。手感和真机上的折痕要在真机上试，华为的阔折叠和三折叠按 `decisions.md` 不算支持。

### 2 · 外壳和设备页

拆开 `lib/page/deviceList.dart`（4119 行）。建窗口外壳、侧栏（顶部是搜索、声音、键鼠）、左下角（连接新设备、共享链接、设置）。隐藏系统标题栏，放上 `WindowButtons`，定最小尺寸（`surfaces.md`「窗口外壳」）。**这一步三个桌面平台要一起做**，不是最后再适配。设备页用 `LiquidSegmented` + `WhisperTabView`，把现有页面嵌进三个分页：`SendMessageScreen`（已有 `embedded`）、`RemoteFilesPage`、`FlowSpacePage`（已有 `focusPeerId`）。此时分页内部还是旧样子。设备卡片替换 `ClientSettingsScreen`。

手机同时改成页面栈：_buildDeviceItemOld 换成新列表，连接设备页基于 `lib/page/pairing_qr.dart`，设备页和设置变成页面。共享链接从「文件」首页（lib/page/remote_files/files_phone.dart）移到设置。

平板和折叠屏**和手机同一步做**，不然手机的页面栈写死后要再拆一次（`surfaces.md`「平板和折叠屏」）：

- 所有骨架判断换成 `WhisperLayout`。删掉 usesSplitDeviceWorkspace 和 usesRetainedTabletWorkspace，安卓也要有侧栏，iPad 分屏时要变成页面栈。`isDesktop()` 只留给功能判断，不再决定骨架。
- 放开方向：`lib/main.dart` 启动时把安卓锁成竖屏，iOS 只在启动时判断一次；`android/app/src/main/AndroidManifest.xml` 里主界面写死了 `portrait`；窗口查看页（lib/page/window_stream/flow_switcher.dart、`lib/page/window_stream/flow_window_viewer_page.dart`）退出时锁回竖屏。都改成按当前窗口判断，折叠状态变化时重新判断。
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

共享元素动画。删除旧 token 和没接入的 lib/widget/device_workspace.dart。更新 `docs/user-guide.md`、`docs/user-guide_en.md` 和 README 截图。去掉开关。

### 第 9 步的结果（2026-11-03）

做了：去掉 `WHISPER_NEW_UI`，构建脚本和 Linux runner 里的判断一起去掉（Linux 一律用 header bar）。删了旧设备列表、三栏键鼠页、旧设置布局、旧手机文件页、旧应用切换器和设备架、旧二维码对话框、探针和钩子，以及 250 多条没人用的文案。Windows 和 macOS 的 `flutter build` 不用再传开关，发布包就是新界面。

没做，要用户决定：

- **旧 token 已删。** 所有颜色换成 Radix Colors 时一起删了（见「色彩」）；`FinderColors`、`FlowSpaceColors` 只是转接到 `WhisperColors`。
- **共享元素动画**没有做。
- **`docs/user-guide*.md` 和 README 的截图**还是旧界面。
- `lib/new_ui/` 现在是唯一的界面，名字没改，改名只是机械替换。

之后又删了五个本来就没有入口用到的非界面文件：connection_request_registry、guarded_auth_callback、connect_prompt_registry、discovery_observation_tracker、local_discovery_runtime。

测试：只测旧界面的删了，测真实逻辑的移到新界面上（通知转发的回滚和串行、设置加载只认最新一次、Windows 服务的确认流程、消息多选）。**不再有测试的：** 设置页下载更新的界面流程、设置行的读屏语义、手机旧文件页的行为（新文件页有自己的测试）。

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

- 旧界面当前版本的现状判断来自代码、文档和 5 月的截图，第 0 步的 golden 是测试环境渲染的，不是真实窗口。
- 原型是 HTML，只在无头 Chrome 里看过，没有在真实屏幕上看过。`flutter.md` 的组件编译和测试过，放进了第 1 步的探针，但没有放到真实页面里。
- 窗口材质：Windows 云母和窗口内玻璃在不带插件的 Flutter 工程里跑过（`windows-real-mica-light.jpg`）。其他见第 1 步的表，都还没有人看到过画面。质感很依赖这一项。
- GNOME 和 KDE 的外观只在原型里看过，**没有在真实的 Linux 桌面上看过**，原型用的字体也不是这两个桌面的默认字体。
- 拖动手感、弹簧参数要在 Flutter 里再调。
- 西班牙语长文案和 200% 文字在原型里没有试过。
- 平板和折叠屏在安卓模拟器和 iPad 模拟器上跑过，见上面「平板和折叠屏的结果」，**没有上过真机**。桌面姿态的手感要真机试。iOS 的真实入口没有跑过。
- 三类划分没有做过用户测试。
- `whisper-web/` 不在当前仓库里，产品站的配色没有核对。
