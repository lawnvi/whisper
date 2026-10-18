// Keyboard translation for streamed windows: Windows key messages to the
// shared input model (macOS virtual key codes, see src/wsn_keymap.h).

#pragma once

#include "../common/wsn_common.h"

#include <cstdint>
#include <string>

namespace wsn {

// Shift, Control, Option (Alt), Command (Windows key), Caps Lock.
int32_t CurrentModifiers();
bool IsModifierKey(WPARAM vk);
// WM_KEYDOWN / WM_KEYUP (and the SYS forms) → macOS key code, -1 if none.
// Positional (scan code first), except navigation keys, which follow the
// virtual key so the numeric keypad with Num Lock off acts as arrows.
int32_t MacKeyFromMessage(WPARAM vk, LPARAM lparam);
// What the key types with the current Shift and Caps Lock but without
// Ctrl/Alt: the text carried by a shortcut's key event ("a" for Ctrl+A).
std::wstring KeyCharacters(UINT vk, UINT scan);
// What the key types with the whole keyboard state, without touching the
// layout's dead-key state. >0: characters written; <0: a dead key; 0: none.
int TypedCharacters(UINT vk, UINT scan, std::wstring* out);
// The character a US layout types at this key position (0 if none), to
// tell keys that mean the same on the source from ones that do not.
wchar_t UsCharacter(int32_t mac, bool shift, bool caps);

}  // namespace wsn
