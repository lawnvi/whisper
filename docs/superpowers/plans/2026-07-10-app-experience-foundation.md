# Whisper App Experience Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Whisper Flutter App 收敛为安静、可靠、可访问的局域网工作台，并补齐空状态、响应式布局、确认反馈与视觉回归门禁。

**Architecture:** 保留 Material 3、现有页面路由、socket/coordinator 和蓝色品牌；新增小型纯 presentation 组件及纯分组/布局函数，业务副作用仍留在原 page。按主题基础、公共反馈、设备工作台、会话、设置、键鼠和最终 QA 分 8 个可独立审核的原子任务。设计依据: `docs/superpowers/specs/2026-07-10-app-experience-foundation-design.md`。

**Tech Stack:** Flutter/Dart、Material 3、`flutter_localizations`/ARB、`flutter_test`、Flutter golden tests；不新增第三方 UI 依赖。

## Global Constraints

- 产品定位固定为“安静、可靠的局域网工作台”，不做营销式 hero、大卡片、渐变、玻璃拟态或装饰性阴影。
- 保留 Material 3 与品牌蓝: Light `#2563EB`，Dark `#7CA7FF`；大面积表面使用 spec 中的中性色。
- 非圆形矩形圆角最大 `8.0`；仅头像、radio、圆形进度和明确圆形 action 可保持圆形。
- 所有交互目标最小 `44x44` logical px；设置行最小 `56px`。
- 使用系统字体，不指定 `SF Pro Display`、Inter 或打包新字体；letter spacing 为 0。
- 生产 UI 文案只来自 `AppLocalizations`；中文、英语、西班牙语 ARB key 必须等量且语义一致。
- 不改变 discovery、socket、传输、音频、remote-input 协议或坐标保存语义；不描述为端到端加密。
- 匿名 FTP 已由网络加固计划决定彻底删除；本计划不得保留 FTP 设置、文案或测试。若网络任务已先落地，Task 6 只做无残留验证，避免重复实现。
- 每个任务严格 TDD: 先提交前写失败测试并确认红灯，再做最小实现，focused tests + `flutter analyze` 通过后原子提交。
- 每条 commit 使用中文 Conventional Commit subject，不加句末标点。

## File Map

**新增基础组件**

- `lib/widget/app_interactive_tile.dart`: 统一 hit target、hover、focus、Enter/Space 与 semantics。
- `lib/widget/app_empty_state.dart`: 紧凑、无卡片外框的空/无结果状态。
- `lib/widget/device_workbench.dart`: 本机发现状态、核心 action、搜索和分组设备列表。
- `lib/widget/adaptive_device_shell.dart`: 只按约束切换单栏/双栏。
- `lib/widget/file_drop_feedback.dart`: 拖放 accepted/rejected overlay。
- `lib/state/chat_message_groups.dart`: 消息视觉组纯函数。
- `lib/remote_input/remote_input_workspace_presentation.dart`: 键鼠 workspace breakpoint 与键盘移动纯函数。

**主要修改点**

- `lib/theme/app_theme.dart`: `WhisperUi` 尺寸 token、Light/Dark palette 与全局组件主题。
- `lib/state/chat_session_list.dart`: connected/nearby/recent 分组纯函数。
- `lib/page/deviceList.dart`: 绑定真实发现/连接状态和 adaptive shell，删除重复 dialog/未用详情原型。
- `lib/page/conversation.dart`, `lib/widget/chat_composer.dart`, `lib/widget/chat_message_list.dart`: clipboard draft、拖放、消息密度和选择。
- `lib/widget/app_dialogs.dart`: Future 结果、destructive 语义、typed field 和 inline validation。
- `lib/page/settings.dart`, `lib/page/appList.dart`: 最大宽度、subtitle、显式操作、空搜索和可选择值。
- `lib/remote_input/remote_input_workspace_screen.dart`, `lib/remote_input/remote_input_layout_editor.dart`: 响应式 pane、focus、shortcuts 和 semantics。
- `lib/l10n/app_{zh,en,es}.arb`: 全部新文案；生成文件只通过 `flutter gen-l10n` 更新。

---

### Task 1: Theme Tokens And Accessible Interaction Primitive

**Files:**
- Modify: `lib/theme/app_theme.dart`
- Create: `lib/widget/app_interactive_tile.dart`
- Create: `test/app_theme_test.dart`
- Create: `test/app_interactive_tile_test.dart`
- Modify: `test/light_surface_source_test.dart`

