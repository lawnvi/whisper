// GENERATED FILE - DO NOT EDIT.
// Regenerate with `dart run script/gen_wsn_keymap.dart` (source:
// lib/remote_input/remote_input_key_translation.dart plus the table in the
// script). test/window_stream_keymap_test.dart fails when this file is stale.
//
// Window-stream key events carry macOS virtual key codes (kVK_*). These
// helpers map them to Windows virtual keys and set-1 scan codes and to
// Linux evdev codes (X11/GDK hardware keycode = evdev + 8), and back. All
// codes are positional. Lookups return 0 (Windows/Linux) or -1 (mac) when
// a key has no mapping.

#ifndef WSN_KEYMAP_H
#define WSN_KEYMAP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wsn_key_row {
  int32_t mac;       // macOS virtual key code
  int32_t vk;        // Windows virtual key, 0 = none
  int32_t scan;      // Windows set-1 scan code without E0
  int32_t extended;  // 1: E0 prefix / KEYEVENTF_EXTENDEDKEY
  int32_t evdev;     // Linux KEY_* code
  const char *name;  // for logs
} wsn_key_row;

#define WSN_KEYMAP_COUNT 119

// The table lives in a function so including the header never leaves an
// unused static array behind.
static inline const wsn_key_row *wsn_keymap_rows(void) {
  static const wsn_key_row rows[WSN_KEYMAP_COUNT] = {
      {  0, 0x41, 0x1E, 0,  30, "keyA"},
      { 11, 0x42, 0x30, 0,  48, "keyB"},
      {  8, 0x43, 0x2E, 0,  46, "keyC"},
      {  2, 0x44, 0x20, 0,  32, "keyD"},
      { 14, 0x45, 0x12, 0,  18, "keyE"},
      {  3, 0x46, 0x21, 0,  33, "keyF"},
      {  5, 0x47, 0x22, 0,  34, "keyG"},
      {  4, 0x48, 0x23, 0,  35, "keyH"},
      { 34, 0x49, 0x17, 0,  23, "keyI"},
      { 38, 0x4A, 0x24, 0,  36, "keyJ"},
      { 40, 0x4B, 0x25, 0,  37, "keyK"},
      { 37, 0x4C, 0x26, 0,  38, "keyL"},
      { 46, 0x4D, 0x32, 0,  50, "keyM"},
      { 45, 0x4E, 0x31, 0,  49, "keyN"},
      { 31, 0x4F, 0x18, 0,  24, "keyO"},
      { 35, 0x50, 0x19, 0,  25, "keyP"},
      { 12, 0x51, 0x10, 0,  16, "keyQ"},
      { 15, 0x52, 0x13, 0,  19, "keyR"},
      {  1, 0x53, 0x1F, 0,  31, "keyS"},
      { 17, 0x54, 0x14, 0,  20, "keyT"},
      { 32, 0x55, 0x16, 0,  22, "keyU"},
      {  9, 0x56, 0x2F, 0,  47, "keyV"},
      { 13, 0x57, 0x11, 0,  17, "keyW"},
      {  7, 0x58, 0x2D, 0,  45, "keyX"},
      { 16, 0x59, 0x15, 0,  21, "keyY"},
      {  6, 0x5A, 0x2C, 0,  44, "keyZ"},
      { 18, 0x31, 0x02, 0,   2, "digit1"},
      { 19, 0x32, 0x03, 0,   3, "digit2"},
      { 20, 0x33, 0x04, 0,   4, "digit3"},
      { 21, 0x34, 0x05, 0,   5, "digit4"},
      { 23, 0x35, 0x06, 0,   6, "digit5"},
      { 22, 0x36, 0x07, 0,   7, "digit6"},
      { 26, 0x37, 0x08, 0,   8, "digit7"},
      { 28, 0x38, 0x09, 0,   9, "digit8"},
      { 25, 0x39, 0x0A, 0,  10, "digit9"},
      { 29, 0x30, 0x0B, 0,  11, "digit0"},
      { 27, 0xBD, 0x0C, 0,  12, "minus"},
      { 24, 0xBB, 0x0D, 0,  13, "equal"},
      { 33, 0xDB, 0x1A, 0,  26, "bracketLeft"},
      { 30, 0xDD, 0x1B, 0,  27, "bracketRight"},
      { 42, 0xDC, 0x2B, 0,  43, "backslash"},
      { 41, 0xBA, 0x27, 0,  39, "semicolon"},
      { 39, 0xDE, 0x28, 0,  40, "quote"},
      { 50, 0xC0, 0x29, 0,  41, "backquote"},
      { 43, 0xBC, 0x33, 0,  51, "comma"},
      { 47, 0xBE, 0x34, 0,  52, "period"},
      { 44, 0xBF, 0x35, 0,  53, "slash"},
      { 10, 0xE2, 0x56, 0,  86, "intlBackslash"},
      { 93, 0xDC, 0x7D, 0, 124, "intlYen"},
      { 94, 0xC1, 0x73, 0,  89, "intlRo"},
      {104, 0x15, 0x72, 0, 122, "lang1"},
      {102, 0x19, 0x71, 0, 123, "lang2"},
      { 36, 0x0D, 0x1C, 0,  28, "enter"},
      { 48, 0x09, 0x0F, 0,  15, "tab"},
      { 49, 0x20, 0x39, 0,  57, "space"},
      { 51, 0x08, 0x0E, 0,  14, "backspace"},
      { 53, 0x1B, 0x01, 0,   1, "escape"},
      {117, 0x2E, 0x53, 1, 111, "delete"},
      {114, 0x2D, 0x52, 1, 110, "insert"},
      {110, 0x5D, 0x5D, 1, 127, "contextMenu"},
      {115, 0x24, 0x47, 1, 102, "home"},
      {119, 0x23, 0x4F, 1, 107, "end"},
      {116, 0x21, 0x49, 1, 104, "pageUp"},
      {121, 0x22, 0x51, 1, 109, "pageDown"},
      {123, 0x25, 0x4B, 1, 105, "arrowLeft"},
      {124, 0x27, 0x4D, 1, 106, "arrowRight"},
      {125, 0x28, 0x50, 1, 108, "arrowDown"},
      {126, 0x26, 0x48, 1, 103, "arrowUp"},
      { 56, 0xA0, 0x2A, 0,  42, "shiftLeft"},
      { 60, 0xA1, 0x36, 0,  54, "shiftRight"},
      { 59, 0xA2, 0x1D, 0,  29, "controlLeft"},
      { 62, 0xA3, 0x1D, 1,  97, "controlRight"},
      { 58, 0xA4, 0x38, 0,  56, "altLeft"},
      { 61, 0xA5, 0x38, 1, 100, "altRight"},
      { 55, 0x5B, 0x5B, 1, 125, "metaLeft"},
      { 54, 0x5C, 0x5C, 1, 126, "metaRight"},
      { 57, 0x14, 0x3A, 0,  58, "capsLock"},
      {122, 0x70, 0x3B, 0,  59, "f1"},
      {120, 0x71, 0x3C, 0,  60, "f2"},
      { 99, 0x72, 0x3D, 0,  61, "f3"},
      {118, 0x73, 0x3E, 0,  62, "f4"},
      { 96, 0x74, 0x3F, 0,  63, "f5"},
      { 97, 0x75, 0x40, 0,  64, "f6"},
      { 98, 0x76, 0x41, 0,  65, "f7"},
      {100, 0x77, 0x42, 0,  66, "f8"},
      {101, 0x78, 0x43, 0,  67, "f9"},
      {109, 0x79, 0x44, 0,  68, "f10"},
      {103, 0x7A, 0x57, 0,  87, "f11"},
      {111, 0x7B, 0x58, 0,  88, "f12"},
      {105, 0x7C, 0x64, 0, 183, "f13"},
      {107, 0x7D, 0x65, 0, 184, "f14"},
      {113, 0x7E, 0x66, 0, 185, "f15"},
      {106, 0x7F, 0x67, 0, 186, "f16"},
      { 64, 0x80, 0x68, 0, 187, "f17"},
      { 79, 0x81, 0x69, 0, 188, "f18"},
      { 80, 0x82, 0x6A, 0, 189, "f19"},
      { 90, 0x83, 0x6B, 0, 190, "f20"},
      { 82, 0x60, 0x52, 0,  82, "numpad0"},
      { 83, 0x61, 0x4F, 0,  79, "numpad1"},
      { 84, 0x62, 0x50, 0,  80, "numpad2"},
      { 85, 0x63, 0x51, 0,  81, "numpad3"},
      { 86, 0x64, 0x4B, 0,  75, "numpad4"},
      { 87, 0x65, 0x4C, 0,  76, "numpad5"},
      { 88, 0x66, 0x4D, 0,  77, "numpad6"},
      { 89, 0x67, 0x47, 0,  71, "numpad7"},
      { 91, 0x68, 0x48, 0,  72, "numpad8"},
      { 92, 0x69, 0x49, 0,  73, "numpad9"},
      { 65, 0x6E, 0x53, 0,  83, "numpadDecimal"},
      { 67, 0x6A, 0x37, 0,  55, "numpadMultiply"},
      { 69, 0x6B, 0x4E, 0,  78, "numpadAdd"},
      { 78, 0x6D, 0x4A, 0,  74, "numpadSubtract"},
      { 75, 0x6F, 0x35, 1,  98, "numpadDivide"},
      { 76, 0x0D, 0x1C, 1,  96, "numpadEnter"},
      { 71, 0x90, 0x45, 1,  69, "numLock"},
      { 81, 0x00, 0x59, 0, 117, "numpadEqual"},
      { 95, 0x6C, 0x7E, 0, 121, "numpadComma"},
      { 72, 0xAF, 0x30, 1, 115, "audioVolumeUp"},
      { 73, 0xAE, 0x2E, 1, 114, "audioVolumeDown"},
      { 74, 0xAD, 0x20, 1, 113, "audioVolumeMute"},
  };
  return rows;
}

