// Words the streamed windows show (wsn_set_strings): English until Dart
// sends the user's language.

#ifndef WSN_RECEIVER_UI_STRINGS_H_
#define WSN_RECEIVER_UI_STRINGS_H_

#include <string>

namespace wsn {

// `json` is a UTF-8 object of strings, {"volume": …, "mute": …,
// "unmute": …}; missing or empty keys keep their word. Any thread.
void SetUiStrings(const char* json);

// The word (UTF-8) for `key` ("volume", "mute", "unmute"). Any thread.
std::string UiString(const char* key);

}  // namespace wsn

#endif  // WSN_RECEIVER_UI_STRINGS_H_