**Interfaces:**
- Produces: `WhisperUi.radiusSmall/Medium/Large`, `minInteractiveSize`, `settingsMaxWidth`, `compactWindowBreakpoint`, `expandedWindowBreakpoint`。
- Produces: `AppInteractiveTile({semanticLabel, selected, enabled, onActivate, leading, title, subtitle, trailing})`；后续设备页与设置页只消费该组件，不复制 focus/keyboard 逻辑。

- [ ] **Step 1: 写失败测试**

在 `app_theme_test.dart` 断言 spec 的 12 个颜色 token、card/input/chip/list tile/dialog 的非圆形 radius 均 `<= 8`、`IconButtonTheme` minimum size 为 44、`textTheme` 未设置自定义 font family，并计算 Light/Dark 正文 >=4.5:1、焦点/非文本状态 >=3:1。Light `surface` 仍为白色。

在 `app_interactive_tile_test.dart` pump 一个 tile，断言实际尺寸高度至少 44、Semantics 含 label/button/enabled/selected，按 Enter 和 Space 各触发一次，disabled 时不触发且 focus ring 仍可辨识。

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/app_theme_test.dart test/app_interactive_tile_test.dart test/light_surface_source_test.dart`

Expected: FAIL，原因是 `WhisperUi`/`AppInteractiveTile` 不存在，现有 14-24px 主题圆角不满足断言。

- [ ] **Step 3: 实现主题与 primitive**

在 `app_theme.dart` 添加 spec 中的常量和精确颜色；把 card/input/chip/list tile/dialog/按钮 shape 收敛到 4/6/8；所有 button theme 使用 `minimumSize: Size(44, 44)`。移除视觉主导的青色 secondary、大阴影和字体覆盖。

`AppInteractiveTile` 使用 `Semantics` + `FocusableActionDetector` + `Actions/Shortcuts`，Enter/Space 映射到同一个 `ActivateIntent`；内部稳定 min height，hover/selected/focus 只改变背景或边框，不缩放。

- [ ] **Step 4: 运行 focused verification**

Run: `dart format lib/theme/app_theme.dart lib/widget/app_interactive_tile.dart test/app_theme_test.dart test/app_interactive_tile_test.dart && flutter test test/app_theme_test.dart test/app_interactive_tile_test.dart test/light_surface_source_test.dart && flutter analyze`

Expected: PASS；analyze 无告警。

- [ ] **Step 5: Commit**

```bash
git add lib/theme/app_theme.dart lib/widget/app_interactive_tile.dart test/app_theme_test.dart test/app_interactive_tile_test.dart test/light_surface_source_test.dart
git commit -m "style(theme): 收敛中性色与交互尺寸"
```

---

### Task 2: Localization, Empty States, And Validated Dialogs

**Files:**
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_es.arb`
- Regenerate: `lib/l10n/app_localizations*.dart`
- Create: `lib/widget/app_empty_state.dart`
- Modify: `lib/widget/app_dialogs.dart`
- Create: `test/app_experience_l10n_test.dart`
- Create: `test/app_empty_state_test.dart`
- Create: `test/app_dialogs_test.dart`

**Interfaces:**
- Produces: `AppEmptyState({icon, title, body, actionLabel, onAction})`。
- Produces: `InputDialogField` exact fields from the spec and `Future<List<String>?> showValidatedInputDialog(...)`。
- Produces: `Future<bool> confirmAction(..., bool isDestructive = false)`；旧 callback API 暂留 deprecated wrapper，到 Task 6 所有调用迁移后删除。

- [ ] **Step 1: 写失败测试**

`app_experience_l10n_test.dart` 用 `jsonDecode` 比较三套 ARB 的非 `@` key set 完全相等，并断言西语关键值不是对应英语值。至少钉住这些 key family: `empty*`、`sessionGroup*`、`localDiscovery*`、`workbenchAction*`、`clipboardPreview*`、`fileDrop*`、`validation*`、`settingsSection*`、`dangerousActions`、`remoteInputWorkspace*Panel`。

`app_dialogs_test.dart` 验证非法输入显示 inline error 且 dialog 不关闭；合法 Enter 返回 trim 后值；Escape 返回 null；destructive 确认为 danger，cancel 为中性且初始 focus 在 cancel。

