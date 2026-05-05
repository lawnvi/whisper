#include "window_theme_plugin.h"

#include <dwmapi.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <utility>

namespace {

constexpr char kWindowThemeChannel[] = "com.vireen.whisper/window_theme";

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

template <typename T>
const T* GetMapValue(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return nullptr;
  }
  return std::get_if<T>(&it->second);
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
      SetBrightness(*brightness);
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  void SetBrightness(const std::string& brightness) {
    if (window_ == nullptr) {
      return;
    }
    BOOL enable_dark_mode = brightness == "dark";
    DwmSetWindowAttribute(window_, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

void WindowThemePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window) {
  auto plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  auto plugin = std::make_unique<WindowThemePlugin>(plugin_registrar, window);
  plugin_registrar->AddPlugin(std::move(plugin));
}
