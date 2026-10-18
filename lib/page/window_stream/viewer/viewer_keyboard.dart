import 'package:flutter/services.dart' hide TextInput;

import '../../../window_stream/core/hid_mac_keycodes.dart';
import '../../../window_stream/core/window_input_event.dart';

/// Where a hardware key of this device goes: to the other device as a key
/// (what never types, and shortcuts), or to the text system here, which
/// composes it (shifted, dead keys, pinyin) and hands over text.
///
/// The way is chosen when the key goes down, and its repeats and its up
/// follow the same way whatever is held by then, so a key let go after ⌘
/// still comes up over there and a typed key never sends a stray up.
class HardwareKeyRouter {
  /// HID usages whose down went out as a key and whose up has not.
  final List<int> _down = [];

  bool get hasKeysDown => _down.isNotEmpty;

  /// What [event] sends, or null when it is the text system's (the caller
  /// lets it through). [textField]: the input method's field has focus, so
  /// typing reaches it; without it printable keys go out as text here.
  /// [composing]: the input method is composing (pinyin, kana): every key
  /// is its own until it commits.
  List<WindowInputEvent>? route(
    KeyEvent event, {
    required int modifiers,
    required bool textField,
    required bool composing,
  }) {
    final usage = HidMacKeyCodes.keyboardUsage(event.physicalKey.usbHidUsage);
    if (usage == null) {
      return null;
    }
    switch (event) {
      case KeyUpEvent():
        final index = _down.lastIndexOf(usage);
        if (index < 0) {
          return null;
        }
        _down.removeAt(index);
        // The up carries the modifiers still held, as a keyboard leaves
        // them, not those of its down.
        return [_key(usage, down: false, modifiers: modifiers)];
      case KeyRepeatEvent():
        if (_down.contains(usage)) {
          return [
            _key(
              usage,
              down: true,
              modifiers: modifiers,
              repeat: true,
              characters: event.character,
            ),
          ];
        }
        if (!textField && !composing) {
          final text = _typed(event.character, modifiers);
          if (text != null) {
            return [TextInput(text)];
          }
        }
        return null;
      case KeyDownEvent():
        if (composing && textField) {
          return null;
        }
        if (HidMacKeyCodes.isModifier(usage)) {
          // Modifiers ride on the keys they change (a shortcut's key carries
          // them), as the desktop receivers send them.
          return null;
        }
        if (goesAsKey(usage, modifiers)) {
          if (HidMacKeyCodes.macKeyCodeForUsage(usage) == null) {
            return null;
          }
          if (!_down.contains(usage)) {
            _down.add(usage);
          }
          return [
            _key(
              usage,
              down: true,
              modifiers: modifiers,
              characters: event.character,
            ),
          ];
        }
        if (!textField) {
          // Nothing composes here: what the key types goes as text.
          final text = _typed(event.character, modifiers);
          if (text != null) {
            return [TextInput(text)];
          }
        }
        return null;
    }
    return null;
  }

  /// Every key still down over there comes up (focus left the viewer, the
  /// app went to the background), last pressed first.
  List<WindowInputEvent> releaseAll() {
    final ups = <WindowInputEvent>[];
    while (_down.isNotEmpty) {
      ups.add(_key(_down.removeLast(), down: false, modifiers: 0));
    }
    return ups;
  }

  /// Keys that go to the other device as keys: those that never type,
  /// Return, Tab and Backspace (keys over there), and any key while ⌘, ⌃
  /// or ⌥ is held, since those make shortcuts. Shift alone makes
  /// characters, which the text system turns into text.
  static bool goesAsKey(int usage, int modifiers) {
    const shortcutMakers =
        InputModifiers.command | InputModifiers.control | InputModifiers.option;
    return HidMacKeyCodes.isNonTyping(usage) ||
        HidMacKeyCodes.isEditingKey(usage) ||
        modifiers & shortcutMakers != 0;
  }

  /// The modifiers held now, as [InputModifiers] bits.
  static int modifiersOf(HardwareKeyboard keyboard) {
    var value = 0;
    if (keyboard.isShiftPressed) value |= InputModifiers.shift;
    if (keyboard.isControlPressed) value |= InputModifiers.control;
    if (keyboard.isAltPressed) value |= InputModifiers.option;
    if (keyboard.isMetaPressed) value |= InputModifiers.command;
    if (keyboard.lockModesEnabled.contains(KeyboardLockMode.capsLock)) {
      value |= InputModifiers.capsLock;
    }
    return value;
  }

  static String? _typed(String? character, int modifiers) {
    if (character == null || character.isEmpty) {
      return null;
    }
    const shortcutMakers =
        InputModifiers.command | InputModifiers.control | InputModifiers.option;
    if (modifiers & shortcutMakers != 0) {
      return null;
    }
    final code = character.runes.first;
    // Control characters (Return, Tab, Escape, Delete) are keys.
    if (code < 0x20 || code == 0x7F) {
      return null;
    }
    // Private-use characters are how some platforms name function keys.
    if (code >= 0xE000 && code <= 0xF8FF) {
      return null;
    }
    return character;
  }

  static KeyInput _key(
    int usage, {
    required bool down,
    required int modifiers,
    bool repeat = false,
    String? characters,
  }) {
    return KeyInput(
      down: down,
      macKeyCode: HidMacKeyCodes.macKeyCodeForUsage(usage) ?? 0,
      modifiers: modifiers,
      repeat: repeat,
      characters: characters,
    );
  }
}

/// The software keyboard's (and the input method's) side: a hidden field
/// holds one invisible character, so Backspace on an empty field still
/// shows up as an edit; whatever else appears in it is typed text. What
/// the input method is still composing stays here (shown, not sent) until
/// it commits.
class ImeTextBuffer {
  /// Keeps one character in the hidden field so backspace is observable.
  static const String sentinel = '​';

  static const TextEditingValue empty = TextEditingValue(
    text: sentinel,
    selection: TextSelection.collapsed(offset: 1),
  );

  /// The draft the input method is composing in [value], or ''.
  static String composingOf(TextEditingValue value) {
    final composing = value.composing;
    if (!composing.isValid ||
        composing.isCollapsed ||
        composing.end > value.text.length) {
      return '';
    }
    return composing.textInside(value.text).replaceAll(sentinel, '');
  }

  /// What the field's new [value] sends, and whether the field goes back
  /// to [empty]. Nothing while the input method composes.
  static ({List<WindowInputEvent> events, bool reset}) consume(
    TextEditingValue value,
  ) {
    if (composingOf(value).isNotEmpty) {
      return (events: const [], reset: false);
    }
    final text = value.text;
    if (text == sentinel) {
      return (events: const [], reset: false);
    }
    if (text.isEmpty) {
      // The sentinel was deleted: Backspace.
      return (events: _press(51), reset: true);
    }
    final typed = text.replaceAll(sentinel, '');
    final events = <WindowInputEvent>[];
    final run = StringBuffer();
    void flush() {
      if (run.isNotEmpty) {
        events.add(TextInput(run.toString()));
        run.clear();
      }
    }

    for (final rune in typed.runes) {
      switch (rune) {
        case 0x0A || 0x0D:
          flush();
          events.addAll(_press(36));
        case 0x09:
          flush();
          events.addAll(_press(48));
        case 0x08:
          flush();
          events.addAll(_press(51));
        default:
          run.writeCharCode(rune);
      }
    }
    flush();
    return (events: events, reset: true);
  }

  static List<WindowInputEvent> _press(int macKeyCode) => [
    KeyInput(down: true, macKeyCode: macKeyCode),
    KeyInput(down: false, macKeyCode: macKeyCode),
  ];
}
