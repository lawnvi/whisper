#include "window_theme_plugin.h"

#include <dwmapi.h>
#include <flutter/encodable_value.h>
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

    // Kept for the next screenshot, without a screen's worth of surface: its
    // next frame gives that back, and it hides after.
    if (call.method_name() == "shrinkCover") {
      SetLayeredWindowAttributes(window_, 0, 0, LWA_ALPHA);
      SetWindowPos(window_, nullptr, 0, 0, 1, 1,
                   SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
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

  HWND window_ = nullptr;
  int backdrop_ = 0;
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
