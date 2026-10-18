#include "wsn_inject.h"

#include "wsn_window.h"
#include "wsn_xaml.h"

#include <windowsx.h>

#include <algorithm>
#include <cmath>

#if __has_include("wsn_keymap.h")
#include "wsn_keymap.h"
#define WSN_HAVE_KEYMAP 1
#elif __has_include("../../src/wsn_keymap.h")
#include "../../src/wsn_keymap.h"
#define WSN_HAVE_KEYMAP 1
#else
#define WSN_HAVE_KEYMAP 0
#endif

namespace wsn {

namespace {

// A small positional fallback (macOS key code -> VK, set-1 scan, extended)
// for when the generated wsn_keymap.h (from agent E) is not present yet.
struct FallbackKey {
  int mac;
  WORD vk;
  WORD scan;
  bool extended;
};
const FallbackKey kFallback[] = {
    {0, 0x41, 0x1E, false},  {1, 0x53, 0x1F, false},  {2, 0x44, 0x20, false},  {3, 0x46, 0x21, false},
    {4, 0x48, 0x23, false},  {5, 0x47, 0x22, false},  {6, 0x5A, 0x2C, false},  {7, 0x58, 0x2D, false},
    {8, 0x43, 0x2E, false},  {9, 0x56, 0x2F, false},  {11, 0x42, 0x30, false}, {12, 0x51, 0x10, false},
    {13, 0x57, 0x11, false}, {14, 0x45, 0x12, false}, {15, 0x52, 0x13, false}, {16, 0x59, 0x15, false},
    {17, 0x54, 0x14, false}, {18, 0x31, 0x02, false}, {19, 0x32, 0x03, false}, {20, 0x33, 0x04, false},
    {21, 0x34, 0x05, false}, {22, 0x36, 0x07, false}, {23, 0x35, 0x06, false}, {24, 0xBB, 0x0D, false},
    {25, 0x39, 0x0A, false}, {26, 0x37, 0x08, false}, {27, 0xBD, 0x0C, false}, {28, 0x38, 0x09, false},
    {29, 0x30, 0x0B, false}, {30, 0xDD, 0x1B, false}, {31, 0x4F, 0x18, false}, {32, 0x55, 0x16, false},
    {33, 0xDB, 0x1A, false}, {34, 0x49, 0x17, false}, {35, 0x50, 0x19, false}, {36, 0x0D, 0x1C, false},
    {37, 0x4C, 0x26, false}, {38, 0x4A, 0x24, false}, {39, 0xDE, 0x28, false}, {40, 0x4B, 0x25, false},
    {41, 0xBA, 0x27, false}, {42, 0xDC, 0x2B, false}, {43, 0xBC, 0x33, false}, {44, 0xBF, 0x35, false},
    {45, 0x4E, 0x31, false}, {46, 0x4D, 0x32, false}, {47, 0xBE, 0x34, false}, {48, 0x09, 0x0F, false},
    {49, 0x20, 0x39, false}, {50, 0xC0, 0x29, false}, {51, 0x08, 0x0E, false}, {53, 0x1B, 0x01, false},
    {123, 0x25, 0x4B, true}, {124, 0x27, 0x4D, true}, {125, 0x28, 0x50, true}, {126, 0x26, 0x48, true},
    {115, 0x24, 0x47, true}, {119, 0x23, 0x4F, true}, {116, 0x21, 0x49, true}, {121, 0x22, 0x51, true},
    {117, 0x2E, 0x53, true}, {114, 0x2D, 0x52, true}, {71, 0x1B, 0x01, false},
    {122, 0x70, 0x3B, false}, {120, 0x71, 0x3C, false}, {99, 0x72, 0x3D, false}, {118, 0x73, 0x3E, false},
    {96, 0x74, 0x3F, false}, {97, 0x75, 0x40, false}, {98, 0x76, 0x41, false}, {100, 0x77, 0x42, false},
    {101, 0x78, 0x43, false}, {109, 0x79, 0x44, false}, {103, 0x7A, 0x57, false}, {111, 0x7B, 0x58, false},
    {56, 0xA0, 0x2A, false}, {60, 0xA1, 0x36, false}, {59, 0xA2, 0x1D, false}, {62, 0xA3, 0x1D, true},
    {58, 0xA4, 0x38, false}, {61, 0xA5, 0x38, true},
};

}  // namespace

bool MacKeyToWindows(int mac, KeyCode* out) {
#if WSN_HAVE_KEYMAP
  if (const wsn_key_row* row = wsn_keymap_find_mac(mac)) {
    if (row->vk != 0) {
      out->vk = static_cast<WORD>(row->vk);
      out->scan = static_cast<WORD>(row->scan);
      out->extended = row->extended != 0;
      return true;
    }
  }
#endif
  for (const auto& key : kFallback) {
    if (key.mac == mac) {
      out->vk = key.vk;
      out->scan = key.scan;
      out->extended = key.extended;
      return true;
    }
  }
  return false;
}

POINT FrameFractionToScreen(HWND top, double fx, double fy) {
  RECT frame = FrameBounds(top);
  fx = std::min(std::max(fx, 0.0), 1.0);
  fy = std::min(std::max(fy, 0.0), 1.0);
  return POINT{frame.left + static_cast<LONG>(std::lround(fx * RectWidth(frame))),
               frame.top + static_cast<LONG>(std::lround(fy * RectHeight(frame)))};
}

HWND ChildAt(HWND top, POINT screen) {
  // RealChildWindowFromPoint picks the child that would actually receive the
  // mouse message (it handles controls like Edit that ChildWindowFromPointEx
  // mis-attributes to the parent, which broke focus on staged windows).
  HWND target = top;
  for (int depth = 0; depth < 32; ++depth) {
    POINT client = screen;
    if (!ScreenToClient(target, &client)) break;
    HWND child = RealChildWindowFromPoint(target, client);
    if (child == nullptr || child == target) break;
    target = child;
  }
  return target;
}

POINT ScreenToClientOf(HWND window, POINT screen) {
  POINT p = screen;
  ScreenToClient(window, &p);
  return p;
}

POINT ScreenForWindow(HWND window, POINT screen) {
  // Per-monitor DPI windows can see screen coordinates differently; round
  // trip through the window's own client space keeps them consistent.
  POINT client = screen;
  ScreenToClient(window, &client);
  ClientToScreen(window, &client);
  return client;
}

LRESULT HitTest(HWND top, POINT screen) {
  DWORD_PTR result = HTNOWHERE;
  if (SendMessageTimeoutW(top, WM_NCHITTEST, 0, MAKELPARAM(screen.x, screen.y), SMTO_ABORTIFHUNG, 200, &result) ==
      0) {
    return HTERROR;
  }
  return static_cast<LRESULT>(result);
}

bool IsForeground(HWND top) { return GetForegroundWindow() == top; }

namespace {
// The switch to another process's window can take a moment to show.
bool BecameForeground(HWND window) {
  for (int i = 0; i < 10; ++i) {
    if (GetForegroundWindow() == window) return true;
    Sleep(8);
  }
  return false;
}
}  // namespace

bool BringToForeground(HWND top, std::string* how) {
  if (GetForegroundWindow() == top) {
    if (how) *how = "already";
    return true;
  }
  HWND root = GetAncestor(top, GA_ROOT);
  if (root == nullptr) root = top;
  if (SetForegroundWindow(root) && BecameForeground(root)) {
    if (how) *how = "set";
    return true;
  }
  // The foreground lock: share the foreground thread's input state for a
  // moment, which lets this thread move the foreground.
  DWORD self = GetCurrentThreadId();
  HWND fg = GetForegroundWindow();
  DWORD fg_thread = fg != nullptr ? GetWindowThreadProcessId(fg, nullptr) : 0;
  if (fg_thread != 0 && fg_thread != self && AttachThreadInput(self, fg_thread, TRUE)) {
    SetForegroundWindow(root);
    AttachThreadInput(self, fg_thread, FALSE);
    if (BecameForeground(root)) {
      if (how) *how = "attach";
      return true;
    }
  }
  // Older variant: attach the foreground thread to the target's.
  DWORD target_thread = GetWindowThreadProcessId(root, nullptr);
  fg = GetForegroundWindow();
  fg_thread = fg != nullptr ? GetWindowThreadProcessId(fg, nullptr) : 0;
  if (fg_thread != 0 && fg_thread != target_thread && AttachThreadInput(fg_thread, target_thread, TRUE)) {
    SetForegroundWindow(root);
    AttachThreadInput(fg_thread, target_thread, FALSE);
    if (BecameForeground(root)) {
      if (how) *how = "attach2";
      return true;
    }
  }
  // The foreground lock is lifted for the process that typed last: an
  // injected key of no meaning (vk 0xFF, nothing maps to it) makes that us.
  {
    INPUT nothing[2] = {};
    nothing[0].type = nothing[1].type = INPUT_KEYBOARD;
    nothing[0].ki.wVk = nothing[1].ki.wVk = 0xFF;
    nothing[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, nothing, sizeof(INPUT));
    SetForegroundWindow(root);
    if (BecameForeground(root)) {
      if (how) *how = "after input";
      return true;
    }
  }
  // Last: the Alt key (pressing Alt always lifts the lock). Its release can
  // put the new window's menu bar in menu mode; close that again.
  {
    INPUT alt[1] = {};
    alt[0].type = INPUT_KEYBOARD;
    alt[0].ki.wVk = VK_MENU;
    SendInput(1, alt, sizeof(INPUT));
    SetForegroundWindow(root);
    alt[0].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, alt, sizeof(INPUT));
    bool ok = BecameForeground(root);
    if (ok) {
      Sleep(30);
      GUITHREADINFO gui{sizeof(gui)};
      if (GetGUIThreadInfo(target_thread, &gui) && (gui.flags & GUI_INMENUMODE)) {
        INPUT esc[2] = {};
        esc[0].type = esc[1].type = INPUT_KEYBOARD;
        esc[0].ki.wVk = esc[1].ki.wVk = VK_ESCAPE;
        esc[1].ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(2, esc, sizeof(INPUT));
      }
    }
    if (how) *how = ok ? "alt" : "failed";
    return ok;
  }
}

