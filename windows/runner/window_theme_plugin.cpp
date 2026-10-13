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

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif

constexpr wchar_t kChosenBrightnessProperty[] = L"WhisperTitleBarBrightness";
constexpr INT_PTR kChosenLight = 1;
constexpr INT_PTR kChosenDark = 2;

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

    result->NotImplemented();
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
  }

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

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
