// Replays a viewer's input on one window of another app.
//
// A staged window is not under the real pointer and has no system focus, so
// everything goes in as messages: the pointer as posted mouse messages to
// the child window under the point (double clicks synthesized, drags
// following the app's capture, the title bar only for its close button);
// keys as WM_KEYDOWN/UP with the modifier state attached, plus the WM_CHAR
// the key would type; text as WM_CHAR. They go to the control the viewer
// last pressed on. The clipboard is never touched. The same posted messages
// drive a window streamed in place.
//
// Shortcuts are different: an app's accelerators (Ctrl+S, F5, Alt+F, XAML
// KeyboardAccelerators) are translated in its own message loop from real
// keyboard input, which a sent message bypasses. So a chord with Ctrl/Alt,
// or a function key, briefly brings the window to the front, types the
// whole chord with SendInput, waits until the app has read it, and gives
// the foreground back — unless the chord opened a menu, a dialog or a
// popup, which then keep the front and get real keys until they close.
// (Text-editing chords in a plain edit control — Ctrl+A/C/V/X/Z/Y and
// Ctrl+arrows — stay on the message path; the control handles them.)
//
// Not thread-safe: one session thread owns an Injector.
#pragma once

#include "wsn_util.h"

#include <functional>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace wsn {

class XamlInput;

// Modifier bits as in window_stream_native.h.
constexpr int kModShift = 0x1;
constexpr int kModControl = 0x2;
constexpr int kModOption = 0x4;
constexpr int kModCommand = 0x8;

struct KeyCode {
  WORD vk = 0;
  WORD scan = 0;
  bool extended = false;
};
// The Windows key at the macOS key code's place (Command is Control).
bool MacKeyToWindows(int mac, KeyCode* out);

// The visible frame's point at fractions [fx], [fy] (screen pixels).
POINT FrameFractionToScreen(HWND top, double fx, double fy);
// The innermost child of [top] under [screen] that takes input.
HWND ChildAt(HWND top, POINT screen);
// [screen] (physical pixels) in [window]'s client coordinates as the
// window's own DPI awareness sees them.
POINT ScreenToClientOf(HWND window, POINT screen);
// [screen] in [window]'s screen coordinate space (for WM_NCHITTEST and
// WM_MOUSEWHEEL, which carry screen coordinates).
POINT ScreenForWindow(HWND window, POINT screen);
// WM_NCHITTEST of the top-level window at [screen] (HTERROR on timeout).
LRESULT HitTest(HWND top, POINT screen);

// Makes [top] the foreground window. [how] says which way worked.
bool BringToForeground(HWND top, std::string* how);
bool IsForeground(HWND top);

class Injector {
 public:
  explicit Injector(HWND top);
  ~Injector();

  void SetInPlace(bool in_place) { in_place_ = in_place; }
  bool in_place() const { return in_place_; }

  // kind: 1 down, 2 move, 3 up, 8 cancel; button 0 left, 1 right, 2 middle.
  void Pointer(int kind, int button, double fx, double fy, int modifiers);
  // dx, dy: wheel lines (precise: fractions of the picture height),
  // positive = content moves down/right (wheel away from the user).
  void Scroll(double fx, double fy, double dx, double dy, bool precise);
  // [text] is the character(s) the key produced on the viewer, used to
  // synthesize WM_CHAR when the layout can't (IME / unusual layouts).
  void Key(bool down, int mac, int modifiers, const std::wstring& text = std::wstring());
  void Text(const std::wstring& text, bool paste);
  // Lets go of a mouse button this injector holds.
  void ReleaseAll();

  // Called before input that changes what the window shows (for the
  // capture's "did the app answer" check) and when we activate it.
  std::function<void(const std::string&)> on_note;
  std::function<void()> on_activated;