namespace {

bool IsFunctionKey(WORD vk) { return vk >= VK_F1 && vk <= VK_F24; }

// A plain text control, which handles its editing chords itself.
bool IsTextControl(HWND hwnd) {
  wchar_t cls[96] = {};
  GetClassNameW(hwnd, cls, 96);
  return _wcsicmp(cls, L"Edit") == 0 || _wcsnicmp(cls, L"RichEdit", 8) == 0 ||
         _wcsnicmp(cls, L"WindowsForms10.EDIT", 19) == 0 || _wcsnicmp(cls, L"WindowsForms10.RichEdit", 23) == 0 ||
         _wcsicmp(cls, L"Scintilla") == 0;
}

bool IsEditingChord(WORD vk, bool ctrl, bool alt) {
  if (!ctrl || alt) return false;
  switch (vk) {
    case 'A': case 'C': case 'V': case 'X': case 'Z': case 'Y':
    case VK_BACK: case VK_DELETE: case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN: case VK_HOME: case VK_END:
      return true;
    default:
      return false;
  }
}

struct ThreadWindows {
  std::vector<HWND> list;
};
BOOL CALLBACK CollectThreadWindow(HWND hwnd, LPARAM param) {
  if (IsWindowVisible(hwnd)) reinterpret_cast<ThreadWindows*>(param)->list.push_back(hwnd);
  return TRUE;
}
std::vector<HWND> VisibleThreadWindows(DWORD thread) {
  ThreadWindows windows;
  EnumThreadWindows(thread, CollectThreadWindow, reinterpret_cast<LPARAM>(&windows));
  return windows.list;
}

bool InMenuMode(DWORD thread) {
  GUITHREADINFO gui{sizeof(gui)};
  return GetGUIThreadInfo(thread, &gui) && (gui.flags & (GUI_INMENUMODE | GUI_POPUPMENUMODE | GUI_SYSTEMMENUMODE));
}

void AddKey(std::vector<INPUT>* inputs, WORD vk, WORD scan, bool extended, bool down) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vk;
  input.ki.wScan = scan;
  input.ki.dwFlags = KEYEVENTF_SCANCODE | (extended ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
  inputs->push_back(input);
}

}  // namespace