`app_empty_state_test.dart` 验证无外层 `Card`、action 为 44px、title/body 合并为可读 semantics。

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/app_experience_l10n_test.dart test/app_empty_state_test.dart test/app_dialogs_test.dart`

Expected: FAIL，新 key、widget 和 dialog API 尚不存在。

- [ ] **Step 3: 补齐三语文案并生成代码**

新增本 spec 所需全部文案。西语示例必须使用自然翻译: `Dispositivos conectados`、`Disponibles cerca`、`Sin resultados`、`Vista previa del portapapeles`、`Suelta para enviar a {device}`、`Acciones peligrosas`，不得复制英语。数量使用 ICU plural，device/file/error 使用 placeholder。

Run: `flutter gen-l10n`

Expected: 生成的三套 localization class 含新 getter/method。

- [ ] **Step 4: 实现公共空状态与 dialog**

`AppEmptyState` 只用 icon/title/body/一个 action，不使用 Card。`showValidatedInputDialog` 在 stateful dialog 内拥有并 dispose controllers，validator 返回错误时保持打开；提交中禁用重复确认。`confirmAction` 返回 bool，cancel 中性，只有 `isDestructive` 改变确认色和语义。

- [ ] **Step 5: Verification And Commit**

Run: `dart format lib/widget/app_empty_state.dart lib/widget/app_dialogs.dart test/app_experience_l10n_test.dart test/app_empty_state_test.dart test/app_dialogs_test.dart && flutter test test/app_experience_l10n_test.dart test/app_empty_state_test.dart test/app_dialogs_test.dart && flutter analyze`

Expected: PASS。

```bash
git add lib/l10n lib/widget/app_empty_state.dart lib/widget/app_dialogs.dart test/app_experience_l10n_test.dart test/app_empty_state_test.dart test/app_dialogs_test.dart
git commit -m "feat(ui): 添加本地化空状态与校验对话框"
```

---

### Task 3: Grouped And Responsive Device Workbench

**Files:**
- Modify: `lib/state/chat_session_list.dart`
- Modify: `lib/state/connection_coordinator.dart`（只读取网络层 discovery permission/error/candidate presentation input）
- Create: `lib/widget/device_workbench.dart`
- Create: `lib/widget/adaptive_device_shell.dart`
- Modify: `lib/page/deviceList.dart`
- Modify: `test/chat_session_list_test.dart`
- Create: `test/device_workbench_test.dart`
- Create: `test/local_discovery_presentation_test.dart`
- Create: `test/adaptive_device_shell_test.dart`
- Delete: `lib/widget/device_workspace.dart`
- Delete: `lib/state/device_workspace_state.dart`
- Delete: `test/device_workspace_state_test.dart`

**Interfaces:**
- Produces: `enum ChatSessionSectionKind { connected, nearby, recent }`、`ChatSessionSection`、`ChatSessionListBuilder.group(List<ChatSessionItem>)`。
- Produces: `LocalDiscoveryPresentation` with `starting/active/stopped/unavailable/permissionDenied/permissionRestricted` phase；unknown `pkh` candidates 使用独立 `NearbyCandidatePresentation`，不要求先有 `DeviceData`。
- Consumes: Task 1 `WhisperUi`/`AppInteractiveTile`，Task 2 `AppEmptyState` 和 localized strings。

- [ ] **Step 1: 写失败测试**

扩展 `chat_session_list_test.dart`: connected/nearby/recent 必须互斥；组内保持最新时间优先；filter 后不返回空组。

`device_workbench_test.dart`: 验证 active discovery 显示本机名称、可选择 `host:port`、三个分组和未鉴权通用候选；无设备显示“手动连接”；有 query 无匹配显示“清除搜索”；action bar 宽时有 icon+label，窄时仍有非空 tooltip/semantics，暂时 unavailable 的 action 保留 disabled reason。`local_discovery_presentation_test.dart` 覆盖 starting/active/stopped/unavailable/denied/restricted、重试与网络错误映射。

`adaptive_device_shell_test.dart`: 720 宽为单栏且选中会话有返回动作，900/1280 为双栏，resize 后无 overflow。

- [ ] **Step 2: 运行红灯**

Run: `flutter test test/chat_session_list_test.dart test/device_workbench_test.dart test/adaptive_device_shell_test.dart`

Expected: FAIL，新分组和 widgets 不存在。

- [ ] **Step 3: 实现纯分组与 presentation widgets**

分组只依赖 `ChatSessionItem.isConnected/isNearby/lastTimestamp`。`DeviceWorkbenchPane` 渲染 `LocalDiscoveryStatus`、command bar、search、section header 和 session rows，不直接 import socket/database。所有 rows 使用 `AppInteractiveTile`，状态用文字+icon，搜索支持 clear、Escape 和 `Cmd/Ctrl+F`。

`AdaptiveDeviceShell` 使用 `LayoutBuilder`: `<760` 单栏，`760-1099` 左栏 288-312，`>=1100` 左栏 340。单栏会话 header 显式返回工作台。

- [ ] **Step 4: 接入真实页面并删除旧原型**

`DeviceListScreen` 把 `_isBroadcasting`、`_isDiscovering`、`socketManager.started`、网络 Task 8 的 permission/error/unknown-candidate 输入、本机 profile、现有 audio/remote-input callbacks 注入新 widget。移动端和桌面共用分组 presentation，保留移动端 push route。手动连接迁到 `showValidatedInputDialog`，host/port 无效时不调用 `_connectServer`；IPv6 只在网络层已使用 `PeerEndpoint`/结构化 `Uri` 后开放。

删除 `device_workspace.dart`、`device_workspace_state.dart` 和对应测试；同时删除未引用的 `DeviceDetailsScreen` 以及 `deviceList.dart` 底部三份重复 dialog，import `widget/app_dialogs.dart`。

- [ ] **Step 5: Verification And Commit**

Run: `dart format lib/state/chat_session_list.dart lib/state/connection_coordinator.dart lib/widget/device_workbench.dart lib/widget/adaptive_device_shell.dart lib/page/deviceList.dart test/chat_session_list_test.dart test/device_workbench_test.dart test/local_discovery_presentation_test.dart test/adaptive_device_shell_test.dart && flutter test test/chat_session_list_test.dart test/device_workbench_test.dart test/local_discovery_presentation_test.dart test/adaptive_device_shell_test.dart test/remote_input_workspace_ui_source_test.dart && flutter analyze`

Expected: PASS；`rg "device_workspace" lib test` 无命中；`rg "void showInputAlertDialog|void showConfirmationDialog" lib/page/deviceList.dart` 无命中。

```bash
git add lib/page/deviceList.dart lib/state/chat_session_list.dart lib/state/connection_coordinator.dart lib/widget/device_workbench.dart lib/widget/adaptive_device_shell.dart lib/widget/device_workspace.dart lib/state/device_workspace_state.dart test/chat_session_list_test.dart test/device_workbench_test.dart test/local_discovery_presentation_test.dart test/adaptive_device_shell_test.dart test/device_workspace_state_test.dart
git commit -m "feat(ui): 重建设备工作台与响应式会话布局"
```

---

### Task 4: Clipboard Confirmation And File Drop Feedback

**Files:**
- Modify: `lib/page/conversation.dart`
- Modify: `lib/widget/chat_composer.dart`
- Create: `lib/widget/file_drop_feedback.dart`
- Modify: `test/chat_composer_test.dart`
- Create: `test/file_drop_feedback_test.dart`
- Modify: `test/desktop_clipboard_image_test.dart`

**Interfaces:**
- `ChatComposer` adds one typed pending clipboard draft and `onPreviewClipboard/onSendClipboardDraft/onClearClipboardDraft`; removes immediate-send `onSendClipboard` after call-site migration。该流程只用于 composer 手动按钮，不改变显式开启的 watcher 自动同步。
- Produces: `enum FileDropFeedbackState { hidden, accepted, rejected }` and `FileDropFeedback` overlay。

- [ ] **Step 1: 写失败测试**

在 `chat_composer_test.dart` 增加: 点击 clipboard 只调用 preview callback，发送 callback 为 0；按 file -> image -> text 优先级生成 typed draft，任意类型可替换任意旧 draft；文本 draft 显示最多 3 行、字符数和 remove；点击发送/按 Enter 才发送；Escape 清空；创建/删除 draft 不清空 controller 普通文本；所有 utility/remove/send button 尺寸至少 44；自动同步开关路径不经过 draft。

`file_drop_feedback_test.dart` 验证 hidden 无 overlay，accepted/rejected 有对应 localized semantics；切换状态不改变 child size。

- [ ] **Step 2: 运行红灯**

Run: `flutter test test/chat_composer_test.dart test/file_drop_feedback_test.dart test/desktop_clipboard_image_test.dart`

Expected: FAIL，文本 clipboard 仍直接发送且无 drop feedback widget。

- [ ] **Step 3: 实现 clipboard draft**

在 `SendMessageScreen` 增加单一 typed clipboard draft。composer clipboard action 读取但不发送，统一按 file -> image -> text 探测；空/失败显示 Task 2 文案。composer 用同一 preview 区处理 text/image/files，跨类型新 draft 替换旧 draft，发送或 Enter 才走现有 `_sendText(..., isClipboard: true)`/file API，Escape/remove 只清 draft。托盘和 watcher 的显式自动同步保持现有行为。composer 外框收敛到 radius 8、无悬浮大阴影。

- [ ] **Step 4: 实现拖放状态**

`conversation.dart` 用 `Stack` + `FileDropFeedback` 包住现有内容；`onDragEntered/Exited/Done` 更新 accepted/rejected/hidden。断线或本机会话可在 enter 时显示拒绝；`desktop_drop` 的 enter event 没有文件列表，空 file list 只能在 done 时拒绝。有效 done 仍逐个调用现有 `sendFileTo`，finally 隐藏 overlay。

- [ ] **Step 5: Verification And Commit**

Run: `dart format lib/page/conversation.dart lib/widget/chat_composer.dart lib/widget/file_drop_feedback.dart test/chat_composer_test.dart test/file_drop_feedback_test.dart && flutter test test/chat_composer_test.dart test/file_drop_feedback_test.dart test/desktop_clipboard_image_test.dart test/desktop_clipboard_image_source_test.dart && flutter analyze`

Expected: PASS。

```bash
git add lib/page/conversation.dart lib/widget/chat_composer.dart lib/widget/file_drop_feedback.dart test/chat_composer_test.dart test/file_drop_feedback_test.dart test/desktop_clipboard_image_test.dart
git commit -m "feat(chat): 剪贴板发送增加预览确认与拖放反馈"
```

---

### Task 5: Quieter Message Groups And Native Text Selection

**Files:**
- Create: `lib/state/chat_message_groups.dart`
- Modify: `lib/widget/chat_message_list.dart`
- Modify: `lib/page/conversation.dart`
- Create: `test/chat_message_groups_test.dart`
- Modify: `test/chat_message_list_test.dart`
- Modify: `test/conversation_text_message_style_source_test.dart`

**Interfaces:**
- Produces: `ChatMessageGroup` and `groupChatMessages(List<MessageData>, {Duration threshold = const Duration(minutes: 5)})`。
- `ChatMessageList` consumes groups and owns only transient hovered/focused message id。

- [ ] **Step 1: 写失败测试**

纯函数测试覆盖同发送者 5 分钟内合组、发送者变化/超过阈值/文件边界拆组、reverse list 时间顺序不被改变。

widget tests 覆盖: 组内只有组尾常驻 timestamp；桌面 hover/focus 才出现 44px copy action；移动端不常驻 copy icon 但长按菜单仍可复制/删除；消息正文存在 `SelectableText` 且未提供空 `contextMenuBuilder`；空会话显示连接态对应 `AppEmptyState`。另用 fixture 覆盖 `AnimatedList` 实时插入同组、拆组、删除组尾、UUID 原位更新和分页边界追加时 group/index 数量一致。

- [ ] **Step 2: 运行红灯**

Run: `flutter test test/chat_message_groups_test.dart test/chat_message_list_test.dart test/conversation_text_message_style_source_test.dart`

Expected: FAIL，当前每条消息都显示时间和复制 icon，选择工具栏被清空。

- [ ] **Step 3: 实现消息分组与 transient actions**

将 `ChatMessageList` 改为 StatefulWidget，只保存 hover/focus id，不保存业务消息。metadata 使用 overlay/固定槽位，出现时不推动 bubble。移动端操作继续走 `ContextMenuRegion`。气泡/文件块 radius 8；桌面最大正文 640，移动端 82%。通知格式化后也走原生 `SelectableText`，删除自定义空选择 toolbar。

- [ ] **Step 4: Verification And Commit**

Run: `dart format lib/state/chat_message_groups.dart lib/widget/chat_message_list.dart lib/page/conversation.dart test/chat_message_groups_test.dart test/chat_message_list_test.dart && flutter test test/chat_message_groups_test.dart test/chat_message_list_test.dart test/conversation_text_message_style_source_test.dart test/outgoing_file_message_ui_source_test.dart && flutter analyze`

Expected: PASS。

```bash
git add lib/state/chat_message_groups.dart lib/widget/chat_message_list.dart lib/page/conversation.dart test/chat_message_groups_test.dart test/chat_message_list_test.dart test/conversation_text_message_style_source_test.dart
git commit -m "style(chat): 降低消息噪声并恢复原生文本选择"
```

---

### Task 6: Settings Structure, Explicit Actions, And App Search Empty State

**Files:**
- Modify: `lib/page/settings.dart`
- Modify: `lib/page/appList.dart`
- Modify: `lib/page/deviceList.dart`, `lib/page/conversation.dart`（迁移剩余 confirmation 调用）
- Modify: `lib/widget/app_dialogs.dart` (remove deprecated wrappers after final migration)
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_es.arb`
- Regenerate: `lib/l10n/app_localizations*.dart`
- Create: `test/settings_experience_test.dart`
- Create: `test/app_list_experience_test.dart`
- Modify: `test/settings_navigation_source_test.dart`
- Modify: `test/remote_input_localization_source_test.dart`

