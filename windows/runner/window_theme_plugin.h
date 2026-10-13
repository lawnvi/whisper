#ifndef RUNNER_WINDOW_THEME_PLUGIN_H_
#define RUNNER_WINDOW_THEME_PLUGIN_H_

#include <flutter_plugin_registrar.h>
#include <windows.h>

void WindowThemePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window);

// Reports the brightness the app chose for the title bar of |window|, which
// is kept on the window itself. Returns false while the app has not chosen.
bool WindowThemeChosenDarkMode(HWND window, BOOL* enable_dark_mode);

// Drops what was kept on |window|; for when the window is destroyed.
void WindowThemeForget(HWND window);

#endif  // RUNNER_WINDOW_THEME_PLUGIN_H_
