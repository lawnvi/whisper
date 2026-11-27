# 键鼠热路径上的 JSON 要花多少（2026-11-28）

协商稿 F28 说键鼠的一个事件在发送端要经过 7 到 10 次 JSON 编解码，建议热路径改成二进制，排在第 4 步之后。动手前先量了一次。

## 怎么量的

临时测试（量完已删）：一个普通的指针移动包，载荷 `{"deltaX":3.25,"deltaY":-1.5,"buttons":0,"x":0.4512,"y":0.7731}`（63 字节），整包带会话号、序号、时间戳、`travel` 和 `fence`（265 字节）。预热 2 万次后各跑 20 万次取平均。这台 Mac（Apple Silicon），`flutter test`，也就是 JIT，正式版的 AOT 只会更快。

| 操作 | 每次 |
|---|---|
| 载荷 `jsonDecode(utf8.decode(...))` | 0.38 µs |
| 载荷 `utf8.encode(jsonEncode(...))` | 0.88 µs |
| 整包 `encode()` 再 `decode()` | 3.23 µs |

## 结论

按发送端解 6 次载荷、编 2 次，加上整包编解码一次，一个事件约 8 µs。1000 Hz 的鼠标每秒 1000 个事件，合计约 8 ms，也就是一个核的 1% 不到；常见的鼠标事件到不了这个频率。加密（XChaCha20-Poly1305）和 WebSocket 写出都比这贵。

所以不改线上格式：改成二进制要协商新旧对端、留两套编解码，省下的不到 1%。也不为了"只解一次"去改 `RemoteInputCoordinator` 这些大文件：省下的是每个事件两三微秒。

以后指针卡顿要查，先看事件循环的延迟（调速器日志里的 `loopLagMs`）和 UDP 车道的排队，而不是 JSON。

## 还没弄清的

`RemoteInputEventType.modifiers` 只定义、从不发出。修饰键靠接收端跟踪按键事件（`RemoteInputCoordinator._sinkPressedModifiers`）。指针越过屏幕边缘之前就已按住的修饰键（按住 Shift 或 Cmd 再移过去点）会不会到对方那里，没有测试，要在两台电脑上试。
