import 'dart:io';

/// 对等设备都在同一局域网,连接必须走两台设备能直接互达的那条链路。
///
/// `dart:io` 的 [HttpClient] 默认会读取 `HTTP_PROXY` / `HTTPS_PROXY`
/// 环境变量;从开着代理的终端启动 app 时,主会话拨号和 `/input`、`/audio`
/// 升级都会被送去代理,代理剥掉 `Upgrade` 头,对端只看到普通 GET 而回 400。
/// 所有对等连接统一用这里的客户端,关闭代理解析。应用内更新下载不在此列。
HttpClient newDirectPeerHttpClient() =>
    HttpClient()..findProxy = (_) => 'DIRECT';
