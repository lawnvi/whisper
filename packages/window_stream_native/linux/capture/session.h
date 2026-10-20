// One streamed window (wsn_capture_start) and the virtual monitors windows
// are staged on. Capture thread only.
//
// With the viewer's screen known, the window goes to a virtual monitor of
// that shape (one per viewer screen; that viewer's windows take turns on it,
// as on macOS): it leaves the user's screen, keeps running and repainting in
// the background, and the whole monitor is the picture. A fence keeps the
// user's own pointer out. When that is not possible the window is captured
// where it is. Paused for a minute, it goes home and the monitor (and the
// screencast indicator) goes away until the viewer comes back.

#ifndef WSN_CAPTURE_SESSION_H_
#define WSN_CAPTURE_SESSION_H_

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "capture/display_config.h"
#include "capture/encoder.h"
#include "capture/screencast.h"
#include "capture/helper.h"

namespace wsn::capture {

struct StageGeometry {
  int pixel_width = 0;
  int pixel_height = 0;
  double scale = 1;  // wanted; Mutter snaps it to a supported one

  bool operator==(const StageGeometry& o) const {
    return pixel_width == o.pixel_width && pixel_height == o.pixel_height && scale == o.scale;
  }
};

// The monitor for a viewer screen of `width` x `height` points at text
// scale `text_scale`: that shape at 2x where the pixel budget allows.
StageGeometry GeometryFor(double width, double height, double text_scale, int max_edge);

class Session;

// Frames from a monitor's PipeWire thread go to whichever encoder owns it.
struct FrameSink {
  std::mutex mutex;
  std::shared_ptr<Encoder> encoder;
};

class Stage {
 public:
  static Stage* ForKey(int64_t key);
  static Stage* Find(int64_t key);
  static void ForEach(const std::function<void(Stage*)>& visit);

  // `session` puts its window on this monitor: the window there goes home.
  void Take(Session* session);
  // `session` is done with the monitor (stopped, parked); the last one
  // removes it.
  void Leave(Session* session, bool keep_monitor = false);
  // A monitor of `geometry`, then `done(ok)`.
  void Ensure(const StageGeometry& geometry, std::function<void(bool ok)> done);
  void SetSink(std::shared_ptr<Encoder> encoder);
  void Fence(bool on);
  // Keeps the monitor while a window is on its way home (Release when it
  // arrived): removed under the window, Mutter would drop it anywhere.
  void Hold();
  void Release();

  int64_t key() const { return key_; }
  Session* owner() const { return owner_; }
  bool ready() const { return cast_ != nullptr && cast_->is_ready(); }
  const Rect& rect() const { return rect_; }
  double scale() const { return scale_; }
  const StageGeometry& geometry() const { return geometry_; }
  bool HasActiveUser(Session* except) const;

 private:
  explicit Stage(int64_t key);

 public:
  ~Stage();

 private:
  void Create(const StageGeometry& geometry);
  void Finish(bool ok);
  void OnLost(const std::string& why);
  void Destroy();
  void Settle();

  const int64_t key_;
  std::set<Session*> users_;
  Session* owner_ = nullptr;
  std::unique_ptr<ScreenCast> cast_;
  std::shared_ptr<FrameSink> sink_ = std::make_shared<FrameSink>();
  StageGeometry geometry_;
  Rect rect_;
  double scale_ = 1;
  Rect fence_;
  bool fenced_ = false;
  std::vector<std::function<void(bool)>> waiting_;
  guint resize_timer_ = 0;
  int holds_ = 0;
};

class Session {
 public:
  Session(int64_t id, uint32_t window, int pid, int max_edge, int fps, int bit_rate);
  ~Session();

  static Session* Find(int64_t id);
  static void ForEach(const std::function<void(Session*)>& visit);
  static void Add(std::unique_ptr<Session> session);
  // Stops and forgets it.
  static void Remove(int64_t id);

  void Start();
  void Stop();
  void SetScreen(int64_t key) { screen_key_ = key; }
  void SetViewport(double width, double height, double scale);
  void SetInset(double bottom);
  void RequestKeyframe();
  void SetBusy(bool busy);
  void SetPaused(bool paused);
  void SetBitRate(int bit_rate);
  // WSN_CAPTURE_AUDIO_OFF / _ON / _ON_SILENT_HERE (see capture/audio_tap.h).
  void SetAudio(int mode);
  void Input(int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx, double dy, int32_t phase,
             const std::string& text);

  // From the helper.
  void OnWindowGone();
  void OnTextFocus(bool focused);
  void OnHelperVanished();

  // The stage this window was on was taken by another window.
  void StepAside();
  // The stage's monitor went away under the stream.
  void OnStageLost();

  int64_t id() const { return id_; }
  uint32_t window() const { return window_; }
  bool paused() const { return paused_; }

 private:
  enum class Mode { kStarting, kStaging, kStaged, kInPlace, kAside, kParked, kStopped };

  void Begin();
  void StageWindow();
  void PlaceWindow(int attempt = 0);
  void InPlace(const std::string& why);
  void Fail(int32_t error, const std::string& why);
  void Park();
  void GoHome();
  void Watch();
  void Check();
  void Note(const std::string& text);
  bool OnStage() const;
  Rect Target() const;
  Rect InputRect() const;
  void SyncModifiers(int32_t modifiers);
  // Lets go of every key and button this viewer holds (stop, step aside,
  // park, window gone): nothing stays pressed on this desktop.
  void ReleaseHeld();
  // The app's sound follows the window: captured while it is streamed,
  // left alone while it is parked or another window has the monitor.
  void UpdateAudio();
  void ScheduleWarp(guint delay_ms);

  const int64_t id_;
  const uint32_t window_;
  [[maybe_unused]] const int pid_;  // kept for logs and future checks
  const int max_edge_;
  const int fps_;
  std::shared_ptr<Encoder> encoder_;
  Mode mode_ = Mode::kStarting;
  HelperWindow info_;
  int64_t screen_key_ = 0;
  double viewport_width_ = 0;
  double viewport_height_ = 0;
  double text_scale_ = 1;
  double inset_ = 0;
  bool paused_ = false;
  Stage* stage_ = nullptr;
  std::unique_ptr<ScreenCast> cast_;  // in place
  std::shared_ptr<FrameSink> place_sink_;
  guint watch_timer_ = 0;
  guint park_timer_ = 0;
  guint warp_timer_ = 0;
  int generation_ = 0;
  bool button_down_ = false;
  uint32_t button_held_ = 0;
  double pointer_x_ = 0;  // where the last pointer event landed (global)
  double pointer_y_ = 0;
  Rect last_rect_;        // the picture's area while it was live
  std::set<uint32_t> keys_down_;  // ordinary keys the viewer holds
  std::set<uint32_t> held_modifiers_;      // pressed here for a shortcut
  std::set<uint32_t> explicit_modifiers_;  // pressed by the viewer as keys
  bool text_focus_ = false;
  int audio_mode_ = 0;
  int audio_applied_ = 0;
  bool staged_once_ = false;
  // Asynchronous replies hold a weak reference: gone means stopped.
  std::shared_ptr<int> life_ = std::make_shared<int>(0);
};

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_SESSION_H_
