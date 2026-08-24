# Whisper

![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Android%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)

[中文](./README.md)

> A LAN collaboration app for personal devices. Whisper uses a paired, encrypted local connection between your computers and phones to send text, files, notifications, audio, and keyboard/mouse input.
> This project is not related to OpenAI's Whisper speech recognition model.

> Android 10 and later do not allow background apps to read new clipboard content copied in another app. Whisper's Android foreground service keeps the LAN connection alive but cannot bypass this platform restriction; copied text is synchronized after Whisper returns to the foreground.

## Download

[Download the latest release](https://github.com/lawnvi/whisper/releases/latest)

## What It Solves

Whisper is built for a small but frequent problem: your computers, phones, and spare devices are right next to you, yet moving a bit of text, a file, or audio still often means using a chat app, cloud drive, or cable.

It is not a cloud drive or a public remote desktop tool. Whisper works inside a trusted LAN by default, and devices establish explicit peer-to-peer connections. It is useful for quick transfers between your own devices, receiving Android notifications, sharing desktop system audio, or moving one keyboard and mouse across desktop machines.

## Screenshots

### File Transfer

![Whisper file transfer](.github/image/file-share.png)

| Audio Sharing | Keyboard/Mouse Sharing |
| --- | --- |
| ![Whisper audio sharing](.github/image/audio-share.png) | ![Whisper keyboard and mouse sharing](.github/image/keyboard-share.png) |

## Features

- **Encrypted transfers**: paired text, files, clipboard data, notifications, audio, and keyboard/mouse control use authenticated encrypted direct channels with visible identity and trust state.
- **Direct multi-device connections**: one device can connect to multiple computers or phones, with visible and explicit connection state.
- **Chat-style transfer**: send text and files in conversations while auto-synced clipboard content stays out of history; view images full screen, play audio inline, open video in the system player, and select multiple messages for deletion.
- **System quick send**: use the Android share sheet, desktop context menus, or a global hotkey without opening a conversation first. Desktop drafts can wait for a trusted device to reconnect; unsent Android system shares are discarded when the app restarts.
- **QR pairing and diagnostics**: pairing codes bind the LAN endpoint to the device identity, while failures identify Wi-Fi, address, service, firewall, identity, or version problems.
- **Transfer assistant**: search, save, and copy historical text without adding auto-synced clipboard content to conversations.
- **Controlled clipboard sync**: auto-sync is off by default. Regular sessions send to the current trusted device, while a multi-device keyboard/mouse workspace syncs its connected members. Desktop apps can watch while Whisper is running, while Android 10 and later can only read new clipboard content when Whisper is in the foreground.
- **Streaming verification and resume**: calculate SHA-256 while receiving, normally avoiding a second full-file read at completion, and resume from the last acknowledged offset after a disconnect.
- **System audio sharing**: stream system audio from one desktop device to one or more playback devices, with basic speaker groups and channel roles.
- **Keyboard and mouse sharing**: share one keyboard and mouse across multiple trusted desktops, with text, image, and file clipboard content following the workspace.
- **Desktop experience**: tray integration, launch at startup, close to tray, reveal files in the system file manager, drag files out from desktop messages, light/dark themes, and multilingual UI.

## Recent Updates (0.0.48)

- LAN file-transfer throughput is higher, and large-file SHA-256 verification follows the receive stream to reduce the wait after transfer.
- Interrupted transfers are resumed manually by the sender, while the receiver only shows the interrupted state to avoid conflicting actions.
- GitHub-powered in-app updates are available, and desktop builds exit safely before installing an update.
- macOS provides separate Apple silicon and Intel packages, with fixes for cross-architecture startup and remote Caps Lock switching.
- Mobile full-screen image previews and image transitions are smoother, and Android only posts an extra connection-request alert on the lock screen.

## Connection

Whisper first tries LAN discovery. When two devices are on the same network and both have Whisper open, they should usually appear in each other's device list. Select a discovered device, then confirm the connection request on the receiving side.

If discovery is unavailable, open the QR pairing dialog and scan the code shown by the other device, or enter its LAN IP address and service port manually. The QR code carries both the LAN endpoint and device identity, so there is no extra password to enter. The default service port is `10002`, and it can be changed in Settings under "Server Port"; first-time pairing still requires both devices to verify and confirm the same pairing code.

Linux discovery depends on Avahi. If the network blocks mDNS/Bonjour, manual IP connection is usually more reliable.

## Developer Quick Start

### 1. Prepare the Environment

Install Flutter stable, and make sure the Flutter SDK satisfies Dart `>=3.11.0 <4.0.0`.

```bash
flutter doctor
```

Prepare the toolchain for your target platform:

- Android: Android Studio / Android SDK
- macOS / iOS: Xcode
- Windows: Visual Studio C++ toolchain
- Linux: Flutter Linux desktop dependencies, Avahi, PulseAudio or PipeWire Pulse, GStreamer, libsecret/keybinder/jsoncpp, and an available system keyring

### 2. Install Dependencies and Run

```bash
flutter pub get
flutter run
```

For local macOS debugging, the repository script is recommended. It builds, signs, and launches the debug app:

```bash
sh script/build_and_run.sh
```

### 3. Verify

```bash
flutter analyze
flutter test
```

### 4. Package and Regenerate Code

Package a macOS DMG:

```bash
sh script/build_and_run.sh package-macos
```

Regenerate code after database or localization changes:

```bash
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n
```

## Usage

### Send Text or Files

Open a conversation with a connected device, type text directly, or use the attachment button to select files. Images open in a full-screen viewer, audio plays inline, and video or other files open through an available system app. Long-press a message and choose multi-select to batch-delete chat records. On desktop, received files can also be revealed in the system file manager or dragged out of a message.

On Android, choose Whisper directly from the system share sheet. On desktop, use the file context-menu entry or press `Cmd+Option+V` on macOS and `Ctrl+Alt+V` on Windows/Linux to quick-send the current clipboard content.

### Automatically Sync the Clipboard

Clipboard auto-sync is off by default. Regular sessions send to the current connected, trusted device; a multi-device keyboard/mouse workspace syncs its connected members, with the most recent copy taking precedence. Synchronized text is not stored in conversation history. Desktop builds can watch text while Whisper remains running. Image and file clipboard sharing is limited to desktop keyboard/mouse workspaces and follows per-file and batch size limits.

Android currently synchronizes text clipboard content only. Under the [Android 10 clipboard privacy restriction](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data), Whisper cannot read content copied in another app while Whisper is in the background. The foreground-service notification only keeps the LAN connection and receiving path alive. Whisper checks the clipboard and sends changes after it returns to the foreground.

### Share System Audio

On desktop, open audio sharing from the device tools area and choose one or more connected devices that support audio playback. Multi-device playback supports basic synchronization and channel roles, but it is not a professional audio system.

### Share Keyboard and Mouse

On desktop, open the keyboard/mouse sharing workspace and arrange the local and target screens. Once enabled, the pointer crosses from the configured screen edge to the target device, and keyboard input follows the active target.

### Listen to Android Notifications

After granting notification listener permission on Android, choose which apps to listen to. Whisper processes notification content according to your selection, which is useful for short messages such as verification codes.

## Platform Status

| Platform | Status |
| --- | --- |
| Android | Primary mobile platform, with system sharing, QR pairing, media previews, one unified foreground notification, notification listening, audio playback, and foreground text clipboard sync. Android 10 and later cannot read new clipboard content in the background. |
| macOS | Primary desktop validation platform, with system services and global quick send, tray support, file drag-out, audio sharing, keyboard/mouse sharing, and packaging scripts. |
| Windows | Desktop target with native integration for windows, single-instance behavior, audio, and keyboard/mouse sharing. |
| Linux | Desktop target. Discovery depends on Avahi, system audio sharing uses PulseAudio or PipeWire Pulse, message audio playback uses GStreamer, and keyboard/mouse sharing currently focuses on X11. |
| iOS | Flutter runner is kept, but capabilities are limited by the system and not fully tested. |

## Boundaries and Security

- Authenticated direct sessions use X25519 session keys and XChaCha20-Poly1305 to protect application data. LAN discovery and connection metadata remain visible, local databases and staged files are not encrypted at rest, and the implementation has not received an independent cryptographic audit.
- Whisper does not provide public relays, hub forwarding, or transitive trust.
- Files, audio, and keyboard/mouse input all require connection and capability negotiation; they are not designed as silent background control paths.
- Keyboard/mouse sharing is for nearby personal devices, not unattended remote control.
- Whisper prioritizes direct, controllable, and recoverable LAN workflows. It is not meant to replace professional sync, remote control, or MDM systems.

## What It Is Not

- **Not a cloud drive**: Whisper is not built for public-network sync or long-term multi-device storage. Its core is immediate nearby transfer.
- **Not a chat app**: conversations are just the interaction shell. The goal is moving files, notifications, audio, and input between devices.
- **Not remote desktop**: keyboard/mouse sharing only transfers input. It does not stream the screen and is not intended for unattended access.
- **Not a professional audio system**: audio groups provide usable multi-device playback and channel roles, but do not promise professional phase synchronization.

## License

[MIT](./LICENSE)
