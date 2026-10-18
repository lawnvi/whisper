// "Is the picture stable yet?" for one streamed window (ws/ROUND2.md).
//
// While a stream opens, the source lays its window out for this viewer, so
// the first frames come at the wrong size and then settle. Until the
// picture is stable the window shows a placeholder (the window's last known
// picture, dimmed, or the app's icon on the dark background) with a
// spinner, never the raw
// frames; then the placeholder crossfades into the live picture.
//
// Stable = a frame was decoded, its size has not changed for 300 ms and at
// least one frame came at it (a static window may send just one). This
// receiver never sees the stream's SIZE packets, so the decoded size is the
// size.
// 2.5 s after the first frame it counts as stable anyway.
// Later size changes (the viewer resizing the window) do not bring the
// spinner back. After a pause the spinner shows again only if no new frame
// arrives within 300 ms of resuming.
//
// Thread-safe: the decode thread reports frames, Dart's calls report
// visual changes, the presenter evaluates when it draws.

#pragma once

#include "../common/wsn_common.h"

#include <cstdint>
#include <mutex>

namespace wsn {

class Readiness {
 public:
  struct View {
    // Opacity of the placeholder layer (1 while loading, falling to 0 over
    // the crossfade, 0 once live).
    double cover = 0;
    // Live frames may be drawn under the cover (false while loading: no
    // raw, wrongly sized frames on screen).
    bool show_frames = true;
    // The placeholder is the last frame (resuming), not the poster.
    bool cover_is_last_frame = false;
    bool spinner = false;
    // Nothing decoded for 8 s: show the visual's message under the spinner.
    bool hint = false;
    // Something moves: draw again at the next refresh.
    bool animating = false;
    // First evaluation after the picture became stable (once).
    bool became_stable = false;
  };

  explicit Readiness(double opened_at);

  void OnFrame(int width, int height, double now);
  void OnVisual(int32_t visual, double now);
  View Evaluate(double now);
  bool stable();
  // Seconds from the first decoded frame to stable (-1 before).
  double settle_seconds();

 private:
  bool CheckStableLocked(double now);

  std::mutex mutex_;
  double opened_at_;
  double connecting_since_;
  int32_t visual_ = WSN_VISUAL_CONNECTING;
  double first_frame_at_ = -1;
  int width_ = 0;
  int height_ = 0;
  double last_change_at_ = -1;
  int frames_since_change_ = 0;
  int64_t frames_ = 0;
  bool stable_ = false;          // the picture settled
  double stable_at_ = -1;
  double live_at_ = -1;          // stable and the visual is live: the crossfade starts
  bool reported_stable_ = false;
  bool reduce_motion_ = false;
  // Resuming after a pause or reconnect.
  double resumed_at_ = -1;
  int64_t frames_at_resume_ = 0;
  bool resume_cover_ = false;    // the spinner came back
  double resume_fade_at_ = -1;
};

// The system's "Show animations in Windows" setting is off.
bool ReduceMotion();

}  // namespace wsn
