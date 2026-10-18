/// Android KeyEvent codes for the keys a Mac keyboard sends that are not
/// plain text. Printable characters are injected as text instead, so the
/// Mac's keyboard layout decides what is typed.
abstract final class AndroidKeycodes {
  static const int home = 3;
  static const int back = 4;
  static const int dpadUp = 19;
  static const int dpadDown = 20;
  static const int dpadLeft = 21;
  static const int dpadRight = 22;
  static const int volumeUp = 24;
  static const int volumeDown = 25;
  static const int a = 29;
  static const int c = 31;
  static const int v = 50;
  static const int x = 52;
  static const int y = 53;
  static const int z = 54;
  static const int tab = 61;
  static const int space = 62;
  static const int enter = 66;
  static const int del = 67;
  static const int menu = 82;
  static const int pageUp = 92;
  static const int pageDown = 93;
  static const int escape = 111;
  static const int forwardDel = 112;
  static const int moveHome = 122;
  static const int moveEnd = 123;
  static const int appSwitch = 187;

  /// macOS virtual key code (kVK_*) → Android keycode for non-text keys.
  static const Map<int, int> fromMacKeyCode = {
    36: enter, // Return
    76: enter, // keypad Enter
    48: tab,
    51: del, // Delete (backspace)
    117: forwardDel,
    123: dpadLeft,
    124: dpadRight,
    125: dpadDown,
    126: dpadUp,
    115: moveHome,
    119: moveEnd,
    116: pageUp,
    121: pageDown,
  };

  /// macOS key codes of letters used in ⌘ shortcuts → Android keycodes.
  static const Map<int, int> shortcutLetters = {
    0: a, // A
    8: c, // C
    9: v, // V
    7: x, // X
    6: z, // Z
    16: y, // Y
  };

  static const int macKeyEscape = 53;
}
