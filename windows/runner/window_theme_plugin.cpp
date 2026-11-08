#include "window_theme_plugin.h"

#include <dwmapi.h>
#include <exdisp.h>
#include <shlguid.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <flutter/encodable_value.h>
#include <flutter_windows.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>

namespace {

constexpr char kWindowThemeChannel[] = "com.vireen.whisper/window_theme";

// DWMWA_SYSTEMBACKDROP_TYPE and its values. MinGW and older SDKs don't name them.
constexpr DWORD kSystemBackdropType = 38;
constexpr int kBackdropMica = 2;
constexpr int kBackdropAcrylic = 3;

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif

constexpr wchar_t kChosenBrightnessProperty[] = L"WhisperTitleBarBrightness";
constexpr INT_PTR kChosenLight = 1;
constexpr INT_PTR kChosenDark = 2;

bool g_next_window_is_panel = false;

std::string Utf8(const wchar_t* text) {
  if (text == nullptr || *text == 0) {
    return std::string();
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0,
                                       nullptr, nullptr);
  std::string out(size > 0 ? size - 1 : 0, '\0');
  if (size > 1) {
    WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr,
                        nullptr);
  }
  return out;
}

// The folder File Explorer shows in [window], or the desktop's: where a
// paste pressed there puts its files. Null for any other window, and for a
// folder that is not a place on disk (This PC, a library).
std::optional<std::pair<std::string, std::string>> FolderShownIn(
    HWND window) {
  wchar_t name[64] = {};
  GetClassNameW(window, name, 64);
  PIDLIST_ABSOLUTE pidl = nullptr;
  if (wcscmp(name, L"Progman") == 0 || wcscmp(name, L"WorkerW") == 0) {
    if (FAILED(SHGetKnownFolderIDList(FOLDERID_Desktop, 0, nullptr, &pidl))) {
      return std::nullopt;
    }
  } else if (wcscmp(name, L"CabinetWClass") == 0) {
    IShellWindows* windows = nullptr;
    if (FAILED(CoCreateInstance(CLSID_ShellWindows, nullptr, CLSCTX_ALL,
                                IID_PPV_ARGS(&windows)))) {
      return std::nullopt;
    }
    long count = 0;
    windows->get_Count(&count);
    for (long i = 0; i < count && pidl == nullptr; ++i) {
      VARIANT index;
      VariantInit(&index);
      index.vt = VT_I4;
      index.lVal = i;
      IDispatch* dispatch = nullptr;
      if (FAILED(windows->Item(index, &dispatch)) || dispatch == nullptr) {
        continue;
      }
      IWebBrowserApp* app = nullptr;
      if (SUCCEEDED(dispatch->QueryInterface(IID_PPV_ARGS(&app)))) {
        SHANDLE_PTR handle = 0;
        IServiceProvider* provider = nullptr;
        IShellBrowser* browser = nullptr;
        IShellView* view = nullptr;
        HWND view_window = nullptr;
        IFolderView* folder_view = nullptr;
        IPersistFolder2* folder = nullptr;
        // Tabs share the window: the tab shown is the one whose view is.
        if (SUCCEEDED(app->get_HWND(&handle)) &&
            reinterpret_cast<HWND>(handle) == window &&
            SUCCEEDED(app->QueryInterface(IID_PPV_ARGS(&provider))) &&
            SUCCEEDED(provider->QueryService(SID_STopLevelBrowser,
                                             IID_PPV_ARGS(&browser))) &&
            SUCCEEDED(browser->QueryActiveShellView(&view)) &&
            SUCCEEDED(view->GetWindow(&view_window)) &&
            IsWindowVisible(view_window) &&
            SUCCEEDED(view->QueryInterface(IID_PPV_ARGS(&folder_view))) &&
            SUCCEEDED(folder_view->GetFolder(IID_PPV_ARGS(&folder)))) {
          folder->GetCurFolder(&pidl);
        }
        if (folder) folder->Release();
        if (folder_view) folder_view->Release();
        if (view) view->Release();
        if (browser) browser->Release();
        if (provider) provider->Release();
        app->Release();
      }
      dispatch->Release();
    }
    windows->Release();
  }
  if (pidl == nullptr) {
    return std::nullopt;
  }
  wchar_t path[MAX_PATH] = {};
  const bool on_disk = SHGetPathFromIDListW(pidl, path) != FALSE;
  PWSTR display = nullptr;
  SHGetNameFromIDList(pidl, SIGDN_NORMALDISPLAY, &display);
  std::optional<std::pair<std::string, std::string>> result;
  if (on_disk && path[0] != 0) {
    result = std::make_pair(Utf8(path), Utf8(display ? display : path));
  }
  if (display) CoTaskMemFree(display);
  CoTaskMemFree(pidl);
  return result;
}

