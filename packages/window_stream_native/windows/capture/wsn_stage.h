// Where a staged window goes, and the style it wears there.
//
// Windows draws nothing for a window that is completely off every monitor:
// DWM stops composing it (Windows.Graphics.Capture gets no frames) and
// Chromium-based apps treat it as hidden and stop rendering. Probes W2/W2x
// found a placement that keeps both going while nothing shows:
//   - WS_EX_LAYERED (alpha 255, looks the same): DWM keeps composing a
//     layered window wherever it is;
//   - the window hangs off a corner of a monitor with only its invisible
//     resize border on the screen (a few transparent pixels), so apps that
//     check "am I on a monitor" still think they are visible;
//   - WS_EX_TRANSPARENT: those pixels never take the local user's clicks.
// Each corner of each monitor is one slot; four windows can be staged per
// monitor without covering each other's on-screen pixels.
#pragma once

#include "wsn_util.h"

#include <vector>

namespace wsn {

struct Borders {
  LONG left = 0, top = 0, right = 0, bottom = 0;  // invisible resize borders
};
Borders InvisibleBorders(HWND window);

// A spot for a window whose window rect (with borders) is [width] x
// [height]. [slot] picks among the usable monitor corners, best first
// (under a taskbar, on the primary monitor). False when no corner leads
// off the desktop.
bool StageSpot(int slot, int width, int height, const Borders& borders, RECT* out);
int StageSlotCount();

struct StyleBackup {
  LONG_PTR ex_style = 0;
  bool had_attributes = false;  // SetLayeredWindowAttributes values existed
  BYTE alpha = 255;
  COLORREF key = 0;
  DWORD flags = 0;
};
// Adds WS_EX_LAYERED (alpha 255 unless the app layers it itself) and
// WS_EX_TRANSPARENT. [backup] receives what to put back.
bool ApplyStageStyle(HWND window, StyleBackup* backup);
void RestoreStageStyle(HWND window, const StyleBackup& backup);
// The staging bits are still there (an app may reset its own style).
bool HasStageStyle(HWND window);

// Moves a (possibly minimized or maximized) window to [target] without
// activating it. Returns true once the window is there.
bool MoveWindowTo(HWND window, const RECT& target, int wait_ms = 600);

}  // namespace wsn