Injector::Injector(HWND top) : top_(top) {}
Injector::~Injector() { ReleaseAll(); }

bool Injector::EnsureForeground() {
  double now = NowMs();
  if (IsForeground(top_)) {
    foreground_checked_ms_ = now;
    return true;
  }
  std::string how;
  bool ok = BringToForeground(top_, &how);
  foreground_checked_ms_ = now;
  // Give the window a moment to take the keys.
  double end = now + 180;
  while (!IsForeground(top_) && NowMs() < end) Sleep(8);
  ok = IsForeground(top_);
  if (ok && on_activated) on_activated();
  if (on_note) on_note(Format("foreground via %s: %d", how.c_str(), ok));
  return ok;
}

HWND Injector::FocusedChild() {
  // A background window's thread has no GUI focus (GetGUIThreadInfo.hwndFocus
  // is only set for the foreground thread), so the keyboard target is the
  // child the viewer last clicked — that is where they want to type, and an
  // edit control inserts WM_CHAR / handles WM_KEYDOWN at its caret whether or
  // not it holds the system focus. When foreground, trust the real focus.
  DWORD thread = GetWindowThreadProcessId(top_, nullptr);
  GUITHREADINFO gui{sizeof(gui)};
  if (GetGUIThreadInfo(thread, &gui) && gui.hwndFocus != nullptr && IsWindow(gui.hwndFocus) &&
      (gui.hwndFocus == top_ || IsChild(top_, gui.hwndFocus))) {
    return gui.hwndFocus;
  }
  if (key_target_ != nullptr && IsWindow(key_target_) &&
      (key_target_ == top_ || IsChild(top_, key_target_))) {
    return key_target_;
  }
  return top_;
}

// Types the whole chord (modifiers down, key down and up, modifiers up) in
// one SendInput call, so nothing can stay pressed (a Mac viewer may never
// send the key up of a Command chord).
void TypeChord(const KeyCode& key, bool ctrl, bool shift, bool alt) {
  std::vector<INPUT> inputs;
  if (ctrl) AddKey(&inputs, VK_LCONTROL, 0x1D, false, true);
  if (shift) AddKey(&inputs, VK_LSHIFT, 0x2A, false, true);
  if (alt) AddKey(&inputs, VK_LMENU, 0x38, false, true);
  AddKey(&inputs, key.vk, key.scan, key.extended, true);
  AddKey(&inputs, key.vk, key.scan, key.extended, false);
  if (alt) AddKey(&inputs, VK_LMENU, 0x38, false, false);
  if (shift) AddKey(&inputs, VK_LSHIFT, 0x2A, false, false);
  if (ctrl) AddKey(&inputs, VK_LCONTROL, 0x1D, false, false);
  SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
}

