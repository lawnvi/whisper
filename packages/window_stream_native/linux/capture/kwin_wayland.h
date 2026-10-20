// KWin's own Wayland protocols, on a connection of the capture side's own
// (capture thread): virtual outputs and window streams
// (zkde_screencast_unstable_v1), input (org_kde_kwin_fake_input), and the
// output layout (kde_output_device_v2, kde_output_management_v2).
//
// KWin hands the first two only to executables a .desktop file vouches for
// (X-KDE-Wayland-Interfaces, matched by the Exec path); capture/kwin_helper.cc
// writes that file before connecting. Nothing here asks the user anything,
// and everything ends with the connection: closing it (or the process dying)
// removes our virtual outputs, and KWin puts their windows back.

#ifndef WSN_CAPTURE_KWIN_WAYLAND_H_
#define WSN_CAPTURE_KWIN_WAYLAND_H_

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "capture/display_config.h"

namespace wsn::capture::kwin {

// Built with the protocols (wayland-client and wayland-scanner were there).
bool Compiled();

struct OutputInfo {
  std::string name;  // "Virtual-<our name>" for ours
  Rect rect;         // logical layout coordinates
  double scale = 1;
  int pixel_width = 0;
  int pixel_height = 0;
  bool enabled = true;
};

struct StreamCallbacks {
  // The PipeWire node carrying the picture.
  std::function<void(uint32_t node)> node;
  // KWin refused or ended the stream (`why` is for the log).
  std::function<void(const std::string& why)> lost;
};

// Connects on first use (and again after the connection was lost). False
// when there is no Wayland display or KWin withholds the screencast and
// input protocols (`why` says which).
bool Connect(std::string* why);
bool Connected();

// A new virtual output "Virtual-<name>" of `pixel_width` x `pixel_height`
// streamed to PipeWire (no cursor in the picture). Returns a handle for
// CloseStream, 0 when not connected.
uint32_t StreamVirtualOutput(const std::string& name, const std::string& description, int pixel_width,
                             int pixel_height, double scale, StreamCallbacks callbacks);
// One window (KWin's internal id) captured where it is.
uint32_t StreamWindow(const std::string& uuid, StreamCallbacks callbacks);
// Ends a stream (a virtual output goes with it). No callbacks after this.
void CloseStream(uint32_t handle);

// The outputs as KWin last described them.
std::vector<OutputInfo> Outputs();
// Runs whenever an output appears, changes or goes away.
void SetOutputsChanged(std::function<void()> changed);

// Moves output `name` to `x`,`y` at `scale`, with a mode of `pixel_width` x
// `pixel_height` when given (> 0; custom modes, KWin 6.4 and later).
// `done(ok)` runs once KWin applied it or refused.
void ConfigureOutput(const std::string& name, int x, int y, double scale, int pixel_width, int pixel_height,
                     std::function<void(bool ok)> done);
// KWin can change a virtual output's mode in place.
bool CanResize();

// Input in layout coordinates (logical pixels).
void PointerAbsolute(double x, double y);
// Linux button codes (BTN_LEFT 0x110 ...).
void Button(uint32_t code, bool down);
// Axis 0 vertical, 1 horizontal; positive scrolls down / right.
void Axis(uint32_t axis, double value);
void Key(uint32_t evdev, bool down);
// Any keysym, Unicode ones (0x01000000 | code point) included.
void Keysym(uint32_t keysym, bool down);

}  // namespace wsn::capture::kwin

#endif  // WSN_CAPTURE_KWIN_WAYLAND_H_
