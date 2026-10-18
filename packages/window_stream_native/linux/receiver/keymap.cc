#include "receiver/keymap.h"

#include <cstring>

#include "window_stream_native.h"
#include "wsn_keymap.h"

namespace wsn {

namespace {

// Keys the shared table (src/wsn_keymap.h, generated for every platform)
// leaves out, mapped the way macOS treats a PC keyboard.
struct KeyPair {
  uint16_t evdev;
  int16_t mac;
};

constexpr KeyPair kExtraKeys[] = {
    {70, 107},   // SCROLLLOCK → F14
    {92, 104},   // HENKAN → JIS kana
    {93, 104},   // KATAKANAHIRAGANA → JIS kana
    {94, 102},   // MUHENKAN → JIS eisu
    {95, 95},    // KPJPCOMMA → JIS keypad comma
    {99, 105},   // SYSRQ (Print Screen) → F13
    {119, 113},  // PAUSE → F15
};

// Modifier keys: sent as flags only (as the macOS receiver does).
constexpr uint16_t kModifierKeys[] = {29, 42, 54, 56, 58, 97, 100, 125, 126};

struct Table {
  int16_t mac[256];
  Table() {
    for (int evdev = 0; evdev < 256; evdev++) mac[evdev] = static_cast<int16_t>(wsn_keymap_mac_from_evdev(evdev));
    for (const KeyPair& pair : kExtraKeys) {
      if (mac[pair.evdev] < 0) mac[pair.evdev] = pair.mac;
    }
  }
};

const Table& Keys() {
  static const Table table;
  return table;
}

bool IsModifierKey(uint16_t evdev) {
  for (uint16_t key : kModifierKeys) {
    if (key == evdev) return true;
  }
  return false;
}

// Keys without a usable hardware code (synthetic events): by keyval.
int32_t ByKeyval(guint keyval) {
  switch (keyval) {
    case GDK_KEY_Return:
    case GDK_KEY_ISO_Enter: return 36;
    case GDK_KEY_KP_Enter: return 76;
    case GDK_KEY_Tab:
    case GDK_KEY_ISO_Left_Tab: return 48;
    case GDK_KEY_BackSpace: return 51;
    case GDK_KEY_Escape: return 53;
    case GDK_KEY_space: return 49;
    case GDK_KEY_Delete: return 117;
    case GDK_KEY_Home: return 115;
    case GDK_KEY_End: return 119;
    case GDK_KEY_Page_Up: return 116;
    case GDK_KEY_Page_Down: return 121;
    case GDK_KEY_Left: return 123;
    case GDK_KEY_Right: return 124;
    case GDK_KEY_Down: return 125;
    case GDK_KEY_Up: return 126;
    default: break;
  }
  static const int16_t kLetters[26] = {0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
                                       45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6};
  static const int16_t kDigits[10] = {29, 18, 19, 20, 21, 23, 22, 26, 28, 25};
  guint lower = gdk_keyval_to_lower(keyval);
  if (lower >= GDK_KEY_a && lower <= GDK_KEY_z) return kLetters[lower - GDK_KEY_a];
  if (keyval >= GDK_KEY_0 && keyval <= GDK_KEY_9) return kDigits[keyval - GDK_KEY_0];
  return -1;
}

}  // namespace

int32_t MacKeyCode(const GdkEventKey* event) {
  int evdev = static_cast<int>(event->hardware_keycode) - 8;
  if (evdev > 0 && evdev < 256) {
    if (IsModifierKey(static_cast<uint16_t>(evdev))) return -1;
    int16_t mac = Keys().mac[evdev];
    if (mac >= 0) return mac;
  }
  if (event->is_modifier) return -1;
  return ByKeyval(event->keyval);
}

int32_t Modifiers(guint state) {
  int32_t value = 0;
  if (state & GDK_SHIFT_MASK) value |= WSN_MOD_SHIFT;
  if (state & GDK_CONTROL_MASK) value |= WSN_MOD_COMMAND;
  if (state & GDK_MOD1_MASK) value |= WSN_MOD_OPTION;
  if (state & GDK_LOCK_MASK) value |= WSN_MOD_CAPS_LOCK;
  return value;
}

void KeyCharacters(const GdkEventKey* event, char out[8]) {
  std::memset(out, 0, 8);
  switch (event->keyval) {
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
    case GDK_KEY_ISO_Enter: out[0] = '\r'; return;
    case GDK_KEY_Tab:
    case GDK_KEY_ISO_Left_Tab: out[0] = '\t'; return;
    case GDK_KEY_BackSpace: out[0] = 0x7f; return;
    case GDK_KEY_Escape: out[0] = 0x1b; return;
    default: break;
  }
  gunichar c = gdk_keyval_to_unicode(event->keyval);
  if (c < 0x20 || c == 0x7f) return;
  g_unichar_to_utf8(c, out);
}

}  // namespace wsn
