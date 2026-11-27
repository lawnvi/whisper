#ifndef FLUTTER_SYSTEM_POWER_PLUGIN_H_
#define FLUTTER_SYSTEM_POWER_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

// Tells Dart when the system is about to sleep (`willSleep`) and when it is
// awake again (`didWake`), on com.vireen.whisper/system_power. Listens to
// logind (or elogind) on the system bus and holds sleep for a moment with a
// delay inhibitor so peers can be let go first. Does nothing without logind.
void system_power_plugin_register(FlPluginRegistry* registry);

#endif  // FLUTTER_SYSTEM_POWER_PLUGIN_H_
