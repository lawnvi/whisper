# Whisper App Experience Foundation - Design

> 本文只定义 Flutter App 的体验基础与首轮界面整改。`whisper-web/` 下载站、网络协议、
> 发现/连接语义、文件传输协议、音频编码与键鼠控制协议不在本 spec 内。

## 背景

Whisper 已经具备局域网消息、文件、剪贴板、系统音频和键鼠共享等核心能力，但当前界面
更像多个功能持续叠加后的工程面板，尚未形成稳定的产品语言。审计发现的问题主要集中在:

1. 主题虽然使用 Material 3 和 `WhisperPalette`，但 14-30px 圆角、药丸形 chip、阴影、
   蓝/青状态色与零散灰色混用，视觉密度和层级不稳定。
2. 主设备页把会话、发现状态和功能入口混在一起。移动端没有空状态，桌面搜索无结果时
   只剩空白，连接/附近/历史设备没有明确分组，本机广播与发现状态也不够清楚。
3. 音频共享和键鼠工作区只藏在小图标里；文件、剪贴板与发送动作的语义也依赖用户猜测。
4. 桌面设备页和键鼠工作区使用固定栏宽，窄窗口容易拥挤；屏幕排列主要依赖鼠标拖动，
   键盘用户缺少可完成同一任务的路径。
5. 多处图标按钮或消息复制按钮小于 44 logical px；`GestureDetector` 形式的行没有统一的
   focus、keyboard、tooltip 和 semantics。
6. 文本剪贴板按钮会直接发送，文件/图片虽有预览但交互不统一；桌面拖入文件没有进入、
   可放置、拒绝或完成反馈。
7. 通用确认框把“取消”显示成红色，危险动作没有一致的 destructive 语义；端口、地址、
   昵称等表单失败时静默关闭或吞掉异常。
8. 每条消息总是显示时间和复制图标，形成噪声；可选择文本使用了空的选择工具栏，降低了
   原生复制体验。
9. 设置页没有桌面最大宽度，传入的分区 subtitle 没有渲染，打开保存目录依赖长按，且
   硬编码 `SF Pro Display`。西班牙语会回退到英语分区标题，仍有其他硬编码文案；匿名
   FTP 已由网络加固决策废弃，设置入口也必须随实现一起删除。
10. `lib/widget/device_workspace.dart` 与 `lib/state/device_workspace_state.dart` 是未接入生产
    导航的旧设备工作区原型，同时维护只会与现有会话工作台产生两套信息架构。
11. 缺少覆盖关键 viewport、200% text scale、semantics、focus traversal 和视觉基线的测试。

## 产品定位与成功标准

Whisper 的 App 定位为**安静、可靠的局域网工作台**。用户打开应用后应先看见“本机是否
可被发现、哪些设备可用、当前能做什么”，而不是营销式大标题或装饰性卡片。

本轮成功标准:

- 现有消息、文件、剪贴板、音频和键鼠能力保持原有协议行为，不新增中继或安全承诺。
- Light/Dark 主题在 Android、macOS、Linux、Windows 上使用同一组语义 token。
- 所有非圆形矩形控件圆角不超过 8px；保留圆形头像、单选标记和圆形进度等语义形状。
- 主设备页在无设备、搜索无结果、发现中、发现不可用、已连接、附近和历史状态下都有清楚
  的界面反馈。
- 所有核心能力都有可发现入口；暂时不可用时说明原因，而不是静默消失。
- 320px 宽移动 viewport、窄桌面窗口、常规桌面和宽桌面均无 overflow 或不可达操作。
- 所有可点击目标至少 44x44 logical px，键盘可以完成主导航、设置和键鼠屏幕排列。
- 新增及整改文案在中文、英语、西班牙语三套 ARB 中含义一致，无生产 UI 硬编码回退。
- 关键页面有 golden、semantics、text scale 和 viewport 回归测试。

## 已选方案

采用“**主题 token + 可复用基础组件 + 按工作流渐进替换**”方案。

- 不采用只换颜色和圆角的表层修补。它不能解决空状态、入口、验证和无障碍问题。
- 不采用重写导航或引入全新设计系统。现有 Material 3、页面路由和状态协调器可以保留，
  全面重写会扩大协议与平台回归面。
