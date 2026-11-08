# 手机摄像头、麦克风和电话：方案调研

2026-11-08 决定暂不做这三项。本文记录当时查明的做法和限制，供以后重新考虑时参考，不是功能承诺。

手机当摄像头和麦克风的半成品在本地分支 `wip/phone-camera`（提交 `900603f`，**只在维护者的 Mac 上，没有推送**），方案、进度和 Linux 原型的实测数据见该分支的 `wip/phone-camera/README.md`。本文补充的是 2026-11-08 读同类开源项目源码后得到的新结论，主要解决了那次暂停的两个原因：macOS 要付费账号、Windows 不签名能否注册没验证。

## 结论一览

| 能力 | Windows | macOS | Linux |
|---|---|---|---|
| 手机当摄像头 | Windows 11 可行：`MFCreateVirtualCamera` 加自写的 Media Foundation 采集源 DLL。Windows 10 不行 | 自己的 Camera Extension 需要付费开发者账号；不付费可以把画面写进 OBS 的虚拟摄像头（用户自装 OBS） | 可行：PipeWire 摄像头节点（不要 root，部分应用默认看不到）或 v4l2loopback（要 root） |
| 手机当麦克风 | 自带虚拟麦克风要签名的内核音频驱动，做不到；可以播进用户自装的 VB-CABLE | 同左，播进用户自装的 BlackHole | 可行：null-sink 加 remap source，不要 root |
| 在电脑上管通话（声音留在手机上） | 可行，只靠安卓权限 | 可行 | 可行 |
| 在电脑上听和说 | 不可靠：系统接口从 Windows 11 22H2 起拒绝第三方应用 | 可行：电脑当手机的蓝牙耳机 | 可行：BlueZ 加 PipeWire |

## 摄像头

### 手机端

相机采集后硬件编码成 H.264，经已认证的连接发到电脑。我们分支里的写法是 Camera2 → GL 转正（Camera2 不会帮编码器转方向）→ MediaCodec。参考实现见 NectarLink 的 `android/.../webcam/CameraEncoder.kt` 和 `WebcamService.kt`。

### Windows 11

两个项目都用系统的 `MFCreateVirtualCamera`，再加一个自己写的 Media Foundation 采集源 DLL。TwinDesk 的具体做法（`windows/vcam.js`、`windows/scripts/vcam-install.ps1`）：

- 加载这个 DLL 的是系统的 Frame Server 服务，以 Local Service 身份运行，看不到当前用户的注册表类和目录，所以 DLL 要为整台电脑注册：拷到 `ProgramData` 下，再用 `regsvr32` 注册，需要一次管理员确认。
- 文件名带构建号，因为已加载的 DLL 不能覆盖；旧副本等没人加载时再删。目录权限只允许管理员写入，Local Service 和普通用户只读。
- 应用进程把解码后的 NV12 画面（1280×720）通过共享内存交给 DLL。
- Windows 10 没有这个接口。

TwinDesk 的发布包没有代码签名，也在用这个做法，说明不签名大概率能注册，但我们还没有自己验证。风险：它的 DLL 被杀毒软件误报并隔离过（TwinDesk issue #111）。

### macOS

- 自己的虚拟摄像头要做成 Camera Extension，放在 App 包的 `Contents/Library/SystemExtensions` 下，用 `OSSystemExtensionRequest` 激活，第一次要用户在系统设置里允许。macOS 只从 `/Applications` 里、用 Developer ID 签名、并带有允许系统扩展的描述文件的 App 加载它，所以需要付费开发者账号。
- 不付费的办法：TwinDesk 默认把画面写进 **OBS 自带的虚拟摄像头**（OBS Studio 自己签好的 Camera Extension），任何构建都能写。用户需要装 OBS，并在 OBS 里点一次「启动虚拟摄像头」，之后它出现在「系统设置 › 通用 › 登录项与扩展 › 摄像头扩展」里。写入方式见 TwinDesk 的 `mac/vcam.js` 和 `mac-helper/Sources/twindesk-vcam/main.swift`（CoreMediaIO）。我们没有验证过。

### Linux

