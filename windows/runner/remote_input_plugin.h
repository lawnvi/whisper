#ifndef RUNNER_REMOTE_INPUT_PLUGIN_H_
#define RUNNER_REMOTE_INPUT_PLUGIN_H_

#include <flutter_plugin_registrar.h>
#include <windows.h>

void RemoteInputPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window);

bool RemoteInputPluginHandleWindowMessage(HWND window,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam);

#endif  // RUNNER_REMOTE_INPUT_PLUGIN_H_