- 不引入 UI 组件依赖。使用 Flutter Material/Cupertino 自带能力、现有图标和现有状态源。

该方案让每个整改任务都能独立测试、审核和提交，同时避免形成第二套产品架构。

## 视觉系统

### 色彩

保留现有蓝色品牌信号，但蓝色只用于主操作、选中、focus 和连接强调；大面积背景使用不偏
蓝的中性色。连接、信任、警告和危险必须是独立语义，不用同一个蓝色替代所有状态。

| Token | Light | Dark | 用途 |
|---|---:|---:|---|
| `primary` | `#2563EB` | `#7CA7FF` | 主操作、选中、focus、链接 |
| `surface` | `#FFFFFF` | `#111318` | 页面与主要内容面 |
| `surfaceCanvas` | `#F6F7F9` | `#0B0D10` | 桌面工作区背景 |
| `surfaceMuted` | `#EEF0F3` | `#1D2127` | 输入、悬停、弱选中 |
| `surfaceElevated` | `#FFFFFF` | `#171A20` | 菜单、对话框、侧栏 |
| `borderSubtle` | `#DDE1E6` | `#303640` | 1px 分隔与边框 |
| `onSurface` | `#171A1F` | `#F2F4F7` | 主要文本 |
| `textMuted` | `#5F6875` | `#A1A9B5` | 次要文本，仍满足可读对比度 |
| `connected` | `#1D6FD8` | `#77A9FF` | 已连接 |
| `trusted` | `#18864B` | `#56C987` | 已信任/成功 |
| `warning` | `#B96A05` | `#F2B45F` | 等待/不稳定 |
| `danger` | `#C93838` | `#FF8A8A` | 删除/错误 |

禁止渐变、彩色光斑、玻璃拟态和装饰性大阴影。普通卡片 elevation 为 0；仅菜单、对话框等
真实浮层使用 Material elevation。状态不能只靠颜色，必须同时有图标或文字。

### 形状、间距与尺寸

在 `app_theme.dart` 中建立单一尺寸源，生产组件不得继续散落魔法数:

```dart
abstract final class WhisperUi {
  static const radiusSmall = 4.0;
  static const radiusMedium = 6.0;
  static const radiusLarge = 8.0;
  static const minInteractiveSize = 44.0;
  static const settingsMaxWidth = 760.0;
  static const compactWindowBreakpoint = 760.0;
  static const expandedWindowBreakpoint = 1100.0;
}
```

- 非圆形矩形最大 8px: 输入框 8、卡片 8、列表选中面 6、chip 6、composer 8。
- 圆形只用于头像、radio、圆形进度与明确的圆形 icon action。
- 间距使用 4/8/12/16/24/32 序列。
- 触控和鼠标点击区域最小 44x44；桌面图标可为 18-20px，但命中盒仍为 44px。
- 列表行最小 52px，设置开关行最小 56px，避免 hover/focus/文案变化引发布局位移。

### 字体与动效

- 使用平台系统字体，不指定 `SF Pro Display`、Inter 或其他外部字体，不增加字体资源。
- 文字层级复用 Material 3 `TextTheme`。紧凑面板使用 `titleSmall/titleMedium`，不使用 hero
  尺寸标题；letter spacing 保持 0。
- 尊重系统 text scale，至少验证 2.0；不按 viewport 宽度缩放字号。
- 动画只用于 120-200ms 的颜色、显隐和面板切换；系统 reduced motion 时直接切换。

## 组件与边界

### 基础组件

新增少量有明确责任的 presentation 组件:

- `AppEmptyState`: 无卡片外框的紧凑空状态，支持 icon、title、body 和最多一个主操作。
- `AppInteractiveTile`: 统一 44px 命中、hover、focus、Enter/Space 激活、semantics 和可选 trailing。
- `DeviceWorkbenchPane`: 只渲染本机状态、核心动作、分组会话、搜索和空状态；连接行为仍由
  `DeviceListScreen` 注入回调。
- `AdaptiveDeviceShell`: 只根据约束选择单栏或双栏，不读取 socket/database。
- `ValidatedInputDialog`: 管理 controller、validator、inline error 和确认结果；业务页提供规则。

