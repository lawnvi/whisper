#ifndef RUNNER_WINDOW_THEME_PLUGIN_H_
#define RUNNER_WINDOW_THEME_PLUGIN_H_

#include <flutter_plugin_registrar.h>
#include <windows.h>

void WindowThemePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window);

#endif  // RUNNER_WINDOW_THEME_PLUGIN_H_
