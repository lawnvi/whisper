#include "system_power_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace {

constexpr char kSystemPowerChannel[] = "com.vireen.whisper/system_power";

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
HPOWERNOTIFY g_notification = nullptr;

}  // namespace

void SystemPowerPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window) {
  if (g_channel) {
    return;
  }
  auto* windows_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      windows_registrar->messenger(), kSystemPowerChannel,
      &flutter::StandardMethodCodec::GetInstance());
  // Without this, machines with modern standby (most current laptops) send
  // no suspend or resume notice at all; with it, both kinds of sleep send
  // PBT_APMSUSPEND and PBT_APMRESUMEAUTOMATIC to |window|.
  if (window != nullptr) {
    g_notification =
        RegisterSuspendResumeNotification(window, DEVICE_NOTIFY_WINDOW_HANDLE);
  }
}

void SystemPowerPluginObserveWindowMessage(UINT message, WPARAM wparam) {
  if (message != WM_POWERBROADCAST || !g_channel) {
    return;
  }
  // Windows does not wait for an application before it sleeps, so this only
  // starts letting peers go; whatever is not closed by then is closed on wake.
  // The automatic resume notice comes on every wake, with or without the user.
  switch (wparam) {
    case PBT_APMSUSPEND:
      g_channel->InvokeMethod("willSleep", nullptr);
      break;
    case PBT_APMRESUMEAUTOMATIC:
      g_channel->InvokeMethod("didWake", nullptr);
      break;
    default:
      break;
  }
}
