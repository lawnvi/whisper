// GPU presentation of one streamed window.
//
// Decoded NV12 (decoder texture slices, or uploaded memory frames) goes
// through an ID3D11VideoProcessor straight into a flip-model swap chain
// (waitable, at most one frame queued), letterboxed. The paused /
// reconnecting / … overlays and the HUD are drawn with Direct2D and
// DirectWrite on the same back buffer. A render thread presents the newest
// frame as soon as the swap chain can take one; resizing renders
// synchronously on the UI thread so live resizing stays smooth.

#pragma once

#include "d3d_device.h"
#include "frame.h"
#include "readiness.h"

#include <d2d1_1.h>
#include <d3d11_1.h>
#include <dwrite.h>
#include <dxgi1_3.h>
#include <mfapi.h>
#include <mfidl.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace wsn {

class D3DPresenter {
 public:
  struct Stats {
    int64_t presented = 0;    // new frames shown
    int64_t skipped = 0;      // frames replaced by a newer one before shown
    double latency_ms = 0;    // decoded → presented, smoothed
  };

  D3DPresenter();
  ~D3DPresenter();
  D3DPresenter(const D3DPresenter&) = delete;
  D3DPresenter& operator=(const D3DPresenter&) = delete;

  // UI thread. False: no usable D3D11 video path (the caller falls back to
  // GDI). `on_lost` runs on the render thread when the device goes away
  // (a DXGI device-removed code) or the picture cannot be shown (E_FAIL).
  bool Initialize(HWND hwnd, double scale, std::shared_ptr<D3DDevice> shared,
                  std::function<void(HRESULT)> on_lost);
  // UI thread: stops the render thread and releases everything.
  void Shutdown();

  const std::shared_ptr<D3DDevice>& shared_device() const { return shared_; }

  // Until the picture is stable a placeholder with a spinner is drawn
  // instead of frames (see readiness.h); `on_stable` runs on the render
  // thread when it becomes stable. Call before Initialize.
  void SetReadiness(std::shared_ptr<Readiness> readiness, std::function<void()> on_stable);
  // The picture shown under the spinner: the window's last picture if
  // known, else the app's icon over the dark background.
  void SetPoster(std::shared_ptr<const Poster> poster);
  void SetIcon(std::shared_ptr<const Poster> icon);
  // The last frame as opaque BGRA, longer edge at most `max_edge`.
  bool CaptureFrame(int max_edge, Poster* out);

  // Decode thread: the newest frame replaces any not yet shown.
  void Submit(DecodedFrame frame);
  void SetOverlay(const OverlayState& overlay);
  void SetScale(double scale);
  // UI thread, after the client area changed: resize buffers and render now.
  void Resize();
  // Any thread: render again soon (overlay change, WM_PAINT).
  void Redraw();
  // Any thread. 0 ok, -2 no frame or failure.
  int32_t Snapshot(const std::wstring& path, int max_edge);
  Stats stats();
  bool has_frame();

 private:
  void RenderLoop();
  // Asks the render thread for a frame and waits for it (up to the timeout).
  void RenderAndWait(int timeout_ms);
  // render_mutex_ held.
  void ResizeLocked(const RECT& client);
  HRESULT RenderLocked();
  bool EnsureProcessor(int in_width, int in_height, int out_width, int out_height);
  bool UploadIfNeeded(const DecodedFrame& frame);
  HRESULT BltFrame(const DecodedFrame& frame, ID3D11Texture2D* target, const RECT& dest, const RECT& target_rect);
  bool EnsureScene(UINT width, UINT height);
  void DrawOverlay(ID3D11Texture2D* back_buffer, UINT width, UINT height, bool have_frame,
                   const Readiness::View& view);
  // Inside BeginDraw/EndDraw, in DIPs.
  void DrawCover(float width, float height, const Readiness::View& view, const OverlayState& overlay);
  void DrawSpinner(float cx, float cy, float opacity);
  // A D2D bitmap of `image`, remade when the image changes.
  ID2D1Bitmap1* BitmapOf(const std::shared_ptr<const Poster>& image, ComPtr<ID2D1Bitmap1>& bitmap,
                         const Poster*& made_of);
  // render_mutex_ held: the last frame into a new BGRA texture.
  HRESULT FrameTexture(int max_edge, ComPtr<ID3D11Texture2D>* out, int* width, int* height);
  void EnsureTextFormats();

  HWND hwnd_ = nullptr;
  std::function<void(HRESULT)> on_lost_;

  std::shared_ptr<D3DDevice> shared_;
  ComPtr<ID3D11Device> device_;
  ComPtr<ID3D11DeviceContext> context_;
  ComPtr<ID3D10Multithread> multithread_;
  ComPtr<ID3D11VideoDevice> video_device_;
  ComPtr<ID3D11VideoContext> video_context_;
  ComPtr<IDXGISwapChain2> swap_chain_;
  HANDLE waitable_ = nullptr;

  ComPtr<ID3D11VideoProcessorEnumerator> enumerator_;
  ComPtr<ID3D11VideoProcessor> processor_;
  int processor_in_width_ = 0;
  int processor_in_height_ = 0;
  int processor_out_width_ = 0;
  int processor_out_height_ = 0;

  // Memory frames go through these (software decoding).
  ComPtr<ID3D11Texture2D> upload_;
  ComPtr<ID3D11Texture2D> upload_staging_;
  int upload_width_ = 0;
  int upload_height_ = 0;
  std::shared_ptr<std::vector<uint8_t>> uploaded_;  // held: its address is the key

  // The picture under an overlay, blurred by Direct2D.
  ComPtr<ID3D11Texture2D> scene_;
  UINT scene_width_ = 0;
  UINT scene_height_ = 0;

  ComPtr<ID2D1DeviceContext> d2d_context_;
  ComPtr<IDWriteFactory> dwrite_;
  ComPtr<IDWriteTextFormat> message_format_;
  ComPtr<IDWriteTextFormat> hud_format_;

  std::mutex render_mutex_;   // D3D objects, current_, overlay_ copy used to draw
  std::optional<DecodedFrame> current_;
  bool current_shown_ = true;

  std::shared_ptr<Readiness> readiness_;
  std::function<void()> on_stable_;
  ComPtr<ID2D1Bitmap1> poster_bitmap_;        // render_mutex_
  const Poster* poster_bitmap_of_ = nullptr;  // render_mutex_
  ComPtr<ID2D1Bitmap1> icon_bitmap_;          // render_mutex_
  const Poster* icon_bitmap_of_ = nullptr;    // render_mutex_
  ComPtr<ID2D1StrokeStyle1> spinner_stroke_;   // render_mutex_
  double spinner_epoch_ = -1;                 // render_mutex_
  COLORREF spinner_color_ = 0;

  std::mutex state_mutex_;    // pending_, overlay_, scale_, stats_, poster_
  std::shared_ptr<const Poster> poster_;
  std::shared_ptr<const Poster> icon_;
  std::optional<DecodedFrame> pending_;
  OverlayState overlay_;
  double scale_ = 1;
  Stats stats_;

  std::mutex rendered_mutex_;
  std::condition_variable rendered_cv_;
  int64_t render_requests_ = 0;
  int64_t rendered_ = 0;

  std::thread render_thread_;
  HANDLE wake_ = nullptr;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> lost_{false};
  int64_t slow_presents_ = 0;
  int upload_bind_ = 0;     // which kind of upload texture (render_mutex_)
  int blt_failures_ = 0;    // in a row (render_mutex_)
};

}  // namespace wsn
