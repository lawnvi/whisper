# 网页传输

2026-11-12 用户定下：名字叫「网页传输」；这台每次确认、核对 4 位数；网页关掉 10 分钟后结束；记录留着；不加密（本来就是临时用的）；不能影响 App 原有的能力；不改数据库结构；两个方向都不传文件夹；网页只有中文和英文，按打开网页的浏览器定，页面上能切换，和这台 App 的语言无关。界面规格见 [`docs/design/surfaces.md`「网页传输」](../design/surfaces.md#网页传输)，网页本身是 `assets/web_transfer/index.html`。验证情况见 [`docs/records/2026-11-12-web-transfer-trial.md`](../records/2026-11-12-web-transfer-trial.md) 和小米手机上的 [`docs/records/2026-11-12-web-transfer-xiaomi.md`](../records/2026-11-12-web-transfer-xiaomi.md)。

没装 Whisper 的设备用浏览器打开这台的一个地址，这台确认之后，两边像两台 Whisper 设备一样互发文字和文件。对方可以是 iPhone、借来的电脑、Chromebook，有浏览器就行。它补的是 iOS 版没上架留下的缺口。

## 用户看到的流程

1. **这台打开网页传输。** 桌面点左下角这台的名字，手机进「连接设备」，在二维码下面点「对方没有 Whisper？用网页传输」。那一面翻过来：二维码和地址，比如 `http://192.168.1.5:10003/`。这一面开着的时候，新的访客才能发起请求。
2. **对方扫码或输入地址。** 网页显示这台的设备图、「连接到 MacBook Air」和一个 4 位数。
3. **这台确认。** 灵动岛弹出请求：对方的设备图、同样的 4 位数、允许和拒绝。60 秒没答复，请求作废，网页显示「没有回应」，可以再试。允许后面板收起，打开和它的对话。
4. **互发。** 对方出现在设备列表里，名字按浏览器猜（iPhone、iPad、Android、Windows、Mac、Chromebook、Linux），可以改备注名。这台的对话和平时一样：文字、文件、截图、发送剪贴板，只是不能发文件夹。网页那边能发文字和文件（相册、「文件」App、拖进来、粘贴）。
5. **结束。** 网页关掉或断网 10 分钟，或者任一边点断开，连接结束。记录留着：设备列表里那一行变成离线，历史还在，输入框变灰。同一个浏览器再打开地址，回到同一个会话的历史，但这台要再确认一次（标题是「iPhone 想再次连接」）。

## 范围

| 做 | 不做（原因） |
| --- | --- |
| 双向文字，带链接识别 | 加密（临时用，见「安全」） |
| 网页发文件：多选、拖放、粘贴，分块续传 | 文件夹，两个方向都不传。网页上拖进文件夹时说一句，这台往网页拖文件夹时提示 |
| 这台发文件，包括截图和发送剪贴板里的图片、文件 | 后台在线和通知（网页推送要 HTTPS 和苹果的推送服务器） |
| 网页上看图片和视频，点开大图 | 剪贴板自动同步（普通 HTTP 页面读不到剪贴板） |
| 断线重连、补发没发出去的文字 | 在网页里截访客自己的屏幕（见「截图」） |
| 网页中文和英文：按浏览器，页面上能切换，记在这个浏览器里 | 键鼠、声音、窗口、浏览文件（只给传输） |
| | 快捷发送、托盘和「发到…」里出现网页访客（只在对话里发） |
| | 二维码一码两用（见「为什么不和配对二维码合并」） |

## 截图

- **这台截图发给网页：能用。** 对话里的截图按钮照常：框选、标注，粘贴到输入框后发出去，到网页就是一张图片。截图是临时文件，发给网页时先复制一份到接收目录，网页晚点下载也还在。
- **网页那边：** 电脑上的浏览器可以把系统截的图粘贴进输入框，手机从相册选。网页自己截屏要用 `getDisplayMedia`，浏览器只在 HTTPS 页面里给，手机浏览器没有，所以不做。

## 不影响 App 原有的能力

- **不碰 Whisper 设备之间的东西：** WebSocket 协议、配对、传输引擎、声音、键鼠、窗口、挂载都没改。`WsSvrManager` 只把两个没人用的 `debugDispatch*` 改名成 `dispatchMessage`、`dispatchTransfer`，访客的消息和传输从这里交给对话页、设备列表和灵动岛。
- **不改数据库结构**，不加迁移。访客用现有的表，见「访客在本机的样子」。
- **不用就不起服务器：** App 启动时只把挂载点装到共享链接服务器上（`WebTransferCoordinator.install()`），不开端口。面板打开、或者还有没结束的访客时，才让服务器跑起来（`ShareLinkStore.hold`）。
- **共享链接照旧：** 路由、文件服务的总开关、端口、地址选择都不变。网页传输只占根路径 `/` 和 `/w/`，链接的路由至少 2 个字符，不会是 `w`；根路径原来回 404，现在只要服务器在跑就是网页传输的页面（没打开时页面写「还没有打开网页传输」）。
- **App 的语言照旧：** 新加的文案走 ARB，中、英、西三种都有。网页的中英文写在网页自己里面。
- **对话页和设备列表**只为 `web-` 开头的设备多一些分支。这两个文件和手机连接页在大小基线里，加之前先挪走了不改行为的代码：对话页的两个辅助函数到 `lib/page/conversation_peer.dart`，设备列表末尾和 `app_dialogs.dart` 重复的三个对话框包装删掉，手机连接页的取景框到 `lib/new_ui/phone/phone_viewfinder.dart`。
- **「已连接」的含义不变：** 设备列表的 `isConnected` 仍然只指 Whisper 设备，托盘、声音、命令面板、键鼠布局都按它来。访客在线是另一个字段 `ChatSessionItem.isWebOnline`，只影响排序、头像颜色和第二行的字。

## 和共享链接共用一个服务器

`ShareServer` 有一个挂载点 `extension`（`ShareServerExtension`）：主机名检查和路径拆分之后、方法检查之前先问它，它认领的请求自己处理（包括 `PUT` 和 WebSocket 升级）。和请求无关的 HTTP 小工具挪到了 `share_http.dart`，`share_server.dart` 导出它，原来的引用不变。

服务器在「有开着的链接（且文件服务开着）」**或**「网页传输要它」时运行。地址沿用共享链接选的那个（多个网络时面板上能换），二维码里是 `http://<地址>:<端口>/`。端口和链接一样从 10003 起往后找空的。

## 协议（第 1 版）

页面是 `GET /`：服务器把 `<script id="boot">` 里的 JSON 换成这台的名字、系统和外形（`<` 转义），其余原样返回。之后网页用一条 WebSocket 收发消息，用 HTTP 传文件内容。代码在 `lib/web_transfer/web_transfer_protocol.dart`。

### WebSocket：`GET /w/ws`

升级前检查 `Origin` 必须是 `http://` 加请求里的 `Host`，否则 403。每帧一个 JSON 对象，`t` 是类型，超过 128 KiB 的帧断开连接。服务器每 15 秒发一次 ping。连上 10 秒内没有 `hello` 就断开。

网页发给这台：

| `t` | 字段 | 说明 |
| --- | --- | --- |
| `hello` | `v`、`key`、`os`、`kind`、`browser` | 每次连上都发。`v` 是 1；`key` 是浏览器存在 `localStorage` 里的 16 字节随机数（base64url，22 个字符），存不了就每次新生成 |
| `text` | `id`、`body` | `id` 是网页生成的 UUID，这台按它去重；`body` 不超过 64 KiB |
| `offer` | `id`、`name`、`size`、`type`、`modified` | 要发一个文件。同一个 `id` 再来是续传：回 `ready` 和已经收到的位置 |
| `cancel` | `id` | 取消自己正在发的文件 |
| `bye` | | 网页点了断开，或者在等确认时点了取消 |

这台发给网页：

| `t` | 字段 | 说明 |
| --- | --- | --- |
| `wait` | `code`、`host` | 请求已经交给这台，等确认。`code` 是 4 位数 |
| `closed` | `host` | 这台没开网页传输，也没有这个浏览器的会话。随后断开，网页隔几秒重试，这台一打开就继续；已经在对话里的网页听到它，说明这次访问在这台那边已经结束（App 重开过），显示「已断开」 |
| `busy` / `declined` / `expired` | | 访客满了 / 被拒绝 / 60 秒没答复。网页停止重试，等用户点「再试一次」 |
| `welcome` | `session`、`host`、`history` | 确认了，或者断线后回来。`history` 是最近 200 条，旧的在前 |
| `text` | `id`、`from`、`body`、`time` | `from` 是 `host` 或 `me`（网页自己发过的，回来时补给它） |
| `file` | `id`、`from`、`name`、`size`、`type`、`time` | 这台发来一个文件，网页按 `id` 下载 |
| `ack` | `id`、`time` | 网页的文字这台收到了 |
| `state` | `id`、`state`、`committed`、`reason` | 网页发的文件：`ready`（从 `committed` 开始传）、`done`、`refused`（`reason`：`space`）、`failed`、`cancelled` |
| `ended` | `by` | 这台断开（`host`）或者会话过期（`expired`） |

`session` 是 32 字节随机数。网页拿到后 `POST /w/session` 换成 Cookie `whisper_web`（`HttpOnly`、`SameSite=Strict`、`Path=/`），之后的下载、预览和上传靠它。WebSocket 重连不靠 Cookie：`hello` 里的 `key` 推出来的就是这个访客，会话还在就直接回 `welcome`。

### 上传：`PUT /w/up/<id>`

- 只接受这个会话 `offer` 过的 `id`。请求头 `Content-Range: bytes <起>-<止>/<总>`（空文件是 `bytes 0-0/0`），一块不超过 8 MiB。网页用 `XMLHttpRequest` 发，好拿进度。
- `<起>` 必须等于这台已经写下的字节数，否则回 409 和 `{"committed": n}`，网页从 `n` 接着发。成功回 200 和新的 `committed`。`GET /w/up/<id>` 查当前位置。一块传到一半断了，收到的部分算数。
- 写进接收目录里的隐藏文件 `.whisper-web-<id>.part`，边写边算 SHA-256（`web_transfer_uploads.dart`）。收齐后用 `publishVerifiedDownload` 换成正式文件：重名加 `-1`、`-2`，不覆盖；Unix 上是移动，Windows 上是硬链接，都不复制。文件名先过 `webSafeFileName`：去掉路径，`<>:"|?*` 和控制字符换成 `_`，去掉开头的点和结尾的点、空格，超长时保留扩展名截短，系统保留名前面加 `_`。然后发 `state: done`；Android 上通知媒体库。
- 不做整文件的端到端校验：普通 HTTP 页面拿不到 `crypto.subtle`，用 JavaScript 算大文件的 SHA-256 太慢。完整性靠 TCP 和按位置续传，写在使用指南的限制里。
- 写盘时磁盘满（`ENOSPC`、`ERROR_DISK_FULL`）回 `refused`/`space`。没有提前检查剩余空间，仓库里没有现成的跨平台办法。

### 下载：`GET /w/f/<id>`

- 只给这台发给这个访客的文件（按消息的 `uuid` 找，收件人必须是这个访客），包括以前的会话发过的。支持 `HEAD`、`Range`、`If-Range`、`If-None-Match`，沿用 `share_range.dart` 和 `share_http.dart`。Android 上选的文件是 `content://`，按块从系统读。
- `?view=1` 给网页预览：图片（png、jpeg、gif、webp、heic、heif、avif）和视频（mp4、quicktime、webm）回 `inline`，其余按附件下载。
- 每个文件响应都带 `X-Content-Type-Options: nosniff` 和 `Content-Security-Policy: sandbox; default-src 'none'`。

Chromium 系的浏览器（Chrome、Edge、Opera）对 http 下载一律提示「无法安全下载」，局域网地址也不例外。不点「保留」，下载会在中途断掉，这台写「等待重连」。网页在这些浏览器上（iOS 除外）点下载后，提示 5 秒要选「保留」。换成 https 也绕不开：自签证书会变成更吓人的证书警告。

这台的文件卡片：网页还没下载时没有传输记录，卡片写「等对方下载」；下载时按送出的字节画进度；一次响应把最后一个字节送完就是「已送达」；中途断了写「等待重连」，不上灵动岛。预览（列表里的图片、视频的第一帧）只在完整送完时算送达，不画进度。

## 状态机（这台）

代码在 `web_transfer_coordinator.dart`，一个访客的状态在 `web_transfer_session.dart`。

```
          hello（面板开着）            允许
  （无）──────────────────▶ 等确认 ──────────▶ 在线 ◀──────┐
                              │ 拒绝/60 秒/bye       │ WebSocket 断了 │ 10 分钟内同一个浏览器回来
                              ▼                      ▼                │
                            作废                   离开 ──────────────┘
                                                     │ 10 分钟
                    这台断开 / 网页 bye / App 退出   ▼
                    ────────────────────────────▶ 结束
```

- 同时最多 4 个没结束的会话（等确认的也算）；等确认的同一个地址最多 1 个、总共最多 3 个，再多回 `busy`。被拒绝和作废都记一次 `ShareRateLimiter` 的失败。
- **等确认时网页断开**（刷新、手机切到别的应用）：请求留着，还是同一个数字，回来接着等；只有网页点「取消」（`bye`）才马上撤掉。没人管的请求 60 秒后作废。
- 离开期间这台照样能发文字和文件，网页回来时从 `history` 里补上。
- 会话只在内存里：App 退出，所有访客收到 `ended`，Cookie 失效。
- 会话结束时，传到一半的上传删掉临时文件，卡片写「接收失败」；正在下载的连接切断。
- 面板关上只是不再接新请求，已经在线的照常。上一次运行留下的访客传输（App 崩溃时传到一半）在第一次打开面板时标成失败。

## 访客在本机的样子

**不改数据库结构。** 访客是 `device` 表里的一行（`web_transfer_records.dart`）：

- `uid` = `web-` 加 `SHA-256("whisper-web-visitor:" + key)` 的 base64url 前 22 个字符。`key` 只有那个浏览器知道，这台只存推出来的 `uid`。`uid` 不是 UUID，和 Whisper 设备的 id 不会撞；`isWebVisitorUid` 按前缀认。
- `platform` 用设备图已经认识的写法：`ios`、`ipad`、`android`、`macos`、`windows`、`linux`，没认出来是空的。手机和平板记进 `DeviceFormFactors`，安卓平板画成平板。
- `name` 是默认名字（不翻译的专名），备注名沿用设备卡片的做法。`host` 是最近一次的 IP，`port` 是 0，`auth` 是 false，没有身份公钥，所以自动重连不会碰它。
- 消息是普通的 `message` 行；文件用 `file_transfer` 行记进度，方向和状态照旧，对话里的文件卡片、灵动岛、设备行的「log.txt 59%」都不用改。

要排除访客的地方：

| 地方 | 怎么做 |
| --- | --- |
| 交给 `ConnectionCoordinator().syncKnownDevices` 的设备 | 跳过 `web-` 开头的 |
| 自动重连 | 本来就要求 `auth` 为 true 且有身份公钥 |
| 键鼠的屏幕布局 | `ShellInputController.updateDevices` 跳过访客 |
| 对话页的文件、应用、控制入口和设备功能 | 访客没有 |
| 设备卡片 | 没有声音、键鼠、剪贴板、挂载的圆钮和权限开关，留备注名和地址 |
| 往设备行上拖文件 | 访客不算已连接，拖不上去；在对话里拖 |

## 安全

- **传输不加密，和共享链接一样。** 页面和数据都走普通 HTTP，同一个网络里的人可能看到内容；即使在网页里加密，页面代码本身也是用 HTTP 发过去的，网络里的攻击者可以在加载时改掉它。面板上和使用指南里说了实话。以后要做，可选的路有三条：电脑用自签证书（Safari 每次都警告）、让访客装一个只认本机地址的证书描述文件、页面从官网用 HTTPS 加载再用 WebRTC 直连这台。每条都要单独设计和审查。
- **准入：** 只在面板开着时接新请求；每个会话都要这台点允许，并核对 4 位数。4 位数是这台随机生成的，只用来认人。
- **会话 Cookie** 是 `HttpOnly`、`SameSite=Strict`。所有改状态的请求（WebSocket 升级、`PUT`、`POST`）都检查 `Origin` 等于 `http://` 加 `Host`，挡住同一网络里别的网页借访客的浏览器发请求。服务器沿用共享链接的局域网来源过滤、DNS 重绑定检查和连接数上限。
- **访客能碰到的只有自己的会话：** 自己发过和收到的文件，不能列目录、不能下载这台没发给它的东西。`offer` 用到已有传输的 `id`（别人的）一律回 `failed`，不会覆盖别人的记录。
- **页面：** 不加载任何外部资源。服务器第一次读页面时算出内联脚本和样式的 SHA-256，放进 `Content-Security-Policy`（`default-src 'none'`、`connect-src 'self' ws://<Host>`、`img-src 'self' blob: data:`、`media-src 'self' blob:`）。消息和文件名都用 `textContent` 放进页面。页脚的官网和 GitHub 是普通的新窗口链接，带 `noopener noreferrer`。
- **收到的文件**不自动打开。
- **没挡住的：** dart:io 的 WebSocket 没有单帧大小上限，超过 128 KiB 的帧是收完整帧后才断开；局域网里一个还没被允许的访客能让这台分配一次大内存。面板开着才有这个窗口，没做更细的限制。
- `AppLog` 只记事件和错误类型（打开、关闭、请求、允许、拒绝、结束、失败），不记 IP、文件名、User-Agent 和消息。

## 为什么不和配对二维码合并

最省事的入口是一个二维码两用：Whisper 扫了直接配对，相机扫了打开网页。但配对二维码是 `whisper://pair?...`，旧版本的 `PairingInvite.parse` 只认这个格式，换成 `http://` 地址后旧版本扫不了。等旧版本基本没人用了再考虑。

## 代码在哪

| 文件 | 管什么 |
| --- | --- |
| `lib/web_transfer/web_transfer_protocol.dart` | 帧的格式、版本、上限，`hello` 和 `offer` 的解析，`Content-Range` |
| `lib/web_transfer/web_transfer_session.dart` | 一个访客的状态和它的 WebSocket |
| `lib/web_transfer/web_transfer_coordinator.dart` | 单例：面板开没开、所有会话、帧的处理、给界面的通知 |
| `lib/web_transfer/web_transfer_records.dart` | 访客的设备行、消息、传输进度、`welcome` 的历史 |
| `lib/web_transfer/web_transfer_routes.dart` | `/`、`/w/ws`、`/w/session`、`/w/up`、`/w/f`，挂到 `ShareServer` 上 |
| `lib/web_transfer/web_transfer_uploads.dart` | 分块写入、续传位置、换成正式文件、文件名清理 |
| `lib/web_transfer/web_transfer_visitor.dart` | `uid` 的推导、平台和默认名字 |
| `lib/new_ui/shell/shell_web_transfer.dart` | 网页传输那一面、入口、翻面动效、灵动岛请求 |
| `assets/web_transfer/index.html` | 网页，一个文件，内联样式和脚本 |

## 测试

`test/web_transfer_test.dart` 一个文件，三个用例，都走真实套接字和内存数据库：

- **主路径**：打开 → `hello` → 允许 → 双向文字（重发的只记一次）→ 上传 3 MiB，第一块传到一半断开再续传，名字带路径也落在接收目录里 → 这台发一个文件，网页分两段 Range 下载。
- **安全边界的表**：没有会话不能上传和下载；别的网页（错误的 `Origin`）不能上传、不能换 Cookie、不能开 WebSocket；位置不对回 409；没 offer 过的、发给别人的文件拿不到；超过访客上限回 `busy`；面板关着回 `closed`；结束了的会话 Cookie 失效，传到一半的上传标成失败。
- **状态机**：请求作废、离开后 10 分钟内回来接上（离开期间这台发的文字随历史补上）、超时结束后再来要重新确认。

## 原型

`node docs/design/tools/web-transfer-demo.mjs <目录>` 给网页接一个假的「这台」，输出可以直接用浏览器打开的本地文件 `demo.html`（只在本地看，不发布到线上），地址后加 `#code`、`#closed`、`#declined`、`#empty`、`#chat`、`#reconnecting`、`#ended` 直接看各个状态。
