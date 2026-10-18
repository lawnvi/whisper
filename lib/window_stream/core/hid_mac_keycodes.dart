/// USB HID keyboard usages (page 0x07, as Flutter reports them in
/// `PhysicalKeyboardKey.usbHidUsage` on iOS) to Mac virtual key codes
/// (`kVK_*` in Carbon's Events.h), which is what [KeyInput.macKeyCode]
/// carries to every source. The key is the physical one: what it types is
/// left to the source's own layout, so only keys that do not type (arrows,
/// Esc, function keys) and shortcuts travel as keys; text goes as text.
abstract final class HidMacKeyCodes {
  /// The keyboard usage page, as the high half of a Flutter usage.
  static const int keyboardPage = 0x07;

  /// The Mac key code for a Flutter usage (0x00070004 for A), or null for
  /// keys on other pages (Fn is 0x00000012) and keys a Mac does not have.
  static int? macKeyCode(int usbHidUsage) {
    final usage = keyboardUsage(usbHidUsage);
    return usage == null ? null : _table[usage];
  }

  /// The Mac key code for a bare keyboard-page usage (0x04 for A).
  static int? macKeyCodeForUsage(int usage) => _table[usage];

  /// The bare usage (0x04…) of a Flutter usage on the keyboard page, or
  /// null for other pages (consumer keys, Fn).
  static int? keyboardUsage(int usage) {
    final page = usage >> 16;
    if (page != keyboardPage) {
      return null;
    }
    return usage & 0xFFFF;
  }

  static const int a = 0x04;
  static const int returnKey = 0x28;
  static const int escape = 0x29;
  static const int backspace = 0x2A;
  static const int tab = 0x2B;
  static const int space = 0x2C;
  static const int keypadEnter = 0x58;

  /// Left and right Control, Shift, Option and Command.
  static bool isModifier(int usage) => usage >= 0xE0 && usage <= 0xE7;

  /// Keys that never type, so a text system never delivers them: they go
  /// to the source as keys whatever is held (arrows, Esc, forward delete,
  /// Home, End, Page Up and Down, Insert/Help, F1–F20, Print Screen,
  /// Scroll Lock, Pause, the keypad's Clear).
  static bool isNonTyping(int usage) =>
      (usage >= 0x3A && usage <= 0x53) ||
      (usage >= 0x68 && usage <= 0x6F) ||
      usage == escape;

  /// Return, Tab and Backspace: they type in a text field, but on the
  /// other device they are keys (a list's Return, a form's Tab).
  static bool isEditingKey(int usage) =>
      usage == returnKey ||
      usage == keypadEnter ||
      usage == tab ||
      usage == backspace;

  static const Map<int, int> _table = {
    // Letters.
    0x04: 0, // A
    0x05: 11, // B
    0x06: 8, // C
    0x07: 2, // D
    0x08: 14, // E
    0x09: 3, // F
    0x0A: 5, // G
    0x0B: 4, // H
    0x0C: 34, // I
    0x0D: 38, // J
    0x0E: 40, // K
    0x0F: 37, // L
    0x10: 46, // M
    0x11: 45, // N
    0x12: 31, // O
    0x13: 35, // P
    0x14: 12, // Q
    0x15: 15, // R
    0x16: 1, // S
    0x17: 17, // T
    0x18: 32, // U
    0x19: 9, // V
    0x1A: 13, // W
    0x1B: 7, // X
    0x1C: 16, // Y
    0x1D: 6, // Z
    // Digits.
    0x1E: 18, // 1
    0x1F: 19, // 2
    0x20: 20, // 3
    0x21: 21, // 4
    0x22: 23, // 5
    0x23: 22, // 6
    0x24: 26, // 7
    0x25: 28, // 8
    0x26: 25, // 9
    0x27: 29, // 0
    // Editing and punctuation.
    0x28: 36, // Return
    0x29: 53, // Escape
    0x2A: 51, // Delete (backspace)
    0x2B: 48, // Tab
    0x2C: 49, // Space
    0x2D: 27, // - _
    0x2E: 24, // = +
    0x2F: 33, // [ {
    0x30: 30, // ] }
    0x31: 42, // \ |
    0x32: 42, // Non-US # ~ (the same key as \ on a Mac)
    0x33: 41, // ; :
    0x34: 39, // ' "
    0x35: 50, // ` ~
    0x36: 43, // , <
    0x37: 47, // . >
    0x38: 44, // / ?
    0x39: 57, // Caps Lock
    // Function keys.
    0x3A: 122, // F1
    0x3B: 120, // F2
    0x3C: 99, // F3
    0x3D: 118, // F4
    0x3E: 96, // F5
    0x3F: 97, // F6
    0x40: 98, // F7
    0x41: 100, // F8
    0x42: 101, // F9
    0x43: 109, // F10
    0x44: 103, // F11
    0x45: 111, // F12
    0x46: 105, // Print Screen (F13)
    0x47: 107, // Scroll Lock (F14)
    0x48: 113, // Pause (F15)
    // Navigation.
    0x49: 114, // Insert (Help)
    0x4A: 115, // Home
    0x4B: 116, // Page Up
    0x4C: 117, // Forward Delete
    0x4D: 119, // End
    0x4E: 121, // Page Down
    0x4F: 124, // Right
    0x50: 123, // Left
    0x51: 125, // Down
    0x52: 126, // Up
    // Keypad.
    0x53: 71, // Num Lock (Clear)
    0x54: 75, // /
    0x55: 67, // *
    0x56: 78, // -
    0x57: 69, // +
    0x58: 76, // Enter
    0x59: 83, // 1
    0x5A: 84, // 2
    0x5B: 85, // 3
    0x5C: 86, // 4
    0x5D: 87, // 5
    0x5E: 88, // 6
    0x5F: 89, // 7
    0x60: 91, // 8
    0x61: 92, // 9
    0x62: 82, // 0
    0x63: 65, // .
    0x64: 10, // Non-US \ | (ISO §)
    0x65: 110, // Application (context menu)
    0x67: 81, // =
    0x68: 105, // F13
    0x69: 107, // F14
    0x6A: 113, // F15
    0x6B: 106, // F16
    0x6C: 64, // F17
    0x6D: 79, // F18
    0x6E: 80, // F19
    0x6F: 90, // F20
    0x7F: 74, // Mute
    0x80: 72, // Volume Up
    0x81: 73, // Volume Down
    0x85: 95, // Keypad , (JIS)
    0x87: 94, // International1 (JIS _ ろ)
    0x89: 93, // International3 (JIS ¥)
    0x90: 104, // LANG1 (Kana, Hangul)
    0x91: 102, // LANG2 (Eisu, Hanja)
    // Modifiers.
    0xE0: 59, // Left Control
    0xE1: 56, // Left Shift
    0xE2: 58, // Left Option
    0xE3: 55, // Left Command
    0xE4: 62, // Right Control
    0xE5: 60, // Right Shift
    0xE6: 61, // Right Option
    0xE7: 54, // Right Command
  };
}
