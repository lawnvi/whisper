// Windows.Graphics.Capture of one window: frames arrive on a thread-pool
// thread (free-threaded frame pool) as BGRA textures on the shared device.
#pragma once

#include "wsn_d3d.h"

#include <atomic>
#include <functional>
#include <mutex>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>

namespace wsn {

struct WgcSupport {
  bool supported = false;            // GraphicsCaptureSession::IsSupported
  bool borderless_allowed = false;   // RequestAccessAsync(Borderless) said Allowed
  bool border_property = false;      // IsBorderRequired exists
  bool secondary_property = false;   // IncludeSecondaryWindows exists
  bool min_interval_property = false;
  bool cursor_property = false;
  int access_status = -1;            // AppCapabilityAccessStatus, -1 unknown
};

// Cached; the first call may block for a moment (asks for borderless
// access). Must not be called from a single-threaded apartment's UI thread.
const WgcSupport& QueryWgcSupport();

class WgcCapture {
 public:
  struct Options {
    bool cursor = false;
    bool border = false;              // ask for no yellow border (when allowed)
    bool secondary = true;            // include the window's menus and dialogs
    int min_interval_ms = 0;          // 0: every frame
  };
  // [texture] is only valid during the call. [content] is the window's
  // current size in pixels (the texture may be larger).
  using FrameFn = std::function<void(ID3D11Texture2D* texture, SIZE content, int64_t time_us)>;
  using ClosedFn = std::function<void()>;

  WgcCapture() = default;
  ~WgcCapture();
  WgcCapture(const WgcCapture&) = delete;
  WgcCapture& operator=(const WgcCapture&) = delete;

  // False with [error] set (HRESULT text) when the window cannot be captured.
  bool Start(HWND window, const Options& options, FrameFn on_frame, ClosedFn on_closed, std::string* error);
  void Stop();
  bool running() const { return running_.load(); }
  SIZE item_size() const;
  void SetMinInterval(int ms);

 private:
  void OnFrame();

  D3D* d3d_ = nullptr;
  std::mutex mutex_;
  winrt::Windows::Graphics::Capture::GraphicsCaptureItem item_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool pool_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession session_{nullptr};
  winrt::event_token frame_token_{};
  winrt::event_token closed_token_{};
  winrt::Windows::Graphics::SizeInt32 pool_size_{};
  FrameFn on_frame_;
  ClosedFn on_closed_;
  std::atomic<bool> running_{false};
  // Frame callbacks in progress; Stop waits for them.
  std::atomic<int> in_callback_{0};
};

}  // namespace wsn
