#ifndef RUNNER_DESKTOP_CLIPBOARD_IMAGE_PLUGIN_H_
#define RUNNER_DESKTOP_CLIPBOARD_IMAGE_PLUGIN_H_

#include <flutter_plugin_registrar.h>
#include <windows.h>

void DesktopClipboardImagePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar,
    HWND window);

#endif  // RUNNER_DESKTOP_CLIPBOARD_IMAGE_PLUGIN_H_