static inline const wsn_key_row *wsn_keymap_find_mac(int32_t mac) {
  const wsn_key_row *rows = wsn_keymap_rows();
  for (int32_t i = 0; i < WSN_KEYMAP_COUNT; ++i) {
    if (rows[i].mac == mac) return &rows[i];
  }
  return 0;
}

// macOS -> Windows virtual key (0 = none).
static inline int32_t wsn_keymap_mac_to_vk(int32_t mac) {
  const wsn_key_row *row = wsn_keymap_find_mac(mac);
  return row ? row->vk : 0;
}

// macOS -> Windows scan code (0 = none); *extended is set when not null.
static inline int32_t wsn_keymap_mac_to_scan(int32_t mac, int32_t *extended) {
  const wsn_key_row *row = wsn_keymap_find_mac(mac);
  if (extended) *extended = row ? row->extended : 0;
  return row ? row->scan : 0;
}

// macOS -> Linux evdev code (0 = none).
static inline int32_t wsn_keymap_mac_to_evdev(int32_t mac) {
  const wsn_key_row *row = wsn_keymap_find_mac(mac);
  return row ? row->evdev : 0;
}

// Windows scan code (+ extended flag) -> macOS (-1 = none). Prefer this to
// the virtual key: it does not depend on the keyboard layout.
static inline int32_t wsn_keymap_mac_from_scan(int32_t scan, int32_t extended) {
  const wsn_key_row *rows = wsn_keymap_rows();
  for (int32_t i = 0; i < WSN_KEYMAP_COUNT; ++i) {
    if (rows[i].scan == scan && rows[i].extended == (extended ? 1 : 0)) {
      return rows[i].mac;
    }
  }
  return -1;
}

