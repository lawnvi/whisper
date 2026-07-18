#ifndef RUNNER_DESKTOP_CLIPBOARD_IMAGE_PLUGIN_H_
#define RUNNER_DESKTOP_CLIPBOARD_IMAGE_PLUGIN_H_

#include <flutter_plugin_registrar.h>
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

void DesktopClipboardImagePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar,
    HWND window);

// Captures the file-list or Unicode-text clipboard payload into explicit
// quick-send arguments. The clipboard is read synchronously so a launcher can
// persist the payload before returning to its caller.
std::optional<std::vector<std::string>>
DesktopClipboardSnapshotQuickSendArguments();

#endif  // RUNNER_DESKTOP_CLIPBOARD_IMAGE_PLUGIN_H_
