#ifndef RUNNER_FILE_MANAGER_PLUGIN_H_
#define RUNNER_FILE_MANAGER_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

// com.vireen.whisper/file_manager for the remote file manager:
//   trash {path: String}                      → bool
//   thumbnail {path: String, size: int, video: bool} → JPEG bytes or null
// Both run off the main thread and answer on it.
void file_manager_plugin_register(FlPluginRegistry* registry);

#endif  // RUNNER_FILE_MANAGER_PLUGIN_H_
