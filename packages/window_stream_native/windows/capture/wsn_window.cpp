#include "wsn_window.h"

#include <appmodel.h>
#include <dwmapi.h>
// propidl before propkey: with WIN32_LEAN_AND_MEAN, propkeydef.h would
// otherwise define PID_FIRST_USABLE before propidlbase.h (C4005).
#include <propidl.h>
#include <propsys.h>
#include <propkey.h>
#include <shellapi.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <cstdlib>

#include <winrt/base.h>

namespace wsn {

std::wstring WindowTitle(HWND window) {
  wchar_t buffer[512];
  int length = GetWindowTextW(window, buffer, 512);
  return std::wstring(buffer, static_cast<size_t>(std::max(length, 0)));
}

std::wstring WindowClass(HWND window) {
  wchar_t buffer[256];
  int length = GetClassNameW(window, buffer, 256);
  return std::wstring(buffer, static_cast<size_t>(std::max(length, 0)));
}

DWORD WindowPid(HWND window, DWORD* thread) {
  DWORD pid = 0;
  DWORD tid = GetWindowThreadProcessId(window, &pid);
  if (thread) *thread = tid;
  return pid;
}

RECT FrameBounds(HWND window) {
  RECT rect{};
  if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &rect, sizeof(rect))) ||
      rect.right <= rect.left) {
    GetWindowRect(window, &rect);
  }
  return rect;
}

bool IsCloaked(HWND window, DWORD* how) {
  DWORD cloaked = 0;
  if (FAILED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)))) cloaked = 0;
  if (how) *how = cloaked;
  return cloaked != 0;
}

UINT WindowDpi(HWND window) {
  UINT dpi = GetDpiForWindow(window);
  return dpi == 0 ? 96 : dpi;
}

RECT VirtualScreen() {
  RECT rect;
  rect.left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  rect.top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  rect.right = rect.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
  rect.bottom = rect.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);
  return rect;
}

RECT PrimaryWorkArea() {
  MONITORINFO info{sizeof(info)};
  GetMonitorInfoW(MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY), &info);
  return info.rcWork;
}

int RectWidth(const RECT& r) { return r.right - r.left; }
int RectHeight(const RECT& r) { return r.bottom - r.top; }

bool SameRect(const RECT& a, const RECT& b, int tolerance) {
  return std::abs(a.left - b.left) <= tolerance && std::abs(a.top - b.top) <= tolerance &&
         std::abs(a.right - b.right) <= tolerance && std::abs(a.bottom - b.bottom) <= tolerance;
}

double FractionInside(const RECT& rect, const RECT& area) {
  RECT inside{};
  if (!IntersectRect(&inside, &rect, &area)) return 0;
  double total = static_cast<double>(RectWidth(rect)) * RectHeight(rect);
  if (total <= 0) return 0;
  return static_cast<double>(RectWidth(inside)) * RectHeight(inside) / total;
}

namespace {
struct MonitorSum {
  RECT rect;
  double fraction = 0;
};
BOOL CALLBACK AddMonitor(HMONITOR, HDC, LPRECT monitor, LPARAM data) {
  auto* sum = reinterpret_cast<MonitorSum*>(data);
  sum->fraction += FractionInside(sum->rect, *monitor);
  return TRUE;
}
}  // namespace

bool OnAnyMonitor(const RECT& rect, double min_fraction) {
  MonitorSum sum{rect};
  EnumDisplayMonitors(nullptr, nullptr, AddMonitor, reinterpret_cast<LPARAM>(&sum));
  return sum.fraction >= min_fraction;
}

std::wstring ProcessImagePath(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return std::wstring();
  wchar_t buffer[MAX_PATH * 2];
  DWORD size = MAX_PATH * 2;
  std::wstring path;
  if (QueryFullProcessImageNameW(process, 0, buffer, &size)) path.assign(buffer, size);
  CloseHandle(process);
  return path;
}

int ProcessElevation(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return -1;
  HANDLE token = nullptr;
  int result = -1;
  if (OpenProcessToken(process, TOKEN_QUERY, &token)) {
    TOKEN_ELEVATION elevation{};
    DWORD size = 0;
    if (GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size)) {
      result = elevation.TokenIsElevated ? 1 : 0;
    }
    // A higher integrity level than ours blocks input (UIPI) even when
    // the token does not say elevated (UIAccess apps, services).
    DWORD length = 0;
    GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &length);
    if (length > 0 && result == 0) {
      std::vector<BYTE> buffer(length);
      if (GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), length, &length)) {
        auto* label = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buffer.data());
        DWORD count = *GetSidSubAuthorityCount(label->Label.Sid);
        DWORD level = *GetSidSubAuthority(label->Label.Sid, count - 1);
        if (level > SECURITY_MANDATORY_MEDIUM_PLUS_RID && !SelfElevated()) result = 1;
      }
    }
    CloseHandle(token);
  }
  CloseHandle(process);
  return result;
}