void Injector::AddPopup(HWND popup) {
  if (popup != nullptr && popup != top_ && std::find(popups_.begin(), popups_.end(), popup) == popups_.end()) {
    popups_.push_back(popup);
  }
}

void Injector::SetPopupShift(HWND popup, POINT shift) {
  for (auto& [w, s] : popup_shifts_) {
    if (w == popup) {
      s = shift;  // relative to where XAML put it (we only move popups it placed)
      return;
    }
  }
  popup_shifts_.push_back({popup, shift});
}

bool Injector::PopupAnchor(RECT* element) const {
  if (anchor_tick_ == 0) return false;
  if (!anchor_sticky_ && GetTickCount64() - anchor_tick_ > 1500) return false;
  *element = anchor_rect_;
  return true;
}

bool Injector::XamlContentRect(HWND popup, RECT* out) {
  if (!IsXamlHost(popup)) return false;
  if (!xaml_) xaml_ = std::make_unique<XamlInput>();
  return xaml_->ContentRect(popup, out);
}

HWND Injector::TopAt(POINT screen) {
  for (auto it = popups_.rbegin(); it != popups_.rend(); ++it) {
    RECT rect{};
    if (IsWindow(*it) && IsWindowVisible(*it) && GetWindowRect(*it, &rect) && PtInRect(&rect, screen)) return *it;
  }
  return top_;
}

bool Injector::RealKeysBegin() {
  HWND previous = GetForegroundWindow();
  if (previous != top_) {
    if (!EnsureForeground()) return false;
    if (real_keys_return_ == nullptr && previous != nullptr) real_keys_return_ = previous;
  }
  real_keys_until_ = GetTickCount64() + 2000;
  return true;
}

void Injector::Tick() {
  if (real_keys_return_ != nullptr && GetTickCount64() > real_keys_until_) {
    HWND previous = real_keys_return_;
    real_keys_return_ = nullptr;
    if (IsForeground(top_) && IsWindow(previous)) BringToForeground(previous, nullptr);
  }
  if (return_front_ == nullptr) return;
  HWND front = GetForegroundWindow();
  DWORD thread = GetWindowThreadProcessId(top_, nullptr);
  if (front == nullptr || GetWindowThreadProcessId(front, nullptr) != thread) {
    return_front_ = nullptr;  // something else took the front meanwhile
    return;
  }
  if (RealKeyboardMode()) return;  // the menu/popup is still open
  HWND previous = return_front_;
  return_front_ = nullptr;
  if (IsWindow(previous) && front == top_) {
    bool ok = BringToForeground(previous, nullptr);
    if (on_note) on_note(Format("menu/popup closed: front %s", ok ? "given back" : "not given back"));
  }
}

bool Injector::RealKeyboardMode() {
  popups_.erase(std::remove_if(popups_.begin(), popups_.end(),
                               [](HWND w) { return !IsWindow(w) || !IsWindowVisible(w); }),
                popups_.end());
  popup_shifts_.erase(std::remove_if(popup_shifts_.begin(), popup_shifts_.end(),
                                     [](const std::pair<HWND, POINT>& p) { return !IsWindow(p.first); }),
                      popup_shifts_.end());
  HWND front = GetForegroundWindow();
  DWORD thread = GetWindowThreadProcessId(top_, nullptr);
  if (front == nullptr || GetWindowThreadProcessId(front, nullptr) != thread) return false;  // app not in front
  if (InMenuMode(thread) || !popups_.empty()) return true;
  // One of the window's own dialogs is in front.
  return front != top_ && GetAncestor(front, GA_ROOTOWNER) == top_;
}

