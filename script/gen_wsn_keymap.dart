// Generates packages/window_stream_native/src/wsn_keymap.h: the key table the
// Windows and Linux window-stream natives use to turn the macOS key codes on
// the wire into Windows virtual keys / scan codes and Linux evdev codes, and
// back.
//
//   dart run script/gen_wsn_keymap.dart          # rewrite the header
//   dart run script/gen_wsn_keymap.dart --check  # exit 1 when it is stale
//
// Keys that remote input already translates take their macOS, Windows and
// Linux codes from lib/remote_input/remote_input_key_translation.dart, so the
// two features can never disagree. This file adds what that table lacks: scan
// codes, left/right modifiers, keypad, F13–F20, the volume keys and the ISO
// and JIS keys. Every key is positional (a key code names a place on the
// keyboard, not a character), which is what both natives need.
import 'dart:io';

import 'package:whisper/remote_input/remote_input_key_translation.dart';

const String wsnKeymapHeaderPath =
    'packages/window_stream_native/src/wsn_keymap.h';

/// One physical key. Rows with [source] take mac/vk/evdev from remote input.
class WsnKeyRow {
  const WsnKeyRow.fromSource(
    this.name, {
    required String this.source,
    required this.scan,
    this.extended = false,
    this.vkOverride,
  }) : mac = -1,
       vk = -1,
       evdev = -1;

  const WsnKeyRow(
    this.name, {
    required this.mac,
    required this.vk,
    required this.scan,
    required this.evdev,
    this.extended = false,
  }) : source = null,
       vkOverride = null;

  final String name;

  /// Semantic name in remote_input_key_translation.dart.
  final String? source;

  /// Remote input sends the generic VK (VK_SHIFT); the natives need the
  /// sided one (VK_LSHIFT) because SendInput and WM_KEYDOWN distinguish them.
  final int? vkOverride;
  final int mac;
  final int vk;
  final int scan;
  final bool extended;
  final int evdev;
}

/// A row with every code filled in.
class WsnKey {
  const WsnKey({
    required this.name,
    required this.mac,
    required this.vk,
    required this.scan,
    required this.extended,
    required this.evdev,
  });

  final String name;
  final int mac;
  final int vk;
  final int scan;
  final bool extended;
  final int evdev;
}

