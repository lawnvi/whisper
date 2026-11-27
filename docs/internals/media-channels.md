# 媒体连接：声音、键鼠和窗口旁边的那几条 WebSocket

声音、键鼠和窗口流转的数据不走 `/chat`，各自另开一条 WebSocket：`/audio`、`/input`、`/window`。三条的令牌、证明、加密、接受和关闭都是同一套代码，只有路由本身的几处参数不同。本文说明这一套怎么工作。UDP 车道见 [udp-lane.md](udp-lane.md)，声音掉线后谁负责接回来见 [audio-group-recovery.md](audio-group-recovery.md)。

## 路由

`lib/socket/media_channel_dial.dart` 的 `MediaRoute` 列出三条路由和它们的不同之处：

| 路由 | namespace | 拨号方 | 不同之处 |
|---|---|---|---|
| `/audio` | `audio-group` | 声音来源拨播放端 | 播放端是电脑时先试它音频 isolate 自己的端口（1.5 秒），不通再走主端口 |
| `/input` | `remote-input` | 控制的一方拨被控的一方 | 拨号方每 5 秒 ping 一次：被控端卡住但 socket 还开着时，控制端不会一直吞掉本机的键鼠 |
| `/window` | `window-stream` | 观看端拨主机 | 升级前就在 socket 上设 TCP_NODELAY；主机是手机且是 `/chat` 的客户端时反过来由主机拨（见下面"反拨"） |

## 令牌和证明

1. 接受方在自己的 accept 控制消息里给出一次性令牌（`SessionUpgradeTokenRegistry`，30 秒有效，最多 128 个）。令牌绑定路由、namespace、会话、对方设备和这条 `/chat` 连接的代次，里面存着接受方对这台设备的**接收**密钥。
2. 拨号方带着 `session` 和 `token` 连上来。接受方查表，没有就回 401；同时在证明的连接超过上限就回 429（主端口 32 个，音频 isolate 的端口 8 个）。
3. 升级之后接受方发一个挑战：路由、namespace、会话、令牌的 SHA-256、32 字节随机数、设备号、连接代次。拨号方用自己的**发送**密钥对它做 HMAC，接受方用接收密钥核对（`media_upgrade_proof.dart`）。3 秒内没有正确的证明就断开。
4. 证明通过后才用掉令牌，再把连接交给子系统。令牌被用过、过期或者属于旧的连接代次，连接就关掉。

主端口和音频 isolate 的端口都用 `lib/socket/media_upgrade_server.dart` 的 `MediaUpgradeServer` 做第 2–4 步。区别只在第 4 步：主端口在同一个 isolate 里查令牌表，当场有答案；音频 isolate 要问主 isolate，所以先告诉拨号方"可以了"，等主 isolate 确认令牌用掉后才开始播放；这段时间里到的包留在连接里等着，不会丢，令牌不对就关掉连接。

## 加密

每个包都用 XChaCha20-Poly1305 加密，外面是 `WEP1` 信封（多 32 字节：魔数、序号、长度、认证标签）。密钥由 HMAC-SHA256 从媒体密钥派生，输入里有路由、namespace、会话和令牌本身（channel binding）。所以同一个媒体密钥下，不同会话、不同令牌的包互相解不开，重放到别的连接上也没用。

两个方向用不同的密钥：每一端都用自己的发送密钥加密、用自己的接收密钥解密，和谁拨的号无关。窗口流转两个方向都有数据，主机加密视频用它自己的发送密钥，而不是令牌里存的接收密钥，否则两个方向会在同一个密钥下重复使用 nonce。

## 拨号

`dialMediaChannel(uri, route, ...)` 是唯一的拨号函数：连上、等证明完成，失败一律抛 `PacketWebSocketConnectException`，异常文字里没有令牌和会话号。地址用 `MediaRoute.uri(...)` 拼，只取对方 accept 里的端口，路径由路由决定，不用对方给的。

## 接受之后

声音和键鼠的接受方用 `lib/socket/media_channel_registry.dart` 的 `MediaChannelRegistry` 记住接上的连接：

- 每个会话、每台设备最多一条；第二条直接关掉。
- 每条消息先按 claim 解密，再交给子系统做自己的检查（声音逐包核对组、流和来源，键鼠核对会话）。
- 可以按会话、按设备、按"不是这把密钥的"或者全部关闭。关闭时子系统收到 `MediaChannelClosed`：`expected` 表示是本机主动关的（会话结束、整体关闭），否则就是链路断了。

窗口流转的接受方是 `WindowStreamHost`（主机）和 `WindowStreamViewer.attachInbound`（被主机反拨的观看端），各自管自己的流。

## 关闭原因

发送一侧用 `PacketByteTransport`，它的 `done` 只完成一次，带一个 `PacketTransportTermination`：

- `localClosed`：本机关的，不算断开。
- `remoteClosed`、`remoteError`：对方关了或者出错。
- `writerFailure`：写不出去，比如对方几秒不读。
- `overflow`：可靠队列装满了（键鼠的按键、窗口的控制包不能丢，满了就整条关掉）。

声音、键鼠和窗口都看这个值：声音交给恢复逻辑重新 offer，键鼠停止这次共享，窗口主机停流并在 `/chat` 上告诉观看端原因。窗口主机以前只靠输入方向发现断开，观看端不读时视频队列写失败也照样在采集和编码。

## 换了一条 /chat 连接

同一台设备的新 `/chat` 连接认证完成时（`WsSvrManager._closeSupersededMediaChannels`），用旧连接密钥接上的媒体连接都要关掉：

- 声音和键鼠按密钥找：claim 里的密钥不是新连接的就关。
- 窗口主机不保存 claim。新连接的密钥下还不可能有窗口流，所以关掉为那台设备主持的全部窗口流；对方也会关掉它主持的。

这些关闭都不算"本机主动"，子系统按断线处理。

## 反拨

现在只有窗口流转能反拨：手机常常从外面连不进去（VPN、AP 隔离、热点），但它能连到电脑，所以手机主机是 `/chat` 的客户端时，主机在 accept 里说 `hostDials`，观看端用 `dial` 发一个自己签的令牌，主机拿它拨观看端的 `/window`，证明用主机自己的发送密钥（`window_stream_control.dart` 的 `WindowStreamMediaDial`）。声音和键鼠的拨号方向还是固定的。

## 测试

- `test/media_websocket_authorization_test.dart`：三条路由的令牌、证明、代次、名额和随机数失败，跨 isolate 先证明后消费令牌的那条路径，都在真实 socket 上。
- `test/bounded_binary_websocket_session_test.dart`：登记、按旧密钥关闭、整体关闭时新来的连接。
- `test/packet_byte_transport_test.dart`、`test/remote_input_packet_transport_test.dart`：关闭原因，包括溢出。
- `test/window_stream_reverse_dial_test.dart`：窗口反拨。

没有测试的：音频 isolate 端口上的完整播放路径（要原生音频），窗口主机在视频发送端坏掉时停流（要原生采集）。