bool Injector::ForegroundChord(const KeyCode& key, bool ctrl, bool shift, bool alt) {
  DWORD thread = GetWindowThreadProcessId(top_, nullptr);
  HWND previous = GetForegroundWindow();
  bool was_front = previous == top_;
  std::vector<HWND> before = VisibleThreadWindows(thread);
  auto thread_focus = [&]() -> HWND {
    GUITHREADINFO gui{sizeof(gui)};
    if (!GetGUIThreadInfo(thread, &gui) || gui.hwndFocus == nullptr) return nullptr;
    return gui.hwndFocus == top_ || IsChild(top_, gui.hwndFocus) ? gui.hwndFocus : nullptr;
  };
  HWND focus_before = thread_focus();
  if (!was_front && !EnsureForeground()) return false;
  DWORD self = GetCurrentThreadId();
  bool attached = thread != self && AttachThreadInput(self, thread, TRUE);
  // Activation may move the window's focus (to the window itself): keep it
  // where it was, or on the control the viewer last pressed when the window
  // had none, so the shortcut applies there.
  if (!was_front && attached) {
    HWND focus_now = thread_focus();
    if (focus_before != nullptr && focus_now != focus_before && IsWindow(focus_before)) {
      SetFocus(focus_before);
    } else if (focus_before == nullptr && (focus_now == nullptr || focus_now == top_) && key_target_ != nullptr &&
               IsWindow(key_target_) && IsChild(top_, key_target_)) {
      SetFocus(key_target_);
    }
  }
  SHORT toggle_before = static_cast<SHORT>(GetKeyState(key.vk) & 1);
  TypeChord(key, ctrl, shift, alt);
  // Wait until the app has read the chord before the foreground moves on:
  // its key state (shared while attached) flips the key's toggle bit when it
  // reads the key down, and clears the down bit when it reads the key up —
  // by then the key down (and its accelerator) has been handled.
  bool read = false;
  double end = NowMs() + 700;
  while (NowMs() < end) {
    SHORT state = GetKeyState(key.vk);
    if (static_cast<SHORT>(state & 1) != toggle_before && (state & 0x8000) == 0) {
      read = true;
      break;
    }
    Sleep(2);
  }
  if (attached) AttachThreadInput(self, thread, FALSE);
  // What the chord opened: a menu, a dialog, a flyout or a new window keep
  // the front (and get real keys) until they close.
  Sleep(60);
  for (HWND w : VisibleThreadWindows(thread)) {
    if (w != top_ && std::find(before.begin(), before.end(), w) == before.end()) popups_.push_back(w);
  }
  bool keep_front = RealKeyboardMode();
  const char* outcome = was_front ? "was in front" : keep_front ? "kept in front (menu/dialog/popup)" : "front given back";
  if (!was_front && keep_front && previous != nullptr && IsWindow(previous)) return_front_ = previous;
  if (!was_front && !keep_front && previous != nullptr && IsWindow(previous)) {
    std::string how;
    if (!BringToForeground(previous, &how)) outcome = "front not given back";
  }
  if (on_note) {
    on_note(Format("shortcut vk 0x%02x%s%s%s by keyboard: read %d, %s", key.vk, ctrl ? " ctrl" : "",
                   shift ? " shift" : "", alt ? " alt" : "", read, outcome));
  }
  return true;
}

void Injector::Key(bool down, int mac, int modifiers, const std::wstring& text) {
  KeyCode key{};
  if (!MacKeyToWindows(mac, &key)) {
    if (on_note) on_note(Format("no key for mac %d", mac));
    return;
  }
  bool ctrl = (modifiers & (kModControl | kModCommand)) != 0;
  bool shift = (modifiers & kModShift) != 0;
  bool alt = (modifiers & kModOption) != 0;

  // The chord of this key was typed whole on its down.
  if (!down && chord_keys_.erase(mac) != 0) return;
  if (down) last_input_tick_ = GetTickCount64();

  // A UWP text box: real keys, with the window in front while typing.
  if (uwp_text_ && down && RealKeysBegin()) {
    TypeChord(key, ctrl, shift, alt);
    chord_keys_.insert(mac);
    return;
  }

  // A menu, dialog or popup of the app is open in front: real keys.
  if (RealKeyboardMode()) {
    if (down) {
      TypeChord(key, ctrl, shift, alt);
      chord_keys_.insert(mac);
    }
    return;
  }

  // Shortcuts (Ctrl/Alt chords, function keys) must reach the app's
  // accelerators: through the real keyboard with the window briefly in front.
  // An edit control's own editing chords stay on the message path.
  bool shortcut = ctrl || alt || IsFunctionKey(key.vk);
  if (shortcut && IsEditingChord(key.vk, ctrl, alt) && IsTextControl(FocusedChild())) shortcut = false;
  if (down && shortcut && ForegroundChord(key, ctrl, shift, alt)) {
    chord_keys_.insert(mac);
    return;
  }

  // Otherwise deliver to the keyboard target by message (works off-screen and
  // for a background window). AttachThreadInput lets the target's GetKeyState
  // see the modifiers we set while it processes the key (SendMessage is
  // synchronous, so processing finishes before we detach and restore).
  HWND focus = FocusedChild();
  DWORD thread = GetWindowThreadProcessId(top_, nullptr);
  DWORD self = GetCurrentThreadId();
  bool attached = thread != self && AttachThreadInput(self, thread, TRUE);
  BYTE state[256];
  BYTE next[256];
  bool had_state = GetKeyboardState(state) != FALSE;
  if (had_state) {
    memcpy(next, state, sizeof(next));
    auto set = [&](int vk, bool d) { next[vk] = d ? 0x80 : 0; };
    set(VK_CONTROL, ctrl);
    set(VK_LCONTROL, ctrl);
    set(VK_SHIFT, shift);
    set(VK_LSHIFT, shift);
    set(VK_MENU, alt);
    set(VK_LMENU, alt);
    SetKeyboardState(next);
  }
  LPARAM lparam = 1 | (static_cast<LPARAM>(key.scan) << 16) | (key.extended ? (static_cast<LPARAM>(1) << 24) : 0);
  if (alt) lparam |= static_cast<LPARAM>(1) << 29;  // context code
  if (!down) lparam |= (static_cast<LPARAM>(1) << 30) | (static_cast<LPARAM>(1) << 31);
  DWORD_PTR result = 0;
  UINT message = down ? (alt ? WM_SYSKEYDOWN : WM_KEYDOWN) : (alt ? WM_SYSKEYUP : WM_KEYUP);
  SendMessageTimeoutW(focus, message, key.vk, lparam, SMTO_ABORTIFHUNG, 150, &result);
  // A sent WM_KEYDOWN bypasses the app's message loop, so TranslateMessage
  // never runs and no WM_CHAR is produced. Generate the character(s) the key
  // would have typed (printable, plus control codes for Back/Enter/Tab/Esc
  // and Ctrl+A..Z, which Edit/RichEdit act on) and post them.
  if (down && had_state) {
    wchar_t chars[8];
    HKL layout = GetKeyboardLayout(thread);
    int n = ToUnicodeEx(key.vk, key.scan, next, chars, 8, 0x4 /* don't change kernel state */, layout);
    // Alt+key types nothing: it is WM_SYSCHAR (DefWindowProc opens the
    // window's menu with it), as TranslateMessage would make it.
    bool menu_key = alt && !ctrl;
    if (n > 0) {
      for (int i = 0; i < n; ++i) PostMessageW(focus, menu_key ? WM_SYSCHAR : WM_CHAR, chars[i], menu_key ? (lparam & ~(3LL << 30)) : 1);
    } else if (!text.empty() && !menu_key) {
      // The receiver already resolved the character (layout/IME): use it.
      for (wchar_t c : text) {
        if (c != L'\r') PostMessageW(focus, c == L'\n' ? WM_CHAR : WM_CHAR, c == L'\n' ? L'\r' : c, 1);
      }
    }
  }
  if (had_state) SetKeyboardState(state);  // put the shared state back
  if (attached) AttachThreadInput(self, thread, FALSE);
}