// Scan codes are Windows set 1 without the E0 prefix (`extended` carries it),
// as MapVirtualKey and the WM_KEYDOWN lParam report them. Order matters only
// for reverse lookups that share a code: the first row wins.
const List<WsnKeyRow> wsnKeyRows = <WsnKeyRow>[
  // Letters.
  WsnKeyRow.fromSource('keyA', source: 'keyA', scan: 0x1E),
  WsnKeyRow.fromSource('keyB', source: 'keyB', scan: 0x30),
  WsnKeyRow.fromSource('keyC', source: 'keyC', scan: 0x2E),
  WsnKeyRow.fromSource('keyD', source: 'keyD', scan: 0x20),
  WsnKeyRow.fromSource('keyE', source: 'keyE', scan: 0x12),
  WsnKeyRow.fromSource('keyF', source: 'keyF', scan: 0x21),
  WsnKeyRow.fromSource('keyG', source: 'keyG', scan: 0x22),
  WsnKeyRow.fromSource('keyH', source: 'keyH', scan: 0x23),
  WsnKeyRow.fromSource('keyI', source: 'keyI', scan: 0x17),
  WsnKeyRow.fromSource('keyJ', source: 'keyJ', scan: 0x24),
  WsnKeyRow.fromSource('keyK', source: 'keyK', scan: 0x25),
  WsnKeyRow.fromSource('keyL', source: 'keyL', scan: 0x26),
  WsnKeyRow.fromSource('keyM', source: 'keyM', scan: 0x32),
  WsnKeyRow.fromSource('keyN', source: 'keyN', scan: 0x31),
  WsnKeyRow.fromSource('keyO', source: 'keyO', scan: 0x18),
  WsnKeyRow.fromSource('keyP', source: 'keyP', scan: 0x19),
  WsnKeyRow.fromSource('keyQ', source: 'keyQ', scan: 0x10),
  WsnKeyRow.fromSource('keyR', source: 'keyR', scan: 0x13),
  WsnKeyRow.fromSource('keyS', source: 'keyS', scan: 0x1F),
  WsnKeyRow.fromSource('keyT', source: 'keyT', scan: 0x14),
  WsnKeyRow.fromSource('keyU', source: 'keyU', scan: 0x16),
  WsnKeyRow.fromSource('keyV', source: 'keyV', scan: 0x2F),
  WsnKeyRow.fromSource('keyW', source: 'keyW', scan: 0x11),
  WsnKeyRow.fromSource('keyX', source: 'keyX', scan: 0x2D),
  WsnKeyRow.fromSource('keyY', source: 'keyY', scan: 0x15),
  WsnKeyRow.fromSource('keyZ', source: 'keyZ', scan: 0x2C),
  // Digits.
  WsnKeyRow.fromSource('digit1', source: 'digit1', scan: 0x02),
  WsnKeyRow.fromSource('digit2', source: 'digit2', scan: 0x03),
  WsnKeyRow.fromSource('digit3', source: 'digit3', scan: 0x04),
  WsnKeyRow.fromSource('digit4', source: 'digit4', scan: 0x05),
  WsnKeyRow.fromSource('digit5', source: 'digit5', scan: 0x06),
  WsnKeyRow.fromSource('digit6', source: 'digit6', scan: 0x07),
  WsnKeyRow.fromSource('digit7', source: 'digit7', scan: 0x08),
  WsnKeyRow.fromSource('digit8', source: 'digit8', scan: 0x09),
  WsnKeyRow.fromSource('digit9', source: 'digit9', scan: 0x0A),
  WsnKeyRow.fromSource('digit0', source: 'digit0', scan: 0x0B),
  // Punctuation.
  WsnKeyRow.fromSource('minus', source: 'minus', scan: 0x0C),
  WsnKeyRow.fromSource('equal', source: 'equal', scan: 0x0D),
  WsnKeyRow.fromSource('bracketLeft', source: 'bracketLeft', scan: 0x1A),
  WsnKeyRow.fromSource('bracketRight', source: 'bracketRight', scan: 0x1B),
  WsnKeyRow.fromSource('backslash', source: 'backslash', scan: 0x2B),
  WsnKeyRow.fromSource('semicolon', source: 'semicolon', scan: 0x27),
  WsnKeyRow.fromSource('quote', source: 'quote', scan: 0x28),
  WsnKeyRow.fromSource('backquote', source: 'backquote', scan: 0x29),
  WsnKeyRow.fromSource('comma', source: 'comma', scan: 0x33),
  WsnKeyRow.fromSource('period', source: 'period', scan: 0x34),
  WsnKeyRow.fromSource('slash', source: 'slash', scan: 0x35),
  // ISO and JIS keys. VK_OEM_102 / VK_ABNT_C1 / VK_KANA / VK_KANJI.
  WsnKeyRow(
    'intlBackslash',
    mac: 10,
    vk: 0xE2,
    scan: 0x56,
    evdev: 86,
  ), // KEY_102ND
  WsnKeyRow('intlYen', mac: 93, vk: 0xDC, scan: 0x7D, evdev: 124), // KEY_YEN
  WsnKeyRow('intlRo', mac: 94, vk: 0xC1, scan: 0x73, evdev: 89), // KEY_RO
  WsnKeyRow('lang1', mac: 104, vk: 0x15, scan: 0x72, evdev: 122), // Kana
  WsnKeyRow('lang2', mac: 102, vk: 0x19, scan: 0x71, evdev: 123), // Eisu
  // Editing and whitespace.
  WsnKeyRow.fromSource('enter', source: 'enter', scan: 0x1C),
  WsnKeyRow.fromSource('tab', source: 'tab', scan: 0x0F),
  WsnKeyRow.fromSource('space', source: 'space', scan: 0x39),
  WsnKeyRow.fromSource('backspace', source: 'backspace', scan: 0x0E),
  WsnKeyRow.fromSource('escape', source: 'escape', scan: 0x01),
  WsnKeyRow.fromSource('delete', source: 'delete', scan: 0x53, extended: true),
  // The Mac Help key sits where PC keyboards have Insert.
  WsnKeyRow(
    'insert',
    mac: 114,
    vk: 0x2D,
    scan: 0x52,
    evdev: 110,
    extended: true,
  ),
  WsnKeyRow(
    'contextMenu',
    mac: 110,
    vk: 0x5D,
    scan: 0x5D,
    evdev: 127,
    extended: true,
  ),
  // Navigation.
  WsnKeyRow.fromSource('home', source: 'home', scan: 0x47, extended: true),
  WsnKeyRow.fromSource('end', source: 'end', scan: 0x4F, extended: true),
  WsnKeyRow.fromSource('pageUp', source: 'pageUp', scan: 0x49, extended: true),
  WsnKeyRow.fromSource(
    'pageDown',
    source: 'pageDown',
    scan: 0x51,
    extended: true,
  ),
  WsnKeyRow.fromSource(
    'arrowLeft',
    source: 'arrowLeft',
    scan: 0x4B,
    extended: true,
  ),
  WsnKeyRow.fromSource(
    'arrowRight',
    source: 'arrowRight',
    scan: 0x4D,
    extended: true,
  ),
  WsnKeyRow.fromSource(
    'arrowDown',
    source: 'arrowDown',
    scan: 0x50,
    extended: true,
  ),
  WsnKeyRow.fromSource(
    'arrowUp',
    source: 'arrowUp',
    scan: 0x48,
    extended: true,
  ),
  // Modifiers. Command is the Windows / Super key on the wire; the natives
  // decide whether a shortcut becomes Ctrl.
  WsnKeyRow.fromSource(
    'shiftLeft',
    source: 'shift',
    scan: 0x2A,
    vkOverride: 0xA0,
  ),
  WsnKeyRow('shiftRight', mac: 60, vk: 0xA1, scan: 0x36, evdev: 54),
  WsnKeyRow.fromSource(
    'controlLeft',
    source: 'control',
    scan: 0x1D,
    vkOverride: 0xA2,
  ),
  WsnKeyRow(
    'controlRight',
    mac: 62,
    vk: 0xA3,
    scan: 0x1D,
    evdev: 97,
    extended: true,
  ),
  WsnKeyRow.fromSource('altLeft', source: 'alt', scan: 0x38, vkOverride: 0xA4),
  WsnKeyRow(
    'altRight',
    mac: 61,
    vk: 0xA5,
    scan: 0x38,
    evdev: 100,
    extended: true,
  ),
  WsnKeyRow.fromSource('metaLeft', source: 'meta', scan: 0x5B, extended: true),
  WsnKeyRow(
    'metaRight',
    mac: 54,
    vk: 0x5C,
    scan: 0x5C,
    evdev: 126,
    extended: true,
  ),
  WsnKeyRow.fromSource('capsLock', source: 'capsLock', scan: 0x3A),
  // Function keys.
  WsnKeyRow.fromSource('f1', source: 'f1', scan: 0x3B),
  WsnKeyRow.fromSource('f2', source: 'f2', scan: 0x3C),
  WsnKeyRow.fromSource('f3', source: 'f3', scan: 0x3D),
  WsnKeyRow.fromSource('f4', source: 'f4', scan: 0x3E),
  WsnKeyRow.fromSource('f5', source: 'f5', scan: 0x3F),
  WsnKeyRow.fromSource('f6', source: 'f6', scan: 0x40),
  WsnKeyRow.fromSource('f7', source: 'f7', scan: 0x41),
  WsnKeyRow.fromSource('f8', source: 'f8', scan: 0x42),
  WsnKeyRow.fromSource('f9', source: 'f9', scan: 0x43),
  WsnKeyRow.fromSource('f10', source: 'f10', scan: 0x44),
  WsnKeyRow.fromSource('f11', source: 'f11', scan: 0x57),
  WsnKeyRow.fromSource('f12', source: 'f12', scan: 0x58),
  WsnKeyRow('f13', mac: 105, vk: 0x7C, scan: 0x64, evdev: 183),
  WsnKeyRow('f14', mac: 107, vk: 0x7D, scan: 0x65, evdev: 184),
  WsnKeyRow('f15', mac: 113, vk: 0x7E, scan: 0x66, evdev: 185),
  WsnKeyRow('f16', mac: 106, vk: 0x7F, scan: 0x67, evdev: 186),
  WsnKeyRow('f17', mac: 64, vk: 0x80, scan: 0x68, evdev: 187),
  WsnKeyRow('f18', mac: 79, vk: 0x81, scan: 0x69, evdev: 188),
  WsnKeyRow('f19', mac: 80, vk: 0x82, scan: 0x6A, evdev: 189),
  WsnKeyRow('f20', mac: 90, vk: 0x83, scan: 0x6B, evdev: 190),
  // Keypad. The Mac keypad Clear key sits where PC keyboards have Num Lock.
  WsnKeyRow('numpad0', mac: 82, vk: 0x60, scan: 0x52, evdev: 82),
  WsnKeyRow('numpad1', mac: 83, vk: 0x61, scan: 0x4F, evdev: 79),
  WsnKeyRow('numpad2', mac: 84, vk: 0x62, scan: 0x50, evdev: 80),
  WsnKeyRow('numpad3', mac: 85, vk: 0x63, scan: 0x51, evdev: 81),
  WsnKeyRow('numpad4', mac: 86, vk: 0x64, scan: 0x4B, evdev: 75),
  WsnKeyRow('numpad5', mac: 87, vk: 0x65, scan: 0x4C, evdev: 76),
  WsnKeyRow('numpad6', mac: 88, vk: 0x66, scan: 0x4D, evdev: 77),
  WsnKeyRow('numpad7', mac: 89, vk: 0x67, scan: 0x47, evdev: 71),
  WsnKeyRow('numpad8', mac: 91, vk: 0x68, scan: 0x48, evdev: 72),
  WsnKeyRow('numpad9', mac: 92, vk: 0x69, scan: 0x49, evdev: 73),
  WsnKeyRow('numpadDecimal', mac: 65, vk: 0x6E, scan: 0x53, evdev: 83),
  WsnKeyRow('numpadMultiply', mac: 67, vk: 0x6A, scan: 0x37, evdev: 55),
  WsnKeyRow('numpadAdd', mac: 69, vk: 0x6B, scan: 0x4E, evdev: 78),
  WsnKeyRow('numpadSubtract', mac: 78, vk: 0x6D, scan: 0x4A, evdev: 74),
  WsnKeyRow(
    'numpadDivide',
    mac: 75,
    vk: 0x6F,
    scan: 0x35,
    evdev: 98,
    extended: true,
  ),
  WsnKeyRow(
    'numpadEnter',
    mac: 76,
    vk: 0x0D,
    scan: 0x1C,
    evdev: 96,
    extended: true,
  ),
  WsnKeyRow(
    'numLock',
    mac: 71,
    vk: 0x90,
    scan: 0x45,
    evdev: 69,
    extended: true,
  ),
  // No Windows virtual key exists for keypad "="; scan code only.
  WsnKeyRow('numpadEqual', mac: 81, vk: 0, scan: 0x59, evdev: 117),
  WsnKeyRow('numpadComma', mac: 95, vk: 0x6C, scan: 0x7E, evdev: 121),
  // Media keys macOS gives key codes to.
  WsnKeyRow(
    'audioVolumeUp',
    mac: 72,
    vk: 0xAF,
    scan: 0x30,
    evdev: 115,
    extended: true,
  ),
  WsnKeyRow(
    'audioVolumeDown',
    mac: 73,
    vk: 0xAE,
    scan: 0x2E,
    evdev: 114,
    extended: true,
  ),
  WsnKeyRow(
    'audioVolumeMute',
    mac: 74,
    vk: 0xAD,
    scan: 0x20,
    evdev: 113,
    extended: true,
  ),
];

