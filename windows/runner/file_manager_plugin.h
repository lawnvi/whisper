#ifndef RUNNER_FILE_MANAGER_PLUGIN_H_
#define RUNNER_FILE_MANAGER_PLUGIN_H_

#include <flutter_plugin_registrar.h>

// `com.vireen.whisper/file_manager` for the remote file manager:
//   thumbnail {path: String, size: int, video: bool} -> JPEG bytes or null.
// The shell's own thumbnail (images, videos, documents with a thumbnail
// handler), fitted into size x size; images the shell will not thumbnail
// (thumbnails turned off in Explorer) are decoded with WIC instead.
// Thumbnails are made on worker threads and answered on the platform thread.
void FileManagerPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif  // RUNNER_FILE_MANAGER_PLUGIN_H_
