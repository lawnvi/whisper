#include "capture_catalog.h"

#include "common/com.h"
#include "common/wsn_common.h"
#include "wsn_image.h"
#include "wsn_wgc.h"
#include "wsn_window.h"

#include <UIAutomation.h>
#include <knownfolders.h>
#include <shellapi.h>
// propidl before propkey: with WIN32_LEAN_AND_MEAN, propkeydef.h would
// otherwise define PID_FIRST_USABLE before propidlbase.h (C4005).
#include <propidl.h>
#include <propsys.h>
#include <propkey.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

#include <winrt/base.h>

namespace wsn {

namespace {

std::string JsonArrayJoin(const std::vector<std::string>& items) {
  std::string out;
  for (size_t i = 0; i < items.size(); ++i) {
    if (i) out += ",";
    out += items[i];
  }
  return out;
}

// ------------------------------------------------------------- installed apps

struct AppInfo {
  std::string id;    // AUMID or exe path (the bundleId)
  std::string name;  // display name
};

std::mutex g_apps_mutex;
std::vector<AppInfo> g_apps;
double g_apps_read_at = -1e9;
std::atomic<bool> g_apps_refreshing{false};

// Enumerates shell:AppsFolder: every launchable app (UWP and desktop),
// each with a parsing name (its AUMID) and a display name.
std::vector<AppInfo> ReadAppsFolder() {
  std::vector<AppInfo> apps;
  ScopedCom com(COINIT_APARTMENTTHREADED);  // the shell namespace wants STA
  winrt::com_ptr<IShellItem> folder;
  if (FAILED(SHGetKnownFolderItem(FOLDERID_AppsFolder, KF_FLAG_DEFAULT, nullptr, IID_PPV_ARGS(folder.put())))) {
    return apps;
  }
  winrt::com_ptr<IEnumShellItems> items;
  if (FAILED(folder->BindToHandler(nullptr, BHID_EnumItems, IID_PPV_ARGS(items.put())))) return apps;
  winrt::com_ptr<IShellItem> item;
  ULONG fetched = 0;
  while (items->Next(1, item.put(), &fetched) == S_OK && fetched == 1) {
    PWSTR parsing = nullptr;
    PWSTR display = nullptr;
    if (SUCCEEDED(item->GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING, &parsing)) && parsing) {
      item->GetDisplayName(SIGDN_NORMALDISPLAY, &display);
      std::wstring id = parsing;
      // The parsing name of an AppsFolder item is like
      // "...::{...}\<AUMID>"; the AUMID is the last path segment.
      size_t slash = id.find_last_of(L'\\');
      std::wstring aumid = slash == std::wstring::npos ? id : id.substr(slash + 1);
      AppInfo app;
      app.id = WideToUtf8(aumid);
      app.name = display ? WideToUtf8(display) : WideToUtf8(aumid);
      if (!app.id.empty() && !app.name.empty()) apps.push_back(std::move(app));
    }
    CoTaskMemFree(parsing);
    CoTaskMemFree(display);
    item = nullptr;
  }
  return apps;
}

void RefreshAppsAsync() {
  bool expected = false;
  if (!g_apps_refreshing.compare_exchange_strong(expected, true)) return;
  std::thread([] {
    auto apps = ReadAppsFolder();
    {
      std::lock_guard<std::mutex> lock(g_apps_mutex);
      if (!apps.empty()) {
        g_apps = std::move(apps);
        g_apps_read_at = NowSeconds();
      }
    }
    g_apps_refreshing = false;
  }).detach();
}

std::vector<AppInfo> AppsForCatalog() {
  std::vector<AppInfo> apps;
  bool stale;
  {
    std::lock_guard<std::mutex> lock(g_apps_mutex);
    apps = g_apps;
    stale = NowSeconds() - g_apps_read_at > 60;
  }
  if (stale) RefreshAppsAsync();  // answer with what we have, refresh for next time
  return apps;
}

// Running apps, by their process AUMID or exe path, for the "running" flag.
std::vector<std::string> RunningAppIds() {
  std::vector<std::string> ids;
  EnumWindows(
      [](HWND w, LPARAM data) -> BOOL {
        if (IsWindowVisible(w) && !IsCloaked(w)) {
          std::string id = WindowAppId(w);
          if (!id.empty()) reinterpret_cast<std::vector<std::string>*>(data)->push_back(id);
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&ids));
  return ids;
}

// ------------------------------------------------------------- windows

bool IsToolWindow(HWND window) {
  return (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0;
}

struct WindowRow {
  HWND hwnd;
  DWORD pid;
};

// The catalog filter: a window a viewer is allowed to browse / thumbnail /
// stream. Hidden, cloaked, tool, owned, tiny, our own and higher-integrity
// windows are all excluded (so a viewer can't thumbnail what the catalog
// hides).
bool IsStreamableWindow(HWND window) {
  if (!IsWindow(window) || !IsWindowVisible(window) || IsCloaked(window) || IsToolWindow(window)) return false;
  if (GetWindow(window, GW_OWNER) != nullptr) return false;
  RECT frame = FrameBounds(window);
  if (RectWidth(frame) < 120 || RectHeight(frame) < 80) return false;
  HWND core = HostedCoreWindow(window);
  DWORD pid = WindowPid(core ? core : window);
  if (pid == GetCurrentProcessId()) return false;
  return CanInjectIntoProcess(pid);
}

BOOL CALLBACK CollectWindow(HWND window, LPARAM data) {
  auto* rows = reinterpret_cast<std::vector<WindowRow>*>(data);
  if (!IsStreamableWindow(window)) return TRUE;
  HWND core = HostedCoreWindow(window);
  rows->push_back(WindowRow{window, WindowPid(core ? core : window)});
  return TRUE;
}

// Windows the viewer asked to close lately: only for these is the (slower)
// UI Automation look for an in-window dialog worth it.
std::mutex g_closed_mutex;
std::vector<std::pair<HWND, ULONGLONG>> g_recently_closed;

bool RecentlyClosed(HWND window) {
  std::lock_guard<std::mutex> lock(g_closed_mutex);
  ULONGLONG now = GetTickCount64();
  for (const auto& [w, at] : g_recently_closed) {
    if (w == window && now - at < 15000) return true;
  }
  return false;
}

// The window shows its own modal dialog ("Save changes?"): a classic owned
// dialog that disables it, or — for a window the viewer just asked to close
// — an in-window modal one (WinUI ContentDialog) found by UI Automation.
bool ShowsModal(HWND window) {
  HWND popup = GetLastActivePopup(window);
  if (popup != nullptr && popup != window && IsWindowVisible(popup) && IsWindowEnabled(popup)) return true;
  if (!RecentlyClosed(window)) return false;
  ScopedCom com;
  Microsoft::WRL::ComPtr<IUIAutomation> uia;
  if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia)))) {
    return false;
  }
  Microsoft::WRL::ComPtr<IUIAutomation2> uia2;
  if (SUCCEEDED(uia.As(&uia2))) {
    uia2->put_ConnectionTimeout(500);
    uia2->put_TransactionTimeout(500);
  }
  Microsoft::WRL::ComPtr<IUIAutomationElement> root;
  if (FAILED(uia->ElementFromHandle(window, &root)) || !root) return false;
  VARIANT yes;
  VariantInit(&yes);
  yes.vt = VT_BOOL;
  yes.boolVal = VARIANT_TRUE;
  Microsoft::WRL::ComPtr<IUIAutomationCondition> modal;
  if (FAILED(uia->CreatePropertyCondition(UIA_WindowIsModalPropertyId, yes, &modal))) return false;
  Microsoft::WRL::ComPtr<IUIAutomationElement> found;
  return SUCCEEDED(root->FindFirst(TreeScope_Descendants, modal.Get(), &found)) && found;
}