int ProcessIntegrityLevel(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return -1;
  HANDLE token = nullptr;
  int level = -1;
  if (OpenProcessToken(process, TOKEN_QUERY, &token)) {
    DWORD length = 0;
    GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &length);
    if (length > 0) {
      std::vector<BYTE> buffer(length);
      if (GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), length, &length)) {
        auto* label = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buffer.data());
        DWORD count = *GetSidSubAuthorityCount(label->Label.Sid);
        level = static_cast<int>(*GetSidSubAuthority(label->Label.Sid, count - 1));
      }
    }
    CloseHandle(token);
  }
  CloseHandle(process);
  return level;
}

int SelfIntegrityLevel() {
  static int value = ProcessIntegrityLevel(GetCurrentProcessId());
  return value;
}

bool CanInjectIntoProcess(DWORD pid) {
  if (pid == GetCurrentProcessId()) return false;
  int target = ProcessIntegrityLevel(pid);
  if (target < 0) return false;  // cannot read it: assume protected
  return target <= SelfIntegrityLevel();
}

bool SelfElevated() {
  static int value = [] {
    HANDLE token = nullptr;
    int elevated = 0;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
      TOKEN_ELEVATION elevation{};
      DWORD size = 0;
      if (GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size)) {
        elevated = elevation.TokenIsElevated ? 1 : 0;
      }
      CloseHandle(token);
    }
    return elevated;
  }();
  return value != 0;
}

std::wstring WindowAumid(HWND window) {
  winrt::com_ptr<IPropertyStore> store;
  if (FAILED(SHGetPropertyStoreForWindow(window, __uuidof(IPropertyStore), store.put_void())) || !store) {
    return std::wstring();
  }
  PROPVARIANT value;
  PropVariantInit(&value);
  std::wstring id;
  if (SUCCEEDED(store->GetValue(PKEY_AppUserModel_ID, &value)) && value.vt == VT_LPWSTR && value.pwszVal) {
    id = value.pwszVal;
  }
  PropVariantClear(&value);
  return id;
}

std::wstring ProcessAumid(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return std::wstring();
  wchar_t buffer[APPLICATION_USER_MODEL_ID_MAX_LENGTH];
  UINT32 length = APPLICATION_USER_MODEL_ID_MAX_LENGTH;
  std::wstring id;
  if (GetApplicationUserModelId(process, &length, buffer) == ERROR_SUCCESS && length > 1) {
    id.assign(buffer, length - 1);
  }
  CloseHandle(process);
  return id;
}

HWND HostedCoreWindow(HWND frame) {
  DWORD frame_pid = WindowPid(frame);
  HWND child = nullptr;
  while ((child = FindWindowExW(frame, child, L"Windows.UI.Core.CoreWindow", nullptr)) != nullptr) {
    if (WindowPid(child) != frame_pid) return child;
  }
  return nullptr;
}

uint64_t ProcessStartTime(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return 0;
  FILETIME created{}, exited{}, kernel{}, user{};
  uint64_t value = 0;
  if (GetProcessTimes(process, &created, &exited, &kernel, &user)) {
    value = (static_cast<uint64_t>(created.dwHighDateTime) << 32) | created.dwLowDateTime;
  }
  CloseHandle(process);
  return value;
}

namespace {
bool Arranged(HWND window) {
  using Fn = BOOL(WINAPI*)(HWND);
  static Fn fn = reinterpret_cast<Fn>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "IsWindowArranged"));
  return fn != nullptr && fn(window) != FALSE;
}
}  // namespace

Placement SavePlacement(HWND window) {
  Placement p;
  p.wp.length = sizeof(WINDOWPLACEMENT);
  GetWindowPlacement(window, &p.wp);
  GetWindowRect(window, &p.rect);
  p.minimized = IsIconic(window) != FALSE;
  p.maximized = IsZoomed(window) != FALSE || (p.minimized && (p.wp.flags & WPF_RESTORETOMAXIMIZED));
  p.arranged = !p.minimized && !p.maximized && Arranged(window);
  p.dpi = WindowDpi(window);
  return p;
}

