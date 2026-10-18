// Facts about other apps' top-level windows: where they are (the visible
// frame, not the invisible resize border), who owns them, whether they are
// shown, elevated or on another virtual desktop, and their placement.
#pragma once

#include "wsn_util.h"

#include <string>
#include <vector>

namespace wsn {

std::wstring WindowTitle(HWND window);
std::wstring WindowClass(HWND window);
DWORD WindowPid(HWND window, DWORD* thread = nullptr);
// The visible frame in physical screen pixels (DWMWA_EXTENDED_FRAME_BOUNDS).
RECT FrameBounds(HWND window);
bool IsCloaked(HWND window, DWORD* how = nullptr);
UINT WindowDpi(HWND window);
RECT VirtualScreen();
RECT PrimaryWorkArea();
bool OnAnyMonitor(const RECT& rect, double min_fraction = 0.25);
double FractionInside(const RECT& rect, const RECT& area);
int RectWidth(const RECT& r);
int RectHeight(const RECT& r);
bool SameRect(const RECT& a, const RECT& b, int tolerance = 0);

std::wstring ProcessImagePath(DWORD pid);
// 1 elevated, 0 not, -1 unknown (cannot open the process: treat as
// elevated or protected).
int ProcessElevation(DWORD pid);
bool SelfElevated();
// Windows integrity level RID (SECURITY_MANDATORY_*_RID); -1 unknown.
int ProcessIntegrityLevel(DWORD pid);
int SelfIntegrityLevel();
// Input can be injected only into a window at our integrity level or below
// (UIPI blocks injecting "up"); an unreadable process is treated as higher.
bool CanInjectIntoProcess(DWORD pid);
// Explicit AppUserModelID of the window, or of the packaged process.
std::wstring WindowAumid(HWND window);
std::wstring ProcessAumid(DWORD pid);
// A UWP app's frame (ApplicationFrameWindow) hosts the app's CoreWindow,
// owned by the app's own process.
HWND HostedCoreWindow(HWND frame);
uint64_t ProcessStartTime(DWORD pid);

// What the window was before it was staged, enough to put it back exactly.
struct Placement {
  WINDOWPLACEMENT wp{};
  RECT rect{};       // GetWindowRect
  bool minimized = false;
  bool maximized = false;
  bool arranged = false;  // snapped (Aero Snap)
  UINT dpi = 96;
};
Placement SavePlacement(HWND window);
// Puts the window back where [saved] says, without activating it unless
// it has to be maximized again. Returns true if the result matches.
bool RestorePlacement(HWND window, const Placement& saved);
std::string PlacementJson(const Placement& p);
bool PlacementFromJson(const std::string& json, Placement* p);

// Screen rectangle → WINDOWPLACEMENT workspace coordinates.
RECT ScreenToWorkspace(const RECT& rect);

// Tiny JSON field readers for the journal (flat objects only).
bool JsonInt(const std::string& json, const char* key, long long* out);
bool JsonStr(const std::string& json, const char* key, std::string* out);

}  // namespace wsn