**Interfaces:**
- Consumes: `WhisperUi.settingsMaxWidth`, `AppInteractiveTile`, `AppEmptyState`, `showValidatedInputDialog`, `confirmAction`。
- No new business-state API；`LocalSetting`/`DesktopStartupManager` calls remain in page callbacks。

- [ ] **Step 1: 写失败测试**

通过可注入的 settings presentation/loaders 在 390/760/1440 宽和 text scale 2.0 pump，不初始化真实插件/数据库；断言 desktop content max width 760、section title+subtitle 同时可见、无 overflow、tile 可键盘激活、没有 `SF Pro Display`。验证 save directory 有“更改/打开”显式 action，路径为 `SelectableText`，删除设备位于危险操作分区且 destructive dialog 默认 focus cancel；源码与三套 ARB 均不存在 FTP 设置/key。

`app_list_experience_test.dart` 验证加载完成空列表和搜索无结果使用 `AppEmptyState`，clear search 可恢复列表，tile semantics 合并 app name/package/switch state。

- [ ] **Step 2: 运行红灯**

Run: `flutter test test/settings_experience_test.dart test/app_list_experience_test.dart test/settings_navigation_source_test.dart test/remote_input_localization_source_test.dart`

Expected: FAIL，subtitle 未渲染、长按操作仍存在、字体硬编码且无空结果。

