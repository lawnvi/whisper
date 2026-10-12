# Whisper User Guide

[中文](user-guide.md) · [Back to README](../README_en.md)

- [Connect devices](#connect-devices)
- [Send text and files](#send-text-and-files)
- [Search, favorite, and delete](#search-favorite-and-delete)
- [Clipboard sync](#clipboard-sync)
- [Keyboard and mouse sharing](#keyboard-and-mouse-sharing)
- [Control a computer from Android](#control-a-computer-from-android)
- [System audio sharing](#system-audio-sharing)
- [Screenshots](#screenshots)
- [Android notifications](#android-notifications)
- [TV casting](#tv-casting)

## Connect devices

When two devices are on the same network with Whisper open, they usually appear in each other's device list. Select the other device and confirm the request on the receiving side; the first time, both sides check and confirm the same pairing code.

If the other device is not listed, select the QR icon above the device list to open "Connect device":

- **Phone**: switch between the QR code, scanner, and IP/port tabs to show your code, scan the other device, or enter its address.
- **Computer**: your QR code stays on the left while the right side switches between local details and the IP/port form.

The QR code carries both the LAN address and the device identity, so there is no extra password. The default service port is `10002` and can be changed under "Server Port" in Settings.

On Linux, discovery depends on Avahi. On networks that block mDNS / Bonjour, connecting by IP is more reliable.

## Send text and files

Open the conversation with a connected device and type, or use the attachment button to pick files. Images open full screen, audio plays inline, and video and other files open in a system app. On desktop, received files can be revealed in the file manager or dragged out of a message.

To send without opening a conversation first:

- **Android**: choose Whisper from the system share sheet.
- **Desktop**: use the file context menu, or press `Cmd+Option+V` (macOS) or `Ctrl+Alt+V` (Windows / Linux) to send the current clipboard content.

An interrupted file transfer continues from the last confirmed position.

## Search, favorite, and delete

Open "Search chat history" from the conversation settings; wide desktop windows also have a search button. Search covers the text of the current conversation, and results let you select text, expand long messages, favorite, or copy everything. The "Favorites" filter at the top shows saved text.

Long-press a message on a phone or right-click it on desktop to delete it or enter multi-select. A confirmation appears first: received local files are deleted too by default, or select "Keep received files" to remove only the records. Files you sent are always kept.

## Clipboard sync

"Auto-sync clipboard" is off by default; turn it on in Settings.

- A regular conversation syncs only to the connected, trusted device.
- A keyboard/mouse workspace syncs to its connected devices, and the most recent copy wins.
- Synced content never enters the chat history.
- Image and file clipboards sync only inside a desktop keyboard/mouse workspace, within per-file and batch size limits.

Android syncs text only. Under the [Android 10 privacy restriction](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data), Whisper cannot read what you copy in another app while it is in the background; it checks the clipboard and sends the change when you return to it.

## Keyboard and mouse sharing

On desktop, open the keyboard/mouse workspace, drag the other device's screen next to this one, and select "Start". After that, moving the pointer past that screen edge takes it to the other device, and the keyboard follows the pointer.

Turn on clipboard sync first if you want to paste across devices.

### Leaving and stopping

- Either the controlling or the controlled device can stop sharing.
- While the pointer is on another device you cannot click the local stop button. Press `Ctrl+Alt+Esc` on the controlling device (`Control+Option+Esc` on macOS) and keyboard and mouse return to it immediately. The shortcut is always shown at the bottom of the workspace's screen arrangement area.
- When the other device disconnects, the pointer returns to the controlling device on its own.
- A device has one role at a time: a device that is being controlled cannot start sharing. Stop the current session before switching.

### Permissions and platform limits

- **macOS**: grant the Accessibility permission when prompted.
- **Linux**: requires X11; it does not work on Wayland.
- **Windows**: if the pointer moves in small jumps, or file transfers swing between fast and slow, check Settings → System → Projecting to this PC. While it is on, the wireless adapter may have to keep a Wi-Fi Direct network alive as well, which adds periodic delay to the Wi-Fi connection; set it to "Always Off" when you do not use wireless projection.

### Windows lock screen and UAC

Once Windows is locked, ordinary programs cannot type on the lock screen. The Whisper installer also installs a system service (one administrator prompt on install and on each upgrade) that lets trusted devices type the password there.

- Settings → System behavior → "Keyboard and mouse on the lock screen and UAC" shows the service state; select the row to uninstall or repair it. Once uninstalled there, later upgrades do not bring it back.
- By default the service only acts while the screen is locked, so UAC prompts that appear after unlocking cannot be answered. Turn on the switch at the end of the same row if you need that (off by default; turning it on or off needs administrator approval).
- While the switch is on, any program running as you on this PC can use Whisper to get past UAC's confirmation. Only enable it if you understand that risk. Uninstalling the service turns it off as well.
- The sign-in screen after a restart cannot be controlled, because Whisper is not running before you log in.

## Control a computer from Android

The phone and computer must already be connected and trust each other, and the computer must be logged in with Whisper running. On Android, open the conversation with that computer, select "Control computer", then the start button at the top.

| Action | How |
| --- | --- |
| Air mouse | Tap the central area to start, turn your wrist to move the pointer, and tap again to pause |
| Touchpad | Move with one finger and tap to left-click; tap with two fingers to right-click, slide two fingers to scroll |
| Click and drag | Use the left and right buttons at the bottom; hold the left button and move to drag |
| Scroll | The area between the buttons scrolls: hold it and turn your wrist in air-mouse mode, or slide on it in touchpad mode |
| Virtual keyboard | The switch at the top opens the keyboard, with number, symbol, and function pages; select modifiers and then a key to send a shortcut |
| Typing text | The text field on the keyboard page uses the phone's input method, which suits Chinese, emoji, and multi-line text |

- The settings button at the top adjusts pointer speed, scroll speed, and motion sensitivity, and calibrates the sensor.
- With several computers connected, tap the computer name at the top to switch; only one is controlled at a time.
- Leaving the page, backgrounding the app, locking the phone, or disconnecting stops control; start it again manually after reconnecting.
- Air-mouse mode needs a gyroscope and a gravity sensor; without them the touchpad is used.
- This feature does not show the computer's screen, and cannot wake the computer or sign in from the lock screen.

## System audio sharing

On desktop, choose audio sharing in the device tools area, then pick one or more connected devices that can play audio. Multi-device playback supports basic synchronization and left/right channel assignment.

## Screenshots

Use the screenshot button on desktop, or the shortcut set in Settings. Click to select a window or drag to select a region, then confirm to copy the image; press `Esc` to cancel. The capture is not sent automatically: paste it into the Whisper composer to preview and send it.

On Linux, what is available depends on the screenshot service your desktop environment provides.

## Android notifications

After granting the notification access permission on Android, choose which apps to forward. This suits short messages such as verification codes.

## TV casting

With "TV casting" turned on in desktop Settings, video apps on the same network can cast to this computer without Whisper pairing. The feature is experimental and off by default; see the [TV casting notes (Chinese)](cast_receiver.md).
