#include "wsn_stage.h"

#include "wsn_window.h"

#include <algorithm>

namespace wsn {

Borders InvisibleBorders(HWND window) {
  RECT rect{};
  GetWindowRect(window, &rect);
  RECT frame = FrameBounds(window);
  Borders b;
  b.left = std::max<LONG>(0, frame.left - rect.left);
  b.top = std::max<LONG>(0, frame.top - rect.top);
  b.right = std::max<LONG>(0, rect.right - frame.right);
  b.bottom = std::max<LONG>(0, rect.bottom - frame.bottom);
  return b;
}

namespace {

struct Monitor {
  RECT rect;
  RECT work;
  bool primary;
};

std::vector<Monitor> Monitors() {
  std::vector<Monitor> out;
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR handle, HDC, LPRECT, LPARAM data) -> BOOL {
        MONITORINFO info{sizeof(info)};
        if (GetMonitorInfoW(handle, &info)) {
          reinterpret_cast<std::vector<Monitor>*>(data)->push_back(
              Monitor{info.rcMonitor, info.rcWork, (info.dwFlags & MONITORINFOF_PRIMARY) != 0});
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&out));
  return out;
}

LONG Area(const RECT& a, const RECT& b) {
  RECT inside{};
  if (!IntersectRect(&inside, &a, &b)) return 0;
  return (inside.right - inside.left) * (inside.bottom - inside.top);
}

struct Candidate {
  RECT rect;
  int score;
};

std::vector<Candidate> Candidates(int width, int height, const Borders& borders) {
  auto monitors = Monitors();
  // At least one transparent pixel on the screen on each side we use.
  LONG left = std::max<LONG>(1, borders.left);
  LONG right = std::max<LONG>(1, borders.right);
  LONG bottom = std::max<LONG>(1, borders.bottom);
  std::vector<Candidate> out;
  for (const auto& m : monitors) {
    for (int corner = 0; corner < 4; ++corner) {
      RECT r{};
      POINT sliver{};
      switch (corner) {
        case 0:  // bottom right: the left border's columns, the top row
          r.left = m.rect.right - left;
          r.top = m.rect.bottom - 1;
          sliver = POINT{m.rect.right - 1, m.rect.bottom - 1};
          break;
        case 1:  // bottom left: the right border's columns, the top row
          r.left = m.rect.left + right - width;
          r.top = m.rect.bottom - 1;
          sliver = POINT{m.rect.left, m.rect.bottom - 1};
          break;
        case 2:  // top right: the left border's columns, the bottom border's rows
          r.left = m.rect.right - left;
          r.top = m.rect.top + bottom - height;
          sliver = POINT{m.rect.right - 1, m.rect.top};
          break;
        default:  // top left
          r.left = m.rect.left + right - width;
          r.top = m.rect.top + bottom - height;
          sliver = POINT{m.rect.left, m.rect.top};
          break;
      }
      r.right = r.left + width;
      r.bottom = r.top + height;
      // Only the sliver on this monitor and nothing on any other.
      LONG on_screen = 0;
      for (const auto& other : monitors) on_screen += Area(r, other.rect);
      LONG allowed = std::max(left, right) * bottom;
      if (on_screen <= 0 || on_screen > allowed) continue;
      // Best under a taskbar (outside the work area): maximized windows
      // never cover it, so Chromium-based apps keep rendering.
      int score = 0;
      if (!PtInRect(&m.work, sliver)) score += 4;
      if (m.primary) score += 2;
      if (corner < 2) score += 1;
      out.push_back(Candidate{r, score});
    }
  }
  std::stable_sort(out.begin(), out.end(), [](const Candidate& a, const Candidate& b) { return a.score > b.score; });
  return out;
}

}  // namespace

int StageSlotCount() { return static_cast<int>(Monitors().size()) * 4; }

bool StageSpot(int slot, int width, int height, const Borders& borders, RECT* out) {
  auto candidates = Candidates(width, height, borders);
  if (candidates.empty()) return false;
  *out = candidates[static_cast<size_t>(slot) % candidates.size()].rect;
  return true;
}

bool ApplyStageStyle(HWND window, StyleBackup* backup) {
  LONG_PTR ex = GetWindowLongPtrW(window, GWL_EXSTYLE);
  backup->ex_style = ex;
  backup->had_attributes = false;
  if (ex & WS_EX_LAYERED) {
    BYTE alpha = 255;
    COLORREF key = 0;
    DWORD flags = 0;
    if (GetLayeredWindowAttributes(window, &key, &alpha, &flags)) {
      backup->had_attributes = true;
      backup->alpha = alpha;
      backup->key = key;
      backup->flags = flags;
    }
    // Layered by the app (UpdateLayeredWindow or its own alpha): leave
    // the layering alone, only let clicks through.
    SetWindowLongPtrW(window, GWL_EXSTYLE, ex | WS_EX_TRANSPARENT);
    return true;
  }
  SetLastError(0);
  if (SetWindowLongPtrW(window, GWL_EXSTYLE, ex | WS_EX_LAYERED | WS_EX_TRANSPARENT) == 0 && GetLastError() != 0) {
    return false;
  }
  if (!SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA)) {
    SetWindowLongPtrW(window, GWL_EXSTYLE, ex);
    return false;
  }
  return true;
}

void RestoreStageStyle(HWND window, const StyleBackup& backup) {
  if (!IsWindow(window)) return;
  LONG_PTR now = GetWindowLongPtrW(window, GWL_EXSTYLE);
  // Keep whatever else the app changed meanwhile; put back our two bits.
  LONG_PTR ours = WS_EX_LAYERED | WS_EX_TRANSPARENT;
  LONG_PTR value = (now & ~ours) | (backup.ex_style & ours);
  if (value != now) SetWindowLongPtrW(window, GWL_EXSTYLE, value);
  if ((backup.ex_style & WS_EX_LAYERED) && backup.had_attributes && backup.flags != 0) {
    // The app's own SetLayeredWindowAttributes values (untouched by us,
    // but re-apply in case clearing WS_EX_TRANSPARENT disturbed them).
    SetLayeredWindowAttributes(window, backup.key, backup.alpha, backup.flags);
  }
  // Repaint the frame with the old style.
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_ASYNCWINDOWPOS);
}

bool HasStageStyle(HWND window) {
  LONG_PTR ex = GetWindowLongPtrW(window, GWL_EXSTYLE);
  return (ex & (WS_EX_LAYERED | WS_EX_TRANSPARENT)) == (WS_EX_LAYERED | WS_EX_TRANSPARENT);
}

bool MoveWindowTo(HWND window, const RECT& target, int wait_ms) {
  if (IsIconic(window) || IsZoomed(window)) {
    // One step from minimized or maximized to the spot: no flash at home.
    WINDOWPLACEMENT wp{sizeof(wp)};
    GetWindowPlacement(window, &wp);
    wp.flags = WPF_ASYNCWINDOWPLACEMENT;
    wp.showCmd = SW_SHOWNOACTIVATE;
    wp.rcNormalPosition = ScreenToWorkspace(target);
    SetWindowPlacement(window, &wp);
  }
  SetWindowPos(window, nullptr, target.left, target.top, RectWidth(target), RectHeight(target),
               SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS);
  double end = NowMs() + wait_ms;
  do {
    RECT now{};
    GetWindowRect(window, &now);
    if (SameRect(now, target, 1) && !IsIconic(window)) return true;
    Sleep(8);
  } while (NowMs() < end);
  return false;
}

}  // namespace wsn
