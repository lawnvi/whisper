#ifndef RUNNER_SCREENSHOT_PLUGIN_H_
#define RUNNER_SCREENSHOT_PLUGIN_H_
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

void ScreenshotPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window);
#endif