不创建“大而全”的设计组件库。只有两个以上页面实际复用或明显需要隔离测试的行为才进入
公共组件。

### 状态边界

- `ChatSessionListBuilder` 继续负责纯数据排序/过滤，并新增纯函数分组结果。UI 不重复判断
  connected/nearby/history。
- 本机广播、发现和 server 状态由 `DeviceListScreen` 将现有布尔值与网络层新增的 permission/error
  phase 映射为明确 presentation；UI 不自行启动 discovery。unknown/denied/restricted、启动失败、
  stopped 与 active 必须可区分并能重试。
- 网络层以 `pkh` 暴露的未鉴权附近候选作为独立 presentation input，不能先伪造成持久
  `DeviceData`；完成签名配对后才并入真实会话。
- clipboard draft 只存在于 `SendMessageScreen` 内存中；确认前不写数据库、不发 socket。
- 键鼠布局仍由现有 `RemoteInputLayoutData` 和 coordinator 保存；响应式 UI 不改变坐标语义。

## 主设备工作台

### 本机状态

设备列表顶部增加一条紧凑、本身不浮起的 `LocalDiscoveryStatus`:

- 第一行: 本机名称、平台图标、服务状态文本。
- 第二行: `host:port` 使用 `SelectableText`，旁边显示“正在广播并发现”“正在启动”“发现
  不可用”或“服务已停止”。
- 发现中使用小型 progress，不用无限占位骨架。
- 失败/停止状态提供一个“重试”操作；稳定运行状态不显示多余按钮。

这条状态明确表示“本机可见性”，不把未实现的端到端加密描述成安全或加密。

### 会话分组与搜索

会话只分为三个稳定、互斥的组:

1. `connected`: 当前已连接，按最近消息时间排序。
2. `nearby`: 当前局域网发现但未连接，按最近消息时间排序。
3. `recent`: 不在附近但保留历史的设备，按最近消息时间排序。

每组用小标题、数量和 1px 分隔组织，不包在大卡片里。设备行显示名称、平台、状态文本、
最新消息/能力提示和时间；状态点必须附带可读文本或 semantics。

- 初始没有任何设备: `AppEmptyState` 显示附近设备图标、简短说明和“手动连接”。
- 搜索有输入但无匹配: 显示“没有匹配的设备”，操作是“清除搜索”。
- 过滤结果仍保留组标题，但空组不渲染。
- 搜索框有 label、clear action、Escape 清空/收起、`Cmd/Ctrl+F` 聚焦。

### 核心功能入口

工作台顶部提供紧凑 command bar，按平台能力显示:

- 手动连接
- 扬声器/系统音频共享
- 键鼠工作区
- 设置

桌面宽度足够时使用 icon + 短标签；侧栏较窄时保留 44px icon button 和 tooltip。结构上
不支持的平台隐藏对应能力；因“未连接、未互信、正在启动”而暂不可用的能力保留入口并在
tooltip/semantics 中说明原因。消息、文件和剪贴板入口留在会话 composer，不重复放到全局。

### 响应式壳

- `<760px`: 单面板。没有选中设备时显示工作台；选中后显示会话，header 提供返回工作台。
- `760-1099px`: 双栏，左栏 288-312px，右侧会话自适应。
- `>=1100px`: 双栏，左栏 340px，右侧限制消息内容行宽但背景铺满。
- 移动端继续使用现有 push route；AppBar 与列表使用同一状态和分组组件。

窗口缩放不能截掉 action、搜索框或 composer，也不能依赖设置最小窗口尺寸来掩盖 overflow。

## 会话与传输体验

### 空会话与消息密度

- 没有消息时显示轻量空状态，根据连接状态显示“可以发送消息或文件”或“连接后即可发送”。
- 相邻同发送者且间隔不超过 5 分钟的消息形成视觉组。组内间距 4px，组间 12px。
- 时间只在组尾、hover/focus 或用户显式打开操作时显示；复制 icon 只在 hover/focus 显示。
  移动端通过长按菜单访问复制/删除，不常驻小图标。