void Injector::Text(const std::wstring& text, bool /*paste*/) {
  if (text.empty()) return;
  if (uwp_text_ && RealKeysBegin()) {
    // Unicode keystrokes (no layout, no IME), the window in front.
    std::vector<INPUT> inputs;
    for (wchar_t c : text) {
      if (c == L'\r') continue;
      for (bool down : {true, false}) {
        INPUT input{};
        input.type = INPUT_KEYBOARD;
        if (c == L'\n') {
          input.ki.wVk = VK_RETURN;
          input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
        } else {
          input.ki.wScan = c;
          input.ki.dwFlags = KEYEVENTF_UNICODE | (down ? 0 : KEYEVENTF_KEYUP);
        }
        inputs.push_back(input);
      }
    }
    if (!inputs.empty()) SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
    return;
  }
  // Always deliver text as WM_CHAR to the keyboard target (post-IME, so the
  // source machine's IME never composes it). Never touch the clipboard, even
  // for a ⌘V: that would wipe the host user's clipboard and leak through
  // clipboard history / sync.
  HWND focus = FocusedChild();
  for (wchar_t c : text) {
    if (c == L'\r') continue;
    if (c == L'\n') {
      PostMessageW(focus, WM_KEYDOWN, VK_RETURN, 1 | (static_cast<LPARAM>(0x1C) << 16));
      PostMessageW(focus, WM_CHAR, L'\r', 1 | (static_cast<LPARAM>(0x1C) << 16));
      PostMessageW(focus, WM_KEYUP, VK_RETURN,
                   1 | (static_cast<LPARAM>(0x1C) << 16) | (static_cast<LPARAM>(3) << 30));
      continue;
    }
    PostMessageW(focus, WM_CHAR, c, 1);
  }
}

void Injector::XamlPointer(int kind, int button, POINT screen, HWND host) {
  if (kind == 1) {
    anchor_sticky_ = false;
    xaml_press_host_ = host;
    xaml_press_button_ = button;
    xaml_press_point_ = screen;
    last_press_screen_ = screen;
    last_down_time_ = GetTickCount64();
    last_input_tick_ = last_down_time_;
    clicks_++;
    return;
  }
  if (kind == 8) {
    xaml_press_host_ = nullptr;
    return;
  }
  if (kind != 3 || xaml_press_host_ == nullptr) return;
  HWND pressed = xaml_press_host_;
  xaml_press_host_ = nullptr;
  if (xaml_press_button_ != 0) {
    if (on_note) on_note("xaml: only left clicks are replayed on XAML content");
    return;
  }
  if (!xaml_) xaml_ = std::make_unique<XamlInput>();
  // In a popup we moved, XAML still reports its elements where the popup
  // was: try that point too.
  HWND root = GetAncestor(pressed, GA_ROOT);
  POINT alternate = xaml_press_point_;
  bool shifted = false;
  for (const auto& [w, s] : popup_shifts_) {
    if (w == root) {
      alternate.x -= s.x;
      alternate.y -= s.y;
      shifted = true;
    }
  }
  XamlInput::Result result = xaml_->Click(pressed, xaml_press_point_, shifted ? &alternate : nullptr);
  if (result.focused_text && result.input_site != nullptr) key_target_ = result.input_site;
  if (result.acted) uwp_text_ = result.focused_text && result.uwp;
  if (result.acted) {
    anchor_rect_ = result.element;
    if (result.used_alternate) {
      OffsetRect(&anchor_rect_, xaml_press_point_.x - alternate.x, xaml_press_point_.y - alternate.y);
    }
    anchor_tick_ = GetTickCount64();
    anchor_sticky_ = result.focused_text;
  }
  if (on_note) on_note("xaml: " + result.what);
}