template <typename T>
const T* GetMapValue(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return nullptr;
  }
  return std::get_if<T>(&it->second);
}

// A Dart int arrives as 32 or 64 bits depending on its size.
std::optional<int64_t> GetIntValue(const flutter::EncodableMap& map,
                                   const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return std::nullopt;
  }
  if (const auto* narrow = std::get_if<int32_t>(&it->second)) {
    return *narrow;
  }
  if (const auto* wide = std::get_if<int64_t>(&it->second)) {
    return *wide;
  }
  return std::nullopt;
}

class WindowThemePlugin : public flutter::Plugin {
 public:
  WindowThemePlugin(flutter::PluginRegistrarWindows* registrar, HWND window)
      : window_(window),
        channel_(std::make_unique<
                 flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), kWindowThemeChannel,
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      HandleMethodCall(call, std::move(result));
    });
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "setBrightness") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto* brightness = args == nullptr
                                   ? nullptr
                                   : GetMapValue<std::string>(*args, "brightness");
      if (brightness == nullptr) {
        result->Error("bad-arguments", "setBrightness requires brightness");
        return;
      }
      SetBrightness(*brightness, GetIntValue(*args, "backgroundColor"));
      result->Success();
      return;
    }

    // Asked just before the tray panel's window is created: see RegisterPanelPlugins.
    if (call.method_name() == "nextWindowIsPanel") {
      g_next_window_is_panel = true;
      result->Success();
      return;
    }

    // The redesigned UI asks for these, the old one never does. The panel is a
    // window of its own: acrylic goes with it, under the panel's own tint.
    if (call.method_name() == "enableWindowMaterial" ||
        call.method_name() == "enablePanelMaterial") {
      backdrop_ = call.method_name() == "enableWindowMaterial" ? kBackdropMica
                                                               : kBackdropAcrylic;
      result->Success(flutter::EncodableValue(ApplyBackdrop()));
      return;
    }

    // The screenshot overlay: over a whole screen, unseen until it has drawn.
    // Where it goes is in pixels, from the selection overlay it takes over from.
    if (call.method_name() == "coverDisplay") {
      const auto* frame = std::get_if<flutter::EncodableList>(call.arguments());
      if (frame == nullptr || frame->size() != 4) {
        result->Success(flutter::EncodableValue(false));
        return;
      }
      const auto at = [&](size_t i) {
        return static_cast<int>(std::get<double>((*frame)[i]));
      };
      SetWindowLongPtr(window_, GWL_STYLE, WS_POPUP);
      SetWindowLongPtr(window_, GWL_EXSTYLE,
                       WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED);
      SetLayeredWindowAttributes(window_, 0, 0, LWA_ALPHA);
      SetWindowPos(window_, HWND_TOPMOST, at(0), at(1), at(2), at(3),
                   SWP_FRAMECHANGED | SWP_SHOWWINDOW | SWP_NOACTIVATE);
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "revealCover") {
      SetLayeredWindowAttributes(window_, 0, 255, LWA_ALPHA);
      ShowWindow(window_, SW_SHOW);
      SetForegroundWindow(window_);
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "hideCover") {
      ShowWindow(window_, SW_HIDE);
      SetLayeredWindowAttributes(window_, 0, 0, LWA_ALPHA);
      result->Success(flutter::EncodableValue(true));
      return;
    }

    // The folder shown in front (File Explorer or the desktop): where a paste
    // pressed now would go.
    if (call.method_name() == "foregroundFolder") {
      const auto folder =
          FolderShownIn(GetAncestor(GetForegroundWindow(), GA_ROOT));
      if (!folder) {
        result->Success();
        return;
      }
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("path"),
           flutter::EncodableValue(folder->first)},
          {flutter::EncodableValue("name"),
           flutter::EncodableValue(folder->second)},
      }));
      return;
    }

    // What is in front: the window a paste was asked for in.
    if (call.method_name() == "foregroundWindow") {
      result->Success(flutter::EncodableValue(
          static_cast<int64_t>(reinterpret_cast<intptr_t>(GetForegroundWindow()))));
      return;
    }

    // The floating island: see-through, over everything, and never taking
    // the keyboard from the window the paste was asked for in, not even
    // when clicked.
    if (call.method_name() == "becomeIsland") {
      SetWindowLongPtr(window_, GWL_STYLE, WS_POPUP);
      SetWindowLongPtr(window_, GWL_EXSTYLE,
                       WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE);
      MARGINS margins = {-1, -1, -1, -1};
      DwmExtendFrameIntoClientArea(window_, &margins);
      MakeTransparent();
      SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
      result->Success(flutter::EncodableValue(true));
      return;
    }
    // Its top middle at the top middle of the work area of the screen with
    // the pointer. Resized later, it keeps that point. Sizes are logical.
    if (call.method_name() == "placeIsland") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto* width =
          args == nullptr ? nullptr : GetMapValue<double>(*args, "width");
      const auto* height =
          args == nullptr ? nullptr : GetMapValue<double>(*args, "height");
      const auto* rescreen =
          args == nullptr ? nullptr : GetMapValue<bool>(*args, "rescreen");
      if (width == nullptr || height == nullptr) {
        result->Success(flutter::EncodableValue(false));
        return;
      }
      if (!island_anchored_ || (rescreen != nullptr && *rescreen)) {
        POINT cursor{};
        GetCursorPos(&cursor);
        HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
        MONITORINFO info{};
        info.cbSize = sizeof(info);
        GetMonitorInfo(monitor, &info);
        island_anchor_ = {(info.rcWork.left + info.rcWork.right) / 2,
                          info.rcWork.top};
        island_scale_ = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
        island_anchored_ = true;
      }
      const int w = static_cast<int>(*width * island_scale_ + 0.5);
      const int h = static_cast<int>(*height * island_scale_ + 0.5);
      SetWindowPos(window_, HWND_TOPMOST, island_anchor_.x - w / 2,
                   island_anchor_.y, w, h, SWP_NOACTIVATE);
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "showIsland") {
      SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "hideIsland") {
      ShowWindow(window_, SW_HIDE);
      result->Success(flutter::EncodableValue(true));
      return;
    }

    // Password managers set this format on what they copy; it must not be
    // remembered in the clipboard history.
    if (call.method_name() == "clipboardIsSensitive") {
      const UINT exclude = RegisterClipboardFormatW(
          L"ExcludeClipboardContentFromMonitorProcessing");
      result->Success(flutter::EncodableValue(
          exclude != 0 && IsClipboardFormatAvailable(exclude) != FALSE));
      return;
    }

    result->NotImplemented();
  }

  // Flutter's transparent areas show the system's backdrop. window_manager's
  // setTitleBarStyle resets the margins to 0, so this runs after it. Windows 10
  // and early 11 refuse the attribute: the margins go back and Dart paints the
  // sidebar itself.
  bool ApplyBackdrop() {
    if (window_ == nullptr || backdrop_ == 0) {
      return false;
    }
    MARGINS margins = {-1, -1, -1, -1};
    DwmExtendFrameIntoClientArea(window_, &margins);
    int backdrop = backdrop_;
    const HRESULT hr = DwmSetWindowAttribute(window_, kSystemBackdropType,
                                             &backdrop, sizeof(backdrop));
    if (FAILED(hr)) {
      margins = {0, 0, 0, 0};
      DwmExtendFrameIntoClientArea(window_, &margins);
      return false;
    }
    return true;
  }

  void SetBrightness(const std::string& brightness,
                     std::optional<int64_t> background_argb) {
    if (window_ == nullptr) {
      return;
    }
    if (background_argb) {
      // The window plugin gives the window its background by painting all
      // of it, title bar included, in that colour. Over such a title bar
      // Windows draws the caption text and buttons white whatever the
      // brightness, which hid them on the light theme. Given a caption
      // colour of its own the title bar is drawn the regular way again,
      // dark on light and light on dark. Windows 10 does not know the
      // attribute and leaves the title bar as it was.
      const auto argb = static_cast<uint32_t>(*background_argb);
      COLORREF caption =
          RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
      DwmSetWindowAttribute(window_, DWMWA_CAPTION_COLOR, &caption,
                            sizeof(caption));
    }
    BOOL enable_dark_mode = brightness == "dark";
    // Kept for the runner, which sets the title bar again whenever Windows
    // reports a colour change and would otherwise go by the system's theme.
    SetPropW(window_, kChosenBrightnessProperty,
             reinterpret_cast<HANDLE>(enable_dark_mode ? kChosenDark
                                                       : kChosenLight));
    DwmSetWindowAttribute(window_, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
    // Set again whenever light and dark change.
    ApplyBackdrop();
  }

  // Flutter's transparent pixels show what is behind the window, as
  // window_manager's transparent background does.
  void MakeTransparent() {
    struct AccentPolicy {
      int state;
      int flags;
      int color;
      int animation;
    };
    struct CompositionData {
      int attribute;
      PVOID data;
      ULONG size;
    };
    using SetComposition = BOOL(WINAPI*)(HWND, CompositionData*);
    const HMODULE user32 = GetModuleHandle(TEXT("user32.dll"));
    const auto set = user32 == nullptr
                         ? nullptr
                         : reinterpret_cast<SetComposition>(GetProcAddress(
                               user32, "SetWindowCompositionAttribute"));
    if (set == nullptr) {
      return;
    }
    // ACCENT_ENABLE_TRANSPARENTGRADIENT, of no colour; 19 is the accent.
    AccentPolicy policy = {2, 2, 0, 0};
    CompositionData data = {19, &policy, sizeof(policy)};
    set(window_, &data);
  }

  HWND window_ = nullptr;
  int backdrop_ = 0;
  POINT island_anchor_{};
  double island_scale_ = 1.0;
  bool island_anchored_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

bool WindowThemeTakeNextWindowIsPanel() {
  const bool panel = g_next_window_is_panel;
  g_next_window_is_panel = false;
  return panel;
}

bool WindowThemeChosenDarkMode(HWND window, BOOL* enable_dark_mode) {
  const INT_PTR chosen =
      reinterpret_cast<INT_PTR>(GetPropW(window, kChosenBrightnessProperty));
  if (chosen != kChosenLight && chosen != kChosenDark) {
    return false;
  }
  *enable_dark_mode = chosen == kChosenDark;
  return true;
}

void WindowThemeForget(HWND window) {
  RemovePropW(window, kChosenBrightnessProperty);
}

void WindowThemePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window) {
  auto plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  auto plugin = std::make_unique<WindowThemePlugin>(plugin_registrar, window);
  plugin_registrar->AddPlugin(std::move(plugin));
}