- [ ] **Step 3: 重构设置 presentation**

用 `Align > ConstrainedBox(maxWidth: 760) > ListView` 组织设置。section header 显示 title/subtitle；setting/client tile 统一用 `AppInteractiveTile`，开关避免重复 semantics。彻底删除 FTP 服务、目录、端口的 UI state/import/callback 和 `ftpService` ARB key，不保留隐藏入口；保存目录用 44px menu/icon actions“更改”和“打开”。路径/地址用 `SelectableText`，长文本允许换行。

所有 nickname/server port 调用迁到 `showValidatedInputDialog`；nickname trim 后 1-64 scalar，host 接受 IPv4/IPv6/hostname/`.local`，port 为 1001-65535。`settings.dart`、`appList.dart`、`deviceList.dart`、`conversation.dart` 的所有确认迁到 `confirmAction`，只给不可逆删除设置 destructive。确认仓库无调用后再删除 `app_dialogs.dart` 中旧 callback wrappers。

- [ ] **Step 4: 清除硬编码并补 app list 空状态**

删除 `_settingsSectionText`、`Save directory`、`Version`、所有生产 UI 的 `AppLocalizations?... ?? '...'` fallback 中英文和 `SF Pro Display`；全部使用 Task 2 key。`AppListScreen` 使用可注入 app loader、localized search placeholder 和 empty/no-result state。执行 `rg "onLongPress|SF Pro Display|Save directory|Device & appearance|AppLocalizations[^;]*\?\?" lib/page lib/widget lib/remote_input`，预期无命中。

