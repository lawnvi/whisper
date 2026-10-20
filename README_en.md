<div align="center">

<img src="assets/app_icon_round.png" width="96" alt="Whisper icon">

# Whisper

Move text, files, clipboard, audio, keyboard/mouse input, and app windows directly between your own computers and phones.

[![Release](https://img.shields.io/github/v/release/lawnvi/whisper?include_prereleases&label=release)](https://github.com/lawnvi/whisper/releases)
![Platform](https://img.shields.io/badge/platform-Android%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

[Website](https://whisper.127014.xyz/en) · [Download](https://github.com/lawnvi/whisper/releases) · [User guide](docs/user-guide_en.md) · [中文](./README.md)

</div>

![Whisper file transfer](.github/image/file-share.png)

Whisper is a LAN collaboration app. Paired devices connect to each other directly over an encrypted channel, and your data never passes through a server. One device can stay connected to several computers and phones at once.

> This project is not related to OpenAI's Whisper speech recognition model.

## Features

| Feature | What it does |
| --- | --- |
| **Text and files** | Send them like chat messages; transfers resume and are verified on arrival |
| **Folders** | Send a whole folder from a desktop, structure and all, without archiving |
| **File browsing** | Browse, copy, rename or delete the other device's files, with its approval |
| **Mount on this computer** | Open the other device's files in Finder, File Explorer or Linux (read-only) |
| **Share links** | Let a browser on a device without Whisper download your files |
| **Window flow** | Use a computer's windows or an Android phone's apps on another device |
| **Quick send** | Send from the Android share sheet, a context menu, or a global hotkey |
| **Clipboard sync** | Copy on one device, paste on another (off by default) |
| **Keyboard and mouse sharing** | A software KVM: one keyboard and mouse across several computers |
| **Phone controller** | Turn an Android phone into an air mouse, touchpad, and keyboard |
| **System audio sharing** | Play a computer's sound on one or more other devices |
| **Notification forwarding** | Show chosen Android apps' notifications, like codes, on your computer |
| **Desktop screenshots** | Click a window or drag a region and the capture lands on the clipboard |
| **TV casting** | Receive DLNA casts from video apps on your computer (experimental) |

| Audio sharing | Keyboard and mouse sharing |
| --- | --- |
| ![Whisper audio sharing](.github/image/audio-share.png) | ![Whisper keyboard and mouse sharing](.github/image/keyboard-share.png) |

## Download

Get the installer for your platform from the [Releases](https://github.com/lawnvi/whisper/releases) page.

| Platform | Requirement | Which file |
| --- | --- | --- |
| Android | 7.0 or later | `android-arm64-v8a.apk` for most phones, `android-universal.apk` if unsure |
| macOS | 10.15 or later | `macos-arm64.dmg` for Apple silicon, `macos-x86_64.dmg` for Intel |
| Windows | 10 / 11, 64-bit | `windows-x86_64.exe` |
| Linux | x86_64 | `.deb`, `.rpm`, or `.AppImage` |

iOS / iPadOS: the project has no paid Apple Developer account, so the app is not on the App Store. Every release includes an unsigned `ios-unsigned.ipa` that you can sign with your own Apple ID using a tool such as AltStore or Sideloadly (apps signed with a free Apple ID must be re-signed every 7 days). It has not been fully tested on a real device and may not work, so please report any problems.

## Quick start

1. Install and open Whisper on two devices connected to the same local network.
2. Select the other device in the device list, then check and confirm the pairing code on both sides.
3. Open the conversation and start sending. Keyboard/mouse sharing, audio sharing, and the other tools are in the device tools area on desktop.

> The other device is not listed? Select the QR icon above the device list, then scan its code or enter its IP address and port (`10002` by default).

## Everyday actions

| To do this | Do this |
| --- | --- |
| Send what is on the clipboard | Press `Cmd+Option+V` on macOS, `Ctrl+Alt+V` on Windows / Linux |
| Send from another app | Use the Android share sheet, or the file context menu on desktop |
| Send a folder | Drop it into a conversation, or choose "Folder" when attaching |
| Browse the other device's files | Select "Files" in Device Details (top right); drag files out to copy |
| Mount the other device's files | Turn on "Mount on this computer" in Device Details; eject to turn off |
| Send to a device without Whisper | Right-click or long-press it in "Files", then "Create Share Link…" |
| Use the other device's windows | Select "Flow" in Device Details, then choose a window or app |
| Start keyboard/mouse sharing | In the workspace, place the other screen beside yours, then "Start" |
| Leave keyboard/mouse sharing | Press `Ctrl+Alt+Esc` (`Control+Option+Esc` on macOS) |
| Control a computer from a phone | Select "Control computer" in the Android conversation, then start |
| Take a screenshot | Use the screenshot button or your shortcut on desktop; `Esc` cancels |

The [user guide](docs/user-guide_en.md) covers every feature in full.

## Platform support

| Feature | Android | macOS | Windows | Linux |
| --- | :---: | :---: | :---: | :---: |
| Text and files | ✅ | ✅ | ✅ | ✅ |
| Folders | Receive only | ✅ | ✅ | ✅ |
| File browsing | ✅ | ✅ | ✅ | ✅ |
| Mounting | Can be mounted only | ✅ | ✅ | Needs fuse3 |
| Share links | ✅ | ✅ | ✅ | ✅ |
| Window flow: view | ✅ | ✅ | ✅ | ✅ |
| Window flow: share | Android 10+, via adb | ✅ | ✅ | GNOME 45+ or KDE Plasma 6 |
| Clipboard sync | Text, foreground only | ✅ | ✅ | ✅ |
| Keyboard & mouse | — | ✅ | ✅ | X11, GNOME or KDE Plasma |
| Phone controller | Controls | Controlled | Controlled | Controlled, as above |
| System audio | Playback only | ✅ | ✅ | ✅ |
| Notifications | Sends | Receives | Receives | Receives |
| Screenshots | — | ✅ | ✅ | Depends on desktop |
| TV casting receiver | — | ✅ | ✅ | ✅ |

On Linux, discovery depends on Avahi. Video previews and TV casting need libmpv, and window flow needs FFmpeg 4 or later; everything else works without them. Showing this computer's windows on other devices needs a Wayland session (X11 can only view for now) and an H.264 encoder in FFmpeg (x264 or openh264; Fedora ships without one). On GNOME, also install the GNOME component from Settings, then log out and back in once; KDE Plasma needs nothing installed and asks for no permission.

On Wayland, keyboard and mouse sharing supports GNOME and KDE Plasma. GNOME asks for no permission. GNOME before 46 (Ubuntu 22.04, for example) can only be controlled; to control other computers from one, choose "Ubuntu on Xorg" on the login screen. Typing text the current keyboard layout cannot produce, such as Chinese from a phone, needs the GNOME component above. KDE Plasma asks for permission the first time it is controlled, and not again once you tick "remember"; controlling other computers from it asks every time it starts (a current KDE limit). Other Wayland desktops have not been verified.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| Device not in the list | Use the same network; if mDNS is blocked, connect by QR code or IP |
| Android copy didn't sync | Android 10+ blocks this in the background; reopen Whisper to send it |
| Pointer stuck on another device | Press `Ctrl+Alt+Esc` (`Control+Option+Esc` on macOS) |
| Stutter on Windows | Set Settings → System → Projecting to this PC to "Always Off" |
| No keyboard/mouse on macOS | Grant Accessibility in System Settings, then reopen Whisper |
| Windows lock screen or UAC | Needs the system service from the installer; see the [user guide](docs/user-guide_en.md#windows-lock-screen-and-uac) |

## Security

- Data between paired devices travels over a direct channel encrypted with X25519 and XChaCha20-Poly1305.
- LAN discovery and connection metadata are not encrypted, and neither are the local database or received files at rest.
- Devices only connect directly on the local network; there is no public relay. The implementation has not had an independent cryptographic audit.
- Keyboard and mouse sharing is meant for your own nearby devices, not for unattended remote control.

## Build from source

Use Flutter 3.44.9 (stable) with the toolchain for your target platform.

```bash
flutter pub get
flutter run
flutter analyze && flutter test
```

On macOS, use `./script/build_and_run.sh`, which builds, signs, and launches the app. Linux also needs the development packages for Avahi, PulseAudio or PipeWire Pulse, GStreamer, libsecret, keybinder, jsoncpp, libmpv, libepoxy, and libpipewire-0.3. See [AGENTS.md](AGENTS.md) for project conventions.

## License

[MIT](./LICENSE)
