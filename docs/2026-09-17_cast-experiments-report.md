# AirPlay 与 Wi-Fi Direct 投屏实验记录

当前产品只保留 DLNA 视频投屏。AirPlay 和 Miracast 接入已移除，本文保留实验方案、实际效果和后续验证入口，不能视为功能支持承诺。

## 实验范围与结论

| 路线 | 当时的实现 | 实际观察 | 本次决定 |
|---|---|---|---|
| DLNA / UPnP AV | Dart 接收媒体地址，交给桌面播放器 | 多个手机视频 App 能发现并播放；部分平台仅提供 720p 投屏入口 | 保留，并改为 Whisper 内置播放 |
| AirPlay | Whisper 管理 UxPlay 子进程，GStreamer 解码播放 | Mac 到 Windows 出现过可见但连接超时；用户后来反馈卡顿、不跟手、清晰度不理想 | 移除，不宣称协议本身不可行 |
| Windows Miracast | 探测系统能力并启动 Windows“无线显示器”，原生桥读取接收状态 | 小米 17 曾连接成功并能通过电脑控制手机，之后出现发现不稳定、连接无响应 | 移除；主要接收能力来自 Windows |
| Linux Miracast | 评估系统工具和网卡条件，能力状态保持不可用 | 没有完成接收会话和实机投屏验证 | 不列为已实现 |

主要测试组合是小米 17、Mac，以及两类 Windows 电脑：仅以太网且没有无线网卡的电脑，以及 Windows 11、Intel AX211 无线网卡的电脑。未建立覆盖多个手机品牌、驱动版本和接入点的测试矩阵，也没有记录可重复比较的延迟、码率或画质分数。

## AirPlay：实现与发现链路

### 当时如何接入

Whisper 的接收管理器与聊天配对独立，启动 UxPlay，并处理启动失败、进程退出和应用关闭时回收。实验使用 UxPlay **1.74 Experimental**，Windows 在 MSYS2 UCRT64 环境编译，播放使用 GStreamer；Mac 发送端使用系统“屏幕镜像”。

典型启动参数如下；其中 `-d` 仅用于诊断：

```sh
uxplay -n Whisper-Windows -nh -hls 3 -h265 -d
```

