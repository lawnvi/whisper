#include "capture/session.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <functional>
#include <vector>

#include "capture/audio_tap.h"
#include "capture/capture_thread.h"
#include "common/callbacks.h"
#include "common/log.h"
#include "window_stream_native.h"
#include "wsn_keymap.h"

namespace wsn::capture {

namespace {

// Mutter offers a scale above 1 only when the logical monitor keeps at
// least this area (800x480).
constexpr double kMinLogicalArea = 800.0 * 480.0;
// x264 on a dual-core laptop keeps 30–60 fps up to about this many pixels.
constexpr double kPixelBudget = 2.4e6;
constexpr int kMaxEdge = 2560;
constexpr int kMinSide = 320;
constexpr int kMaxSide = 4096;
constexpr double kMaxInset = 0.8;

// Pointer moves without a button: the pointer goes home after this pause.
constexpr guint kHoverWarpMs = 600;
// After a tap: back home unless another one follows right away.
constexpr guint kTapWarpMs = 150;

// evdev codes (linux/input-event-codes.h).
constexpr uint32_t kKeyLeftCtrl = 29;
constexpr uint32_t kKeyRightCtrl = 97;
constexpr uint32_t kKeyLeftShift = 42;
constexpr uint32_t kKeyRightShift = 54;
constexpr uint32_t kKeyLeftAlt = 56;
constexpr uint32_t kKeyRightAlt = 100;
constexpr uint32_t kKeyCapsLock = 58;

// How long a pause lasts before the window goes home (WHISPER_WSN_PARK_SECONDS
// shortens it for tests).
guint ParkDelayMs() {
  static guint delay = [] {
    const char* value = g_getenv("WHISPER_WSN_PARK_SECONDS");
    int seconds = value != nullptr ? atoi(value) : 0;
    return static_cast<guint>((seconds > 0 ? seconds : 60) * 1000);
  }();
  return delay;
}

// Clutter scroll sources (Clutter.ScrollSource).
constexpr uint32_t kScrollWheel = 1;
constexpr uint32_t kScrollFinger = 2;

std::map<int64_t, std::unique_ptr<Stage>>& Stages() {
  static auto* stages = new std::map<int64_t, std::unique_ptr<Stage>>();
  return *stages;
}

std::map<int64_t, std::unique_ptr<Session>>& Sessions() {
  static auto* sessions = new std::map<int64_t, std::unique_ptr<Session>>();
  return *sessions;
}

// macOS modifier keys as evdev keys (Command is Ctrl here: one shortcut
// convention for every source).
uint32_t ModifierKey(int32_t mac) {
  switch (mac) {
    case 55:  // Command
    case 59:  // Control
      return kKeyLeftCtrl;
    case 54:  // right Command
    case 62:  // right Control
      return kKeyRightCtrl;
    case 56: return kKeyLeftShift;
    case 60: return kKeyRightShift;
    case 58: return kKeyLeftAlt;
    case 61: return kKeyRightAlt;
    case 57: return kKeyCapsLock;
    default: return 0;
  }
}

std::string Describe(const Rect& r) {
  gchar* text = g_strdup_printf("%dx%d at %d,%d", r.width, r.height, r.x, r.y);
  std::string value = text;
  g_free(text);
  return value;
}

}  // namespace

StageGeometry GeometryFor(double width, double height, double text_scale, int max_edge) {
  double s = text_scale > 0 ? text_scale : 1;
  double lw = std::clamp(std::round(width / s), double(kMinSide), double(kMaxSide));
  double lh = std::clamp(std::round(height / s), double(kMinSide), double(kMaxSide));
  if (lw * lh < kMinLogicalArea) {
    // A little larger than the viewer's screen, so 2x is allowed at all.
    double k = std::sqrt(kMinLogicalArea / (lw * lh));
    lw = std::ceil(lw * k);
    lh = std::ceil(lh * k);
  }
  int edge = max_edge > 0 ? std::min(max_edge, kMaxEdge) : kMaxEdge;
  double fit = std::min({2.0, std::sqrt(kPixelBudget / (lw * lh)), edge / std::max(lw, lh)});
  StageGeometry g;
  if (fit < 1) {
    // Even 1x is over budget: fewer, larger logical pixels.
    g.pixel_width = std::max(160, static_cast<int>(std::round(lw * fit)) & ~1);
    g.pixel_height = std::max(160, static_cast<int>(std::round(lh * fit)) & ~1);
    g.scale = 1;
    return g;
  }
  // The largest scale within the budget that Mutter can apply exactly: the
  // logical size a multiple of the scale's denominator (and of the pixel
  // size's evenness), so logical and pixel sizes are both whole.
  struct Choice {
    double scale;
    int multiple;
  };
  static const Choice kChoices[] = {{2.0, 1}, {1.75, 8}, {1.5, 4}, {1.25, 8}, {1.0, 2}};
  for (const Choice& choice : kChoices) {
    if (choice.scale > fit + 1e-9) continue;
    auto snap = [&](double logical) {
      int m = choice.multiple;
      return std::max(m, static_cast<int>(std::lround(logical / m)) * m);
    };
    int w = snap(lw);
    int h = snap(lh);
    g.pixel_width = static_cast<int>(std::lround(w * choice.scale));
    g.pixel_height = static_cast<int>(std::lround(h * choice.scale));
    g.scale = choice.scale;
    break;
  }
  return g;
}

// ---------------------------------------------------------------- Stage

Stage::Stage(int64_t key) : key_(key) {}

Stage::~Stage() { CancelTimer(resize_timer_); }

Stage* Stage::ForKey(int64_t key) {
  auto& stages = Stages();
  auto found = stages.find(key);
  if (found != stages.end()) return found->second.get();
  auto* stage = new Stage(key);
  stages[key].reset(stage);
  return stage;
}

Stage* Stage::Find(int64_t key) {
  auto& stages = Stages();
  auto found = stages.find(key);
  return found == stages.end() ? nullptr : found->second.get();
}

void Stage::ForEach(const std::function<void(Stage*)>& visit) {
  std::vector<Stage*> all;
  for (auto& entry : Stages()) all.push_back(entry.second.get());
  for (Stage* stage : all) visit(stage);
}

bool Stage::HasActiveUser(Session* except) const {
  for (Session* user : users_) {
    if (user != except && !user->paused()) return true;
  }
  return false;
}

void Stage::Take(Session* session) {
  users_.insert(session);
  if (owner_ != nullptr && owner_ != session) {
    Session* previous = owner_;
    owner_ = nullptr;
    SetSink(nullptr);
    previous->StepAside();
  }
  owner_ = session;
}

void Stage::Leave(Session* session, bool keep_monitor) {
  if (owner_ == session) {
    owner_ = nullptr;
    SetSink(nullptr);
  }
  if (!keep_monitor) users_.erase(session);
  Settle();
}

void Stage::Hold() {
  holds_++;
  int64_t key = key_;
  // Never longer than this, whatever the helper does.
  PostAfter(2500, [key] {
    if (Stage* stage = Find(key)) stage->Release();
  });
}

void Stage::Release() {
  if (holds_ == 0) return;
  holds_--;
  Settle();
}

// Nobody live on the monitor: it goes (once no window is on its way home),
// and the stage itself once nobody uses it.
void Stage::Settle() {
  if (holds_ > 0) return;
  if (cast_ != nullptr && (users_.empty() || (owner_ == nullptr && !HasActiveUser(nullptr)))) Destroy();
  if (users_.empty()) {
    int64_t key = key_;
    // Deleted from the loop, not from inside one of its own calls.
    Post([key] {
      auto& stages = Stages();
      auto found = stages.find(key);
      if (found != stages.end() && found->second->users_.empty() && found->second->holds_ == 0) stages.erase(found);
    });
  }
}

void Stage::SetSink(std::shared_ptr<Encoder> encoder) {
  std::lock_guard<std::mutex> lock(sink_->mutex);
  sink_->encoder = std::move(encoder);
}

void Stage::Fence(bool on) {
  ShellHelper& helper = ShellHelper::Get();
  if (fenced_ && (!on || fence_ != rect_)) {
    helper.SetFence(fence_, false);
    fenced_ = false;
  }
  if (on && !fenced_ && !rect_.empty()) {
    fence_ = rect_;
    helper.SetFence(fence_, true);
    fenced_ = true;
  }
}

void Stage::Ensure(const StageGeometry& geometry, std::function<void(bool ok)> done) {
  if (cast_ != nullptr && cast_->is_ready() && geometry == geometry_) {
    Post([done] { done(true); });
    return;
  }
  waiting_.push_back(std::move(done));
  if (cast_ != nullptr && !cast_->is_ready() && geometry == geometry_) return;  // already on its way
  if (cast_ != nullptr && cast_->is_ready()) {
    // A new size: Mutter changes the monitor's mode in place when the
    // stream asks for it; if it does not within a moment, a new monitor.
    geometry_ = geometry;
    cast_->Resize(geometry.pixel_width, geometry.pixel_height, geometry.scale);
    CancelTimer(resize_timer_);
    // Looked up again by key: the stage may be gone by then.
    resize_timer_ = PostAfter(1500, [key = key_] {
      Stage* stage = Find(key);
      if (stage == nullptr) return;
      stage->resize_timer_ = 0;
      // Still waiting: the mode did not change; a monitor of the new size.
      if (stage->cast_ != nullptr && !stage->waiting_.empty()) {
        WSN_LOG("capture: monitor resize not seen, making a new one");
        stage->Create(stage->geometry_);
      }
    });
    return;
  }
  Create(geometry);
}

void Stage::Create(const StageGeometry& geometry) {
  geometry_ = geometry;
  Fence(false);
  std::shared_ptr<FrameSink> sink = sink_;
  int fps = geometry.pixel_width * geometry.pixel_height > 1300000 ? 30 : 60;
  cast_ = ScreenCast::Virtual(
      geometry.pixel_width, geometry.pixel_height, geometry.scale, fps,
      [sink](const Frame& frame) {
        std::shared_ptr<Encoder> encoder;
        {
          std::lock_guard<std::mutex> lock(sink->mutex);
          encoder = sink->encoder;
        }
        if (encoder != nullptr) encoder->Push(frame);
      },
      ScreenCast::Callbacks{
          [this](const Rect& rect, double scale) {
            rect_ = rect;
            scale_ = scale;
            Finish(true);
          },
          [this](const std::string& why) { OnLost(why); },
          [this](const Rect& rect, double scale) {
            bool resized = rect.width != rect_.width || rect.height != rect_.height;
            rect_ = rect;
            scale_ = scale;
            if (fenced_) Fence(true);
            if (!waiting_.empty() && resized) {
              CancelTimer(resize_timer_);
              resize_timer_ = 0;
              Finish(true);
            } else if (owner_ != nullptr) {
              // Moved in the layout: put the window back on it.
              owner_->OnStageLost();
            }
          },
      });
}

void Stage::Finish(bool ok) {
  auto waiting = std::move(waiting_);
  waiting_.clear();
  for (auto& done : waiting) done(ok);
}

void Stage::OnLost(const std::string& why) {
  bool creating = !waiting_.empty();
  CancelTimer(resize_timer_);
  resize_timer_ = 0;
  Fence(false);
  // Destroyed from the loop: this runs inside the cast's own callback.
  std::shared_ptr<ScreenCast> doomed(cast_.release());
  Post([doomed] {});
  if (creating) {
    Finish(false);
    return;
  }
  if (owner_ != nullptr) owner_->OnStageLost();
}

void Stage::Destroy() {
  Fence(false);
  CancelTimer(resize_timer_);
  resize_timer_ = 0;
  cast_.reset();
  rect_ = Rect();
  Finish(false);
}

// ---------------------------------------------------------------- Session

Session::Session(int64_t id, uint32_t window, int pid, int max_edge, int fps, int bit_rate)
    : id_(id),
      window_(window),
      pid_(pid),
      max_edge_(max_edge),
      fps_(std::clamp(fps, 1, 60)),
      encoder_(std::make_shared<Encoder>(id, std::clamp(fps, 1, 60), bit_rate)) {
  screen_key_ = id;
}

Session::~Session() {
  Stop();
  life_.reset();  // replies still on their way find nobody
}

Session* Session::Find(int64_t id) {
  auto& sessions = Sessions();
  auto found = sessions.find(id);
  return found == sessions.end() ? nullptr : found->second.get();
}

void Session::ForEach(const std::function<void(Session*)>& visit) {
  std::vector<Session*> all;
  for (auto& entry : Sessions()) all.push_back(entry.second.get());
  for (Session* session : all) visit(session);
}

void Session::Add(std::unique_ptr<Session> session) {
  int64_t id = session->id();
  Sessions()[id] = std::move(session);
}

void Session::Remove(int64_t id) {
  auto& sessions = Sessions();
  auto found = sessions.find(id);
  if (found == sessions.end()) return;
  std::unique_ptr<Session> session = std::move(found->second);
  sessions.erase(found);
  session->Stop();
}

void Session::Note(const std::string& text) { EmitCaptureNote(id_, text); }

void Session::Start() {
  // After the screen and viewport Dart sets right after start.
  int generation = generation_;
  std::weak_ptr<int> alive = life_;
  Post([this, alive, generation] {
    if (!alive.expired() && generation == generation_) Begin();
  });
}

void Session::Fail(int32_t error, const std::string& why) {
  if (mode_ == Mode::kStopped) return;
  Note(why);
  EmitCapture(id_, WSN_CAPTURE_FAILED, nullptr, 0, 0, error);
}

void Session::Begin() {
  if (mode_ == Mode::kStopped) return;
  ShellHelper& helper = ShellHelper::Get();
  HelperState state = helper.Check();
  if (state != HelperState::kReady) {
    Fail(WSN_CAPTURE_ERROR_HELPER, std::string("helper: ") + HelperStateName(state));
    return;
  }
  std::string encoder;
  if (!Encoder::Available(&encoder)) {
    Fail(WSN_CAPTURE_ERROR_ENCODER, "no H.264 encoder (FFmpeg with libx264 or libopenh264)");
    return;
  }
  int generation = ++generation_;
  std::weak_ptr<int> alive = life_;
  helper.ListWindows([this, alive, generation](bool ok, std::vector<HelperWindow> windows, bool locked) {
    if (alive.expired() || generation != generation_ || mode_ == Mode::kStopped) return;
    if (locked) {
      Fail(WSN_CAPTURE_ERROR_LOCKED, "the session is locked");
      return;
    }
    auto found = std::find_if(windows.begin(), windows.end(), [this](const HelperWindow& w) { return w.id == window_; });
    if (!ok || found == windows.end()) {
      Fail(WSN_CAPTURE_ERROR_NOT_FOUND, "window not found");
      return;
    }
    info_ = *found;
    if (viewport_width_ > 0 && viewport_height_ > 0) {
      StageWindow();
    } else {
      InPlace("no viewer screen size yet");
    }
  });
}

bool Session::OnStage() const { return stage_ != nullptr && stage_->owner() == this && mode_ == Mode::kStaged; }

Rect Session::Target() const {
  Rect rect = stage_ != nullptr ? stage_->rect() : Rect();
  rect.height = std::max(1, static_cast<int>(std::lround(rect.height * (1 - inset_))));
  return rect;
}

void Session::StageWindow() {
  if (mode_ == Mode::kStopped) return;
  WSN_TRACE("capture %lld: staging on screen %lld", static_cast<long long>(id_), static_cast<long long>(screen_key_));
  cast_.reset();
  place_sink_.reset();
  mode_ = Mode::kStaging;
  UpdateAudio();
  CancelTimer(park_timer_);
  park_timer_ = 0;
  stage_ = Stage::ForKey(screen_key_);
  stage_->Take(this);
  StageGeometry geometry = GeometryFor(viewport_width_, viewport_height_, text_scale_, max_edge_);
  int generation = ++generation_;
  std::weak_ptr<int> alive = life_;
  stage_->Ensure(geometry, [this, alive, generation](bool ok) {
    if (alive.expired()) return;
    WSN_TRACE("capture %lld: monitor %s (generation %d/%d, mode %d)", static_cast<long long>(id_),
              ok ? "ready" : "failed", generation, generation_, static_cast<int>(mode_));
    if (generation != generation_ || mode_ != Mode::kStaging) return;
    if (!ok || stage_ == nullptr || stage_->owner() != this) {
      InPlace("no virtual monitor");
      return;
    }
    PlaceWindow();
  });
}

void Session::PlaceWindow(int attempt) {
  int generation = ++generation_;
  Rect target = Target();
  std::weak_ptr<int> alive = life_;
  ShellHelper::Get().Stage(window_, target, [this, alive, generation, attempt, target](bool ok, Rect frame,
                                                                                      const std::string& error) {
    if (alive.expired() || generation != generation_ || mode_ == Mode::kStopped || stage_ == nullptr ||
        stage_->owner() != this) {
      return;
    }
    if (!ok) {
      InPlace("could not move the window (" + error + ")");
      return;
    }
    bool first = mode_ != Mode::kStaged;
    mode_ = Mode::kStaged;
    if (attempt == 0 && (frame.width != target.width || frame.height != target.height)) {
      // A GTK 4 window keeps the size bounds of the monitor it came from
      // for its first configure; asked again on its new monitor, it fills it.
      PostAfter(150, [this, alive, generation] {
        if (!alive.expired() && generation == generation_ && mode_ == Mode::kStaged) PlaceWindow(1);
      });
    }
    staged_once_ = true;
    stage_->SetSink(encoder_);
    stage_->Fence(true);
    encoder_->RequestKeyframe();
    if (first) {
      gchar* text = g_strdup_printf("staged on its own monitor: %dx%d px at scale %.2f, window %s",
                                    stage_->geometry().pixel_width, stage_->geometry().pixel_height, stage_->scale(),
                                    Describe(frame).c_str());
      Note(text);
      g_free(text);
      Watch();
    }
  });
}

void Session::InPlace(const std::string& why) {
  if (mode_ == Mode::kStopped) return;
  Note("streaming the window where it is: " + why);
  ReleaseHeld();
  if (stage_ != nullptr) {
    if (stage_->owner() == this) ShellHelper::Get().Unstage(window_);
    stage_->Leave(this);
    stage_ = nullptr;
  }
  mode_ = Mode::kInPlace;
  ++generation_;
  UpdateAudio();
  if (info_.minimized) ShellHelper::Get().Unminimize(window_);
  auto sink = std::make_shared<FrameSink>();
  {
    std::lock_guard<std::mutex> lock(sink->mutex);
    sink->encoder = encoder_;
  }
  place_sink_ = sink;
  cast_ = ScreenCast::Window(
      info_.window_id, 0, 0, fps_,
      [sink](const Frame& frame) {
        std::shared_ptr<Encoder> encoder;
        {
          std::lock_guard<std::mutex> lock(sink->mutex);
          encoder = sink->encoder;
        }
        if (encoder != nullptr) encoder->Push(frame);
      },
      ScreenCast::Callbacks{
          [this](const Rect&, double) { encoder_->RequestKeyframe(); },
          [this](const std::string& why) {
            Note("window capture ended: " + why);
            EmitCapture(id_, WSN_CAPTURE_STOPPED, nullptr, 0, 0, WSN_CAPTURE_ERROR_UNKNOWN);
          },
          {},
      });
  Watch();
}

void Session::StepAside() {
  if (mode_ == Mode::kStopped) return;
  Note("another window took the monitor");
  ReleaseHeld();
  GoHome();
  CancelTimer(watch_timer_);
  watch_timer_ = 0;
  ++generation_;
  mode_ = Mode::kAside;
  UpdateAudio();
}

void Session::OnStageLost() {
  if (mode_ == Mode::kStopped || stage_ == nullptr) return;
  if (stage_->ready()) {
    // Still there, only moved in the layout: the window follows.
    if (mode_ == Mode::kStaged) PlaceWindow();
    return;
  }
  // Gone: Mutter put the window somewhere; capture it where it is now.
  stage_->Leave(this);
  stage_ = nullptr;
  ShellHelper::Get().Unstage(window_);
  InPlace("the virtual monitor went away");
}

void Session::GoHome() {
  if (stage_ == nullptr) {
    ShellHelper::Get().Unstage(window_);
    return;
  }
  stage_->Hold();
  int64_t key = stage_->key();
  ShellHelper::Get().Unstage(window_, [key](bool, const std::string&) {
    if (Stage* stage = Stage::Find(key)) stage->Release();
  });
}

void Session::Park() {
  park_timer_ = 0;
  if (!paused_ || mode_ != Mode::kStaged || stage_ == nullptr) return;
  Note("paused a minute: window back home");
  ReleaseHeld();
  GoHome();
  CancelTimer(watch_timer_);
  watch_timer_ = 0;
  ++generation_;
  // The monitor goes too (and with it the screencast indicator), unless
  // another window of this viewer is live on it.
  stage_->Leave(this);
  stage_ = nullptr;
  mode_ = Mode::kParked;
  UpdateAudio();
}

void Session::Watch() {
  CancelTimer(watch_timer_);
  watch_timer_ = PostAfter(1000, [this] {
    watch_timer_ = 0;
    Check();
    if (mode_ == Mode::kStaged || mode_ == Mode::kInPlace) Watch();
  });
}

void Session::Check() {
  if (mode_ != Mode::kStaged && mode_ != Mode::kInPlace) return;
  int generation = generation_;
  std::weak_ptr<int> alive = life_;
  ShellHelper::Get().ListWindows([this, alive, generation](bool ok, std::vector<HelperWindow> windows, bool locked) {
    // Locked, the helper lists no windows: nothing is gone, nothing to check.
    if (alive.expired() || !ok || locked || generation != generation_) return;
    auto found = std::find_if(windows.begin(), windows.end(), [this](const HelperWindow& w) { return w.id == window_; });
    if (found == windows.end()) {
      OnWindowGone();
      return;
    }
    info_ = *found;
    if (mode_ != Mode::kStaged || stage_ == nullptr || stage_->owner() != this) return;
    Rect area = stage_->rect();
    double cx = info_.frame.x + info_.frame.width / 2.0;
    double cy = info_.frame.y + info_.frame.height / 2.0;
    if (!area.Contains(cx, cy) || info_.minimized || info_.maximized || info_.fullscreen) {
      Note("window left its monitor: putting it back");
      PlaceWindow();
      return;
    }
    // Another app's window that landed here would be seen by nobody.
    ShellHelper::Get().EvictStrangers(area, window_);
  });
}

void Session::SetViewport(double width, double height, double scale) {
  bool changed = width != viewport_width_ || height != viewport_height_ || (scale > 0 ? scale : 1) != text_scale_;
  viewport_width_ = width;
  viewport_height_ = height;
  text_scale_ = scale > 0 ? scale : 1;
  if (!changed || width <= 0 || height <= 0) return;
  if (mode_ == Mode::kInPlace && !paused_) {
    // Known at last: the window can go to its own monitor.
    StageWindow();
    return;
  }
  if (mode_ != Mode::kStaged || stage_ == nullptr || stage_->owner() != this) return;
  StageGeometry wanted = GeometryFor(width, height, text_scale_, max_edge_);
  if (wanted == stage_->geometry()) return;
  gchar* text = g_strdup_printf("viewer screen now %.0fx%.0f: monitor %dx%d", width, height, wanted.pixel_width,
                                wanted.pixel_height);
  Note(text);
  g_free(text);
  mode_ = Mode::kStaging;
  int generation = ++generation_;
  std::weak_ptr<int> alive = life_;
  stage_->Ensure(wanted, [this, alive, generation](bool ok) {
    if (alive.expired() || generation != generation_ || mode_ != Mode::kStaging) return;
    if (!ok || stage_ == nullptr || stage_->owner() != this) {
      InPlace("no virtual monitor after a resize");
      return;
    }
    PlaceWindow();
  });
}

void Session::SetInset(double bottom) {
  double inset = std::clamp(bottom, 0.0, kMaxInset);
  if (std::fabs(inset - inset_) < 0.01) return;
  inset_ = inset;
  if (OnStage()) PlaceWindow();
}

void Session::RequestKeyframe() { encoder_->RequestKeyframe(); }

void Session::SetAudio(int mode) {
  audio_mode_ = std::clamp(mode, 0, 2);
  UpdateAudio();
}

void Session::UpdateAudio() {
  bool streamed = mode_ == Mode::kStaged || mode_ == Mode::kStaging || mode_ == Mode::kInPlace;
  int wanted = streamed ? audio_mode_ : 0;
  if (wanted == audio_applied_) return;
  audio_applied_ = wanted;
  int pid = info_.pid > 0 ? info_.pid : pid_;
  capture::SetAudio(id_, pid, wanted);
}

void Session::SetBusy(bool busy) { encoder_->SetBusy(busy); }

void Session::SetBitRate(int bit_rate) { encoder_->SetBitRate(bit_rate); }

void Session::SetPaused(bool paused) {
  paused_ = paused;
  encoder_->SetPaused(paused);
  CancelTimer(park_timer_);
  park_timer_ = 0;
  if (paused) {
    // Switching apps on the phone pauses for a moment; only a longer
    // pause sends the window home.
    if (OnStage()) park_timer_ = PostAfter(ParkDelayMs(), [this] { Park(); });
    return;
  }
  if (mode_ == Mode::kParked || mode_ == Mode::kAside) {
    Note("viewer is back");
    StageWindow();
  }
}

void Session::Stop() {
  if (mode_ == Mode::kStopped) return;
  bool staged = stage_ != nullptr && stage_->owner() == this &&
                (mode_ == Mode::kStaged || mode_ == Mode::kStaging);
  mode_ = Mode::kStopped;
  ++generation_;
  bool warp_pending = warp_timer_ != 0;
  CancelTimer(watch_timer_);
  CancelTimer(park_timer_);
  CancelTimer(warp_timer_);
  watch_timer_ = park_timer_ = warp_timer_ = 0;
  ReleaseHeld();
  UpdateAudio();  // off now that the session is stopped: routes back
  // The pointer was still out on the monitor for the viewer: back first.
  if (warp_pending) ShellHelper::Get().WarpHome();
  if (staged) GoHome();
  if (stage_ != nullptr) {
    stage_->Leave(this);
    stage_ = nullptr;
  }
  cast_.reset();
  if (place_sink_ != nullptr) {
    std::lock_guard<std::mutex> lock(place_sink_->mutex);
    place_sink_->encoder.reset();
  }
  encoder_->Stop();
}

void Session::OnWindowGone() {
  if (mode_ == Mode::kStopped) return;
  Note("window closed");
  ReleaseHeld();
  EmitCapture(id_, WSN_CAPTURE_STOPPED, nullptr, 0, 0, WSN_CAPTURE_ERROR_NOT_FOUND);
  CancelTimer(watch_timer_);
  watch_timer_ = 0;
}

void Session::OnTextFocus(bool focused) {
  if (focused == text_focus_ || mode_ == Mode::kStopped) return;
  text_focus_ = focused;
  EmitCapture(id_, WSN_CAPTURE_TEXT_FOCUS, nullptr, 0, 0, focused ? 1 : 0);
}

void Session::OnHelperVanished() {
  if (mode_ == Mode::kStopped) return;
  // It put the window back on its way out; nothing here can move it now.
  Note("GNOME Shell helper went away");
  EmitCapture(id_, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_HELPER);
}

// ---------------------------------------------------------------- input

Rect Session::InputRect() const {
  if (stage_ != nullptr && stage_->owner() == this && mode_ == Mode::kStaged) return stage_->rect();
  return info_.frame;
}

void Session::ScheduleWarp(guint delay_ms) {
  CancelTimer(warp_timer_);
  warp_timer_ = PostAfter(delay_ms, [this] {
    warp_timer_ = 0;
    if (!button_down_) ShellHelper::Get().WarpHome();
  });
}

void Session::SyncModifiers(int32_t modifiers) {
  ShellHelper& helper = ShellHelper::Get();
  struct Group {
    bool wanted;
    uint32_t left;
    uint32_t right;
  };
  const Group groups[] = {
      {(modifiers & (WSN_MOD_COMMAND | WSN_MOD_CONTROL)) != 0, kKeyLeftCtrl, kKeyRightCtrl},
      {(modifiers & WSN_MOD_SHIFT) != 0, kKeyLeftShift, kKeyRightShift},
      {(modifiers & WSN_MOD_OPTION) != 0, kKeyLeftAlt, kKeyRightAlt},
  };
  // Only the presses made here are let go here; a modifier the viewer
  // pressed as a key stays down until the viewer releases it.
  for (const Group& group : groups) {
    bool pressed = explicit_modifiers_.count(group.left) != 0 || explicit_modifiers_.count(group.right) != 0;
    bool held = held_modifiers_.count(group.left) != 0 || held_modifiers_.count(group.right) != 0;
    if (group.wanted && !pressed && !held) {
      helper.Key(group.left, true);
      held_modifiers_.insert(group.left);
    } else if (!group.wanted && held) {
      for (uint32_t key : {group.left, group.right}) {
        if (held_modifiers_.erase(key) != 0) helper.Key(key, false);
      }
    }
  }
}

void Session::ReleaseHeld() {
  ShellHelper& helper = ShellHelper::Get();
  for (uint32_t key : keys_down_) helper.Key(key, false);
  keys_down_.clear();
  for (uint32_t key : explicit_modifiers_) helper.Key(key, false);
  for (uint32_t key : held_modifiers_) helper.Key(key, false);
  explicit_modifiers_.clear();
  held_modifiers_.clear();
  if (button_down_) {
    helper.Pointer(WSN_INPUT_POINTER_UP, button_held_, pointer_x_, pointer_y_);
    button_down_ = false;
  }
}

void Session::Input(int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx, double dy,
                    int32_t phase, const std::string& text) {
  bool live = mode_ == Mode::kStaged || mode_ == Mode::kInPlace;
  // Releases always go through (a resize or a turn may be under way): a
  // key or button the viewer let go of must never stay down here.
  bool release = kind == WSN_INPUT_KEY_UP || kind == WSN_INPUT_POINTER_UP || kind == WSN_INPUT_POINTER_CANCEL;
  if (!live && !release) return;
  ShellHelper& helper = ShellHelper::Get();
  Rect rect = live ? InputRect() : last_rect_;
  if (live && !rect.empty()) last_rect_ = rect;
  if (rect.empty()) {
    if (release) ReleaseHeld();
    return;
  }
  auto px = [&](double fx) { return rect.x + std::clamp(fx, 0.0, 1.0) * (rect.width - 0.5); };
  auto py = [&](double fy) { return rect.y + std::clamp(fy, 0.0, 1.0) * (rect.height - 0.5); };
  switch (kind) {
    case WSN_INPUT_POINTER_DOWN:
    case WSN_INPUT_POINTER_MOVE:
    case WSN_INPUT_POINTER_UP:
    case WSN_INPUT_POINTER_CANCEL: {
      // An up for a press already let go of (stop, turn) would only drag
      // the pointer back onto the monitor.
      if ((kind == WSN_INPUT_POINTER_UP || kind == WSN_INPUT_POINTER_CANCEL) && !button_down_) break;
      CancelTimer(warp_timer_);
      warp_timer_ = 0;
      uint32_t button = code == 1 ? 1 : code == 2 ? 2 : 0;
      if (kind == WSN_INPUT_POINTER_DOWN) {
        helper.Activate(window_);
        SyncModifiers(modifiers);
        button_down_ = true;
        button_held_ = button;
      }
      pointer_x_ = px(x);
      pointer_y_ = py(y);
      helper.Pointer(static_cast<uint32_t>(kind), button, pointer_x_, pointer_y_);
      if (kind == WSN_INPUT_POINTER_UP || kind == WSN_INPUT_POINTER_CANCEL) {
        button_down_ = false;
        SyncModifiers(0);
        ScheduleWarp(kTapWarpMs);
      } else if (kind == WSN_INPUT_POINTER_MOVE && !button_down_) {
        ScheduleWarp(kHoverWarpMs);
      }
      break;
    }
    case WSN_INPUT_SCROLL: {
      CancelTimer(warp_timer_);
      warp_timer_ = 0;
      bool precise = (phase & (1 << 16)) != 0;
      int step = phase & 0xff;
      bool finish = (step & (8 | 16)) != 0;  // NSEventPhase ended / cancelled
      // The shared input model: positive dy scrolls toward the top.
      if (precise) {
        helper.Scroll(px(x), py(y), -dx * rect.width, -dy * rect.height, kScrollFinger, finish);
      } else {
        helper.Scroll(px(x), py(y), -dx, -dy, kScrollWheel, false);
      }
      ScheduleWarp(kHoverWarpMs);
      break;
    }
    case WSN_INPUT_KEY_DOWN:
    case WSN_INPUT_KEY_UP: {
      bool down = kind == WSN_INPUT_KEY_DOWN;
      uint32_t modifier = ModifierKey(code);
      if (modifier != 0) {
        if (down) {
          helper.Activate(window_);
          // Already down for a shortcut: it is the viewer's now.
          if (held_modifiers_.erase(modifier) == 0 && explicit_modifiers_.count(modifier) == 0) {
            helper.Key(modifier, true);
          }
          explicit_modifiers_.insert(modifier);
        } else if (explicit_modifiers_.erase(modifier) != 0) {
          helper.Key(modifier, false);
        }
        break;
      }
      int32_t evdev = wsn_keymap_mac_to_evdev(code);
      if (evdev <= 0) break;
      if (down) {
        helper.Activate(window_);
        SyncModifiers(modifiers);
        keys_down_.insert(static_cast<uint32_t>(evdev));
        helper.Key(static_cast<uint32_t>(evdev), true);
      } else {
        if (keys_down_.erase(static_cast<uint32_t>(evdev)) != 0) helper.Key(static_cast<uint32_t>(evdev), false);
        // A shortcut's modifiers do not outlive it (a phone never sends
        // their release).
        SyncModifiers(0);
      }
      break;
    }
    case WSN_INPUT_TEXT: {
      if (text.empty()) break;
      helper.Activate(window_);
      SyncModifiers(0);
      helper.Text(text);
      break;
    }
    default:
      break;
  }
}

}  // namespace wsn::capture
