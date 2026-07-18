#ifndef FLUTTER_DESKTOP_QUICK_SEND_PLUGIN_H_
#define FLUTTER_DESKTOP_QUICK_SEND_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

void desktop_quick_send_plugin_register(FlPluginRegistry* registry);
typedef enum {
  DESKTOP_QUICK_SEND_IGNORED,
  DESKTOP_QUICK_SEND_ACCEPTED,
  DESKTOP_QUICK_SEND_REJECTED,
} DesktopQuickSendEnqueueOutcome;
DesktopQuickSendEnqueueOutcome desktop_quick_send_plugin_emit_arguments(
    char** arguments);

#endif  // FLUTTER_DESKTOP_QUICK_SEND_PLUGIN_H_
