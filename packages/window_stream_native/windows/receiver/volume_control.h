// The volume control of one streamed window: a round speaker button over
// the top-right corner of its client area, shown while the pointer moves
// over the window, and a small flyout with a mute toggle and a slider (a
// Win32 trackbar).
//
// Both are windows of their own, owned by the streamed window: the button
// is a per-pixel-alpha layered window (only its round face takes the
// pointer), the flyout a popup that takes the keyboard while it is open.
// So nothing aimed at them reaches the streamed app, and nothing aimed at
// the app beside them is taken. They show only once the window has sound.
//
// UI thread only.

#pragma once

#include "../common/wsn_common.h"

#include <functional>

namespace wsn {

class VolumeControl {
 public:
  // `on_change`: the user changed the volume (the sound follows at once).
  // `on_report`: the value to tell Dart: at most ~10 a second while a
  // change goes on, and the last one when it ends.
  VolumeControl(std::function<void(double)> on_change, std::function<void(double)> on_report);
  ~VolumeControl();
  VolumeControl(const VolumeControl&) = delete;
  VolumeControl& operator=(const VolumeControl&) = delete;

  // The streamed window (again after it was replaced) and its DPI.
  void Attach(HWND owner, UINT dpi);
  // Before the streamed window goes: the control's windows go first.
  void Detach();
  // The window has sound: from now on the button may show.
  void SetAvailable();
  // From Dart: shown, never reported back.
  void SetVolume(double volume);
  void SetDpi(UINT dpi);
  void StringsChanged();

  // From the streamed window's messages: the pointer moved over its client
  // area (no button held), left it, or the window is busy (a drag in the
  // app, moving or sizing, hidden, minimized) and the control steps aside.
  void OwnerPointerMoved();
  void OwnerPointerLeft();
  void OwnerBusy();
  // The client area moved or changed size (programmatically): the button
  // follows if it shows.
  void OwnerMoved();
  // The wheel at `screen` (WM_MOUSEWHEEL delta): true when it was over the
  // button and changed the volume (it is then not the app's).
  bool Wheel(POINT screen, int delta);

  // Window procedures (public for the class registration only).
  LRESULT ButtonMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  LRESULT PopupMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  LRESULT ChildMessage(HWND child, WNDPROC original, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void CreateButton();
  void Render();
  void Show();
  void Hide(bool now = false);
  void FadeStep();
  bool CursorOver(HWND window);
  void OpenPopup();
  void CreatePopup();
  void ClosePopup(bool refocus_owner);
  void SyncPopup();
  void UserChanged(double volume, bool final);
  void FlushReport();
  int Px(double dips) const;

  std::function<void(double)> on_change_;
  std::function<void(double)> on_report_;

  HWND owner_ = nullptr;
  UINT dpi_ = 96;
  bool available_ = false;
  double volume_ = 1;
  double audible_ = 1;  // what unmuting goes back to

  HWND button_ = nullptr;
  HWND tooltip_ = nullptr;
  bool shown_ = false;       // the button is (being) shown
  int alpha_ = 0;            // its opacity now, 0..255
  bool hot_ = false;         // the pointer is over it

  HWND popup_ = nullptr;
  HWND mute_ = nullptr;
  HWND slider_ = nullptr;
  HFONT glyph_font_ = nullptr;
  HBRUSH popup_brush_ = nullptr;
  bool popup_dark_ = false;
  bool popup_open_ = false;

  double reported_ = 1;
  double last_report_ = 0;
  bool report_pending_ = false;
};

}  // namespace wsn