std::string WindowJson(const WindowRow& row) {
  HWND window = row.hwnd;
  RECT frame = FrameBounds(window);
  std::wstring title = WindowTitle(window);
  std::string app_name;
  // App display name: the window title's app, or the process image base name.
  std::wstring exe = ProcessImagePath(row.pid);
  size_t slash = exe.find_last_of(L"\\/");
  std::wstring base = slash == std::wstring::npos ? exe : exe.substr(slash + 1);
  if (base.size() > 4 && _wcsicmp(base.c_str() + base.size() - 4, L".exe") == 0) base.resize(base.size() - 4);
  app_name = WideToUtf8(base);
  bool minimized = IsIconic(window) != FALSE;
  bool on_screen = !minimized && OnAnyMonitor(frame, 0.01);
  bool active = GetForegroundWindow() == window;
  // Size in DIPs (points), like macOS, so Dart's viewport maths is uniform.
  UINT dpi = WindowDpi(window);
  int width = MulDiv(RectWidth(frame), 96, dpi);
  int height = MulDiv(RectHeight(frame), 96, dpi);
  return Format(
      "{\"id\":%u,\"title\":%s,\"appName\":%s,\"bundleId\":%s,\"pid\":%lu,\"width\":%d,\"height\":%d,"
      "\"onScreen\":%s,\"active\":%s%s}",
      HwndToId(window), JsonString(title).c_str(), JsonString(app_name).c_str(),
      JsonString(WindowAppId(window)).c_str(), row.pid, width, height, on_screen ? "true" : "false",
      active ? "true" : "false", ShowsModal(window) ? ",\"modal\":true" : "");
}

}  // namespace

