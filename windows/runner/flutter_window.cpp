#include "flutter_window.h"

#include <optional>

#include "audio_share_plugin.h"
#include "desktop_clipboard_image_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "remote_input_plugin.h"
#include "window_theme_plugin.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::Shutdown() {
  HWND handle = GetHandle();
  if (handle) {
    ShowWindow(handle, SW_HIDE);
  }
  Destroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  AudioSharePluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("AudioSharePlugin"));
  RemoteInputPluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("RemoteInputPlugin"),
      GetHandle());
  DesktopClipboardImagePluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "DesktopClipboardImagePlugin"),
      GetHandle());
  WindowThemePluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("WindowThemePlugin"),
      GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
//    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    RemoteInputPluginHandleWindowMessage(hwnd, message, wparam, lparam);
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
