// The volume control of one streamed window: a round speaker button over
// the top-right corner of its client area, shown while the pointer moves
// over the window, and a flyout in the manner of the Windows 11 quick
// settings: a mute button, a slider and the level in percent.
//
// Both are windows of their own, owned by the streamed window: the button
// is a per-pixel-alpha layered window (only its round face takes the
// pointer), the flyout a popup that takes the keyboard while it is open.
// So nothing aimed at them reaches the streamed app, and nothing aimed at
// the app beside them is taken. They show only once the window has sound.
//
// Both are drawn here with Direct2D, in the app theme (light, dark or high
// contrast) and the accent colour, and follow them as they change. The
// flyout sits on the system's backdrop for transient windows where there
// is one (Windows 11), on the theme's plain colour elsewhere. A click
// outside it closes it, like a menu: on a window of this thread (the
// streamed window above all) that click goes no further.
//
// UI thread only.

#pragma once

#include "../common/wsn_common.h"

#include <cstdint>
#include <functional>

namespace wsn {

class VolumeAutomation;

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

  // Window procedures and the flyout's mouse hook (public for their
  // registration only).
  LRESULT ButtonMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  LRESULT PopupMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  // A button going down on a window of this thread while the flyout is
  // open: true when it was outside the flyout and closed it.
  bool DismissingClick(HWND target, UINT hit_test);

 private:
  friend class VolumeAutomation;

  // The parts of the flyout the pointer and the keyboard deal with.
  enum class Part { kNone, kMute, kSlider };

  void CreateButton();
  void Render();
  void Show();
  void Hide(bool now = false);
  void FadeStep();
  bool CursorOver(HWND window);
  RECT ButtonFace() const;
  void ReadTheme();
  void ThemeChanged();
  void OpenPopup();
  void CreatePopup();
  void ApplyPopupTheme();
  void ClosePopup(bool refocus_owner);
  void SyncPopup();
  void PaintPopup(HDC dc);
  Part PartAt(POINT client) const;
  void SetHover(Part part);
  void DragTo(int x);
  void AnimateThumb();
  void StepPercent(int delta);
  void SetPercent(long percent);
  void ToggleMute();
  void UserChanged(double volume, bool final);
  void FlushReport();
  void VolumeShown(double previous);
  int Px(double dips) const;
  float Dp(double dips) const;

  std::function<void(double)> on_change_;
  std::function<void(double)> on_report_;

  HWND owner_ = nullptr;
  UINT dpi_ = 96;
  bool available_ = false;
  double volume_ = 1;
  double audible_ = 1;  // what unmuting goes back to

  // The look: the app theme, high contrast and the accent colour (0xRRGGBB,
  // the shade the theme fills with).
  bool dark_ = false;
  bool high_contrast_ = false;
  uint32_t accent_ = 0x005FB8;

  HWND button_ = nullptr;
  HWND tooltip_ = nullptr;
  bool shown_ = false;       // the button is (being) shown
  int alpha_ = 0;            // its opacity now, 0..255
  bool hot_ = false;         // the pointer is over it

  HWND popup_ = nullptr;
  HWND popup_tip_ = nullptr;  // the flyout's mute button's tooltip
  bool popup_open_ = false;
  bool backdrop_ = false;     // the system draws the flyout's background
  bool rounded_ = false;      // and its rounded corners and border
  bool popup_tracking_ = false;
  Part hover_ = Part::kNone;
  Part pressed_ = Part::kNone;
  Part focus_ = Part::kSlider;
  bool focus_visible_ = false;  // after Tab, as Fluent shows focus
  bool dragging_ = false;
  float grab_ = 0;              // the pointer's offset from the thumb's centre
  double thumb_scale_ = 0.86;   // the thumb's inner dot (Fluent's 0.86 at rest)
  VolumeAutomation* automation_ = nullptr;

  double reported_ = 1;
  double last_report_ = 0;
  bool report_pending_ = false;
};

}  // namespace wsn