namespace {
// A viewer may only name an app id that the host actually offered: an AUMID
// in the installed-apps cache, or the appId of a window currently in the
// catalog. Anything else (an arbitrary path the viewer invented, a UNC path
// that would force SMB/NTLM auth) is refused, so ShellExecute /
// SHCreateItemFromParsingName never run on viewer-chosen paths.
bool IsKnownAppId(const std::string& id) {
  if (id.empty()) return false;
  std::wstring wid = Utf8ToWide(id);
  if (wid.rfind(L"\\\\", 0) == 0 || wid.rfind(L"//", 0) == 0) return false;  // UNC
  {
    std::lock_guard<std::mutex> lock(g_apps_mutex);
    for (const auto& app : g_apps) {
      if (_stricmp(app.id.c_str(), id.c_str()) == 0) return true;
    }
  }
  for (const auto& running : RunningAppIds()) {
    if (_stricmp(running.c_str(), id.c_str()) == 0) return true;
  }
  return false;
}
}  // namespace

std::string WindowAppId(HWND window) {
  std::wstring aumid = WindowAumid(window);
  HWND core = HostedCoreWindow(window);
  DWORD pid = WindowPid(core ? core : window);
  if (aumid.empty()) aumid = ProcessAumid(pid);
  if (!aumid.empty()) return WideToUtf8(aumid);
  std::wstring exe = ProcessImagePath(pid);
  for (auto& c : exe) c = static_cast<wchar_t>(towlower(c));
  return WideToUtf8(exe);
}

bool SessionLocked() {
  HDESK desk = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (desk == nullptr) return true;  // a secure desktop we cannot open: locked
  wchar_t name[128] = L"";
  DWORD needed = 0;
  bool normal = GetUserObjectInformationW(desk, UOI_NAME, name, sizeof(name), &needed) &&
                _wcsicmp(name, L"Default") == 0;
  CloseDesktop(desk);
  return !normal;
}

void WarmInstalledApps() { RefreshAppsAsync(); }

void RequestCatalog(int64_t request_id) {
  std::vector<WindowRow> rows;
  EnumWindows(CollectWindow, reinterpret_cast<LPARAM>(&rows));
  std::vector<std::string> windows;
  windows.reserve(rows.size());
  for (const auto& row : rows) windows.push_back(WindowJson(row));

  auto apps = AppsForCatalog();
  std::vector<std::string> running = RunningAppIds();
  auto is_running = [&](const std::string& id) {
    for (const auto& r : running) {
      if (_stricmp(r.c_str(), id.c_str()) == 0) return true;
    }
    return false;
  };
  std::vector<std::string> app_items;
  app_items.reserve(apps.size());
  for (const auto& app : apps) {
    app_items.push_back(Format("{\"bundleId\":%s,\"name\":%s,\"running\":%s}", JsonString(app.id).c_str(),
                               JsonString(app.name).c_str(), is_running(app.id) ? "true" : "false"));
  }
  bool locked = SessionLocked();
  std::string json = "{\"windows\":[" + JsonArrayJoin(windows) + "],\"apps\":[" + JsonArrayJoin(app_items) +
                     "],\"locked\":" + (locked ? "true" : "false") + "}";
  EmitCapture(request_id, WSN_CAPTURE_CATALOG, json.data(), static_cast<int32_t>(json.size()));
}

void RequestIcon(int64_t request_id, const std::string& app_id, int size) {
  if (!IsKnownAppId(app_id)) {
    EmitCapture(request_id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_NOT_FOUND);
    return;
  }
  std::string id = app_id;
  std::thread([request_id, id, size] {
    // IShellItemImageFactory wants an STA.
    ScopedCom com(COINIT_APARTMENTTHREADED);
    int px = size > 0 ? size : 128;
    std::wstring wid = Utf8ToWide(id);
    bool path = wid.size() > 2 && (wid[1] == L':' || wid.substr(0, 2) == L"\\\\");
    std::wstring parsing = path ? wid : (L"shell:AppsFolder\\" + wid);
    std::vector<uint8_t> png;
    bool ok = ShellIconPng(parsing, px, &png);
    if (!ok && path) ok = ExeIconPng(wid, px, &png);     // the exe's own icon
    if (!ok && !path) ok = ShellIconPng(wid, px, &png);  // AUMID tried as a path
    if (ok) {
      EmitCapture(request_id, WSN_CAPTURE_ICON, png.data(), static_cast<int32_t>(png.size()));
    } else {
      EmitCapture(request_id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_NOT_FOUND);
    }
  }).detach();
}

