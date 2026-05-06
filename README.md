## Whisper

[English](./README_en.md)

Whisper（土电话）是一款面向局域网的跨平台设备协作工具。它把文本、文件、剪贴板、Android 通知、系统声音和桌面键鼠共享放在一个对话式界面里，让同一网络里的电脑和手机可以快速互联。

当前版本：`0.0.31`

### 功能特点

- 在 Android、macOS、Linux 和 Windows 设备之间发送文本与文件。
- 支持大文件续传与传输状态恢复，断线重连后继续发送。
- 转发 Android 设备通知到已连接设备。
- 在桌面端共享系统声音，可把一台设备的声音播放到另一台设备。
- 在桌面端共享键盘和鼠标，支持 macOS、Windows、Linux 作为控制端或被控端。
- 支持互信设备自动连接，桌面端可配置开机自启动。
- 可单独启动 FTP 服务（alpha），用于临时文件访问。
- 支持浅色/深色主题和中英西三种语言。

### 工作原理

Whisper 使用 Flutter 开发，通过局域网设备发现和 WebSocket 连接在设备间传递消息、文件块、音频帧和键鼠事件。数据传输发生在局域网内，不依赖公网中转。

### 使用提示

1. 设备需要处于同一局域网，部分网络环境下自动发现可能失败，可手动输入 IP 地址连接。
2. 互信设备可自动连接；如果要长期使用桌面键鼠共享，建议开启桌面端开机自启动。
3. 桌面端拖放文件可以直接开始传输；移动端受系统文件访问限制，部分大文件可能需要先复制到应用缓存。
4. 写入文件前请确保接收设备有足够存储空间。
5. 当前传输未做端到端加密，请只在可信局域网内使用，不要传输敏感数据。
6. Linux 设备发现依赖 Avahi；Linux 键鼠共享当前依赖 X11 显示会话。
7. Linux 系统声音共享依赖 PulseAudio/PipeWire Pulse 兼容层。
8. Windows 安装包仍在改进中，ARM 设备兼容性未充分验证。

### 安装

[主页](https://2.127014.xyz/whisper) | [Latest Release](https://github.com/lawnvi/whisper/releases)

### Linux 安装

如果您的 Linux 系统未安装 Avahi（用于设备发现），请运行以下命令：

```shell
sudo apt install -y avahi-daemon avahi-discover avahi-utils libnss-mdns mdns-scan
```

如需使用 Linux 音频共享，请确保系统具备 PulseAudio 或 PipeWire Pulse 兼容服务。

### 截图展示

<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_4.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_2.png" width="24%" style="border-radius: 6px;"/>
</div>
<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_3.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_5.png" width="24%" style="border-radius: 6px;"/>
</div>

### 说明

Whisper 是一个个人使用场景优先的开源项目，目标是替代“文件传输助手”这类临时中转方式。如果遇到问题，欢迎在 GitHub Issues 反馈。
