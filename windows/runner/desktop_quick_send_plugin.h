#ifndef RUNNER_DESKTOP_QUICK_SEND_PLUGIN_H_
#define RUNNER_DESKTOP_QUICK_SEND_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#include <string>
#include <vector>

void DesktopQuickSendPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
enum class DesktopQuickSendEnqueueOutcome {
  kIgnored,
  kAccepted,
  kRejected,
};
DesktopQuickSendEnqueueOutcome DesktopQuickSendPluginEmitArguments(
    const std::vector<std::string>& arguments);

#endif  // RUNNER_DESKTOP_QUICK_SEND_PLUGIN_H_