- 我们的原型用 PipeWire `Video/Source` 节点，不需要 root，但默认设置下的 Firefox 和 Chrome 看不到它（兼容性表见分支 README）。
- 两个项目都用 v4l2loopback，所有只认 V4L2 的应用都能看到，但要 root 加载模块。NectarLink 的 Linux 一键安装脚本会顺带把它配好。

## 麦克风

- **Linux**：建一个 null-sink，再从它的 monitor 映射出一个输入源（TwinDesk 用 `pactl`，在 PulseAudio 和 PipeWire 的 pulse 服务上都能用）。我们的原型实测延迟中位数 35–38 ms。
- **Windows 和 macOS**：系统没有给普通程序开放虚拟采集设备的接口，自带虚拟麦克风要写驱动（Windows 是签名的内核音频驱动，macOS 是 AudioServerPlugIn）。两个项目都没写，而是按名字找用户自己装的虚拟声卡（Windows 的 VB-CABLE，Mac 的 BlackHole），把手机的声音播进去，声卡另一端就是系统里的一个麦克风；没装时从扬声器放。NectarLink 把自带驱动列为以后单独的一步。
- **手机端**：`AudioRecord` 用 `VOICE_COMMUNICATION` 模式、48 kHz 单声道，开回声消除和降噪；前台服务类型要带 microphone。

## 电话

### 第一层：在电脑上管通话，声音留在手机上

- 安卓权限：`READ_PHONE_STATE`、`READ_CALL_LOG`、`ANSWER_PHONE_CALLS`、`CALL_PHONE`、`READ_CONTACTS`。Whisper 不上架商店，不受商店对通话记录权限的限制。
- 能做到：来电弹窗显示联系人，接听、拒接、静音铃声、拒接并回短信，在电脑上拨号（双卡时选卡），通话记录和联系人，来电时暂停电脑上的音乐，挂断。
- 借 adb shell 级别的权限（我们窗口流转的安卓组件就跑在这个级别），安卓 12 起还能在电脑上静音、切免提、保持通话、按拨号键盘（DTMF）。
- 参考：NectarLink 的 `docs/guide/calls.md`、`android/.../calls/PhoneCalls.kt`；TwinDesk 的 `android/.../Calls.kt`。

### 第二层：在电脑上听和说

只能让电脑当手机的蓝牙耳机（Hands-Free Profile）。手机要先在系统的蓝牙设置里和电脑配对一次；电脑自己连着蓝牙耳机时，两条免提链路不能同时存在。

- **macOS**：`IOBluetooth` 里的 `IOBluetoothHandsFreeDevice`，声明来电显示、增强通话状态、远程音量、回声消除和降噪等特性，系统自己把通话声音接到 Mac 的扬声器和麦克风。需要蓝牙权限，不需要付费账号。参考 TwinDesk 的 `mac-helper/Sources/macshare-calls/main.swift`。
- **Linux**：BlueZ 加 PipeWire 或 PulseAudio。参考 NectarLink 的 `desktop/app/src/linux/bt_hfp.rs`。
- **Windows**：
  - `AudioPlaybackConnection` 只是 A2DP 媒体接收，不能双向通话。
  - `PhoneLineTransportDevice` 要求应用有包身份和受限能力。NectarLink 实测从 Windows 11 22H2 起第三方应用一律被拒（`E_ACCESSDENIED`），因此放弃，Windows 上通话声音留在手机。TwinDesk 用自签证书注册一个稀疏包取得包身份（安装器把证书加入受信任列表），失败时提示「Windows 把蓝牙通话留给了系统的手机连接，声音留在手机上」。
  - 其余路线要 WHQL 签名的内核蓝牙驱动。
  - 结论：Windows 上不能承诺在电脑上通话。

### 第三层：只走 Wi-Fi，不用蓝牙

- 安卓不让普通应用录通话声音；`AudioPlaybackCapture` 明确排除通话用途。
- adb shell 有 `CAPTURE_AUDIO_OUTPUT`。NectarLink 在一台三星 Galaxy A35（安卓 17、VoLTE）上实测：`VOICE_DOWNLINK` 和 `VOICE_CALL` 能录到对方的声音，`VOICE_UPLINK` 全是零。能不能录到由各厂商的音频 HAL 决定。
- 把电脑麦克风送进通话：shell 下用通话用途的 `AudioTrack` 能路由到 `TYPE_TELEPHONY` 设备而不报错，但对方能否听到没有证实。
- 结论：最多只能听，而且因机型而异，做不成功能。详见 NectarLink 的 `docs/research/hfp.md`。

