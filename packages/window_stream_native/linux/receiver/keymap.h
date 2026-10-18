// Keys of this keyboard → macOS virtual key codes (the shared input model:
// every source maps those to its own keys).

#ifndef WSN_RECEIVER_KEYMAP_H_
#define WSN_RECEIVER_KEYMAP_H_

#include <gdk/gdk.h>

#include <cstdint>

namespace wsn {

// By physical position (the event's hardware keycode: evdev + 8 on X11 and
// Wayland), as the macOS receiver sends NSEvent.keyCode. Modifier keys
// return -1: modifiers travel as flags with the keys they modify. Falls
// back to the keyval for keys without a hardware code.
int32_t MacKeyCode(const GdkEventKey* event);

// WSN_MOD_* for a GDK modifier state. Ctrl travels as Command, so every
// source sees one shortcut convention (Ctrl+C here = ⌘C on a Mac source =
// Ctrl+C on a Windows or Linux source).
int32_t Modifiers(guint state);

// What the key types on its own (as NSEvent.characters would): the
// keyval's character, or \r \t \x7f \x1b for Return, Tab, Backspace,
// Escape; empty for keys that type nothing.
void KeyCharacters(const GdkEventKey* event, char out[8]);

}  // namespace wsn

#endif  // WSN_RECEIVER_KEYMAP_H_
