// Mutter ScreenCast sources (capture thread): a virtual monitor of a chosen
// size (RecordVirtual), or one window where it is (RecordWindow, the
// fallback). Each owns its ScreenCast session and its PipeWire stream; the
// session (and the virtual monitor with it) ends when the object goes.

#ifndef WSN_CAPTURE_SCREENCAST_H_
#define WSN_CAPTURE_SCREENCAST_H_

#include <glib.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "capture/display_config.h"
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
  // `fps`, given `scale` (snapped to what Mutter supports) once it is up.
  static std::unique_ptr<ScreenCast> Virtual(int pixel_width, int pixel_height, double scale, int fps,
                                             PipeWireStream::FrameCallback on_frame, Callbacks callbacks);

  // One window (Mutter's window id) captured where it is. `width` x
  // `height` 0 takes what Mutter offers (a monitor-sized buffer with the
  // window's area marked by a crop region, which the stream applies).
  static std::unique_ptr<ScreenCast> Window(uint64_t window_id, int width, int height, int fps,
                                            PipeWireStream::FrameCallback on_frame, Callbacks callbacks);

  ~ScreenCast();

  // A virtual monitor takes a new size and scale (in place when PipeWire
  // renegotiates it, which Mutter turns into a mode change).
  void Resize(int pixel_width, int pixel_height, double scale);

  bool is_ready() const { return ready_; }
  const Rect& rect() const { return rect_; }
  double scale() const { return scale_; }
  int pixel_width() const { return pixel_width_; }
  int pixel_height() const { return pixel_height_; }
  const std::string& connector() const { return connector_; }

 private:
  ScreenCast(bool virtual_monitor, int pixel_width, int pixel_height, double scale, int fps,
             PipeWireStream::FrameCallback on_frame, Callbacks callbacks);
  bool Begin(uint64_t window_id);
  void OnNode(uint32_t node);
  void OnNegotiated(int width, int height);
  void FindMonitor(int attempt);
  void OnLayoutChanged();
  void Fail(const std::string& why);

  const bool virtual_;
  int pixel_width_;
  int pixel_height_;
  double wanted_scale_;
  const int fps_;
  PipeWireStream::FrameCallback on_frame_;
  Callbacks callbacks_;

  std::string session_path_;
  std::string stream_path_;
  guint node_signal_ = 0;
  guint closed_signal_ = 0;
  guint layout_signal_ = 0;
  guint find_timer_ = 0;
  guint deadline_timer_ = 0;  // creation must finish within kCreateTimeoutMs
  std::unique_ptr<PipeWireStream> stream_;
  std::shared_ptr<bool> alive_;
  std::string connector_;
  Rect rect_;
  double scale_ = 1;
  bool ready_ = false;
  bool failed_ = false;
  bool resizing_ = false;
  int placements_ = 0;  // re-placements in a row (no fight with the layout)
};

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_SCREENCAST_H_