  int clicks() const { return clicks_; }
  // The control the viewer last pressed on (keys and text go there).
  HWND key_target() const { return key_target_; }
  // A popup of the app (menu, drop-down, flyout, dialog) shown for the
  // streamed window: pointer input over it goes to it, and while it is open
  // in front keys go through the real keyboard.
  void AddPopup(HWND popup);
  // The follower moved [popup] by [shift] (XAML popups keep reporting their
  // old place to UI Automation).
  void SetPopupShift(HWND popup, POINT shift);
  // Where a popup the viewer just opened belongs: below the XAML element
  // they clicked, or below the text box they are typing in.
  bool PopupAnchor(RECT* element) const;
  // See XamlInput::ContentRect.
  bool XamlContentRect(HWND popup, RECT* out);
  // Where and when the viewer last pressed (screen pixels, GetTickCount64),
  // and when they last pressed or typed anything.
  POINT last_press_screen() const { return last_press_screen_; }
  ULONGLONG last_press_tick() const { return last_down_time_; }
  ULONGLONG last_input_tick() const { return last_input_tick_; }
  // Periodic: once a menu/popup a shortcut opened has closed, give the
  // foreground back to the window that had it.
  void Tick();

 private:
  bool EnsureForeground();
  HWND FocusedChild();
  // The streamed window, or a popup of it, under [screen].
  HWND TopAt(POINT screen);
  // A press/release on XAML content (which ignores posted mouse messages):
  // replayed through UI Automation on release (wsn_xaml.h).
  void XamlPointer(int kind, int button, POINT screen, HWND host);
  // The chord through the real keyboard with the window in front (see above).
  bool ForegroundChord(const KeyCode& key, bool ctrl, bool shift, bool alt);
  // A menu, a dialog or a popup of the app is open in front: keys go
  // through the real keyboard.
  bool RealKeyboardMode();
  void PostButton(int kind, int button, POINT screen, int modifiers);
  void InPlacePointer(int kind, int button, POINT screen);
  void RestoreCursorSoon();

  HWND top_;
  bool in_place_ = false;
  // Pointer state.
  int pressed_button_ = -1;
  HWND press_target_ = nullptr;
  // The child the viewer last pressed on: where keys and text go (a staged
  // background window has no GUI focus of its own).
  HWND key_target_ = nullptr;
  POINT last_point_{};
  HWND last_down_target_ = nullptr;
  POINT last_down_point_{};
  ULONGLONG last_down_time_ = 0;
  int last_down_button_ = -1;
  int click_count_ = 0;
  bool close_pressed_ = false;
  double last_hover_ms_ = 0;
  int clicks_ = 0;
  // In place: where the user's cursor was.
  bool cursor_saved_ = false;
  POINT cursor_home_{};
  int touch_serial_ = 0;
  // Keys whose chord was typed whole on key down (their up is dropped).
  std::set<int> chord_keys_;
  // Popups of the app (menus, dialogs, flyouts) while they are visible.
  std::vector<HWND> popups_;
  // The window that had the foreground before a shortcut kept it for a popup.
  HWND return_front_ = nullptr;
  POINT last_press_screen_{};
  std::unique_ptr<XamlInput> xaml_;
  std::vector<std::pair<HWND, POINT>> popup_shifts_;
  RECT anchor_rect_{};
  ULONGLONG anchor_tick_ = 0;
  bool anchor_sticky_ = false;  // a text box has the focus: its popups (suggestions) go below it
  // A UWP text box has the viewer's focus: it takes only real keyboard
  // input, so typing brings the window to the front (it is off-screen;
  // nothing is seen) and the front goes back 2 s after the last key.
  bool uwp_text_ = false;
  ULONGLONG real_keys_until_ = 0;
  HWND real_keys_return_ = nullptr;
  bool RealKeysBegin();
  HWND xaml_press_host_ = nullptr;
  int xaml_press_button_ = 0;
  POINT xaml_press_point_{};
  ULONGLONG last_input_tick_ = 0;
  double wheel_rest_x_ = 0;
  double wheel_rest_y_ = 0;
  double foreground_checked_ms_ = 0;
};



}  // namespace wsn
