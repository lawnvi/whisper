import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class ScreenshotShortcut {
  const ScreenshotShortcut({
    required this.key,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  factory ScreenshotShortcut.defaultFor({required bool macOS}) =>
      ScreenshotShortcut(key: 'S', control: !macOS, alt: true, meta: macOS);

  factory ScreenshotShortcut.fromJson(Map<String, dynamic> json) {
    final shortcut = ScreenshotShortcut(
      key: json['key'] as String,
      control: json['control'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
      meta: json['meta'] == true,
    );
    if (!shortcut.isValid) throw const FormatException('Invalid shortcut');
    return shortcut;
  }

  static ScreenshotShortcut? fromKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    final keyboard = HardwareKeyboard.instance;
    final candidate = ScreenshotShortcut(
      key: keyLabelFor(event),
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
      meta: keyboard.isMetaPressed,
    );
    return candidate.isValid ? candidate : null;
  }

  static String keyLabelFor(KeyEvent event) {
    final label = event.logicalKey.keyLabel.toUpperCase();
    if (RegExp(r'^([A-Z0-9]|F([1-9]|1[0-2]))$').hasMatch(label)) return label;
    // Option/AltGr can turn a letter into a symbol before Flutter receives it.
    final usage = event.physicalKey.usbHidUsage;
    if (usage >= 0x70004 && usage <= 0x7001d) {
      return String.fromCharCode('A'.codeUnitAt(0) + usage - 0x70004);
    }
    if (usage >= 0x7001e && usage <= 0x70026) return '${usage - 0x7001d}';
    if (usage == 0x70027) return '0';
    return label;
  }

  final String key;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  bool get isValid =>
      RegExp(r'^([A-Z0-9]|F([1-9]|1[0-2]))$').hasMatch(key) &&
      (control || alt || meta);

  bool isQuickSendShortcut({required bool macOS}) =>
      key == 'V' &&
      alt &&
      !shift &&
      (macOS ? meta && !control : control && !meta);

  String label({required bool macOS}) => [
    if (control) macOS ? '⌃' : 'Ctrl',
    if (alt) macOS ? '⌥' : 'Alt',
    if (shift) macOS ? '⇧' : 'Shift',
    if (meta) macOS ? '⌘' : 'Super',
    key,
  ].join(macOS ? '' : '+');

  String get portalTrigger => [
    if (control) 'CTRL',
    if (alt) 'ALT',
    if (shift) 'SHIFT',
    if (meta) 'LOGO',
    key.length == 1 ? key.toLowerCase() : key,
  ].join('+');

  Map<String, dynamic> toJson() => {
    'key': key,
    'control': control,
    'alt': alt,
    'shift': shift,
    'meta': meta,
  };

  @override
  bool operator ==(Object other) =>
      other is ScreenshotShortcut &&
      key == other.key &&
      control == other.control &&
      alt == other.alt &&
      shift == other.shift &&
      meta == other.meta;

  @override
  int get hashCode => Object.hash(key, control, alt, shift, meta);
}
