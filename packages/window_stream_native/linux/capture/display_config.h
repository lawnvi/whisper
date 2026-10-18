// Mutter's monitor layout (org.gnome.Mutter.DisplayConfig), capture thread.

#ifndef WSN_CAPTURE_DISPLAY_CONFIG_H_
#define WSN_CAPTURE_DISPLAY_CONFIG_H_

#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace wsn::capture {

struct Rect {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;

  bool empty() const { return width <= 0 || height <= 0; }
  bool operator==(const Rect& o) const {
    return x == o.x && y == o.y && width == o.width && height == o.height;
  }
  bool operator!=(const Rect& o) const { return !(*this == o); }
  bool Contains(double px, double py) const { return px >= x && py >= y && px < x + width && py < y + height; }
};

struct MonitorInfo {
  std::string connector;
  std::string mode_id;  // the current mode
  int pixel_width = 0;
  int pixel_height = 0;
  std::vector<double> scales;  // supported by the current mode
  bool builtin = false;
  // Per-monitor settings a configuration must hand back unchanged, or Mutter
  // resets them (HDR colour mode, RGB range, underscanning).
  bool has_color_mode = false;
  uint32_t color_mode = 0;
  bool has_rgb_range = false;
  uint32_t rgb_range = 0;
  bool underscanning = false;
};

struct LogicalMonitor {
  Rect rect;  // layout coordinates (logical pixels in logical layout mode)
  double scale = 1;
  uint32_t transform = 0;
  bool primary = false;
  std::vector<std::string> connectors;
};

struct DisplayState {
  uint32_t serial = 0;
  bool logical_layout = true;
  std::vector<LogicalMonitor> logical;
  std::map<std::string, MonitorInfo> monitors;

  const LogicalMonitor* ForConnector(const std::string& connector) const;
};

// Reads the current layout (synchronous, a few ms). False when Mutter's
// DisplayConfig is not reachable.
bool ReadDisplayState(DisplayState* out);

// Our virtual monitors (connector → scale) go in one row below the real
// monitors, left-aligned with them, in the order Mutter numbered them; every
// other logical monitor stays exactly as it is. One temporary configuration
// for all of them at once (Mutter lays a new monitor set out afresh, so they
// are placed together): never stored, Mutter falls back to the user's own
// when they go. Below, not beside: the left and right outer edges belong to
// keyboard-and-mouse sharing with other devices. Each scale must be one
// Mutter lists for that monitor's mode. True when the layout already was so
// or the change was applied.
bool PlaceVirtualMonitors(const std::map<std::string, double>& ours, std::string* error);

// Where PlaceVirtualMonitors puts each of `ours` (logical rects).
std::map<std::string, Rect> LayoutBelow(const DisplayState& state, const std::map<std::string, double>& ours);

// Largest scale Mutter supports for the mode that is at most `wanted` (1 if
// none).
double PickScale(const std::vector<double>& supported, double wanted);

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_DISPLAY_CONFIG_H_
