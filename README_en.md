## Whisper

[中文](./README.md)

Whisper is a cross-platform LAN collaboration app for nearby devices. It brings text, files, clipboard sharing, Android notifications, system audio sharing, and desktop keyboard/mouse sharing into a chat-style interface.

Current version: `0.0.31`

### Features

- Send text and files between Android, macOS, Linux, and Windows devices.
- Resume large file transfers after reconnecting.
- Forward Android notifications to connected devices.
- Share desktop system audio from one device to another.
- Share keyboard and mouse between desktop devices, with macOS, Windows, and Linux support.
- Auto-connect mutually trusted devices and enable launch-at-startup on desktop.
- Start a standalone FTP service (alpha) for quick temporary access.
- Supports light/dark themes and Chinese, English, and Spanish UI text.

### How It Works

Whisper is built with Flutter. Devices discover each other on the local network and communicate through WebSocket channels for messages, file chunks, audio frames, and keyboard/mouse events. Transfers stay inside your LAN and do not require a public relay.

### Usage Notes

1. Devices should be on the same LAN. If discovery fails in some network environments, connect manually with the target IP address.
2. Mutually trusted devices can reconnect automatically. For desktop keyboard/mouse sharing, launch-at-startup is recommended.
3. Desktop drag-and-drop can start transfers directly. On mobile, OS file access rules may require large files to be copied into the app cache first.
4. Make sure the receiving device has enough free storage before sending files.
5. Transfers are not end-to-end encrypted yet. Use Whisper only on trusted local networks and avoid sensitive data.
6. Linux discovery depends on Avahi. Linux keyboard/mouse sharing currently requires an X11 display session.
7. Linux system audio sharing depends on PulseAudio or the PipeWire Pulse compatibility layer.
8. Windows packaging is still being improved, and ARM device compatibility has not been fully verified.

### Installation

[Home page](https://2.127014.xyz/whisper) | [Latest Release](https://github.com/lawnvi/whisper/releases)

### Linux Installation

If Avahi is not installed on your Linux system, run:

```shell
sudo apt install -y avahi-daemon avahi-discover avahi-utils libnss-mdns mdns-scan
```

For Linux audio sharing, make sure PulseAudio or PipeWire Pulse compatibility is available.

### Screenshots

<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_4.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_2.png" width="24%" style="border-radius: 6px;"/>
</div>
<div style="display: inline-block; text-align: center;">
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_3.jpg" width="74%" style="border-radius: 6px;"/>
    <img src="https://github.com/lawnvi/whisper/blob/dev/.github/image/img_5.png" width="24%" style="border-radius: 6px;"/>
</div>

### Notes

Whisper is an open-source project focused on personal LAN workflows. It is meant to replace temporary relay tools such as file-transfer assistants. Please report issues through GitHub Issues.
