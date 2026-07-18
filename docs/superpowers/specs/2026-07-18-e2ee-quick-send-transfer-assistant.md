# Whisper 端到端加密、快捷发送与传输助手规格

> 状态：2026-07-18 实现基线。本文记录当前协议和产品边界，不构成第三方安全审计。

## 目标与范围

本轮对应“随手传、放心传、断线也能传”，覆盖以下能力：

- 配对后加密文本、文件、剪贴板、通知、音频和键鼠控制，并显示加密/可信状态。
- Android 系统分享、桌面右键菜单和全局快捷键直接创建待发送内容。
- 二维码同时携带局域网地址和设备身份摘要，失败时给出分阶段诊断。
- 文件夹打包发送、按设备搜索文本、收藏文本和默认关闭的剪贴板自动同步。

仍不包含公网中继、账号云同步、NAT 穿透、数据库/下载文件静态加密和跨设备消息索引。

## 协议与安全边界

### 身份、握手与会话密钥

- 连接协议硬切到 v8，旧版本返回升级提示，不回退到明文业务帧。
- 每台设备使用长期 Ed25519 身份密钥；私钥 seed 保存到平台安全存储，并迁移、删除旧的 SharedPreferences 副本。
- 每次连接生成临时 X25519 密钥和 32-byte nonce；双方签名包含身份、公钥、nonce、profile digest、目标 peer/pkh 和配对语义的固定 transcript。
- 首次配对或身份需要重新确认时，双方显示同一 6 位配对码并分别明确确认；提前发送的签名 proof 只证明身份，`allow=true` 必须等本机确认后才生成，已保存的 peerId 必须同时匹配 pinned public key。
- 撤销信任、删除设备或确认身份替换时，先阻止该 peer 的新发送；信任位、identity CAS 与旧身份下的持久文件队列在同一数据库事务内失效，连接随后关闭。旧目标绑定必须重新选择并校验当前 trusted peerId + pkh，不能因后台重连自行恢复。
- X25519 shared secret 经 HKDF-SHA256 派生四把 32-byte 方向性密钥：双向 chat 和双向 media；临时密钥在会话关闭时销毁。

### 加密帧

- chat 通道使用 `WAE1`，XChaCha20-Poly1305，header 和协议 domain 进入 AAD；序号严格单调，拒绝篡改、重放、跳号、截断和超限载荷。
- 文本、文件 offer/chunk/ack、剪贴板、通知和控制消息都经过 chat AEAD，业务分发只发生在鉴权完成后。
- 音频、音频组和远程输入使用 `WEP1`，XChaCha20-Poly1305；route、namespace、sessionId、一次性升级令牌、header 和序号共同派生或绑定密钥与 AAD，重建通道后序号归零也不会复用旧 key/nonce。
- `/audio` 与 `/input` 升级令牌为 32-byte 随机值，默认 30 秒、单次消费，并绑定 route、session、peer 和连接 generation；随后还需用 media key 完成 challenge proof。
- App 启动时加载 libsodium 的 XChaCha20-Poly1305 原生实现；常规文件选择器仍按现有分块流式传输，不增加整文件内存缓冲或第二份磁盘副本。Android 系统分享为支持断线和进程重启恢复，会先生成一份应用私有暂存副本。

### 明确边界

- E2EE 只保护已鉴权端点之间的在途内容；不保护已被控制的手机、电脑、系统账号、输入法、剪贴板提供者或文件提供者。
- mDNS 仍公开设备名、平台、peerId、局域网地址和端口，握手元数据也不是匿名通信；二维码中的地址、peerId 和 pkh 不是秘密。
- 本地 Drift 数据库、收藏文本、桌面快捷发送草稿、下载文件、文件夹临时 ZIP 和 Android 系统分享暂存文件均不是静态加密数据。
- Android 分享接收 `content://` 时会流式复制到应用私有 `filesDir/android_system_shares`，因此完成暂存后不依赖来源 URI 权限；完成或取消传输会清理副本，失败或断线时则保留以便恢复。卸载应用或清除应用数据仍会丢失这些待发送内容。
- “不降低速度”定义为不增加文件复制，并让加密不成为 LAN 吞吐瓶颈；AEAD 必然消耗 CPU，因此发布前仍需固定硬件的加密前后吞吐基线，不能把“零性能开销”作为事实宣传。
- 设备身份、协议和加密实现尚未经过独立密码学审计。

