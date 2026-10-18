// Words the streamed windows show (wsn_set_strings): English until Dart
// sends the user's language.

#pragma once

#include <string>

namespace wsn {

// `json` is a UTF-8 object of strings, {"volume": …, "mute": …,
// "unmute": …}; missing or empty keys keep their word. Any thread.
void SetUiStrings(const char* json);

// The word for `key` ("volume", "mute", "unmute"). Any thread.
std::wstring UiString(const char* key);

}  // namespace wsn
