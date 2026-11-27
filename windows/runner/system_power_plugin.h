#ifndef RUNNER_SYSTEM_POWER_PLUGIN_H_
#define RUNNER_SYSTEM_POWER_PLUGIN_H_

#include <flutter_plugin_registrar.h>
#include <windows.h>

// Tells Dart when the system is about to sleep (`willSleep`) and when it is
// awake again (`didWake`), on com.vireen.whisper/system_power, so peers are
// let go before sleep and redialled after it. |window| is the main window,
// which receives the WM_POWERBROADCAST notices.
void SystemPowerPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window);

// Passes WM_POWERBROADCAST on to Dart. Never consumes the message: the window
// procedure still answers it as before.
void SystemPowerPluginObserveWindowMessage(UINT message, WPARAM wparam);

#endif  // RUNNER_SYSTEM_POWER_PLUGIN_H_