/// Windows reports Shift, Ctrl and Alt as generic virtual keys in
/// WM_KEYDOWN; these resolve to the left key unless the scan code says
/// otherwise.
const Map<int, String> wsnGenericVkAliases = <int, String>{
  0x10: 'shiftLeft', // VK_SHIFT
  0x11: 'controlLeft', // VK_CONTROL
  0x12: 'altLeft', // VK_MENU
};

/// Resolves every row against remote input and checks the table.
List<WsnKey> resolveWsnKeys() {
  final keys = <WsnKey>[];
  for (final row in wsnKeyRows) {
    if (row.source != null) {
      final codes = remoteInputKeyCodes(row.source!);
      keys.add(
        WsnKey(
          name: row.name,
          mac: codes.macKeyCode,
          vk: row.vkOverride ?? codes.windowsKeyCode,
          scan: row.scan,
          extended: row.extended,
          evdev: codes.linuxKeyCode,
        ),
      );
    } else {
      keys.add(
        WsnKey(
          name: row.name,
          mac: row.mac,
          vk: row.vk,
          scan: row.scan,
          extended: row.extended,
          evdev: row.evdev,
        ),
      );
    }
  }
  _validate(keys);
  return keys;
}

void _validate(List<WsnKey> keys) {
  final macs = <int>{};
  final scans = <int>{};
  final evdevs = <int>{};
  final names = <String>{};
  for (final key in keys) {
    if (!names.add(key.name)) {
      throw StateError('duplicate key name ${key.name}');
    }
    if (key.mac < 0 || key.mac > 127 || !macs.add(key.mac)) {
      throw StateError('bad or duplicate mac code ${key.mac} (${key.name})');
    }
    final scanKey = key.scan | (key.extended ? 0x100 : 0);
    if (key.scan <= 0 || key.scan > 0x7F || !scans.add(scanKey)) {
      throw StateError('bad or duplicate scan code ${key.scan} (${key.name})');
    }
    if (key.evdev <= 0 || key.evdev > 0x2FF || !evdevs.add(key.evdev)) {
      throw StateError(
        'bad or duplicate evdev code ${key.evdev} '
        '(${key.name})',
      );
    }
    if (key.vk < 0 || key.vk > 0xFE) {
      throw StateError('bad virtual key ${key.vk} (${key.name})');
    }
    // In the classic block a set-1 scan code equals its evdev code; this
    // catches typos in either column.
    if (!key.extended && key.scan <= 0x58 && key.scan != key.evdev) {
      throw StateError('scan ${key.scan} != evdev ${key.evdev} (${key.name})');
    }
  }
  for (final name in wsnGenericVkAliases.values) {
    if (!names.contains(name)) throw StateError('alias to unknown $name');
  }
}