- [ ] **Step 5: Verification And Commit**

Run: `flutter gen-l10n && dart format lib/page/settings.dart lib/page/appList.dart lib/page/deviceList.dart lib/page/conversation.dart lib/widget/app_dialogs.dart test/settings_experience_test.dart test/app_list_experience_test.dart && flutter test test/settings_experience_test.dart test/app_list_experience_test.dart test/settings_navigation_source_test.dart test/remote_input_localization_source_test.dart test/notification_app_list_source_test.dart && flutter analyze`

Expected: PASS；三语 locale 分别 pump 时 section title/subtitle 正确。

```bash
git add lib/page/settings.dart lib/page/appList.dart lib/page/deviceList.dart lib/page/conversation.dart lib/widget/app_dialogs.dart lib/l10n/app_zh.arb lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/app_localizations.dart lib/l10n/app_localizations_zh.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_es.dart test/settings_experience_test.dart test/app_list_experience_test.dart test/settings_navigation_source_test.dart test/remote_input_localization_source_test.dart test/notification_app_list_source_test.dart
git commit -m "feat(settings): 优化设置分区与显式操作"
```

---

### Task 7: Responsive And Keyboard-Operable Remote Input Workspace

**Files:**
- Create: `lib/remote_input/remote_input_workspace_presentation.dart`
- Modify: `lib/remote_input/remote_input_workspace_screen.dart`
- Modify: `lib/remote_input/remote_input_layout_editor.dart`
- Create: `test/remote_input_workspace_presentation_test.dart`
- Create: `test/remote_input_workspace_accessibility_test.dart`
- Modify: `test/remote_input_workspace_ui_source_test.dart`