bool RestorePlacement(HWND window, const Placement& saved) {
  WINDOWPLACEMENT wp = saved.wp;
  wp.length = sizeof(wp);
  wp.flags |= WPF_ASYNCWINDOWPLACEMENT;
  if (saved.minimized) {
    wp.showCmd = SW_SHOWMINNOACTIVE;
  } else if (saved.maximized) {
    wp.showCmd = SW_SHOWMAXIMIZED;
  } else {
    wp.showCmd = SW_SHOWNOACTIVATE;
  }
  SetWindowPlacement(window, &wp);
  if (!saved.minimized && !saved.maximized) {
    // Snapped windows sit somewhere other than their normal position.
    SetWindowPos(window, nullptr, saved.rect.left, saved.rect.top, RectWidth(saved.rect), RectHeight(saved.rect),
                 SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS);
  }
  // The requests are posted to the window's thread: wait until they show.
  for (int i = 0; i < 50; ++i) {
    RECT now{};
    GetWindowRect(window, &now);
    bool minimized = IsIconic(window) != FALSE;
    if (minimized == saved.minimized && (saved.minimized || SameRect(now, saved.rect))) return true;
    Sleep(10);
  }
  return false;
}

RECT ScreenToWorkspace(const RECT& rect) {
  MONITORINFO info{sizeof(info)};
  GetMonitorInfoW(MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST), &info);
  LONG dx = info.rcWork.left - info.rcMonitor.left;
  LONG dy = info.rcWork.top - info.rcMonitor.top;
  return RECT{rect.left - dx, rect.top - dy, rect.right - dx, rect.bottom - dy};
}

std::string PlacementJson(const Placement& p) {
  const auto& w = p.wp;
  return Format(
      "\"flags\":%u,\"showCmd\":%u,\"minX\":%ld,\"minY\":%ld,\"maxX\":%ld,\"maxY\":%ld,"
      "\"nl\":%ld,\"nt\":%ld,\"nr\":%ld,\"nb\":%ld,\"l\":%ld,\"t\":%ld,\"r\":%ld,\"b\":%ld,"
      "\"minimized\":%d,\"maximized\":%d,\"arranged\":%d,\"dpi\":%u",
      w.flags, w.showCmd, w.ptMinPosition.x, w.ptMinPosition.y, w.ptMaxPosition.x, w.ptMaxPosition.y,
      w.rcNormalPosition.left, w.rcNormalPosition.top, w.rcNormalPosition.right, w.rcNormalPosition.bottom,
      p.rect.left, p.rect.top, p.rect.right, p.rect.bottom, p.minimized ? 1 : 0, p.maximized ? 1 : 0,
      p.arranged ? 1 : 0, p.dpi);
}

bool JsonInt(const std::string& json, const char* key, long long* out) {
  std::string needle = std::string("\"") + key + "\":";
  size_t at = json.find(needle);
  if (at == std::string::npos) return false;
  const char* start = json.c_str() + at + needle.size();
  char* end = nullptr;
  long long value = std::strtoll(start, &end, 10);
  if (end == start) return false;
  *out = value;
  return true;
}

bool JsonStr(const std::string& json, const char* key, std::string* out) {
  std::string needle = std::string("\"") + key + "\":\"";
  size_t at = json.find(needle);
  if (at == std::string::npos) return false;
  std::string value;
  for (size_t i = at + needle.size(); i < json.size(); ++i) {
    char c = json[i];
    if (c == '"') {
      *out = value;
      return true;
    }
    if (c == '\\' && i + 1 < json.size()) {
      char next = json[++i];
      switch (next) {
        case 'n': value += '\n'; break;
        case 'r': value += '\r'; break;
        case 't': value += '\t'; break;
        default: value += next;
      }
    } else {
      value += c;
    }
  }
  return false;
}

bool PlacementFromJson(const std::string& json, Placement* p) {
  long long v[18];
  const char* keys[18] = {"flags", "showCmd", "minX", "minY", "maxX", "maxY", "nl", "nt", "nr",
                          "nb",    "l",       "t",    "r",    "b",    "minimized", "maximized", "arranged", "dpi"};
  for (int i = 0; i < 18; ++i) {
    if (!JsonInt(json, keys[i], &v[i])) return false;
  }
  p->wp.length = sizeof(WINDOWPLACEMENT);
  p->wp.flags = static_cast<UINT>(v[0]);
  p->wp.showCmd = static_cast<UINT>(v[1]);
  p->wp.ptMinPosition = POINT{static_cast<LONG>(v[2]), static_cast<LONG>(v[3])};
  p->wp.ptMaxPosition = POINT{static_cast<LONG>(v[4]), static_cast<LONG>(v[5])};
  p->wp.rcNormalPosition = RECT{static_cast<LONG>(v[6]), static_cast<LONG>(v[7]), static_cast<LONG>(v[8]),
                                static_cast<LONG>(v[9])};
  p->rect = RECT{static_cast<LONG>(v[10]), static_cast<LONG>(v[11]), static_cast<LONG>(v[12]),
                 static_cast<LONG>(v[13])};
  p->minimized = v[14] != 0;
  p->maximized = v[15] != 0;
  p->arranged = v[16] != 0;
  p->dpi = static_cast<UINT>(v[17]);
  return true;
}

}  // namespace wsn
