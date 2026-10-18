// The catalog of windows this PC can stream, plus installed-app list, app
// icons and window thumbnails, launching and closing — the Windows side of
// macOS CaptureCatalog. Results go to Dart through the capture callback,
// keyed by the request id (so they can be async like the shell calls).
#pragma once

#include "wsn_util.h"

#include <cstdint>
#include <string>

namespace wsn {

// {"windows":[{id,title,appName,bundleId,pid,width,height,onScreen,active}],
//  "apps":[{bundleId,name,running}], "locked":bool}. Emitted as CATALOG.
void RequestCatalog(int64_t request_id);
// PNG of [app_id] (AUMID or exe path) at [size] px. Emitted as ICON.
void RequestIcon(int64_t request_id, const std::string& app_id, int size);
// JPEG of window [window_id] (HWND as uint32), longest edge <= [max_edge].
// PrintWindow first, WGC as a fallback. Emitted as THUMBNAIL.
void RequestThumbnail(int64_t request_id, uint32_t window_id, int max_edge);
// Starts (or reopens) [app_id]; emits LAUNCHED on success, FAILED otherwise.
void LaunchApp(int64_t request_id, const std::string& app_id);
// Closes window [window_id] as its close button would (SC_CLOSE), if it
// belongs to [pid].
void CloseWindow(uint32_t window_id, int pid);

// Starts the installed-app cache warming in the background (called once when
// the capture callback is set) so the first catalog answers quickly.
void WarmInstalledApps();

// HWND <-> uint32 (sign-extended back), as the ABI carries window ids.
inline uint32_t HwndToId(HWND window) {
  return static_cast<uint32_t>(reinterpret_cast<intptr_t>(window));
}
inline HWND IdToHwnd(uint32_t id) {
  return reinterpret_cast<HWND>(static_cast<intptr_t>(static_cast<int32_t>(id)));
}

// The app id (bundleId) of a window: its explicit AUMID, else the packaged
// process AUMID, else the lowercased exe path.
std::string WindowAppId(HWND window);

// Whether the input desktop is the normal one (false: a secure desktop /
// locked session, where nothing can be captured or injected).
bool SessionLocked();

}  // namespace wsn
