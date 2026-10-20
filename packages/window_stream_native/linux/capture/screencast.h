// Screencast sources (capture thread): a virtual monitor of a chosen size,
// or one window where it is (the fallback). Each owns its compositor
// session and its PipeWire stream; the session (and the virtual monitor with
// it) ends when the object goes. Mutter's ScreenCast API on GNOME
// (screencast.cc), KWin's zkde_screencast protocol on KDE Plasma
// (kwin_screencast.cc).

#ifndef WSN_CAPTURE_SCREENCAST_H_
#define WSN_CAPTURE_SCREENCAST_H_

#include <glib.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "capture/display_config.h"
#include "capture/helper.h"
#include "capture/pipewire_stream.h"

namespace wsn::capture {

// Mutter's ScreenCast API is there in a version this code knows (≥ 4).
// Synchronous, any thread; cached after the first answer.
bool ScreenCastAvailable();

class ScreenCast {
 public:
  struct Callbacks {
    // The source is up. For a virtual monitor: where it sits in the layout
    // (logical pixels) and its scale.
    std::function<void(const Rect& rect, double scale)> ready;
    // It failed or went away (`why` is for the log).
    std::function<void(const std::string& why)> lost;
    // The layout moved or resized the virtual monitor.
    std::function<void(const Rect& rect, double scale)> moved;
  };

  // A virtual monitor of `pixel_width` x `pixel_height`, refreshing at up to
  // `fps`, given `scale` (snapped to what the compositor supports) once it
  // is up.
  static std::unique_ptr<ScreenCast> Virtual(int pixel_width, int pixel_height, double scale, int fps,
                                             PipeWireStream::FrameCallback on_frame, Callbacks callbacks);

  // One window captured where it is. `width` x `height` 0 takes what the
  // compositor offers (Mutter: a monitor-sized buffer with the window's area
  // marked by a crop region, which the stream applies).
  static std::unique_ptr<ScreenCast> Window(const HelperWindow& window, int width, int height, int fps,
                                            PipeWireStream::FrameCallback on_frame, Callbacks callbacks);

  virtual ~ScreenCast() = default;

  // A virtual monitor takes a new size and scale (in place where the
  // compositor allows; `moved` reports the result).
  virtual void Resize(int pixel_width, int pixel_height, double scale) = 0;

  bool is_ready() const { return ready_; }
  const Rect& rect() const { return rect_; }
  double scale() const { return scale_; }
  int pixel_width() const { return pixel_width_; }
  int pixel_height() const { return pixel_height_; }
  const std::string& connector() const { return connector_; }

 protected:
  ScreenCast(int pixel_width, int pixel_height) : pixel_width_(pixel_width), pixel_height_(pixel_height) {}

  int pixel_width_;
  int pixel_height_;
  std::string connector_;
  Rect rect_;
  double scale_ = 1;
  bool ready_ = false;
};

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_SCREENCAST_H_