`-hls` 不代表所有视频 App 的 AirPlay URL 投屏都兼容；当时上游把 HLS 支持限定为部分发送路径。镜像、音频、HLS 应分别验收。上游还说明分辨率参数只是向发送端提出请求，最终发送格式可能不同。[UxPlay 实现说明](https://github.com/FDH2/UxPlay)

旧构建脚本默认拉取 `master`，没有把实验产物绑定到不可变提交，因此不能保证未来逐字节复现本次二进制；重新引入时必须先固定源码提交、GStreamer 版本和构建工具链。

### 可复用的排查结果

| 证据 | 发现 | 后续验证路径 |
|---|---|---|
| Windows 同时存在物理局域网地址、代理虚拟网卡和 Wi-Fi Direct 虚拟网卡 | 自动选网卡可能选错，服务广播与实际可达地址需要一致 | 检查网卡描述、SRV/A 记录和真实控制端口，不能只检查进程是否存在 |
| Mac 日志显示查询 AirPlay 服务的 SRV 后约 30 秒超时 | 当次连接尚未进入有效媒体播放，不能直接归因于解码慢 | 分开验证发现、地址解析、TCP/RTSP 握手、媒体接收和解码 |
| 同机存在占用/复用 UDP 5353 的其他进程；一次对照监听中，绑定 `0.0.0.0:5353` 收到 0 个 Mac 探测包，绑定物理地址收到 6 个 | Windows 通配地址绑定与多网卡/共享端口组合存在异常，单看端口列表不足以证明发现可用 | 固定同一发送端与探测间隔，对比两个绑定地址；不能把一次结果推广到所有 Windows |
| 让 Windows mDNS socket 绑定选中的局域网地址后，Mac 收到服务响应，`dns-sd -L` 能解析名称与端口 | 该调整改善了本次实验的发现链路 | 仍须独立验证连接、画面、重连、睡眠恢复和长期运行 |
| 用户反馈 AirPlay 实际投屏卡顿、跟手差、画质差 | 已有产品体验不满足要求 | 没有量化证据证明仅更换参数就能解决，也没有证据证明软件接收完全不可行 |

实验曾修改 UxPlay 的 `lib/mdnsd/mdnsd.c` 网卡选择，并通过 Whisper 自定义的 `UXPLAY_MDNS_IPV4` 环境变量传入选中地址；**这个变量属于实验补丁，不是上游通用配置**。后续临时诊断还将 Windows socket 的绑定地址从通配地址改为选定的本地地址。补丁和实验构建脚本已从产品代码删除，未来应针对固定的上游版本重新审查，而不是直接照搬行号。

另一个启动问题出现在缺少语言环境时的 HLS 初始化；当时给子进程补充 `LANG` 后继续验证。这类运行库和启动环境问题应与网络超时分开记录。不要用“进程存活 500 毫秒”代替可播放状态。

Mac 上可用以下命令观察发现与解析；设备名称按实际广播名称选择：

```sh
dns-sd -B _airplay._tcp local.
dns-sd -L Whisper-Windows _airplay._tcp local.
```

重新评估时，先用本地测试视频确认画面与声音，再测具体 App；记录实际分辨率、帧率、解码器、丢帧、CPU/GPU、音画同步和端到端延迟。必须包含两次以上断开重连、锁屏/唤醒以及同时运行代理和其他发现服务的情况。单纯发现成功不等于兼容性和体验合格。

## Wi-Fi Direct / Miracast：实现与边界

### 为什么广播成“电视”不够

最早的局域网服务探针没有让小米控制中心的系统投屏发现 Mac，而视频 App 的 DLNA 列表可以发现接收端。这是两个不同入口的实测结果，不能用 DLNA 发现成功推断系统镜像也应成功。

Windows 的 `MiracastReceiver` 接口明确要求设备支持 Wi-Fi Direct；它还提供 `GetStatus`、设置和接收会话接口。[Microsoft API 文档](https://learn.microsoft.com/en-us/uwp/api/windows.media.miracast.miracastreceiver?view=winrt-26100)

仅以太网且没有无线网卡的测试机不能通过本次采用的系统 Miracast 接收路径补出 Wi-Fi Direct 能力。即使电脑有 Wi-Fi，也需要验证驱动和接收能力，而不是仅凭网卡名称显示“支持”；Microsoft 也把无线和图形驱动作为投屏体验的重要条件。[Microsoft 硬件要求](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/wireless-projection-pc-manufacturers)

### Windows 桥接做了什么

实验原生插件使用 `Windows.Media.Miracast` 读取系统状态，通过 Flutter MethodChannel 向设置页返回结果，并提供打开系统接收器和系统设置的入口；WinRT 查询在后台执行，结果送回 UI 线程。真正的接收窗口、无线协商、解码和反向输入来自 Windows“无线显示器”。

最初只检查网卡/组件时，Whisper 的“不可用”与系统接收器实际状态可能不一致，后来改为读取原生状态。这仍不能替代连接成功判断：曾出现系统返回 `MiracastSupported / Listening`，但小米搜索或连接失败的情况。

| 证据 | 发现 | 后续验证路径 |
|---|---|---|
| 小米曾成功连接 Windows 系统接收器，且支持电脑反向操作手机 | 该硬件组合具有可行路径；成功不代表 Whisper 实现了独立 Miracast 接收器 | 先在 Whisper 完全退出时建立系统接收基线，再比较集成后的行为 |
| 用户随后看到设备时有时无、点击连接没反应 | 连续使用与重连体验不合格 | 分别记录发现、Wi-Fi Direct 配对、会话建立和首帧时间 |
| Windows WLAN 事件出现 `0x48005`，描述为动态密钥交换超时 | 当次失败落在无线协商路径，不是 Whisper 聊天加密握手 | 结合相同时间窗口的驱动、发送端和接收器日志排查，不通过改聊天协议修复 |
| 通过 SSH 启动的 GUI 进程和交互桌面会话不同 | 后台进程存在并不等于用户桌面上的接收器正在监听 | 通过交互用户会话启动，验证窗口、实际状态和手机连接；结束后移除临时启动任务 |

Windows 可用这些只读命令建立检查基线：

```powershell
netsh wlan show drivers
Get-NetAdapter -Physical
Get-WindowsCapability -Online -Name 'App.WirelessDisplay.Connect*'
Get-WinEvent -LogName 'Microsoft-Windows-WLAN-AutoConfig/Operational' -MaxEvents 50
```

本次没有把 Linux 的 `miracle-sinkctl` 加上固定网卡编号就作为成品接入：那会有误选网卡的问题，也没有解决设备权限、会话建立和桌面播放集成。Linux 和 macOS 的系统镜像接收不能根据 Windows 的成功案例直接推导为已支持。

## 留给下一次的决策依据

保留的是接收器与 Whisper 配对分离、显式控制生命周期、选择真实局域网地址、错误状态可见、退出时释放播放资源这些设计；没有保留实验后台服务和系统投屏入口。

重新引入 AirPlay 前，应先确定需要的是视频 App 投屏还是完整屏幕镜像，再把媒体渲染集成到 Whisper，并取得可重复的延迟/画质数据。重新引入 Miracast 前，应先证明目标机型在系统接收器中能稳定连接和重连，再评估 Whisper 自己需要增加的价值。

当前 DLNA 视频流清晰度取决于 App 给出的媒体地址；多款 App 只展示 720p 入口是本次用户观察，推测与平台策略有关，但没有证明所有 App 的限制来源都相同。没有尝试伪装商业电视型号、绕过会员权限或处理受保护视频。
