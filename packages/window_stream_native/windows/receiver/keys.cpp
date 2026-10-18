#include "keys.h"

#include "wsn_keymap.h"

namespace wsn {
namespace {

bool Down(int vk) { return (GetKeyState(vk) & 0x8000) != 0; }

// ToUnicodeEx flag: leave the keyboard (dead key) state alone (Windows 10
// 1607 and later).
constexpr UINT kNoStateChange = 0x4;

int Translate(UINT vk, UINT scan, const BYTE state[256], std::wstring* out) {
  wchar_t buffer[8] = {};
  HKL layout = GetKeyboardLayout(0);
  int count = ToUnicodeEx(vk, scan, state, buffer, 8, kNoStateChange, layout);
  if (out != nullptr) {
    out->assign(buffer, count > 0 ? static_cast<size_t>(count) : 0);
  }
  return count;
}

}  // namespace

int32_t CurrentModifiers() {
  int32_t value = 0;
  if (Down(VK_SHIFT)) value |= WSN_MOD_SHIFT;
  if (Down(VK_CONTROL)) value |= WSN_MOD_CONTROL;
  if (Down(VK_MENU)) value |= WSN_MOD_OPTION;
  if (Down(VK_LWIN) || Down(VK_RWIN)) value |= WSN_MOD_COMMAND;
  if (GetKeyState(VK_CAPITAL) & 0x0001) value |= WSN_MOD_CAPS_LOCK;
  return value;
}

bool IsModifierKey(WPARAM vk) {
  switch (vk) {
    case VK_SHIFT:
    case VK_LSHIFT:
    case VK_RSHIFT:
    case VK_CONTROL:
    case VK_LCONTROL:
    case VK_RCONTROL:
    case VK_MENU:
    case VK_LMENU:
    case VK_RMENU:
    case VK_LWIN:
    case VK_RWIN:
    case VK_CAPITAL:
    case VK_NUMLOCK:
    case VK_SCROLL:
      return true;
    default:
      return false;
  }
}

int32_t MacKeyFromMessage(WPARAM vk, LPARAM lparam) {
  const int32_t scan = static_cast<int32_t>((lparam >> 16) & 0xFF);
  const int32_t extended = static_cast<int32_t>((lparam >> 24) & 0x1);
  switch (vk) {
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_LEFT:
    case VK_RIGHT:
    case VK_UP:
    case VK_DOWN:
    case VK_INSERT:
    case VK_DELETE:
      return wsn_keymap_mac_from_vk(static_cast<int32_t>(vk));
    case VK_RETURN:
      return extended ? 76 : 36;  // numpad Enter / Return
    default:
      break;
  }
  return wsn_keymap_mac_from_win(static_cast<int32_t>(vk), scan, extended);
}

std::wstring KeyCharacters(UINT vk, UINT scan) {
  BYTE state[256] = {};
  if (Down(VK_SHIFT)) state[VK_SHIFT] = 0x80;
  if (GetKeyState(VK_CAPITAL) & 0x0001) state[VK_CAPITAL] = 0x01;
  std::wstring out;
  if (Translate(vk, scan, state, &out) <= 0) return std::wstring();
  return out;
}

int TypedCharacters(UINT vk, UINT scan, std::wstring* out) {
  BYTE state[256];
  if (!GetKeyboardState(state)) return 0;
  return Translate(vk, scan, state, out);
}

wchar_t UsCharacter(int32_t mac, bool shift, bool caps) {
  struct Row {
    int32_t mac;
    wchar_t plain;
    wchar_t shifted;
  };
  static const Row kRows[] = {
      {0, L'a', L'A'},   {11, L'b', L'B'},  {8, L'c', L'C'},   {2, L'd', L'D'},   {14, L'e', L'E'},
      {3, L'f', L'F'},   {5, L'g', L'G'},   {4, L'h', L'H'},   {34, L'i', L'I'},  {38, L'j', L'J'},
      {40, L'k', L'K'},  {37, L'l', L'L'},  {46, L'm', L'M'},  {45, L'n', L'N'},  {31, L'o', L'O'},
      {35, L'p', L'P'},  {12, L'q', L'Q'},  {15, L'r', L'R'},  {1, L's', L'S'},   {17, L't', L'T'},
      {32, L'u', L'U'},  {9, L'v', L'V'},   {13, L'w', L'W'},  {7, L'x', L'X'},   {16, L'y', L'Y'},
      {6, L'z', L'Z'},   {18, L'1', L'!'},  {19, L'2', L'@'},  {20, L'3', L'#'},  {21, L'4', L'$'},
      {23, L'5', L'%'},  {22, L'6', L'^'},  {26, L'7', L'&'},  {28, L'8', L'*'},  {25, L'9', L'('},
      {29, L'0', L')'},  {27, L'-', L'_'},  {24, L'=', L'+'},  {33, L'[', L'{'},  {30, L']', L'}'},
      {42, L'\\', L'|'}, {41, L';', L':'},  {39, L'\'', L'"'}, {50, L'`', L'~'},  {43, L',', L'<'},
      {47, L'.', L'>'},  {44, L'/', L'?'},  {49, L' ', L' '},  {82, L'0', L'0'},  {83, L'1', L'1'},
      {84, L'2', L'2'},  {85, L'3', L'3'},  {86, L'4', L'4'},  {87, L'5', L'5'},  {88, L'6', L'6'},
      {89, L'7', L'7'},  {91, L'8', L'8'},  {92, L'9', L'9'},  {65, L'.', L'.'},  {67, L'*', L'*'},
      {69, L'+', L'+'},  {78, L'-', L'-'},  {75, L'/', L'/'},  {81, L'=', L'='},
  };
  for (const Row& row : kRows) {
    if (row.mac != mac) continue;
    bool letter = row.plain >= L'a' && row.plain <= L'z';
    bool upper = letter ? (shift != caps) : shift;
    return upper ? row.shifted : row.plain;
  }
  return 0;
}

}  // namespace wsn