void RequestThumbnail(int64_t request_id, uint32_t window_id, int max_edge) {
  HWND window = IdToHwnd(window_id);
  // Only windows the catalog would list: never thumbnail a hidden, elevated
  // or non-app window a viewer guessed the id of.
  if (!IsStreamableWindow(window)) {
    EmitCapture(request_id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_NOT_FOUND);
    return;
  }
  std::thread([request_id, window, max_edge] {
    ScopedCom com;
    Bitmap bitmap;
    bool ok = PrintWindowBitmap(window, &bitmap);
    if (!ok || bitmap.empty()) {
      // WGC fallback: a short capture into one frame.
      WgcCapture capture;
      std::mutex mutex;
      Bitmap grabbed;
      std::string error;
      bool got = false;
      capture.Start(
          window, {},
          [&](ID3D11Texture2D* texture, SIZE content, int64_t) {
            std::lock_guard<std::mutex> lock(mutex);
            if (!got) got = ReadTexture(D3D::Shared(), texture, content.cx, content.cy, &grabbed);
          },
          nullptr, &error);
      for (int i = 0; i < 20 && !got; ++i) Sleep(50);
      capture.Stop();
      std::lock_guard<std::mutex> lock(mutex);
      bitmap = grabbed;
    }
    if (bitmap.empty()) {
      EmitCapture(request_id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_UNKNOWN);
      return;
    }
    Bitmap scaled = Scale(bitmap, max_edge > 0 ? max_edge : 480);
    std::vector<uint8_t> jpeg;
    if (EncodeImage(scaled, true, 0.75f, &jpeg)) {
      EmitCapture(request_id, WSN_CAPTURE_THUMBNAIL, jpeg.data(), static_cast<int32_t>(jpeg.size()));
    } else {
      EmitCapture(request_id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_UNKNOWN);
    }
  }).detach();
}

void LaunchApp(int64_t request_id, const std::string& app_id) {
  if (!IsKnownAppId(app_id)) {
    EmitCapture(request_id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_NOT_FOUND);
    return;
  }
  std::string id = app_id;
  std::thread([request_id, id] {
    ScopedCom com;
    std::wstring wid = Utf8ToWide(id);
    bool path = wid.size() > 2 && (wid[1] == L':' || wid.substr(0, 2) == L"\\\\");
    SHELLEXECUTEINFOW info{sizeof(info)};
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
    info.nShow = SW_SHOWNOACTIVATE;
    std::wstring target = path ? wid : (L"shell:AppsFolder\\" + wid);
    info.lpFile = target.c_str();
    bool ok = ShellExecuteExW(&info) != FALSE;
    if (info.hProcess) CloseHandle(info.hProcess);
    EmitCapture(request_id, ok ? WSN_CAPTURE_LAUNCHED : WSN_CAPTURE_FAILED, nullptr, 0, 0,
                ok ? 0 : WSN_CAPTURE_ERROR_NOT_FOUND);
  }).detach();
}

void CloseWindow(uint32_t window_id, int pid) {
  HWND window = IdToHwnd(window_id);
  if (!IsWindow(window)) return;
  // Accept either the frame HWND's owner pid or the hosted CoreWindow's pid
  // (UWP: the catalog reports the latter, the frame is owned by the former).
  if (pid != 0) {
    DWORD frame_pid = WindowPid(window);
    HWND core = HostedCoreWindow(window);
    DWORD core_pid = core ? WindowPid(core) : frame_pid;
    if (static_cast<DWORD>(pid) != frame_pid && static_cast<DWORD>(pid) != core_pid) return;
  }
  {
    std::lock_guard<std::mutex> lock(g_closed_mutex);
    ULONGLONG now = GetTickCount64();
    g_recently_closed.erase(std::remove_if(g_recently_closed.begin(), g_recently_closed.end(),
                                           [&](const auto& e) { return now - e.second > 15000; }),
                            g_recently_closed.end());
    g_recently_closed.push_back({window, now});
  }
  // As the window's own close button: the app may ask to save, or hide to
  // the tray; nothing is forced.
  PostMessageW(window, WM_SYSCOMMAND, SC_CLOSE, 0);
}

}  // namespace wsn