void Injector::PostButton(int kind, int button, POINT screen, int modifiers) {
  HWND top = TopAt(screen);  // a popup of the app (menu, drop-down) over the window
  HWND target = ChildAt(top, screen);
  if (IsXamlHost(target) || (kind != 1 && xaml_press_host_ != nullptr)) {
    XamlPointer(kind, button, screen, target);
    return;
  }
  LRESULT hit = top == top_ ? HitTest(top_, screen) : HTCLIENT;
  // The title bar's close button is the only non-client spot we honour.
  if (hit == HTCLOSE) {
    if (kind == 1) close_pressed_ = true;
    if (kind == 3 && close_pressed_) {
      close_pressed_ = false;
      PostMessageW(top_, WM_SYSCOMMAND, SC_CLOSE, 0);
    }
    return;
  }
  if (hit == HTMINBUTTON || hit == HTMAXBUTTON || hit == HTCAPTION || hit == HTSYSMENU) {
    // Leave window-management chrome alone while staged.
    return;
  }
  // No foreground steal: a posted button-down makes the child set its own
  // focus within the app's thread (GetGUIThreadInfo then reports it), which
  // is where keys and text are sent.
  POINT client = screen;
  ScreenToClient(target, &client);
  WPARAM keys = 0;
  if (modifiers & kModControl) keys |= MK_CONTROL;
  if (modifiers & kModShift) keys |= MK_SHIFT;
  UINT down_msg, up_msg, dbl_msg, move_msg;
  WPARAM button_flag;
  switch (button) {
    case 1:
      down_msg = WM_RBUTTONDOWN;
      up_msg = WM_RBUTTONUP;
      dbl_msg = WM_RBUTTONDBLCLK;
      button_flag = MK_RBUTTON;
      break;
    case 2:
      down_msg = WM_MBUTTONDOWN;
      up_msg = WM_MBUTTONUP;
      dbl_msg = WM_MBUTTONDBLCLK;
      button_flag = MK_MBUTTON;
      break;
    default:
      down_msg = WM_LBUTTONDOWN;
      up_msg = WM_LBUTTONUP;
      dbl_msg = WM_LBUTTONDBLCLK;
      button_flag = MK_LBUTTON;
  }
  move_msg = WM_MOUSEMOVE;
  LPARAM at = MAKELPARAM(client.x, client.y);
  if (kind == 1) {  // down
    // Let the window take activation the way a real click would.
    SendMessageTimeoutW(target, WM_MOUSEACTIVATE, reinterpret_cast<WPARAM>(top),
                        MAKELPARAM(hit == 0 ? HTCLIENT : hit, down_msg), SMTO_ABORTIFHUNG, 100, nullptr);
    PostMessageW(target, move_msg, keys, at);
    ULONGLONG now = GetTickCount64();
    bool is_double = last_down_target_ == target && last_down_button_ == button &&
                     now - last_down_time_ <= GetDoubleClickTime() &&
                     std::abs(last_down_point_.x - client.x) <= GetSystemMetrics(SM_CXDOUBLECLK) &&
                     std::abs(last_down_point_.y - client.y) <= GetSystemMetrics(SM_CYDOUBLECLK);
    PostMessageW(target, is_double ? dbl_msg : down_msg, keys | button_flag, at);
    last_down_target_ = target;
    last_down_button_ = button;
    last_down_time_ = now;
    last_down_point_ = client;
    last_press_screen_ = screen;
    last_input_tick_ = now;
    anchor_sticky_ = false;
    anchor_tick_ = 0;
    uwp_text_ = false;
    pressed_button_ = button;
    press_target_ = target;
    // A left press sets where keyboard input goes (the field the viewer
    // tapped); a right press opens a menu, so it does not move the target.
    if (button == 0 && top == top_) key_target_ = target;
    clicks_++;
  } else if (kind == 3 || kind == 8) {  // up or cancel
    HWND up_target = press_target_ ? press_target_ : target;
    POINT up_client = screen;
    ScreenToClient(up_target, &up_client);
    PostMessageW(up_target, up_msg, keys, MAKELPARAM(up_client.x, up_client.y));
    pressed_button_ = -1;
    press_target_ = nullptr;
  } else {  // move
    HWND move_target = pressed_button_ >= 0 && press_target_ ? press_target_ : target;
    POINT move_client = screen;
    ScreenToClient(move_target, &move_client);
    WPARAM held_flag = pressed_button_ == 1 ? MK_RBUTTON : pressed_button_ == 2 ? MK_MBUTTON
                        : pressed_button_ == 0 ? MK_LBUTTON : 0;
    PostMessageW(move_target, move_msg, keys | held_flag, MAKELPARAM(move_client.x, move_client.y));
  }
}