## 系统级快捷发送

### Android 系统分享

- `MainActivity` 保持 `singleTop`，接收 `ACTION_SEND` 和 `ACTION_SEND_MULTIPLE`；冷启动读取 initial intent，热启动通过 `onNewIntent` 接收。
- 解析 `EXTRA_TEXT`、`EXTRA_STREAM` 和 `ClipData`，只接受 `content://`；读取 `DISPLAY_NAME`、`SIZE` 和 MIME，并将内容流式暂存到应用私有 `filesDir/android_system_shares`，不写入 cache 或整文件读入内存。
- native 最多保留 16 个事件，每个事件最多 64 个 item、256 KiB 文本；事件、选定目标、公钥摘要和条目发送进度通过 `AtomicFile` 持久化，Dart inbox 再做 URI 和事件 ID 去重及同等限额。
- 队列满、文本或条目超限、来源不可读时原子拒绝新事件并持久化可见错误，不截断内容、不驱逐旧事件；冷启动后仍会提示拒绝原因。
- 设备列表用底部弹层选择已配对可信设备。只有一个可信在线设备时可预选，但用户仍须明确确认，不允许静默发送。
- 文本使用由事件 ID 派生的稳定消息 UUID，并只在收到目标设备的认证 ACK 后记录完成；暂存文件通过应用私有 `FileProvider` URI、现有 Android document reader 和 `sendPickedFileTo` 分块发送。
- 离线目标以 peerId 和 pinned public key hash 双重绑定并保留 inbox；失败、断线或进程重启后按已持久化进度自动重试，身份缺失或变化会清除目标绑定并要求重新选择，已确认条目不会重复发送。完成或取消传输时清理对应暂存文件，等待重连和失败状态下继续保留。

### 桌面入口

- 全局快捷键为 macOS `Cmd+Option+V`、Windows/Linux `Ctrl+Alt+V`；优先读取剪贴板文件，其次图片，最后文本。Windows 安装器创建带 `Ctrl+Alt+V` 的开始菜单快捷方式，可在应用未运行时通过 `--quick-send` 冷启动。
- Windows 冷启动的裸 `--quick-send` 在原生入口同步快照 `CF_HDROP` 文件或 `CF_UNICODETEXT` 文本后才持久化；图片、空内容或剪贴板占用时持久化可见拒绝，不允许 Dart 稍后读取已经变化的内容。Linux 冷启动裸命令同样转为可见拒绝，显式文件参数和运行中全局快捷键不受影响。
- macOS/Linux 全局快捷键依赖应用在后台运行，默认关窗后继续驻留；macOS NSServices 与 open-files、Windows 文件/文件夹右键 verb、Linux desktop action 和 KDE service menu 均可冷启动应用处理请求。
- 命令行统一为 `--quick-send`、`--quick-send-file`、`--quick-send-text`，运行中的单实例通过平台通道接收后续请求。
- 三个平台的原生入口先把带稳定事件 ID 的参数持久化到磁盘；Dart 只 peek，确认草稿或可见拒绝已经持久化后才 ACK 删除。队满时保留旧事件并持久化拒绝提示，不静默驱逐。
- 桌面草稿持久化，最多 32 条；单条最多 64 个路径、256 KiB 文本，路径最长 4096 字符。超限请求原子拒绝并显示原因，不截断或覆盖旧草稿；文本以草稿 ID 派生稳定 UUID，只在目标设备认证 ACK 后移除，文件逐项成功后才更新草稿。
- 首次发送前原子绑定目标 peerId 和 pinned public key hash，每段发送和重试前重新验证；身份变化会清除目标并要求重选，部分已送达草稿不会改投其他设备。

## 二维码连接与诊断

- QR invite 格式为 `whisper://pair?v=1&host=...&port=...&peer=...&pkh=...`，编码最长 512 字符。
- host 与连接端点共用严格策略：只接受 RFC1918 IPv4、合法 `.local`，以及 IPv6 ULA、带 zone 的 link-local 或 global-unicast 地址；拒绝回环、未指定、多播、公开 IPv4 和非规范写法。port、UUID peerId 和 32-byte canonical pkh 都严格校验。
- Android/iOS 可扫码，桌面显示和复制二维码；扫描自己、无效码、无相机和无可用 Wi-Fi 均有明确反馈。
- 扫码连接把 peerId 和 `expectedPublicKeyHash` 一起交给握手，二维码不能绕过签名、pin 或配对确认。
- 连接失败映射为 Wi-Fi、地址、服务、防火墙、身份、版本和配对七类诊断。身份或版本错误不可直接重试，其余类别可保留原目标重试。

