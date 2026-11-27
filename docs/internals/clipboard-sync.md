# 剪贴板同步

`lib/clipboard/`。设备列表页只负责启动，发什么、发给谁、哪些不发，都在这里决定。

## 发给谁

- **文字**：所有已连接、可信（`auth`，有身份公钥）、开着剪贴板同步（设备的 `clipboard`）的设备。以前没开键鼠时只发给界面上选中的那台（`WsSvrManager.receiver`），见 `docs/records/2026-11-27-network-architecture-consensus.md` 的 F8、U2。
- **文件和图片**：只发给正在进行的键鼠共享会话，不论本机是主控端还是被控端；主控端带多台设备时发给每一台。对方粘贴时才开始传。
- 键鼠共享的主控端收到一台被控端的文字，会转发给其余被控端（`WsSvrManager._relayWorkspaceClipboardText`），因为被控端之间不一定互相连着。

## 哪些不发：`ClipboardLedger`

以前有四套各管一段的防回声：设备列表页的 `_clipboardText`、按内容匹配 2 秒的 `ClipboardWriteSuppressionQueue`、粘贴引擎的 1.5 秒窗口 `_ownWriteUntil`、文件管理器的 `_ownClipboardFiles`。只要系统的变化通知来得比窗口晚（Windows 上很常见），收到的内容就会被当成新复制发回去。现在只有一份记录，两条规则：

1. **变化序号**（桌面）。每次剪贴板变化，系统都有一个只增不减的数：macOS 是 `NSPasteboard.changeCount`，Windows 是 `GetClipboardSequenceNumber()`，由原生插件的 `changeToken` 读出。每个序号只处理一次（Windows 一次复制常常通知两次）。Whisper 自己写剪贴板一律经过 `ClipboardLedger.ownWrite`：写完读一次序号记为“自己的”，这个序号的通知来得多晚都不发。自己的写包括：收到别的设备的文字、粘贴时放上去的文件、粘贴后放回原来的内容、文件管理器的复制、复制分享链接。
2. **最后同步的文字**。发出去或收到的文字记为 `syncedText`，剪贴板上还是它就不再发。手机没有序号，只靠这一条；桌面上它还挡住一次复制写好几遍的程序。

Linux 没有系统序号。原生插件数 GTK 的 `owner-change`，但只数别的程序的变化：GTK 对本进程自己的写也会通知，而且通知在写完之后才到，那时 Dart 已经读过序号了。判断依据是变化之后剪贴板归不归本进程（`gdk_selection_owner_get`）。代价是在 Whisper 自己的输入框里按复制，Linux 上不会同步出去；macOS 和 Windows 上会。

## 通知丢了怎么办

系统的变化通知来自 `clipboard_watcher`。Windows 上它只在启动时调一次 `AddClipboardFormatListener`，失败也不知道。桌面上另有每秒一次的检查：有设备连着时读一次序号，和上次处理的不同就当作一次变化。序号读取很便宜，不打开剪贴板。

Windows 上别的程序刚复制完常常还开着剪贴板，`OpenClipboard` 会失败。原生插件现在最多重试 10 次、每次等 15 毫秒；读文字的 `getClipboardText` 本来就在 Dart 里重试。

## 测过和没测过的

- `test/clipboard_ledger_test.dart`：自己的写无论通知多晚都不发、每个序号只处理一次、写失败也记为自己的、没有序号时按文字。
- 没有在真机上测：三端的序号读取、Linux 的 `gdk_selection_owner_get` 在 X11 和 Wayland 上是否都对本进程的写返回窗口、每秒检查能否补上 Windows 丢掉的通知。
- 主控端转发和设备间直连同时存在时，同一段文字会到两次；两次之间对方又复制了别的，晚到的旧文字会盖掉新的。这需要线上带来源序号，没有做。
