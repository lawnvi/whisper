#ifndef WHISPER_SCREENSHOT_SELECTION_H_
#define WHISPER_SCREENSHOT_SELECTION_H_

#include <algorithm>
#include <cmath>

namespace whisper {
struct CapturePoint { double x = 0, y = 0; };
struct CaptureRect {
  double left = 0, top = 0, right = 0, bottom = 0;
  double width() const { return right - left; }
  double height() const { return bottom - top; }
  bool contains(CapturePoint p) const {
    return p.x >= left && p.x <= right && p.y >= top && p.y <= bottom;
  }
};

// Pure selection geometry shared by the Win32 and X11 overlays. Mouse-up only
// settles the selection; the caller must explicitly confirm before copying.
class ScreenshotSelection {
 public:
  enum Hit { kOutside = 0, kLeft = 1, kRight = 2, kTop = 4, kBottom = 8,
             kMove = 16, kCreate = 32 };
  void Reset(double width, double height) {
    width_ = width; height_ = height;
    rect_ = {}; original_ = {}; anchor_ = {};
    selected_ = false; operation_ = kOutside;
  }
  CaptureRect rect() const { return rect_; }
  bool selected() const { return selected_; }
  bool dragging() const { return operation_ != kOutside; }
  int HitTest(CapturePoint p, double tolerance = 9) const {
    if (!selected_) return kOutside;
    if (p.x < rect_.left - tolerance || p.x > rect_.right + tolerance ||
        p.y < rect_.top - tolerance || p.y > rect_.bottom + tolerance) return kOutside;
    int hit = kOutside;
    if (std::abs(p.x - rect_.left) <= tolerance) hit |= kLeft;
    else if (std::abs(p.x - rect_.right) <= tolerance) hit |= kRight;
    if (std::abs(p.y - rect_.top) <= tolerance) hit |= kTop;
    else if (std::abs(p.y - rect_.bottom) <= tolerance) hit |= kBottom;
    return hit ? hit : rect_.contains(p) ? kMove : kOutside;
  }
  void Begin(CapturePoint p, double tolerance = 9) {
    anchor_ = Clamp(p);
    original_ = rect_;
    operation_ = HitTest(p, tolerance);
    if (operation_ == kOutside) {
      operation_ = kCreate; selected_ = false;
      rect_ = {anchor_.x, anchor_.y, anchor_.x, anchor_.y};
    }
  }
  void Update(CapturePoint p) {
    if (!dragging()) return;
    p = Clamp(p);
    if (operation_ == kCreate) {
      rect_ = {std::min(anchor_.x, p.x), std::min(anchor_.y, p.y),
               std::max(anchor_.x, p.x), std::max(anchor_.y, p.y)};
    } else if (operation_ == kMove) {
      const double dx = std::max(-original_.left,
          std::min(p.x - anchor_.x, width_ - original_.right));
      const double dy = std::max(-original_.top,
          std::min(p.y - anchor_.y, height_ - original_.bottom));
      rect_ = {original_.left + dx, original_.top + dy,
               original_.right + dx, original_.bottom + dy};
    } else {
      double left = original_.left, right = original_.right;
      double top = original_.top, bottom = original_.bottom;
      if (operation_ & kLeft) left = p.x;
      if (operation_ & kRight) right = p.x;
      if (operation_ & kTop) top = p.y;
      if (operation_ & kBottom) bottom = p.y;
      rect_ = {std::min(left, right), std::min(top, bottom),
               std::max(left, right), std::max(top, bottom)};
    }
  }
  void End(CapturePoint p) {
    if (!dragging()) return;
    Update(p);
    operation_ = kOutside;
    selected_ = rect_.width() >= 2 && rect_.height() >= 2;
    if (!selected_) rect_ = {};
  }

 private:
  CapturePoint Clamp(CapturePoint p) const {
    return {std::max(0.0, std::min(p.x, width_)),
            std::max(0.0, std::min(p.y, height_))};
  }
  double width_ = 0, height_ = 0;
  CaptureRect rect_, original_;
  CapturePoint anchor_;
  int operation_ = kOutside;
  bool selected_ = false;
};
}  // namespace whisper
#endif  // WHISPER_SCREENSHOT_SELECTION_H_
