#include "capture/kwin_screencast.h"

#include <glib.h>

#include <algorithm>
#include <climits>
#include <cmath>
#include <set>

#include "capture/capture_thread.h"
#include "capture/kwin_wayland.h"
#include "common/log.h"

namespace wsn::capture {

namespace {

constexpr const char* kPrefix = "Whisper-";
constexpr const char* kOutputPrefix = "Virtual-Whisper-";
constexpr const char* kDescription = "Whisper window flow";
// From the request to a usable source.
constexpr guint kCreateTimeoutMs = 8000;
// Between the real outputs and ours, and between ours: nothing the pointer
// can cross.
constexpr int kGap = 256;
// Wider than any of ours (session.cc keeps monitors at most 4096 wide).
constexpr int kSlotWidth = 4096 + kGap;

class KWinScreenCast;

std::set<int>& Slots() {
  static auto* slots = new std::set<int>();
  return *slots;
}

std::set<KWinScreenCast*>& Casts() {
  static auto* casts = new std::set<KWinScreenCast*>();
  return *casts;
}

void OnOutputsChanged();

class KWinScreenCast : public ScreenCast {
 public:
  KWinScreenCast(bool virtual_output, int pixel_width, int pixel_height, double scale, int fps,
                 PipeWireStream::FrameCallback on_frame, Callbacks callbacks)
      : ScreenCast(pixel_width, pixel_height),
        virtual_(virtual_output),
        wanted_scale_(scale > 0 ? scale : 1),
        fps_(fps),
        on_frame_(std::move(on_frame)),
        callbacks_(std::move(callbacks)) {
    static bool watching = false;
    if (!watching) {
      watching = true;
      kwin::SetOutputsChanged(OnOutputsChanged);
    }
    Casts().insert(this);
  }

  ~KWinScreenCast() override {
    Casts().erase(this);
    alive_.reset();
    stream_.reset();  // no frames after this
    CancelTimer(deadline_timer_);
    if (handle_ != 0) kwin::CloseStream(handle_);
    if (slot_ != 0) Slots().erase(slot_);
  }

  void BeginVirtual() {
    Arm();
    std::string why;
    if (!kwin::Connect(&why)) {
      Fail(why);
      return;
    }
    for (slot_ = 1; Slots().count(slot_) != 0; slot_++) {
    }
    Slots().insert(slot_);
    connector_ = std::string(kOutputPrefix) + std::to_string(slot_);
    handle_ = kwin::StreamVirtualOutput(kPrefix + std::to_string(slot_), kDescription, pixel_width_, pixel_height_,
                                        wanted_scale_, MakeCallbacks());
    if (handle_ == 0) Fail("no KWin screencast");
  }

  void BeginWindow(const std::string& uuid) {
    Arm();
    std::string why;
    if (uuid.empty() || !kwin::Connect(&why)) {
      Fail(uuid.empty() ? "no window id" : why);
      return;
    }
    handle_ = kwin::StreamWindow(uuid, MakeCallbacks());
    if (handle_ == 0) Fail("no KWin screencast");
  }

  void Resize(int pixel_width, int pixel_height, double scale) override {
    if (!virtual_ || !ready_) return;
    pixel_width_ = pixel_width;
    pixel_height_ = pixel_height;
    wanted_scale_ = scale > 0 ? scale : 1;
    resizing_ = true;
    // Without custom modes nothing happens here, and the stage makes a new
    // output of the new size once it sees no change.
    if (!kwin::CanResize()) return;
    Configure();
  }

  // The output layout changed: ours appeared, was configured, moved, or
  // went away.
  void OnOutputs() {
    if (!virtual_ || failed_ || connector_.empty()) return;
    std::vector<kwin::OutputInfo> outputs = kwin::Outputs();
    auto ours = std::find_if(outputs.begin(), outputs.end(),
                             [this](const kwin::OutputInfo& o) { return o.name == connector_; });
    if (ours == outputs.end()) {
      if (seen_) Fail("virtual output removed");
      return;
    }
    seen_ = true;
    Rect target = Target(outputs);
    bool placed = ours->rect.x == target.x && ours->rect.y == target.y && std::fabs(ours->scale - wanted_scale_) < 0.01;
    bool sized = ours->pixel_width == pixel_width_ && ours->pixel_height == pixel_height_;
    if (!placed && !configuring_ && placements_ < 4) {
      Configure();
      return;
    }
    if (configuring_) return;
    if (!ready_) {
      if (!placed) WSN_LOG("capture: %s stays at %d,%d scale %.2f", connector_.c_str(), ours->rect.x, ours->rect.y,
                           ours->scale);
      ready_ = true;
      rect_ = ours->rect;
      scale_ = ours->scale;
      CancelTimer(deadline_timer_);
      deadline_timer_ = 0;
      WSN_TRACE("capture: %s ready: %dx%d px at %d,%d scale %.2f", connector_.c_str(), ours->pixel_width,
                ours->pixel_height, rect_.x, rect_.y, scale_);
      if (callbacks_.ready) callbacks_.ready(rect_, scale_);
      return;
    }
    if (placed) placements_ = 0;
    // A resize counts once the new mode is there.
    if (resizing_ && !sized) return;
    resizing_ = false;
    if (ours->rect != rect_ || std::fabs(ours->scale - scale_) > 0.001) {
      rect_ = ours->rect;
      scale_ = ours->scale;
      if (callbacks_.moved) callbacks_.moved(rect_, scale_);
    }
  }

  std::weak_ptr<bool> Alive() const { return alive_; }