- 桌面复制按钮的视觉图标可以小，但命中盒为 44px；出现时不挤动消息宽度。
- 消息正文始终是原生 `SelectableText`，保留系统选择工具栏。通知消息也先格式化再选择。
- `host:port`、保存路径、文件路径和设备详情等用户可能复制的值使用 `SelectableText`。
- 气泡与文件块圆角 8px，桌面正文最大宽度 640px，移动端最大 82% 可用宽度。

### Composer 与剪贴板确认

composer 是固定格式工具面，不使用 30px 药丸或悬浮大阴影:

- 8px 圆角、1px 边框、稳定 padding；输入、附件、剪贴板、发送动作不改变外框尺寸。
- 附件、剪贴板、移除预览和发送都有 tooltip、semantic label、disabled reason 和 44px 命中。
- `Enter` 发送，`Shift+Enter` 换行；保持 macOS/Windows/Linux 的粘贴快捷键。

点击 composer 中“剪贴板”按钮后的统一流程（只改变手动发送；已由用户显式开启的自动剪贴板
同步和托盘动作保持各自现有设置语义，不被本 draft 流程偷偷改写）:

1. 读取剪贴板，不发送；按 file -> image -> text 的优先级统一探测。
2. 文本显示可选择的 3 行预览、字符数和“移除”；图片显示缩略图、文件名、大小；文件显示
   首个文件名、总数和总大小。
3. 用户点击发送或按 Enter 后才发出；Escape 或移除只清空 draft。
4. 任意类型的新 draft 替换任意旧 draft，但不会清空用户已输入的普通文本。
5. 空剪贴板或读取失败显示本地化 toast，不创建空 draft。

### 拖放反馈

桌面会话使用 `Stack` 包住原内容。有效文件进入时显示整面板 2px primary 边框、上传图标和
“松开发送到 {device}”；离开/完成立即消失。断线、本机会话或无文件时显示明确的拒绝文案，
不静默吞掉。overlay 不改变布局、不能挡住 drag exit，发送逻辑仍走现有 file API。

## 设置与对话框

### 设置页

- 桌面内容居中并限制到 760px；移动端铺满并保留 12-16px 边距。
- 分区标题和传入的 subtitle 都渲染。标题为 `titleSmall`，subtitle 为 `bodySmall`，不使用
  大卡片标题。
- 分区是一个 8px 边框容器，行之间用 inset divider，不在卡片中嵌套卡片。
- 所有 setting tile 使用系统字体、最小 56px、显式 hover/focus/Enter/Space/semantics。
- 删除 FTP 服务、目录和端口的全部设置 UI，不以“高级选项”或长按入口保留。相关依赖、
  helper 和偏好由网络加固任务一并删除；本 spec 负责确保 App UI 不再引用或宣传 FTP。
- 保存目录的“更改”和“在文件管理器打开”使用明确按钮/菜单，不再依赖长按。
- 路径和地址允许选择，长文本在 2.0 text scale 下换行，不把关键内容强制省略为不可读。
- 客户端设备设置采用同一 tile/section primitive；删除设备单独放在“危险操作”分区。

### 表单验证

`ValidatedInputDialog` 使用字段描述而不是 `List<Map<String,bool>>`:

```dart
class InputDialogField {
  const InputDialogField({
    required this.initialValue,
    required this.label,
    this.keyboardType,
    this.inputFormatters = const [],
    this.validator,
  });

  final String initialValue;
  final String label;
  final TextInputType? keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final String? Function(String value)? validator;
}
```

- nickname: trim 后非空，最大 64 个 Unicode scalar；空昵称不再静默改成系统名称。
- host: trim 后非空，接受有效 IPv4、IPv6、`.local` 或普通主机名；错误显示 inline。
- server port: 十进制整数且 `1001..65535`，错误时对话框保持打开。
- Enter 提交当前有效表单，Escape 取消；确认过程中禁用重复提交。

### 确认框

- cancel 永远使用中性文本色，默认 focus 在 cancel，避免 Enter 误触危险动作。
- 只有删除设备、删除消息、删除本地文件等不可逆操作设置 `isDestructive: true`，确认按钮用
  danger 色并明确对象与后果。
- 连接/断开、停止共享等可恢复动作使用普通 primary 确认，不滥用红色。
- 对话框返回 `Future` 结果并在关闭时 dispose controller，避免回调和路由顺序竞态。
- `deviceList.dart` 内重复的 dialog 实现删除，所有页面统一使用 `widget/app_dialogs.dart`。