// Windows virtual key -> macOS (-1 = none). Generic VK_SHIFT/CONTROL/MENU
// resolve to the left key.
static inline int32_t wsn_keymap_mac_from_vk(int32_t vk) {
  switch (vk) {
    case 0x10: return 56;  // shiftLeft
    case 0x11: return 59;  // controlLeft
    case 0x12: return 58;  // altLeft
    default: break;
  }
  if (vk <= 0) return -1;
  const wsn_key_row *rows = wsn_keymap_rows();
  for (int32_t i = 0; i < WSN_KEYMAP_COUNT; ++i) {
    if (rows[i].vk == vk) return rows[i].mac;
  }
  return -1;
}

// WM_KEYDOWN/WM_KEYUP -> macOS (-1 = none): scan code first, then the
// virtual key (injected keys may carry no scan code).
static inline int32_t wsn_keymap_mac_from_win(int32_t vk, int32_t scan, int32_t extended) {
  int32_t mac = scan > 0 ? wsn_keymap_mac_from_scan(scan, extended) : -1;
  return mac >= 0 ? mac : wsn_keymap_mac_from_vk(vk);
}

// Linux evdev code -> macOS (-1 = none).
static inline int32_t wsn_keymap_mac_from_evdev(int32_t evdev) {
  const wsn_key_row *rows = wsn_keymap_rows();
  for (int32_t i = 0; i < WSN_KEYMAP_COUNT; ++i) {
    if (rows[i].evdev == evdev) return rows[i].mac;
  }
  return -1;
}

// X11 / GDK hardware keycode (evdev + 8) -> macOS (-1 = none).
static inline int32_t wsn_keymap_mac_from_xkb(int32_t keycode) {
  return keycode > 8 ? wsn_keymap_mac_from_evdev(keycode - 8) : -1;
}

#ifdef __cplusplus
}
#endif

#endif  // WSN_KEYMAP_H