String _hex(int value, [int width = 2]) =>
    '0x${value.toRadixString(16).toUpperCase().padLeft(width, '0')}';

/// The header text, deterministic for a given table.
String buildWsnKeymapHeader() {
  final keys = resolveWsnKeys();
  final out = StringBuffer()
    ..writeln('// GENERATED FILE - DO NOT EDIT.')
    ..writeln(
      '// Regenerate with `dart run script/gen_wsn_keymap.dart` '
      '(source:',
    )
    ..writeln(
      '// lib/remote_input/remote_input_key_translation.dart plus the '
      'table in the',
    )
    ..writeln(
      '// script). test/window_stream_keymap_test.dart fails when '
      'this file is stale.',
    )
    ..writeln('//')
    ..writeln(
      '// Window-stream key events carry macOS virtual key codes '
      '(kVK_*). These',
    )
    ..writeln(
      '// helpers map them to Windows virtual keys and set-1 scan '
      'codes and to',
    )
    ..writeln(
      '// Linux evdev codes (X11/GDK hardware keycode = evdev + 8), '
      'and back. All',
    )
    ..writeln(
      '// codes are positional. Lookups return 0 (Windows/Linux) or '
      '-1 (mac) when',
    )
    ..writeln('// a key has no mapping.')
    ..writeln()
    ..writeln('#ifndef WSN_KEYMAP_H')
    ..writeln('#define WSN_KEYMAP_H')
    ..writeln()
    ..writeln('#include <stdint.h>')
    ..writeln()
    ..writeln('#ifdef __cplusplus')
    ..writeln('extern "C" {')
    ..writeln('#endif')
    ..writeln()
    ..writeln('typedef struct wsn_key_row {')
    ..writeln('  int32_t mac;       // macOS virtual key code')
    ..writeln('  int32_t vk;        // Windows virtual key, 0 = none')
    ..writeln('  int32_t scan;      // Windows set-1 scan code without E0')
    ..writeln('  int32_t extended;  // 1: E0 prefix / KEYEVENTF_EXTENDEDKEY')
    ..writeln('  int32_t evdev;     // Linux KEY_* code')
    ..writeln('  const char *name;  // for logs')
    ..writeln('} wsn_key_row;')
    ..writeln()
    ..writeln('#define WSN_KEYMAP_COUNT ${keys.length}')
    ..writeln()
    ..writeln(
      '// The table lives in a function so including the header never '
      'leaves an',
    )
    ..writeln('// unused static array behind.')
    ..writeln('static inline const wsn_key_row *wsn_keymap_rows(void) {')
    ..writeln('  static const wsn_key_row rows[WSN_KEYMAP_COUNT] = {');
  for (final key in keys) {
    out.writeln(
      '      {${key.mac.toString().padLeft(3)}, ${_hex(key.vk)}, '
      '${_hex(key.scan)}, ${key.extended ? 1 : 0}, '
      '${key.evdev.toString().padLeft(3)}, "${key.name}"},',
    );
  }
  out
    ..writeln('  };')
    ..writeln('  return rows;')
    ..writeln('}')
    ..writeln()
    ..writeln(
      'static inline const wsn_key_row *wsn_keymap_find_mac('
      'int32_t mac) {',
    )
    ..writeln('  const wsn_key_row *rows = wsn_keymap_rows();')
    ..writeln('  for (int32_t i = 0; i < WSN_KEYMAP_COUNT; ++i) {')
    ..writeln('    if (rows[i].mac == mac) return &rows[i];')
    ..writeln('  }')
    ..writeln('  return 0;')
    ..writeln('}')
    ..writeln()
    ..writeln('// macOS -> Windows virtual key (0 = none).')
    ..writeln('static inline int32_t wsn_keymap_mac_to_vk(int32_t mac) {')
    ..writeln('  const wsn_key_row *row = wsn_keymap_find_mac(mac);')
    ..writeln('  return row ? row->vk : 0;')
    ..writeln('}')
    ..writeln()
    ..writeln(
      '// macOS -> Windows scan code (0 = none); *extended is set '
      'when not null.',
    )
    ..writeln(
      'static inline int32_t wsn_keymap_mac_to_scan(int32_t mac, '
      'int32_t *extended) {',
    )
    ..writeln('  const wsn_key_row *row = wsn_keymap_find_mac(mac);')
    ..writeln('  if (extended) *extended = row ? row->extended : 0;')
    ..writeln('  return row ? row->scan : 0;')
    ..writeln('}')
    ..writeln()
    ..writeln('// macOS -> Linux evdev code (0 = none).')
    ..writeln('static inline int32_t wsn_keymap_mac_to_evdev(int32_t mac) {')
    ..writeln('  const wsn_key_row *row = wsn_keymap_find_mac(mac);')
    ..writeln('  return row ? row->evdev : 0;')
    ..writeln('}')
    ..writeln()
    ..writeln(
      '// Windows scan code (+ extended flag) -> macOS (-1 = none). '
      'Prefer this to',
    )
    ..writeln('// the virtual key: it does not depend on the keyboard layout.')
    ..writeln(
      'static inline int32_t wsn_keymap_mac_from_scan(int32_t scan, '
      'int32_t extended) {',
    )
    ..writeln('  const wsn_key_row *rows = wsn_keymap_rows();')
    ..writeln('  for (int32_t i = 0; i < WSN_KEYMAP_COUNT; ++i) {')
    ..writeln(
      '    if (rows[i].scan == scan && rows[i].extended == '
      '(extended ? 1 : 0)) {',
    )
    ..writeln('      return rows[i].mac;')
    ..writeln('    }')
    ..writeln('  }')
    ..writeln('  return -1;')
    ..writeln('}')
    ..writeln()
    ..writeln(
      '// Windows virtual key -> macOS (-1 = none). Generic '
      'VK_SHIFT/CONTROL/MENU',
    )
    ..writeln('// resolve to the left key.')
    ..writeln('static inline int32_t wsn_keymap_mac_from_vk(int32_t vk) {')
    ..writeln('  switch (vk) {');
  final byName = {for (final key in keys) key.name: key};
  for (final entry in wsnGenericVkAliases.entries) {
    out.writeln(
      '    case ${_hex(entry.key)}: return '
      '${byName[entry.value]!.mac};  // ${entry.value}',
    );
  }
  out
    ..writeln('    default: break;')
    ..writeln('  }')
    ..writeln('  if (vk <= 0) return -1;')
    ..writeln('  const wsn_key_row *rows = wsn_keymap_rows();')
    ..writeln('  for (int32_t i = 0; i < WSN_KEYMAP_COUNT; ++i) {')
    ..writeln('    if (rows[i].vk == vk) return rows[i].mac;')
    ..writeln('  }')
    ..writeln('  return -1;')
    ..writeln('}')
    ..writeln()
    ..writeln(
      '// WM_KEYDOWN/WM_KEYUP -> macOS (-1 = none): scan code first, '
      'then the',
    )
    ..writeln('// virtual key (injected keys may carry no scan code).')
    ..writeln(
      'static inline int32_t wsn_keymap_mac_from_win(int32_t vk, '
      'int32_t scan, int32_t extended) {',
    )
    ..writeln(
      '  int32_t mac = scan > 0 ? wsn_keymap_mac_from_scan(scan, '
      'extended) : -1;',
    )
    ..writeln('  return mac >= 0 ? mac : wsn_keymap_mac_from_vk(vk);')
    ..writeln('}')
    ..writeln()
    ..writeln('// Linux evdev code -> macOS (-1 = none).')
    ..writeln(
      'static inline int32_t wsn_keymap_mac_from_evdev(int32_t '
      'evdev) {',
    )
    ..writeln('  const wsn_key_row *rows = wsn_keymap_rows();')
    ..writeln('  for (int32_t i = 0; i < WSN_KEYMAP_COUNT; ++i) {')
    ..writeln('    if (rows[i].evdev == evdev) return rows[i].mac;')
    ..writeln('  }')
    ..writeln('  return -1;')
    ..writeln('}')
    ..writeln()
    ..writeln('// X11 / GDK hardware keycode (evdev + 8) -> macOS (-1 = none).')
    ..writeln(
      'static inline int32_t wsn_keymap_mac_from_xkb(int32_t keycode) '
      '{',
    )
    ..writeln(
      '  return keycode > 8 ? wsn_keymap_mac_from_evdev(keycode - 8) '
      ': -1;',
    )
    ..writeln('}')
    ..writeln()
    ..writeln('#ifdef __cplusplus')
    ..writeln('}')
    ..writeln('#endif')
    ..writeln()
    ..writeln('#endif  // WSN_KEYMAP_H');
  return out.toString();
}

void main(List<String> args) {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final file = File('$root/$wsnKeymapHeaderPath');
  final text = buildWsnKeymapHeader();
  if (args.contains('--check')) {
    final current = file.existsSync() ? file.readAsStringSync() : '';
    if (current != text) {
      stderr.writeln(
        '$wsnKeymapHeaderPath is stale; run '
        '`dart run script/gen_wsn_keymap.dart`.',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('$wsnKeymapHeaderPath is up to date.');
    return;
  }
  file.writeAsStringSync(text);
  stdout.writeln(
    'Wrote $wsnKeymapHeaderPath '
    '(${resolveWsnKeys().length} keys).',
  );
}