**Interfaces:**
- Produces: `enum RemoteInputWorkspacePaneLayout { compact, medium, expanded }` and `paneLayoutForWidth(double width)` with `<760`, `760-1099`, `>=1100` boundaries。
- Produces: `RemoteInputScreenRect moveRemoteLayoutByKey(..., required RemoteInputEdge direction, required bool coarse)`；step 为 10，coarse step 为 50。

- [ ] **Step 1: 写失败测试**

纯函数测试钉住三个 breakpoint 和四方向 10/50 unit movement，不改变 width/height。

widget/accessibility tests 在 700x600、900x700、1440x900 pump workspace presentation fixture，断言 compact 用 canvas + panel buttons，medium 用 device panel + canvas + inspector drawer，expanded 三栏；无 overflow。Semantics 断言屏幕块包含 name/resolution/local-or-remote/selected/conflict。发送方向键更新 layout，Shift+方向键 coarse move，Space toggle target，`Ctrl/Cmd+S` 保存 editor，Escape 关闭 panel/返回。

- [ ] **Step 2: 运行红灯**

Run: `flutter test test/remote_input_workspace_presentation_test.dart test/remote_input_workspace_accessibility_test.dart test/remote_input_workspace_ui_source_test.dart`

Expected: FAIL，当前固定 260 + canvas + 280 且 drag-only。

- [ ] **Step 3: 实现响应式 panes**

顶层 body 使用 `LayoutBuilder`。expanded 保留三栏但宽度 clamp；medium 隐藏详情栏并用 inspector drawer；compact 以 canvas 为主，通过 44px “设备/详情”按钮打开 bottom sheet。空目标和冲突使用 `AppEmptyState`/warning icon+文字，screen block radius 8 且无大阴影。

- [ ] **Step 4: 实现 focus、shortcuts 和 editor wrap**

设备 checkbox、屏幕块、toolbar、start/stop 建立显式 traversal order。远端 block 用 `FocusableActionDetector` 处理方向键/Shift；鼠标 drag 仍保留。layout editor 的四个贴边按钮有 selected semantics 和 44px hit，底部使用 `Wrap`/两行布局；`Ctrl/Cmd+S` 调现有 `_save`，Escape 关闭当前 surface。

- [ ] **Step 5: Verification And Commit**

Run: `dart format lib/remote_input/remote_input_workspace_presentation.dart lib/remote_input/remote_input_workspace_screen.dart lib/remote_input/remote_input_layout_editor.dart test/remote_input_workspace_presentation_test.dart test/remote_input_workspace_accessibility_test.dart && flutter test test/remote_input_workspace_presentation_test.dart test/remote_input_workspace_accessibility_test.dart test/remote_input_workspace_ui_source_test.dart test/remote_input_workspace_layout_test.dart test/remote_input_layout_test.dart && flutter analyze`

Expected: PASS；既有 topology/snap/save tests 不变。

```bash
git add lib/remote_input test/remote_input_workspace_presentation_test.dart test/remote_input_workspace_accessibility_test.dart test/remote_input_workspace_ui_source_test.dart
git commit -m "feat(remote-input): 键鼠工作区适配窄窗与键盘操作"
```

