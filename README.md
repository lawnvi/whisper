<div align="center">

<img src="assets/app_icon_round.png" width="96" alt="Whisper 图标">

# Whisper

在自己的电脑和手机之间，直接传文本、文件、剪贴板、声音和键鼠。

[![Release](https://img.shields.io/github/v/release/lawnvi/whisper?include_prereleases&label=release)](https://github.com/lawnvi/whisper/releases)
![Platform](https://img.shields.io/badge/platform-Android%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

[官网](https://whisper.127014.xyz/zh) · [下载](https://github.com/lawnvi/whisper/releases) · [使用指南](docs/user-guide.md) · [English](./README_en.md)

</div>

![Whisper 文件传输](.github/image/file-share.png)

Whisper 是一个局域网协作工具。设备配对后通过加密通道直接相连，数据不经过任何服务器；一台设备可以同时连接多台电脑和手机。

> 本项目与 OpenAI 的 Whisper 语音识别模型无关。

## 功能

| 功能 | 说明 |
| --- | --- |
| **文本与文件** | 像聊天一样发送；文件断线后可续传，接收时自动校验 |
| **文件夹** | 桌面端可以直接发整个文件夹，不用先打包，对方收到同样的目录结构 |
| **浏览文件** | 像用本机的文件管理器一样浏览对方的文件，可以拷贝、新建、重命名和删除；对方每次确认，也可以设为始终允许 |
| **挂载到本机** | 把对方的文件挂成访达、资源管理器或 Linux 文件管理器里的一个位置，用系统自带的方式打开（只读） |
| **共享链接** | 给没装 Whisper 的设备发一个链接，对方用浏览器就能下载本机的文件或文件夹，可以加密码 |
| **窗口流转** | 在手机、平板或另一台电脑上打开这台电脑的窗口或安卓手机上的应用，直接操作；也可以把窗口送到另一台设备 |
| **快捷发送** | Android 分享菜单、桌面右键菜单或全局快捷键，不用先打开会话 |
| **剪贴板同步** | 在一台设备上复制，到另一台粘贴（默认关闭） |
| **键鼠共享** | 多台电脑共用一套键盘鼠标，指针移到屏幕边缘就切换过去 |
| **手机控制电脑** | Android 手机充当体感鼠标、触控板和键盘 |
| **系统音频共享** | 把电脑的声音送到一台或多台设备播放 |
| **通知转发** | 把 Android 上选定 App 的通知（比如验证码）发到电脑 |
| **桌面截图** | 点选窗口或框选区域，截图直接进剪贴板 |
| **电视投屏** | 在电脑上接收视频 App 的 DLNA 投屏（实验性） |

| 音频共享 | 键鼠共享 |
| --- | --- |
| ![Whisper 音频共享](.github/image/audio-share.png) | ![Whisper 键鼠共享](.github/image/keyboard-share.png) |

## 下载

到 [Releases](https://github.com/lawnvi/whisper/releases) 页面下载对应平台的安装包。

| 平台 | 系统要求 | 选哪个文件 |
| --- | --- | --- |
| Android | 7.0 及以上 | 多数手机选 `android-arm64-v8a.apk`，不确定就选 `android-universal.apk` |
| macOS | 10.15 及以上 | Apple 芯片选 `macos-arm64.dmg`，Intel 选 `macos-x86_64.dmg` |
| Windows | 10 / 11，64 位 | `windows-x86_64.exe` |
| Linux | x86_64 | `.deb`、`.rpm` 或 `.AppImage` |

iOS / iPadOS：项目没有付费的 Apple 开发者账号，所以不上架 App Store。每次发布附带一个未签名的 `ios-unsigned.ipa`，可以用 AltStore、Sideloadly 等工具以自己的 Apple ID 签名安装（免费 Apple ID 签的应用每 7 天要重签一次）。目前只在一台 iPad 上测过窗口流转和浏览文件，其他功能没有经过真机测试，遇到问题欢迎反馈。

## 快速开始

1. 在两台设备上安装并打开 Whisper，连到同一个局域网。
2. 在设备列表里点击对方，双方核对并确认配对码。
3. 进入会话开始发送。键鼠共享、音频共享等入口在桌面端的设备工具区。

> 列表里没有出现对方？点设备列表顶部的二维码图标，扫码或输入对方的 IP 和端口（默认 `10002`）。

## 常用操作

| 想做的事 | 怎么做 |
| --- | --- |
| 发送剪贴板里的内容 | macOS 按 `Cmd+Option+V`，Windows / Linux 按 `Ctrl+Alt+V` |
| 从其他 App 发送 | Android 用系统分享菜单，桌面用文件右键菜单 |
| 发送文件夹 | 桌面端把文件夹拖进会话，或点附件按钮选「文件夹」 |
| 浏览对方的文件 | 在会话右上角打开设备详情，点「文件」；桌面端可以把文件直接拖进访达或资源管理器 |
| 在系统文件管理器里打开对方的文件 | 在设备详情里打开「挂载到本机」，以后连上就自动挂载；在系统里推出后，这个开关会自动关闭 |
| 给没装 Whisper 的设备发文件 | 在「文件」里右键本机的文件或文件夹（手机上长按），选「创建共享链接…」 |
| 操作对方的窗口或应用 | 在设备详情里点「流转」，选一个窗口或应用打开 |
| 开始键鼠共享 | 打开键鼠工作区，把对方屏幕拖到本机屏幕旁边，点「启动」 |
| 退出键鼠共享 | 在主控端按 `Ctrl+Alt+Esc`（macOS 为 `Control+Option+Esc`） |
| 用手机控制电脑 | 在 Android 的会话里点「控制电脑」，再点顶部的开始按钮 |
| 截图 | 桌面端点截图按钮或按自定义快捷键，按 `Esc` 取消 |

每项功能的完整说明见 [使用指南](docs/user-guide.md)。

## 平台支持

| 功能 | Android | macOS | Windows | Linux |
| --- | :---: | :---: | :---: | :---: |
| 文本与文件 | ✅ | ✅ | ✅ | ✅ |
| 文件夹 | 仅接收 | ✅ | ✅ | ✅ |
| 浏览文件 | ✅ | ✅ | ✅ | ✅ |
| 挂载到本机 | 只能被挂载 | ✅ | ✅ | 需要 fuse3 |
| 共享链接 | ✅ | ✅ | ✅ | ✅ |
| 窗口流转：接收 | ✅ | ✅ | ✅ | ✅ |
| 窗口流转：被流转 | Android 10 及以上，需打开 USB 调试或无线调试 | ✅ | ✅ | 仅 GNOME（Wayland） |
| 剪贴板同步 | 仅文本，需在前台 | ✅ | ✅ | ✅ |
| 键鼠共享 | — | ✅ | ✅ | 仅 X11 |
| 手机控制电脑 | 控制端 | 被控端 | 被控端 | 被控端，仅 X11 |
| 系统音频共享 | 仅播放 | ✅ | ✅ | ✅ |
| 通知转发 | 发送 | 接收 | 接收 | 接收 |
| 桌面截图 | — | ✅ | ✅ | 取决于桌面环境 |
| 电视投屏接收 | — | ✅ | ✅ | ✅ |

iOS / iPadOS 版可以接收流转的窗口、浏览其他设备的文件。

Linux 的自动发现依赖 Avahi。视频预览和电视投屏需要系统装有 libmpv，窗口流转需要 FFmpeg 的 libavcodec，缺了这些其他功能照常可用。让别的设备流转本机窗口时，要先在设置里装一个 GNOME 组件，装完注销并重新登录一次。

## 常见问题

| 问题 | 解决办法 |
| --- | --- |
| 设备列表里看不到对方 | 确认两台设备在同一个网络并且都打开了 Whisper。网络禁用了 mDNS / Bonjour 时无法自动发现，改用二维码或 IP 连接 |
| Android 上复制的内容没有同步 | Android 10 及以上不允许后台应用读取剪贴板，回到 Whisper 后会自动补发 |
| 指针留在另一台设备上回不来 | 在主控端按 `Ctrl+Alt+Esc`（macOS 为 `Control+Option+Esc`），键鼠立即回到本机 |
| Windows 上指针一顿一顿，或传输时快时慢 | 检查「设置 → 系统 → 投影到此电脑」，不用无线投屏就设为「始终关闭」 |
| macOS 上键鼠共享没有反应 | 按提示在系统设置里授予辅助功能权限，然后重新打开 Whisper |
| Windows 锁屏或弹出 UAC 时无法操作 | 需要安装包附带的系统服务，见[使用指南](docs/user-guide.md#windows-锁屏与-uac) |

## 安全说明

- 配对后的数据通过 X25519 和 XChaCha20-Poly1305 加密的直连通道传输。
- 局域网发现和连接元数据不加密，本地数据库和收到的文件也不做静态加密。
- 只在局域网内直连，没有公网中继。实现未经独立的密码学审计。
- 键鼠共享面向身边的自有设备，不是无人值守的远程控制方案。

## 从源码构建

建议使用 Flutter 3.44.9（stable），并准备好目标平台的工具链。

```bash
flutter pub get
flutter run
flutter analyze && flutter test
```

macOS 上请用 `./script/build_and_run.sh`，它会构建、签名并启动应用。Linux 还需要 Avahi、PulseAudio 或 PipeWire Pulse、GStreamer、libsecret、keybinder、jsoncpp、libmpv、libepoxy 和 libpipewire-0.3 的开发包。代码约定见 [AGENTS.md](AGENTS.md)。

## License

[MIT](./LICENSE)