## 文件夹与传输助手

### 文件夹

- 会话文件选择器和桌面快捷发送都可选择目录；目录先在临时 staging 区生成 ZIP，再走现有文件传输协议。
- ZIP 使用 store 模式避免压缩占用 CPU，不跟随符号链接，归档名过滤平台非法字符；生成失败会删除不完整文件。
- ZIP 一旦被持久传输队列接纳，即使首次 offer 因瞬时断线失败也保留并进入 `waitingReconnect`；失败状态同样保留，供用户重试。
- 完成或取消传输会立即删除受管 staging ZIP；启动和新建归档时清理超过 15 分钟且未被数据库传输或桌面持久草稿引用的崩溃孤儿。路径解析后只允许删除 staging 目录内的 ZIP。

### 搜索、收藏与剪贴板

- 传输助手按 peer 展示最近 50 条文本和最多 500 条收藏；输入搜索 250 ms debounce，结果最多 500 条。
- 三个及以上字符使用 SQLite FTS5 trigram，短查询使用大小写不敏感的 substring；只搜索文本消息，不搜索文件正文。
- `favorite_text` 在 schema v10 中保存来源消息 ID、peer、文本快照和时间；来源消息唯一，收藏/取消收藏幂等，并可复制文本。
- 剪贴板自动同步默认关闭，只同步文本；文件剪贴板不会误当文本。只有当前选中的在线、已信任且允许剪贴板的设备才接收，收到后按写入代次和精确内容抑制回声，并串行等待系统剪贴板写入，避免快速连续远端写入互相回传。
- 自动同步离线时不排队；需要断线保留的内容应走系统分享或桌面快捷发送草稿。

## 验证矩阵

| 区域 | 自动化覆盖 | 额外验收 |
|---|---|---|
| 身份与 chat AEAD | `auth_session_keys_test`、`authenticated_frame_test`、`peer_socket_session_test`、`typed_connection_handshake_integration_test` | 两台设备首次配对、旧版本拒绝、身份变化告警 |
| media 加密与升级 | `packet_byte_transport_test`、`media_websocket_authorization_test`、`session_upgrade_token_registry_test` | 音频、音频组、键鼠长时间运行和断线重连 |
| Android 分享 | `android_system_share_test`、`android_system_share_router_test`、`android_quick_share_removed_source_test` | 真机冷/热启动、单/多文件、强杀恢复、离线目标与暂存清理 |
| 桌面快捷发送 | `desktop_quick_send_inbox_test`、`desktop_quick_send_native_source_test`、`windows_quick_send_bare_snapshot_source_test` | macOS Services、Windows 安装器右键、Linux 文件管理器、全局快捷键 |
| QR 与诊断 | `pairing_invite_test`、`pairing_qr_test`、`connection_diagnostic_test`、`qr_pairing_wiring_source_test` | 双真机扫码、Wi-Fi 隔离、防火墙、地址变化、身份不匹配 |
| 文件夹与传输助手 | `folder_transfer_stager_test`、`local_database_transfer_assistant_test`、`transfer_assistant_page_test`、`clipboard_sync_test` | 大目录、符号链接、磁盘不足、长文本和多语言 UI |

合并门槛为 `flutter analyze`、`flutter test` 和 `./script/test_remote_input_keys.sh`；Android 另跑 `flutter build apk --debug`。涉及发布包时还需验证对应 macOS/Windows/Linux 安装器或打包脚本。

`tool/e2ee_throughput_benchmark.dart` 在本机以 512 KiB 分块处理 256 MiB 数据时测得加密 608.9 MiB/s、解密 568.8 MiB/s，超过覆盖 1 GbE 的 119 MiB/s 门槛。该结果证明 AEAD 在当前开发机上不是千兆局域网瓶颈，但不替代双机大文件、CPU、内存和断线续传验收。