---

### Task 8: Cross-Screen Accessibility, Text Scale, Viewport, And Golden Gates

**Files:**
- Create: `test/app_experience_accessibility_test.dart`
- Create: `test/app_experience_viewport_test.dart`
- Create: `test/app_experience_golden_test.dart`
- Create: `test/goldens/app_experience/mobile_workbench_light.png`
- Create: `test/goldens/app_experience/desktop_chat_dark.png`
- Create: `test/goldens/app_experience/settings_medium_light.png`
- Create: `test/goldens/app_experience/remote_input_medium_dark.png`
- Modify: legacy source tests whose old 14/16/18/24/30px assumptions conflict with the approved spec; keep behavior assertions。

**Interfaces:**
- No production API；fixtures inject fixed localizations, times, devices and callbacks，不启动 socket/database/platform plugins。

- [ ] **Step 1: 写跨页面失败测试**

`app_experience_accessibility_test.dart` 枚举主工作台、composer、message actions、settings 和 remote-input 的所有可点击 button、`InkWell`、`GestureDetector`、switch、checkbox 与 menu，断言 tooltip/semantic label 非空且 render hit box >=44；Tab traversal 能到每个核心 action，连接/selected/toggled/disabled reason 可读；连接错误、拖放拒绝和表单错误是 `liveRegion`。设置 `disableAnimations=true` 时非必要显隐/面板动画立即稳定。

`app_experience_viewport_test.dart` 在 `320x568`、`390x844`、`760x600`、`1024x720`、`1440x900`，text scale 1.0/2.0 pump fixtures；每次 `expect(tester.takeException(), isNull)`，同时断言无水平滚动和关键 command 可达。

- [ ] **Step 2: 运行红灯并修最后遗漏**

Run: `flutter test test/app_experience_accessibility_test.dart test/app_experience_viewport_test.dart`

Expected: 首次可能 FAIL；只修测试指出的 hit target、tooltip、overflow、SelectableText 或 focus 漏洞，不做新的视觉方向改动。修复应落在各自 production 文件并加入本任务 commit。

- [ ] **Step 3: 生成并人工检查 golden**

Run: `flutter test test/app_experience_golden_test.dart --update-goldens`

Expected: 生成四个 spec 指定 viewport 的 PNG。逐张确认无重叠、裁切、空白 canvas、错误语言、过度圆角或大阴影；不接受只为让测试通过而更新明显错误的基线。

- [ ] **Step 4: 全量验证**

Run: `flutter gen-l10n && dart format --output=none --set-exit-if-changed lib test && flutter analyze && flutter test`

Expected: 全部 PASS，analyze 无告警。

附加静态检查:

```bash
rg "BorderRadius\.circular\((1[0-9]|[2-9][0-9]|999)" lib/page lib/widget lib/remote_input lib/helper/toast.dart
rg "SF Pro Display|Device Name:|IP Address:|Save directory" lib/page lib/widget lib/remote_input
rg "FTP|ftpService|SimpleFtpServer" lib/page lib/widget lib/l10n lib/helper lib/global.dart
rg "AppLocalizations[^;]*\?\?" lib/page lib/widget lib/remote_input
rg "device_workspace" lib test
```

Expected: 五条均无命中。若第一条命中语义圆形控件，改为 `CircleBorder`/`BoxShape.circle`，不得用大 radius 绕过门禁。FTP 的 source test 可以包含断言字面量，因此静态 gate 只扫生产代码。

- [ ] **Step 5: Commit**

```bash
git add test/app_experience_accessibility_test.dart test/app_experience_viewport_test.dart test/app_experience_golden_test.dart test/goldens/app_experience/mobile_workbench_light.png test/goldens/app_experience/desktop_chat_dark.png test/goldens/app_experience/settings_medium_light.png test/goldens/app_experience/remote_input_medium_dark.png
# 再逐文件加入本任务实际修复的 production/legacy test 文件，先用 git diff --cached 核对，不使用宽范围 git add
git commit -m "test(ui): 固化多视口无障碍与视觉基线"
```

## Completion Report

执行者最终必须汇报:

- 8 个 commit hash 与 subject。
- 用户可见变化，按设备工作台、会话、设置、键鼠工作区分组。
- `flutter analyze`、`flutter test`、golden 结果。
- 未能在本机实测的平台及残余风险；不得把未实测的 Android/Windows/Linux 原生行为描述为已验证。
