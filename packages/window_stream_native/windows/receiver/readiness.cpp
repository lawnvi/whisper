#include "readiness.h"

#include <algorithm>

namespace wsn {
namespace {

constexpr double kSettleSeconds = 0.3;
constexpr int kSettleFrames = 1;  // a static window may send just one
constexpr double kStableCapSeconds = 2.5;
constexpr double kCrossfadeSeconds = 0.18;
constexpr double kResumeGraceSeconds = 0.3;
constexpr double kHintSeconds = 8.0;

double EaseOut(double t) {
  t = std::clamp(t, 0.0, 1.0);
  const double inverse = 1 - t;
  return 1 - inverse * inverse * inverse;
}

bool IsInterruption(int32_t visual) {
  return visual == WSN_VISUAL_PAUSED || visual == WSN_VISUAL_RECONNECTING || visual == WSN_VISUAL_DISPLACED ||
         visual == WSN_VISUAL_SECURE;
}

}  // namespace

bool ReduceMotion() {
  BOOL enabled = TRUE;
  if (!SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0)) return false;
  return enabled == FALSE;
}

Readiness::Readiness(double opened_at) : opened_at_(opened_at), connecting_since_(opened_at) {}

void Readiness::OnFrame(int width, int height, double now) {
  std::lock_guard<std::mutex> lock(mutex_);
  frames_++;
  if (first_frame_at_ < 0) {
    first_frame_at_ = now;
    width_ = width;
    height_ = height;
    last_change_at_ = now;
    frames_since_change_ = 1;
  } else if (width != width_ || height != height_) {
    width_ = width;
    height_ = height;
    last_change_at_ = now;
    frames_since_change_ = 1;
  } else {
    frames_since_change_++;
  }
  if (resumed_at_ >= 0) {
    // A new frame after resuming: no spinner, or fade it away.
    resumed_at_ = -1;
    if (resume_cover_) {
      resume_cover_ = false;
      resume_fade_at_ = now;
    }
  }
}

void Readiness::OnVisual(int32_t visual, double now) {
  std::lock_guard<std::mutex> lock(mutex_);
  const int32_t previous = visual_;
  visual_ = visual;
  if (visual == WSN_VISUAL_CONNECTING && previous != WSN_VISUAL_CONNECTING) connecting_since_ = now;
  if (visual == WSN_VISUAL_LIVE && live_at_ >= 0 && IsInterruption(previous)) {
    resumed_at_ = now;
    frames_at_resume_ = frames_;
    resume_cover_ = false;
    resume_fade_at_ = -1;
  } else if (visual != WSN_VISUAL_LIVE) {
    resumed_at_ = -1;
    resume_cover_ = false;
    resume_fade_at_ = -1;
  }
}

bool Readiness::CheckStableLocked(double now) {
  if (stable_) return true;
  if (first_frame_at_ < 0) return false;
  if (now - first_frame_at_ >= kStableCapSeconds ||
      (now - last_change_at_ >= kSettleSeconds && frames_since_change_ >= kSettleFrames)) {
    stable_ = true;
    stable_at_ = now;
  }
  return stable_;
}

Readiness::View Readiness::Evaluate(double now) {
  std::lock_guard<std::mutex> lock(mutex_);
  View view;
  CheckStableLocked(now);
  if (stable_ && visual_ == WSN_VISUAL_LIVE && live_at_ < 0) {
    live_at_ = now;
    reduce_motion_ = ReduceMotion();
  }
  if (live_at_ >= 0 && !reported_stable_) {
    reported_stable_ = true;
    view.became_stable = true;
  }
  if (live_at_ < 0) {
    view.cover = 1;
    view.show_frames = false;
    view.spinner = true;
    // The connecting words only after 8 s connecting (the spinner alone
    // before), or once nothing has decoded for 8 s.
    view.hint = (visual_ == WSN_VISUAL_CONNECTING && now - connecting_since_ >= kHintSeconds) ||
                (first_frame_at_ < 0 && now - opened_at_ >= kHintSeconds);
    view.animating = true;
    return view;
  }
  const double fade = reduce_motion_ ? 1.0 : (now - live_at_) / kCrossfadeSeconds;
  view.cover = 1 - EaseOut(fade);
  view.spinner = view.cover > 0;
  if (resumed_at_ >= 0 && frames_ <= frames_at_resume_ && now - resumed_at_ >= kResumeGraceSeconds) {
    resume_cover_ = true;
  }
  if (resume_cover_) {
    view.cover = 1;
    view.cover_is_last_frame = true;
    view.spinner = true;
  } else if (resume_fade_at_ >= 0) {
    const double resume = reduce_motion_ ? 1.0 : (now - resume_fade_at_) / kCrossfadeSeconds;
    const double cover = 1 - EaseOut(resume);
    if (cover > 0) {
      view.cover = std::max(view.cover, cover);
      view.cover_is_last_frame = true;
      view.spinner = true;
    } else {
      resume_fade_at_ = -1;
    }
  }
  view.animating = view.cover > 0 || resumed_at_ >= 0;
  return view;
}

bool Readiness::stable() {
  std::lock_guard<std::mutex> lock(mutex_);
  return live_at_ >= 0;
}

double Readiness::settle_seconds() {
  std::lock_guard<std::mutex> lock(mutex_);
  return stable_at_ >= 0 && first_frame_at_ >= 0 ? stable_at_ - first_frame_at_ : -1;
}

}  // namespace wsn