void Injector::InPlacePointer(int kind, int button, POINT screen) {
  // The real pointer: SendInput at absolute virtual-desktop coordinates.
  if (kind == 1 && !cursor_saved_) {
    GetCursorPos(&cursor_home_);
    cursor_saved_ = true;
    touch_serial_++;
    // The window must be under the synthesized cursor to get the events.
    if (!IsForeground(top_)) {
      std::string how;
      BringToForeground(top_, &how);
    }
  }
  RECT vs = VirtualScreen();
  int vw = std::max(1, RectWidth(vs));
  int vh = std::max(1, RectHeight(vs));
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  input.mi.dx = static_cast<LONG>((screen.x - vs.left) * 65535.0 / vw);
  input.mi.dy = static_cast<LONG>((screen.y - vs.top) * 65535.0 / vh);
  DWORD down_flag = button == 1 ? MOUSEEVENTF_RIGHTDOWN : button == 2 ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_LEFTDOWN;
  DWORD up_flag = button == 1 ? MOUSEEVENTF_RIGHTUP : button == 2 ? MOUSEEVENTF_MIDDLEUP : MOUSEEVENTF_LEFTUP;
  if (kind == 1) {
    input.mi.dwFlags |= down_flag;
  } else if (kind == 3 || kind == 8) {
    input.mi.dwFlags |= up_flag;
  }
  SendInput(1, &input, sizeof(input));
  if (kind == 3 || kind == 8) RestoreCursorSoon();
}

void Injector::RestoreCursorSoon() {
  if (cursor_saved_ && pressed_button_ < 0) {
    POINT home = cursor_home_;
    cursor_saved_ = false;
    SetCursorPos(home.x, home.y);
  }
}

void Injector::Pointer(int kind, int button, double fx, double fy, int modifiers) {
  // Receivers send hover as POINTER_MOVE with code -1 (no button). Presses
  // always name a button; anything else is the primary one.
  if (button < 0 || button > 2) button = 0;
  POINT screen = FrameFractionToScreen(top_, fx, fy);
  last_point_ = screen;
  // Staged or in place alike: posted messages to the real child under the
  // point. They reach the window whatever covers it on screen, and the
  // user's own cursor is never moved. (InPlacePointer, the real-cursor
  // path, is kept only for reference; it needs the window in front.)
  if (kind == 2 && pressed_button_ < 0) {
    // Hover: a plain WM_MOUSEMOVE with no button flags, never a drag. No
    // hit-test (it is a blocking call), at most ~120 per second.
    double now = NowMs();
    if (now - last_hover_ms_ < 8) return;
    last_hover_ms_ = now;
    HWND target = ChildAt(TopAt(screen), screen);
    POINT client = screen;
    ScreenToClient(target, &client);
    WPARAM keys = 0;
    if (modifiers & (kModControl | kModCommand)) keys |= MK_CONTROL;
    if (modifiers & kModShift) keys |= MK_SHIFT;
    PostMessageW(target, WM_MOUSEMOVE, keys, MAKELPARAM(client.x, client.y));
    return;
  }
  PostButton(kind, button, screen, modifiers);
}

void Injector::Scroll(double fx, double fy, double dx, double dy, bool precise) {
  POINT screen = FrameFractionToScreen(top_, fx, fy);
  RECT frame = FrameBounds(top_);
  // Positive wheel delta scrolls content up (toward the user); the input
  // model's positive dy means content moves down, so the wheel is -dy.
  double lines_y = precise ? dy * RectHeight(frame) / 40.0 : dy;
  double lines_x = precise ? dx * RectWidth(frame) / 40.0 : dx;
  wheel_rest_y_ += lines_y * WHEEL_DELTA;
  wheel_rest_x_ += lines_x * WHEEL_DELTA;
  int delta_y = static_cast<int>(wheel_rest_y_);
  int delta_x = static_cast<int>(wheel_rest_x_);
  wheel_rest_y_ -= delta_y;
  wheel_rest_x_ -= delta_x;
  HWND target = ChildAt(TopAt(screen), screen);
  LPARAM at = MAKELPARAM(screen.x, screen.y);  // wheel messages carry screen coords
  if (delta_y != 0) PostMessageW(target, WM_MOUSEWHEEL, MAKEWPARAM(0, -delta_y), at);
  if (delta_x != 0) PostMessageW(target, WM_MOUSEHWHEEL, MAKEWPARAM(0, delta_x), at);
}

void Injector::ReleaseAll() {
  // Keys are never left pressed (chords are typed whole); only a button may be.
  chord_keys_.clear();
  if (pressed_button_ >= 0 && press_target_) {
    UINT up_msg = pressed_button_ == 1 ? WM_RBUTTONUP : pressed_button_ == 2 ? WM_MBUTTONUP : WM_LBUTTONUP;
    POINT client = last_point_;
    ScreenToClient(press_target_, &client);
    PostMessageW(press_target_, up_msg, 0, MAKELPARAM(client.x, client.y));
  }
  pressed_button_ = -1;
  press_target_ = nullptr;
  close_pressed_ = false;
  RestoreCursorSoon();
}

}  // namespace wsn