## 和现有代码的衔接（2026-11-08）

- 媒体通道：照窗口流转的做法新开一条路由，见 `lib/window_stream/remote/window_stream_control.dart`、`window_stream_host.dart` 和 `lib/socket/media_upgrade_proof.dart`。
- 原生解码和虚拟设备：放进 `packages/window_stream_native/`，分支 README 第 5 节有 Linux 原型用的 ABI。
- 声音：`lib/audio/` 里的 Opus 编解码和包传输。
- adb shell 级别的操作：`lib/window_stream/adb/` 和 `android_agent/`。

## 如果重新开始

1. 先确认本地分支 `wip/phone-camera` 还在。
2. 补完安卓端采集，先跑通安卓 → Linux。
3. Windows：做不签名注册 MF 采集源的可行性验证，留意杀毒误报。
4. macOS：走 OBS 虚拟摄像头。
5. 麦克风：Linux 用自己的虚拟源，Windows 和 macOS 播进用户自装的虚拟声卡。
6. 电话：先做第一层；第二层只做 macOS 和 Linux。

## 许可证

两个参考项目都是 GPL（NectarLink 的核心库是 MPL-2.0），Whisper 是 MIT。只借鉴做法，不复制代码。

## 参考（固定到 2026-11-08 的提交）

- NectarLink（`54bf951`）
  - [docs/research/hfp.md](https://github.com/thtbee/nectarlink/blob/54bf9512704d3cf2a9e247adc73f8a30c4630bf5/docs/research/hfp.md)
  - [docs/guide/calls.md](https://github.com/thtbee/nectarlink/blob/54bf9512704d3cf2a9e247adc73f8a30c4630bf5/docs/guide/calls.md)
  - [docs/guide/cameras-and-audio.md](https://github.com/thtbee/nectarlink/blob/54bf9512704d3cf2a9e247adc73f8a30c4630bf5/docs/guide/cameras-and-audio.md)
  - [desktop/app/src/phone_mic.rs](https://github.com/thtbee/nectarlink/blob/54bf9512704d3cf2a9e247adc73f8a30c4630bf5/desktop/app/src/phone_mic.rs)
  - [desktop/app/src/linux/bt_hfp.rs](https://github.com/thtbee/nectarlink/blob/54bf9512704d3cf2a9e247adc73f8a30c4630bf5/desktop/app/src/linux/bt_hfp.rs)
  - [desktop/vcam/](https://github.com/thtbee/nectarlink/tree/54bf9512704d3cf2a9e247adc73f8a30c4630bf5/desktop/vcam)
- TwinDesk（`c56e081`）
  - [windows/vcam.js](https://github.com/InukaAsith/TwinDesk/blob/c56e081852ad011d21ea4db7f063fa54055a3250/windows/vcam.js)
  - [windows/scripts/vcam-install.ps1](https://github.com/InukaAsith/TwinDesk/blob/c56e081852ad011d21ea4db7f063fa54055a3250/windows/scripts/vcam-install.ps1)
  - [mac/vcam.js](https://github.com/InukaAsith/TwinDesk/blob/c56e081852ad011d21ea4db7f063fa54055a3250/mac/vcam.js)
  - [mac-helper/Sources/twindesk-vcam/main.swift](https://github.com/InukaAsith/TwinDesk/blob/c56e081852ad011d21ea4db7f063fa54055a3250/mac-helper/Sources/twindesk-vcam/main.swift)
  - [mac-helper/Sources/macshare-calls/main.swift](https://github.com/InukaAsith/TwinDesk/blob/c56e081852ad011d21ea4db7f063fa54055a3250/mac-helper/Sources/macshare-calls/main.swift)
  - [windows/callaudio.js](https://github.com/InukaAsith/TwinDesk/blob/c56e081852ad011d21ea4db7f063fa54055a3250/windows/callaudio.js)
  - [shared/mic.js](https://github.com/InukaAsith/TwinDesk/blob/c56e081852ad011d21ea4db7f063fa54055a3250/shared/mic.js)
