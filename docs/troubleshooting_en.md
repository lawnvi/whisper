# Whisper troubleshooting

[中文](troubleshooting.md) · [User guide](user-guide_en.md) · [Back to README](../README_en.md)

Two places find the cause of most problems:

- **Connection diagnostics**: on a computer, click the info button at the top right of a conversation; on a phone, open that device's page. Then tap "Connection diagnostics". It checks this device's network, the other device's address, Whisper on that device and the encrypted connection in turn, and tells you where it stops.
- **Diagnostics**: open "Diagnostics" in Settings to see the database, the local service, device discovery and more. While Whisper is not running properly, the island keeps saying so.

- [It won't install or open](#it-wont-install-or-open)
- [Can't find or connect to a device](#cant-find-or-connect-to-a-device)
- [It connects, then drops](#it-connects-then-drops)
- [Keyboard and mouse sharing](#keyboard-and-mouse-sharing)
- [Sound, window flow and screenshots](#sound-window-flow-and-screenshots)
- [Clipboard](#clipboard)
- [Report a problem](#report-a-problem)

## It won't install or open

**Windows says "Windows protected your PC"**: the installer is not code-signed. Click "More info", then "Run anyway".

**Antivirus flags or blocks it**: Whisper listens on a LAN port, reads and writes the clipboard and simulates the keyboard and mouse, and its installer is unsigned, so some antivirus software reports it by mistake. Download it only from [GitHub Releases](https://github.com/lawnvi/whisper/releases), then add Whisper to the antivirus's trusted list.

**macOS says it can't be opened or the developer can't be verified**: the project has no paid Apple developer account, so the app is not notarized by Apple. Open System Settings → Privacy & Security and click "Open Anyway" near the bottom. From macOS 15, right-click → Open no longer skips this step. If it says the app "is damaged and can't be opened", run this in Terminal, then open it again:

```bash
xattr -dr com.apple.quarantine /Applications/Whisper.app
```

**Google Play Protect blocks the Android install**: choose "Install anyway". If there is no such button, open the Play Store, tap your profile picture, go to Play Protect → Settings, turn off "Scan apps with Play Protect" for the install, then turn it back on.

**Android 13 or later: the notification forwarding switch is greyed out**: Android restricts this setting for apps installed from a file. Find Whisper in the system's App info, tap ⋮ at the top right, choose "Allow restricted settings", then come back and turn it on.

## Can't find or connect to a device

**Follow what connection diagnostics says**:

| Result | What to do |
| --- | --- |
| The device cannot be reached | Both devices must be on the same network. Guest Wi-Fi, routers with AP (client) isolation and many office and campus networks stop devices from talking to each other. Turn isolation off, or put both on the same phone hotspot |
| The address in the QR code is invalid | Ask the other device to show its QR code again |
| Whisper is not responding | Open Whisper on the other device. If it changed its Server Port, connect with the new port |
| The connection timed out | Usually a firewall; see Windows Firewall below |
| The identity doesn't match the QR code | Whisper stopped the connection. Ask for the QR code again, and don't work around this check |
| The protocol versions are incompatible | Update both devices to the same new version |
| Pairing did not finish | Keep Whisper open on both devices and compare the pairing code again |

**Windows Firewall**: the first time Whisper opens, Windows asks whether it may use the network; tick "Private networks". If the current network is set to "Public", Windows blocks other devices from connecting in. In Settings → Network & internet, open the current network's properties and set its network profile type to "Private", or tick "Private" for Whisper under "Allow an app through Windows Firewall".

**macOS Local Network permission**: from macOS 15, apps need permission to reach the local network. Open System Settings → Privacy & Security → Local Network and make sure Whisper is on.

**Proxies and VPNs**: TUN or enhanced modes in tools like Clash, and company VPNs, can take over LAN traffic. Route your LAN directly, or turn them off and try again.

**The other device isn't listed, but the network works**: the router or network may block multicast, so discovery finds nothing. Connect with a QR code or an address instead: on a computer, click this device's name at the bottom left and choose "Enter an address…"; on a phone, tap the plus button. The default port is `10002`. Discovery on Linux relies on Avahi.

**The computer has Hyper-V, WSL, Docker or virtual machines**: these add virtual network adapters, and the address in the QR code may be on the wrong one. Use "Enter an address…" with the other device's address on the network you actually share.

**The local service didn't start**: Diagnostics shows why, for example a port already in use. Pick another port under Settings → Connection → Server Port; it applies when you leave Settings.

## It connects, then drops

**Android stops Whisper in the background**:
- Under Settings → Connection, turn on "Stay connected in background" and add Whisper to "Battery optimization" exceptions.
- Many phone brands add their own background limits. Find Whisper in the system's app management, set its battery use to "Unrestricted" or allow background activity, and allow it to start automatically.
- Locking Whisper in the recent apps list also helps.

**Mac sleep**: before a Mac sleeps, Whisper disconnects on purpose, so another computer can't move its pointer onto a sleeping Mac. After it wakes, it reconnects by itself if Settings → Connection → "Auto-connect paired devices" is on.

**On Windows the pointer stutters, or transfers speed up and slow down**: check Settings → System → Projecting to this PC. While it is on, the Wi-Fi adapter also keeps a Wi-Fi Direct network up, and Wi-Fi slows down every few seconds. If you don't project to this PC, set it to "Always Off".

## Keyboard and mouse sharing

**The pointer is stuck on another device**: press `Ctrl+Alt+Esc` on the controlling computer, or `Control+Option+Esc` on a Mac.

**Nothing happens on macOS**: turn Whisper on under System Settings → Privacy & Security → Accessibility, then quit and reopen Whisper. If it stopped working after an update while Whisper still looks enabled there, remove it with "−", add it again and turn it on.

**On Windows, an administrator window such as Task Manager is in front**: ordinary apps can't operate these windows. It takes the system service that comes with the installer, with the switch at the end of its row turned on; see [Windows lock screen and UAC](user-guide_en.md#windows-lock-screen-and-uac) in the user guide. With the switch off:
- If this computer is being controlled, the pointer returns to the controlling computer.
- If this computer is in control, the pointer can't move to other devices, and a hint asks you to click once first.

**The pointer stutters or the sound breaks up on Wi-Fi**:
- Update both computers to 0.0.60 or later. The keyboard, mouse and sound then go over UDP and no longer stop on every lost packet.
- Windows Firewall has to allow Whisper. The prompt the first time it opens allows both TCP and UDP; if only TCP is allowed, everything works but stutters again on a weak network.
- Check "Network" on the device card: with much loss or jitter, move to 5 GHz Wi-Fi, closer to the router, or to a cable. While a large file is being sent, Whisper slows the transfer to make room for the keyboard, mouse and sound.

**Lock screen**: Windows needs the system service; see the same section. After a restart, before anyone signs in, Whisper isn't running and can't be controlled.

**Linux**: for what works under Wayland and what it asks for, see [Permissions and platform limits](user-guide_en.md#permissions-and-platform-limits) in the user guide.

## Sound, window flow and screenshots

**On macOS, sound sharing fails, flowed windows stay black or screenshots don't work**: all of these need Screen Recording permission (Screen & System Audio Recording from macOS 15). Turn Whisper on under System Settings → Privacy & Security, then reopen Whisper.

**On Linux, flowed windows stay black**: this needs a Wayland session and FFmpeg with an H.264 encoder, and GNOME also needs the component from Settings. See [The device being shown](user-guide_en.md#the-device-being-shown) in the user guide.

## Clipboard

- Clipboard sync is off by default; turn it on on both devices.
- Android syncs text only. From Android 10, apps in the background can't read the clipboard; Whisper sends what you copied when you return to it.
- On macOS and Windows, what password managers copy is not synced, on purpose.

## Report a problem

If none of this helps, [open an issue](https://github.com/lawnvi/whisper/issues/new/choose) and choose "English":

1. Open "Diagnostics" in Settings and click "Report". The diagnostics are copied, and GitHub's issue form opens.
2. Paste the diagnostics in, and add both devices' Whisper and system versions and how to reproduce the problem.
3. If connection diagnostics found something, attach a screenshot.

Diagnostics contain no messages, files or device names, only system versions, this device's network addresses and the app's log.