 private:
  kwin::StreamCallbacks MakeCallbacks() {
    std::weak_ptr<bool> alive = alive_;
    kwin::StreamCallbacks callbacks;
    callbacks.node = [this, alive](uint32_t node) {
      if (!alive.expired()) OnNode(node);
    };
    callbacks.lost = [this, alive](const std::string& why) {
      if (!alive.expired()) Fail(why);
    };
    return callbacks;
  }

  void Arm() {
    std::weak_ptr<bool> alive = alive_;
    deadline_timer_ = PostAfter(kCreateTimeoutMs, [this, alive] {
      if (alive.expired()) return;
      deadline_timer_ = 0;
      if (!ready_) Fail("timed out");
    });
  }

  // Below the outputs that are not ours, in our slot's column.
  Rect Target(const std::vector<kwin::OutputInfo>& outputs) const {
    int left = INT_MAX;
    int bottom = 0;
    for (const kwin::OutputInfo& o : outputs) {
      if (IsKWinVirtualOutput(o.name) || !o.enabled) continue;
      left = std::min(left, o.rect.x);
      bottom = std::max(bottom, o.rect.y + o.rect.height);
    }
    if (left == INT_MAX) left = 0;
    return Rect{left + (slot_ - 1) * kSlotWidth, bottom + kGap, 0, 0};
  }

  void Configure() {
    Rect target = Target(kwin::Outputs());
    configuring_ = true;
    placements_++;
    std::weak_ptr<bool> alive = alive_;
    kwin::ConfigureOutput(connector_, target.x, target.y, wanted_scale_, pixel_width_, pixel_height_,
                          [this, alive](bool ok) {
                            if (alive.expired()) return;
                            configuring_ = false;
                            if (!ok) WSN_LOG("capture: KWin did not take the layout for %s", connector_.c_str());
                            OnOutputs();
                          });
  }

  void OnNode(uint32_t node) {
    WSN_TRACE("capture: KWin PipeWire node %u", node);
    std::weak_ptr<bool> alive = alive_;
    // Any size: KWin's own (a window's, or the output's after a resize).
    stream_ = PipeWireStream::Connect(
        node, 0, 0, fps_, on_frame_, [alive, this](bool failed, const char* error, int width, int height) {
          std::string why = error != nullptr ? error : "";
          Post([alive, this, failed, why, width, height] {
            if (alive.expired()) return;
            if (failed) {
              Fail("PipeWire: " + why);
            } else {
              OnNegotiated(width, height);
            }
          });
        });
    if (stream_ == nullptr) Fail("PipeWire unavailable");
  }

  void OnNegotiated(int width, int height) {
    WSN_TRACE("capture: KWin stream negotiated %dx%d", width, height);
    if (virtual_ || ready_) return;
    pixel_width_ = width;
    pixel_height_ = height;
    ready_ = true;
    CancelTimer(deadline_timer_);
    deadline_timer_ = 0;
    if (callbacks_.ready) callbacks_.ready(Rect{0, 0, width, height}, 1);
  }

  void Fail(const std::string& why) {
    if (failed_) return;
    failed_ = true;
    WSN_LOG("capture: KWin screencast %s", why.c_str());
    CancelTimer(deadline_timer_);
    deadline_timer_ = 0;
    // The owner may delete this object from the callback.
    auto lost = callbacks_.lost;
    if (lost) lost(why);
  }

  const bool virtual_;
  double wanted_scale_;
  const int fps_;
  PipeWireStream::FrameCallback on_frame_;
  Callbacks callbacks_;
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  std::unique_ptr<PipeWireStream> stream_;
  uint32_t handle_ = 0;
  int slot_ = 0;
  guint deadline_timer_ = 0;
  bool failed_ = false;
  bool seen_ = false;
  bool configuring_ = false;
  bool resizing_ = false;
  int placements_ = 0;  // configurations in a row (no fight with KWin)
};

void OnOutputsChanged() {
  std::vector<KWinScreenCast*> casts(Casts().begin(), Casts().end());
  for (KWinScreenCast* cast : casts) {
    // A callback may have deleted the next one.
    if (Casts().count(cast) != 0) cast->OnOutputs();
  }
}

}  // namespace

bool IsKWinVirtualOutput(const std::string& name) { return name.rfind(kOutputPrefix, 0) == 0; }

std::unique_ptr<ScreenCast> KWinVirtualCast(int pixel_width, int pixel_height, double scale, int fps,
                                            PipeWireStream::FrameCallback on_frame, ScreenCast::Callbacks callbacks) {
  auto cast = std::make_unique<KWinScreenCast>(true, pixel_width, pixel_height, scale, fps, std::move(on_frame),
                                               std::move(callbacks));
  KWinScreenCast* self = cast.get();
  std::weak_ptr<bool> alive = self->Alive();
  // Started from the loop, never inside the caller's own frame: callbacks
  // may then safely replace the object that is being made.
  Post([self, alive] {
    if (!alive.expired()) self->BeginVirtual();
  });
  return cast;
}

std::unique_ptr<ScreenCast> KWinWindowCast(const std::string& uuid, int fps, PipeWireStream::FrameCallback on_frame,
                                           ScreenCast::Callbacks callbacks) {
  auto cast = std::make_unique<KWinScreenCast>(false, 0, 0, 1, fps, std::move(on_frame), std::move(callbacks));
  KWinScreenCast* self = cast.get();
  std::weak_ptr<bool> alive = self->Alive();
  Post([self, alive, uuid] {
    if (!alive.expired()) self->BeginWindow(uuid);
  });
  return cast;
}

}  // namespace wsn::capture
