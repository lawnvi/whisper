// CPU fallback presentation (no usable D3D11 video path): decoded frames
// are converted to BGRA at the size they are shown at and painted with GDI.

#pragma once

#include "frame.h"
#include "readiness.h"

#include <atomic>
#include <condition_variable>
#include <functional>
#include <thread>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace wsn {

class GdiPresenter {
 public:
  // `on_ready` runs on the conversion thread when a new picture can be
  // painted.
  explicit GdiPresenter(std::function<void()> on_ready);
  ~GdiPresenter();

  // UI thread: the size of the video rect, which frames are converted to.
  void SetTargetSize(int width, int height);
  // Decode thread: hands a memory frame over for conversion (on a thread
  // of its own, so decoding goes on meanwhile; the newest frame wins).
  void Submit(const DecodedFrame& frame);
  // As D3DPresenter::SetReadiness; `on_stable` runs inside Paint.
  void SetReadiness(std::shared_ptr<Readiness> readiness, std::function<void()> on_stable);
  void SetPoster(std::shared_ptr<const Poster> poster);
  void SetIcon(std::shared_ptr<const Poster> icon);
  // UI thread, inside WM_PAINT. True while something animates (paint
  // again at the next tick).
  bool Paint(HWND hwnd, const OverlayState& overlay, double scale);
  int32_t Snapshot(const std::wstring& path, int max_edge);
  bool CaptureFrame(int max_edge, Poster* out);
  int64_t painted() const { return painted_; }

 private:
  struct Picture {
    std::vector<uint8_t> bgra;
    int width = 0;
    int height = 0;
  };
  void EnsureFonts(double scale);
  void ConvertLoop();

  std::function<void()> on_ready_;
  std::thread converter_;
  std::condition_variable convert_cv_;
  bool stopping_ = false;          // mutex_
  bool have_pending_ = false;      // mutex_
  DecodedFrame pending_;           // mutex_

  std::mutex mutex_;  // picture_, source_
  std::shared_ptr<const Picture> picture_;
  DecodedFrame source_;  // the last frame, for snapshots at full size
  bool fresh_ = false;
  std::atomic<int> target_width_{0};
  std::atomic<int> target_height_{0};
  std::atomic<int64_t> painted_{0};
  int64_t converted_ = 0;  // decode thread
  void DrawCover(HDC memory, const RECT& client, double scale, const Readiness::View& view,
                 const OverlayState& overlay);

  std::shared_ptr<Readiness> readiness_;
  std::function<void()> on_stable_;
  std::shared_ptr<const Poster> poster_;  // UI thread
  std::shared_ptr<const Poster> icon_;    // UI thread
  double spinner_epoch_ = -1;             // UI thread
  COLORREF spinner_color_ = 0;
  HFONT message_font_ = nullptr;
  HFONT hud_font_ = nullptr;
  double font_scale_ = 0;
};

}  // namespace wsn
