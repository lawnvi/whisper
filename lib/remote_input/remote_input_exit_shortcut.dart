/// The one release hotkey every desktop capture backend recognises.
const String remoteInputReleaseHotkey = 'ctrl+alt+esc';

/// How the release hotkey is written on the keyboard in front of the user.
String remoteInputReleaseHotkeyLabel({required bool macOS}) =>
    macOS ? '⌃⌥Esc' : 'Ctrl+Alt+Esc';