## 键鼠工作区与布局编辑器

键鼠工作区保留三类信息: 可控设备、屏幕画布、当前设备详情，但不再固定为 260 + canvas +
280 的唯一布局。

- `>=1100px`: 三栏，设备栏 240-280px，详情栏 260-300px，画布占剩余空间。
- `760-1099px`: 设备栏 + 画布；详情通过可聚焦的 inspector drawer 打开。
- `<760px`: 画布为主；“设备”和“详情”通过 44px toolbar button 打开 bottom sheet。
- 画布空时使用 `AppEmptyState`，冲突状态同时显示 warning icon、文字和语义提示。
- 屏幕块使用 8px 圆角；选中只增加边框/背景，不用大阴影或缩放。

鼠标拖动之外，必须提供等价键盘操作:

- Tab 在设备、屏幕块、toolbar 和 start/stop 之间移动；Space 选中/取消目标。
- 聚焦远端屏幕块后，方向键移动 10 logical layout units，Shift+方向键移动 50 units。
- `Ctrl/Cmd+S` 在单设备布局编辑器保存；Escape 退出当前 drawer/sheet 或返回。
- 四个贴边按钮保持可用并有 tooltip、selected semantics 和 44px 命中。
- 屏幕块 semantics 包含设备名、分辨率、本机/远端、选中和冲突状态。

布局编辑器底部状态与贴边动作在窄宽度/大字号下改为 `Wrap` 或两行，不允许横向 overflow。
所有坐标保存、吸附和 topology 逻辑保持现状。

## 无障碍与输入规范

- 每个 icon-only button 都有非空 tooltip 和 semantic label；tooltip 文案描述动作，不只描述图标。
- `AppInteractiveTile` 暴露 `button/enabled/selected/toggled`，状态文本用 `Semantics` 合并，避免
  屏幕阅读器重复读 icon。
- 动态连接、拖放拒绝、表单错误和传输失败使用 `liveRegion`，但普通进度更新不高频打断。
- `MediaQuery.disableAnimations` 或平台 reduced motion 开启时，颜色以外的非必要显隐/面板动画
  直接完成，不依赖测试等待固定时长。
- focus indicator 为 2px primary 外框并留 2px gap，在 Light/Dark 都可见。
- hover 只是增强，任何操作都不能只在 hover 出现且无键盘/长按替代。
- switch、checkbox 使用组件自身语义，不再把整个行与 switch 暴露成两个相同动作。
- 颜色对比遵循 WCAG AA: 正文至少 4.5:1，大字/非文本控件至少 3:1。
- 320x568、390x844、760x600、1024x720、1440x900，以及 text scale 1.0/2.0 都必须无 overflow。

## 本地化

- 所有新增或现存用户可见文案进入 `app_zh.arb`、`app_en.arb`、`app_es.arb`，然后运行
  `flutter gen-l10n`。生产 widget 使用非空 `AppLocalizations`，不保留中英文字符串 fallback。
- 西班牙语必须覆盖设置分区标题/subtitle、空状态、设备分组、本机发现、拖放、clipboard
  preview、验证错误、危险操作和键盘操作提示，不用英语替代。
- 数量使用 ICU plural，设备名/文件名/错误详情使用 placeholder。
- 技术缩写 IP、RTT 可保留；操作和状态必须翻译。FTP 相关 key 和文案直接删除。
- 删除 `DeviceDetailsScreen` 中的硬编码英语原型，真实可复制的设备信息留在会话 header/设置。

## 未接入 Device Workspace 的决定

删除以下未接入原型及只为它存在的测试:

- `lib/widget/device_workspace.dart`
- `lib/state/device_workspace_state.dart`
- `test/device_workspace_state_test.dart`

理由: 生产入口已经是 `ChatSessionListBuilder` + `DeviceListScreen` 的会话工作台，键鼠另有
`RemoteInputWorkspaceScreen`。接入旧原型会增加第三个“workspace”概念，并把硬编码文案、
24px 卡片和重复信任分组重新带回主流程。需要保留的分组思想直接落实到新的会话分组纯函数，
不迁移旧 widget。此删除不影响 remote input workspace。

