# Whisper User Guide

[中文](user-guide.md) · [Back to README](../README_en.md)

- [Connect devices](#connect-devices)
- [Send text and files](#send-text-and-files)
- [Search, favorite, and delete](#search-favorite-and-delete)
- [Browse files](#browse-files)
- [Share links](#share-links)
- [Window flow](#window-flow)
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

On desktop you can also send a whole folder: drop it into the conversation, or choose "Folder" from the attachment button. A folder goes as one transfer, without being archived first, and arrives with the same structure. Links are not sent. If some files could not be transferred, the message shows how many; open it to see which. If Whisper on the other device is too old, you are asked to update it first.

## Search, favorite, and delete

Open "Search chat history" from the conversation settings; wide desktop windows also have a search button. Search covers the text of the current conversation, and results let you select text, expand long messages, favorite, or copy everything. The "Favorites" filter at the top shows saved text.

Long-press a message on a phone or right-click it on desktop to delete it or enter multi-select. A confirmation appears first: received local files are deleted too by default, or select "Keep received files" to remove only the records. Files you sent are always kept.

## Browse files

Select ⋯ at the top right of a conversation to open "Device Details", then select "Files" to browse the other device's files as you would in your own file manager. The other device must be connected and running a recent version of Whisper.

Each time, the other device asks whether you may browse its files, with "Don't allow", "Allow this time", and "Always allow". Turning off "Always Allow Browsing My Files" in a device's details takes back an earlier "Always allow".

- **Computer**: the other device sees your home folder (and each drive on Windows). Deleted files go to the Trash.
- **Android**: the other device sees internal storage. Phones have no Trash, so deleting asks once more.

| To do this | Do this |
| --- | --- |
| Copy to this device | On desktop, drag files into Finder or File Explorer; they are written as they arrive. Or right-click and choose "Copy To…" |
| Copy to the other device | Drop files from this device into the window, or copy them and paste into a folder on the other device |
| Create, rename, or delete | Right-click an item or an empty area; long-press on a phone |
| Switch between list and icons | Use the switch in the toolbar, or press `Cmd+1` / `Cmd+2` (`Ctrl+1` / `Ctrl+2` on Windows / Linux) |

Copy progress shows at the top of the window. "Transfers" in the sidebar lists every copy, where you can resume, retry, or stop it; after a disconnect a copy waits for the device to come back and continues. Pasting the same files into the same place again within a few seconds counts as one copy.

### Mount on this computer

On macOS, Windows, and Linux you can also put the other device's files into the system file manager and open them in any app without copying them first. Android phones and computers can both be mounted.

- Turn on "Mount on this computer" in the device details, and the files are mounted whenever the device connects. For a one-off, right-click the device in the sidebar of the "Files" window and choose "Open in Finder" ("Open in File Explorer" on Windows).
- Where the files appear:
  - **macOS**: under Locations in the Finder sidebar, named after the device.
  - **Windows**: in the File Explorer navigation pane, with the Whisper icon.
  - **Linux**: in `Whisper/<device name>` in your home folder, also shown in the GNOME Files sidebar. Install fuse3 first.
- Mounted files work like local ones: open, edit, create, rename, and delete them.
  - A save is written to a hidden copy next to the file and put in its place in one go, so a dropped connection never leaves a half-written file.
  - If the file changes on the other device while you write it, the original is left alone and what you wrote is saved next to it as "name (this device)".
  - Deleting a file that was already there sends it to the other device's Trash (Android has none, so it is deleted); files made in the mount are deleted right away.
  - If the other device turns off "Allow Changes to My Files" in its device details, the mount only lets you open and copy files out.
  - On macOS, the `._` and `.DS_Store` files Finder writes stay on this Mac and never reach the other device.
  - On Windows, files you create or change in File Explorer are sent a few seconds after they are closed.
- Only the parts of a file that are opened are transferred, so speed depends on the network and the other device.
- Unless the other device chose "Always allow", it has to allow each mount.
- A mount goes away when the device disconnects, "Mount on this computer" stays on, and the files come back when it reconnects. Ejecting the mount in Finder or a Linux file manager turns the switch off.
- On Windows, files changed on the other device update within about 5 seconds, and new files appear the next time you open their folder.

## Share links

To give files on this device to a device without Whisper, create a link. Devices on the same local network can open it in a browser and download, with no pairing. Available on Android, macOS, Windows, and Linux.

1. Open "Files" for any device and choose "This device" in the sidebar.
2. Right-click a file or folder, or several selected ones, and choose "Create Share Link…". On a phone, long-press an item, or select several and choose "Share Link" at the bottom.
3. Set a route and password if you like:
   - Leave the route empty for a random one; "Short Route" makes it 4 characters, easy to say out loud.
   - The password is optional.
4. The link and its QR code appear once it is created. Copy the link, or let the other person scan the code with a phone camera. On a computer with several networks, you can switch the address in the link.

When someone opens the link:

- A single file shows a download page. A folder or several files can be browsed level by level and downloaded one by one, or all at once as a zip.
- Large downloads can resume after an interruption, and video and audio play right in the browser.
- With a password set, the password comes first.

All links are listed under "Share Links" in the sidebar (on the "Files" home screen on a phone):

- Each link shows its status, visits, downloads, and last visit, and can be copied, shown as a QR code, turned on or off, or deleted. Deleting a link leaves the files on this device alone.
- "File Server" at the top shows this device's address and port (`10003` by default, or another one when that is taken). The server only runs while at least one link is on; turning it off keeps the links, which just cannot be opened for now.
- Only devices on the local network are let in. Links use plain HTTP, so others on the same network may be able to see what is downloaded; the password only keeps people from opening the link casually.

## Window flow

Open a window or app from one device on another and use it there: carry on with a computer's app on a phone or tablet, use an Android phone's apps on a computer with a keyboard and mouse, or move a window from one computer to another's screen.

### Open the other device's windows

Select "Flow" in the device details. It lists the other device's recent tasks, windows, and apps; select one to open it here.

- **Phones and tablets**: the window fills the screen and works with touch, or with a keyboard and mouse. When the on-screen keyboard comes up, the window on the other device gets shorter so nothing is hidden. You can rotate to landscape.
- **Computers**: each window opens as its own system window that you can resize or make full screen, and use with this computer's keyboard, mouse, and input methods.
- Open windows form a stack of cards you can switch between.
- The window's sound comes along.
- "Quality" has four levels, Smooth, Standard, High, and Best; higher looks sharper and uses more of the network.
- "Pause" stops only the picture, to save the network. Phones and tablets pause a window when you leave it, and close it after 10 minutes paused.
- Closing the window here puts it back where it was on the other device. "Close Window" really closes it there; an app with unsaved work may ask whether to save first.

### Send a window

In Flow, select "Send to <device>" and choose one of this computer's windows. The window moves to that device and leaves this screen; when it is closed there, it comes back. A phone or tablet shows "<device> sent you a window", where "View" opens it; a computer opens it straight away.

### The device being shown

A window opened elsewhere keeps running here in the background, off your screen: on macOS and Linux it moves to an invisible virtual display, and on Windows it moves off screen. It returns to where it was afterwards. A few Windows apps cannot run in the background and are shared in place.

"Share This Computer's Windows" under Settings → Permissions and sharing on desktop is on by default; turn it off and other devices no longer see this computer's windows. Nothing can be shown while the computer is locked, and windows running as administrator or that block screen capture cannot be shown.

| System | Requirement |
| --- | --- |
| macOS | 12.3 or later. Allow Whisper under "Screen & System Audio Recording" in System Settings › Privacy & Security, and under "Accessibility" so the other device can control windows. Settings → Permissions and sharing shows the status of each |
| Windows | Windows 10 (1903) or later |
| Linux | A GNOME 45 or later, or KDE Plasma 6, session on Wayland. On GNOME, install the "Window sharing helper" from Settings the first time, then log out and back in once; KDE Plasma needs nothing installed and asks for no permission. X11 can only view for now |
| Android | Android 10 or later; see below |

On Linux, showing windows from other devices needs FFmpeg 4 or later. Sharing this computer's windows also needs an H.264 encoder in FFmpeg (x264 or openh264; Fedora ships without one).

### Android apps

Apps on an Android phone can flow to a computer. Whisper on the phone must be paired with the computer and connected.

The first time, start it from a computer that has adb installed (Android SDK Platform-Tools; Whisper looks in the Android SDK's default location and on PATH, and the installers do not include it). Turn on "USB debugging" in the phone's Developer options, connect the phone to that computer with a cable, and allow it to debug on the phone ("Wireless debugging" also works). The phone's apps then show up in that computer's Flow.

Once started, the phone's window flow service keeps running, and your other trusted computers can show this phone's apps without a cable; after the phone restarts, start it from a computer again. The service's status is under Settings → "Window flow service" in Whisper on the phone, where you can stop it at any time.

Flowed apps run on a virtual display on the phone, so you can keep using the phone for other things. Also:

- Opening a flowed app on the phone brings it back to the phone's screen; select it on the computer to bring it back there.
- The app's sound comes to the computer too (Android 13 or later).
- Apps that block screen capture, such as some banking apps, cannot be shown.
- On some phones the picture stops while the phone is locked.
- On Xiaomi phones, also turn on "USB debugging (Security settings)" in Developer options, then restart the phone.

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
- **Linux**: any X11 session works. On Wayland, GNOME works without asking for permission and shows its remote control icon in the top bar while in use. GNOME before 46 (Ubuntu 22.04, for example) can only be controlled; to control other computers from one, choose "Ubuntu on Xorg" on the login screen. Typing text the current keyboard layout cannot produce, such as Chinese from a phone, needs the "Window sharing helper" from Settings (GNOME 45 or later). KDE Plasma asks for permission the first time it is controlled, and not again once you tick "remember"; it takes any text, Chinese included. Controlling other computers from it asks every time it starts (a current KDE limit). Other Wayland desktops have not been tested, so they may not work.
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
