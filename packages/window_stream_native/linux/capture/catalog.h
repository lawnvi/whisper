// What this desktop can offer: its windows (from the GNOME Shell helper),
// the installed apps (GIO), their icons (the GTK icon theme), window
// thumbnails, and starting apps. Results go out through the capture
// callback under the request's id.

#ifndef WSN_CAPTURE_CATALOG_H_
#define WSN_CAPTURE_CATALOG_H_

#include <cstdint>
#include <string>

namespace wsn::capture {

// Capture thread.
void RequestCatalog(int64_t id);
void RequestThumbnail(int64_t id, uint32_t window, int max_edge);
void CloseWindow(uint32_t window);

// Any thread (they hop to the GTK thread themselves).
void RequestIcon(int64_t id, const std::string& app_id, int size);
void LaunchApp(int64_t id, const std::string& app_id);

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_CATALOG_H_