## 测试策略

每个行为先写失败测试，再实现最小改动。

### 真行为与 widget 测试

- 主题: 12 个 token 值、最大矩形圆角、44px minimum、系统字体、Light/Dark 对比语义。
- 会话分组: connected/nearby/recent 互斥、排序、过滤后空组删除。
- 空状态: 初始空、搜索无结果、会话空、app 通知列表无结果。
- dialog: 非法 host/port/nickname 不关闭且显示错误；destructive/cancel 颜色与默认 focus。
- clipboard: composer 点击只生成 draft；file -> image -> text 探测；跨类型替换；发送/Enter 才调用
  socket callback；Escape/移除清空；普通文本保留；自动同步设置的既有行为不变。
- 消息: 组尾 metadata、hover/focus actions、移动端不常驻复制 icon、原生 `SelectableText`；
  `AnimatedList` 实时插入同组/拆组、删除组尾、UUID 原位更新和分页边界索引正确。
- 拖放: enter/exit/done/rejected overlay 状态。
- responsive: 设备 shell 与键鼠 workspace 在 5 个 viewport 无异常和 overflow。
- keyboard: `Cmd/Ctrl+F`、Escape、tile Enter/Space、屏幕块方向键/Shift 步长、保存快捷键。
- semantics: 核心动作 label 非空、selected/toggled/enabled 正确，所有可点击 `InkWell`、
  `GestureDetector`、button、switch、checkbox 和菜单命中盒至少 44px；动态错误是 live region。
- motion/contrast: reduced motion 下非必要动画立即完成；Light/Dark 正文达到 4.5:1、焦点和
  非文本状态达到 3:1 的自动化 token 对比检查。

### Golden

提交稳定 golden，至少覆盖:

1. Light 390x844: 本机发现状态 + 分组设备列表 + 空搜索结果。
2. Dark 1440x900: 桌面双栏会话、消息组和 composer clipboard preview。
3. Light 760x600: 设置页分区 title/subtitle 与长路径换行。
4. Dark 760x600: 键鼠工作区中等布局与冲突状态。

golden 使用测试内固定时间、设备数据和系统字体，不读取真实 socket、数据库或平台插件。

### 回归命令

每个原子任务运行对应 focused tests 和 `flutter analyze`。全部任务完成后运行:

```bash
flutter gen-l10n
flutter analyze
flutter test
```

## 验收清单

- [ ] Material 3 与蓝色品牌保留，页面呈现为中性、克制的工作台。
- [ ] 非圆形矩形圆角均不超过 8px，无营销式大卡片、渐变或装饰性阴影。
- [ ] 本机发现、设备分组、无设备和搜索无结果状态清楚。
- [ ] 消息、文件、剪贴板、音频与键鼠能力有可发现入口和 disabled reason。
- [ ] composer 手动剪贴板内容必须二次确认，显式自动同步设置保持原语义，拖入文件有完整反馈。
- [ ] 危险确认、表单验证、设置 subtitle 与显式操作符合本 spec。
- [ ] 所有核心交互满足 44px、tooltip、semantics、focus 和 keyboard 要求。
- [ ] 生产 UI 无硬编码文案，中文/英语/西班牙语完整。
- [ ] 未接入 device workspace 原型已删除，remote input workspace 保留并响应式化。
- [ ] golden、semantics、text scale、viewport 测试通过，`flutter analyze` 与全量测试通过。

## 风险与控制

- `deviceList.dart`、`conversation.dart` 和 `settings.dart` 文件较大。新增纯 UI 必须优先提取为
  小组件，socket/coordinator 调用仍留在原 page，避免顺手重构业务状态机。
- golden 可能因 Flutter 升级产生差异。固定测试数据、字体环境和动画时间；只有审核过的视觉
  变化才更新基线。
- composer clipboard preview 改变该按钮一次点击即发送的旧行为，这是有意的隐私保护；
  不提供“跳过确认”设置。现有自动剪贴板同步是用户另行显式开启的能力，本轮不改变其协议和开关。
- 响应式键鼠工作区只改变呈现和输入映射，不改 layout 坐标、吸附和共享协议；相关既有纯逻辑
  测试必须继续通过。
