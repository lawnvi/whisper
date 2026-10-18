#include "d3d_presenter.h"

#include <d2d1effects.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <vector>

#include "spinner.h"
#include "wic_util.h"

namespace wsn {
namespace {

// CLSID_D2D1GaussianBlur (d2d1effects.h declares it; defined here so the
// DLL does not need dxguid.lib).
const CLSID kGaussianBlur = {0x1feb6d69, 0x2fe6, 0x4ac9, {0x8c, 0x58, 0x1d, 0x7f, 0x93, 0xe7, 0xa6, 0xa5}};

constexpr UINT kSwapChainFlags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

bool IsDeviceLost(HRESULT hr) {
  return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET || hr == DXGI_ERROR_DEVICE_HUNG ||
         hr == D2DERR_RECREATE_TARGET;
}

bool FontExists(IDWriteFactory* factory, const wchar_t* family) {
  ComPtr<IDWriteFontCollection> fonts;
  if (FAILED(factory->GetSystemFontCollection(&fonts, FALSE))) return false;
  UINT32 index = 0;
  BOOL exists = FALSE;
  fonts->FindFamilyName(family, &index, &exists);
  return exists != FALSE;
}

class MultithreadLock {
 public:
  explicit MultithreadLock(ID3D10Multithread* multithread) : multithread_(multithread) {
    if (multithread_ != nullptr) multithread_->Enter();
  }
  ~MultithreadLock() {
    if (multithread_ != nullptr) multithread_->Leave();
  }

 private:
  ID3D10Multithread* multithread_;
};

}  // namespace

D3DPresenter::D3DPresenter() { wake_ = CreateEventW(nullptr, FALSE, FALSE, nullptr); }

D3DPresenter::~D3DPresenter() {
  Shutdown();
  if (wake_ != nullptr) CloseHandle(wake_);
}

bool D3DPresenter::Initialize(HWND hwnd, double scale, std::shared_ptr<D3DDevice> shared,
                              std::function<void(HRESULT)> on_lost) {
  hwnd_ = hwnd;
  scale_ = scale;
  on_lost_ = std::move(on_lost);
  if (shared == nullptr) return false;
  const double started = NowSeconds();
  shared_ = std::move(shared);
  device_ = shared_->device;
  context_ = shared_->context;
  multithread_ = shared_->multithread;
  video_device_ = shared_->video_device;
  video_context_ = shared_->video_context;
  dwrite_ = shared_->dwrite;
  ComPtr<IDXGIDevice> dxgi_device;
  ComPtr<IDXGIAdapter> adapter;
  ComPtr<IDXGIFactory2> factory;
  if (FAILED(device_.As(&dxgi_device)) || FAILED(dxgi_device->GetAdapter(&adapter)) ||
      FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) {
    return false;
  }
  RECT client;
  GetClientRect(hwnd_, &client);
  DXGI_SWAP_CHAIN_DESC1 desc = {};
  desc.Width = static_cast<UINT>(std::max<LONG>(1, client.right));
  desc.Height = static_cast<UINT>(std::max<LONG>(1, client.bottom));
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.Scaling = DXGI_SCALING_STRETCH;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
  desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
  desc.Flags = kSwapChainFlags;
  ComPtr<IDXGISwapChain1> swap_chain;
  HRESULT hr;
  {
    MultithreadLock mt(multithread_.Get());
    hr = factory->CreateSwapChainForHwnd(device_.Get(), hwnd_, &desc, nullptr, nullptr, &swap_chain);
  }
  if (FAILED(hr) || FAILED(swap_chain.As(&swap_chain_))) {
    Log("presenter: CreateSwapChainForHwnd failed (0x%08lx)", hr);
    return false;
  }
  factory->MakeWindowAssociation(hwnd_, DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);
  swap_chain_->SetMaximumFrameLatency(1);
  waitable_ = swap_chain_->GetFrameLatencyWaitableObject();
  hr = shared_->d2d_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &d2d_context_);
  if (FAILED(hr)) {
    Log("presenter: Direct2D context failed (0x%08lx)", hr);
    return false;
  }
  d2d_context_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  EnsureTextFormats();
  spinner_color_ = SpinnerColor();
  D2D1_STROKE_STYLE_PROPERTIES1 stroke = D2D1::StrokeStyleProperties1(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND);
  shared_->d2d_factory->CreateStrokeStyle(&stroke, nullptr, 0, &spinner_stroke_);
  stopping_ = false;
  render_thread_ = std::thread([this] { RenderLoop(); });
  // The first frame (black, or the overlay) is up before the window shows.
  RenderAndWait(100);
  Log("presenter: flip swap chain %ux%u ready in %.0f ms", desc.Width, desc.Height, (NowSeconds() - started) * 1000);
  return true;
}

// Only the render thread presents, and only after the swap chain's
// waitable object said a frame may be queued: presenting without that
// wait (from a second thread, or after a timeout) leaves the count one off
// for good, and every Present after it blocks for a whole refresh.
void D3DPresenter::RenderAndWait(int timeout_ms) {
  std::unique_lock<std::mutex> lock(rendered_mutex_);
  const int64_t target = render_requests_ + 1;
  render_requests_ = target;
  SetEvent(wake_);
  rendered_cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return rendered_ >= target || stopping_; });
}

void D3DPresenter::Shutdown() {
  stopping_ = true;
  if (wake_ != nullptr) SetEvent(wake_);
  if (render_thread_.joinable()) render_thread_.join();
  std::lock_guard<std::mutex> lock(render_mutex_);
  {
    std::lock_guard<std::mutex> state(state_mutex_);
    pending_.reset();
  }
  current_.reset();
  if (context_ != nullptr) {
    MultithreadLock mt(multithread_.Get());
    if (d2d_context_ != nullptr) d2d_context_->SetTarget(nullptr);
    context_->Flush();
  }
  processor_.Reset();
  enumerator_.Reset();
  upload_.Reset();
  upload_staging_.Reset();
  uploaded_.reset();
  scene_.Reset();
  poster_bitmap_.Reset();
  poster_bitmap_of_ = nullptr;
  icon_bitmap_.Reset();
  icon_bitmap_of_ = nullptr;
  spinner_stroke_.Reset();
  message_format_.Reset();
  hud_format_.Reset();
  dwrite_.Reset();
  d2d_context_.Reset();
  if (waitable_ != nullptr) {
    CloseHandle(waitable_);
    waitable_ = nullptr;
  }
  swap_chain_.Reset();
  video_context_.Reset();
  video_device_.Reset();
  multithread_.Reset();
  context_.Reset();
  device_.Reset();
  shared_.reset();
}

void D3DPresenter::EnsureTextFormats() {
  if (dwrite_ == nullptr || (message_format_ != nullptr && hud_format_ != nullptr)) return;
  dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL,
                            DWRITE_FONT_STRETCH_NORMAL, 15.0f, L"", &message_format_);
  if (message_format_ != nullptr) {
    message_format_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    message_format_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    message_format_->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
  }
  const wchar_t* mono = FontExists(dwrite_.Get(), L"Cascadia Mono") ? L"Cascadia Mono" : L"Consolas";
  dwrite_->CreateTextFormat(mono, nullptr, DWRITE_FONT_WEIGHT_MEDIUM, DWRITE_FONT_STYLE_NORMAL,
                            DWRITE_FONT_STRETCH_NORMAL, 11.0f, L"", &hud_format_);
  if (hud_format_ != nullptr) {
    hud_format_->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
  }
}

void D3DPresenter::Submit(DecodedFrame frame) {
  if (frame.gpu()) {
    // A frame from another (lost) device cannot be shown here.
    ComPtr<ID3D11Device> owner;
    frame.texture->GetDevice(&owner);
    if (owner.Get() != device_.Get()) return;
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (pending_.has_value()) stats_.skipped++;
    pending_ = std::move(frame);
  }
  SetEvent(wake_);
}

void D3DPresenter::SetReadiness(std::shared_ptr<Readiness> readiness, std::function<void()> on_stable) {
  readiness_ = std::move(readiness);
  on_stable_ = std::move(on_stable);
}

void D3DPresenter::SetPoster(std::shared_ptr<const Poster> poster) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    poster_ = std::move(poster);
  }
  Redraw();
}

void D3DPresenter::SetIcon(std::shared_ptr<const Poster> icon) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    icon_ = std::move(icon);
  }
  Redraw();
}

void D3DPresenter::SetOverlay(const OverlayState& overlay) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    overlay_ = overlay;
  }
  Redraw();
}

void D3DPresenter::SetScale(double scale) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    scale_ = scale;
  }
  Redraw();
}

void D3DPresenter::Redraw() {
  if (wake_ != nullptr) SetEvent(wake_);
}

D3DPresenter::Stats D3DPresenter::stats() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return stats_;
}

bool D3DPresenter::has_frame() {
  std::lock_guard<std::mutex> lock(render_mutex_);
  return current_.has_value();
}

void D3DPresenter::Resize() {
  if (swap_chain_ == nullptr || lost_) return;
  RECT client;
  GetClientRect(hwnd_, &client);
  if (client.right <= 0 || client.bottom <= 0) return;  // minimized
  {
    std::lock_guard<std::mutex> lock(render_mutex_);
    ResizeLocked(client);
  }
  // Show the new size before WM_SIZE returns, so live resizing is smooth.
  RenderAndWait(50);
}

void D3DPresenter::ResizeLocked(const RECT& client) {
  DXGI_SWAP_CHAIN_DESC1 desc = {};
  swap_chain_->GetDesc1(&desc);
  if (desc.Width != static_cast<UINT>(client.right) || desc.Height != static_cast<UINT>(client.bottom)) {
    MultithreadLock mt(multithread_.Get());
    d2d_context_->SetTarget(nullptr);
    context_->ClearState();
    context_->Flush();
    HRESULT hr = swap_chain_->ResizeBuffers(0, static_cast<UINT>(client.right), static_cast<UINT>(client.bottom),
                                            DXGI_FORMAT_UNKNOWN, kSwapChainFlags);
    if (FAILED(hr)) {
      Log("presenter: ResizeBuffers failed (0x%08lx)", hr);
      if (IsDeviceLost(hr) && !lost_.exchange(true) && on_lost_) on_lost_(hr);
      return;
    }
  }
}

void D3DPresenter::RenderLoop() {
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
  while (!stopping_) {
    WaitForSingleObject(wake_, INFINITE);
    if (stopping_) break;
    int64_t requested;
    {
      std::lock_guard<std::mutex> lock(rendered_mutex_);
      requested = render_requests_;
    }
    if (!lost_) {
      // One wait per present: until the swap chain can take a frame. If it
      // cannot (window minimized or hidden), try again shortly rather than
      // present without the wait.
      if (waitable_ != nullptr && WaitForSingleObjectEx(waitable_, 100, FALSE) != WAIT_OBJECT_0) {
        if (!stopping_) SetEvent(wake_);
        continue;
      }
      if (stopping_) break;
      HRESULT hr;
      {
        std::lock_guard<std::mutex> lock(render_mutex_);
        hr = RenderLocked();
      }
      if (IsDeviceLost(hr) && !lost_.exchange(true)) {
        Log("presenter: device lost (0x%08lx)", hr);
        if (on_lost_) on_lost_(hr);
      }
    }
    {
      std::lock_guard<std::mutex> lock(rendered_mutex_);
      rendered_ = std::max(rendered_, requested);
    }
    rendered_cv_.notify_all();
  }
  rendered_cv_.notify_all();
}

bool D3DPresenter::EnsureProcessor(int in_width, int in_height, int out_width, int out_height) {
  if (processor_ != nullptr && in_width == processor_in_width_ && in_height == processor_in_height_ &&
      out_width == processor_out_width_ && out_height == processor_out_height_) {
    return true;
  }
  processor_.Reset();
  enumerator_.Reset();
  D3D11_VIDEO_PROCESSOR_CONTENT_DESC desc = {};
  desc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  desc.InputFrameRate = {60, 1};
  desc.InputWidth = static_cast<UINT>(in_width);
  desc.InputHeight = static_cast<UINT>(in_height);
  desc.OutputFrameRate = {60, 1};
  desc.OutputWidth = static_cast<UINT>(std::max(1, out_width));
  desc.OutputHeight = static_cast<UINT>(std::max(1, out_height));
  desc.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
  HRESULT hr = video_device_->CreateVideoProcessorEnumerator(&desc, &enumerator_);
  if (SUCCEEDED(hr)) hr = video_device_->CreateVideoProcessor(enumerator_.Get(), 0, &processor_);
  if (FAILED(hr)) {
    Log("presenter: video processor %dx%d -> %dx%d failed (0x%08lx)", in_width, in_height, out_width, out_height, hr);
    processor_.Reset();
    enumerator_.Reset();
    return false;
  }
  video_context_->VideoProcessorSetStreamAutoProcessingMode(processor_.Get(), 0, FALSE);
  video_context_->VideoProcessorSetStreamFrameFormat(processor_.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
  D3D11_VIDEO_COLOR black = {};
  black.RGBA.A = 1.0f;
  video_context_->VideoProcessorSetOutputBackgroundColor(processor_.Get(), FALSE, &black);
  processor_in_width_ = in_width;
  processor_in_height_ = in_height;
  processor_out_width_ = out_width;
  processor_out_height_ = out_height;
  return true;
}

bool D3DPresenter::UploadIfNeeded(const DecodedFrame& frame) {
  if (frame.gpu()) return true;
  if (frame.nv12 == nullptr) return false;
  if (uploaded_ == frame.nv12 && upload_ != nullptr) return true;
  const int width = frame.coded_width & ~1;
  const int height = frame.coded_height & ~1;
  if (width <= 0 || height <= 0) return false;
  if (upload_ == nullptr || upload_width_ != width || upload_height_ != height) {
    upload_.Reset();
    upload_staging_.Reset();
    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = static_cast<UINT>(width);
    desc.Height = static_cast<UINT>(height);
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_NV12;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    // What video processors accept as input differs by driver: decoder
    // output textures everywhere, plain ones only on some.
    static const UINT kBinds[] = {D3D11_BIND_DECODER, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE,
                                  D3D11_BIND_SHADER_RESOURCE, 0};
    HRESULT hr = E_FAIL;
    for (; upload_bind_ < static_cast<int>(ARRAYSIZE(kBinds)); upload_bind_++) {
      desc.BindFlags = kBinds[upload_bind_];
      hr = device_->CreateTexture2D(&desc, nullptr, &upload_);
      if (SUCCEEDED(hr)) break;
    }
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (SUCCEEDED(hr)) hr = device_->CreateTexture2D(&desc, nullptr, &upload_staging_);
    if (FAILED(hr)) {
      Log("presenter: NV12 upload textures failed (0x%08lx)", hr);
      upload_.Reset();
      upload_staging_.Reset();
      return false;
    }
    upload_width_ = width;
    upload_height_ = height;
  }
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (FAILED(context_->Map(upload_staging_.Get(), 0, D3D11_MAP_WRITE, 0, &mapped))) return false;
  const uint8_t* source = frame.nv12->data();
  auto* target = static_cast<uint8_t*>(mapped.pData);
  const size_t row = static_cast<size_t>(width);
  for (int y = 0; y < height; y++) {
    std::memcpy(target + static_cast<size_t>(mapped.RowPitch) * y, source + static_cast<size_t>(frame.pitch) * y, row);
  }
  const uint8_t* uv_source = source + static_cast<size_t>(frame.pitch) * frame.coded_height;
  uint8_t* uv_target = target + static_cast<size_t>(mapped.RowPitch) * height;
  for (int y = 0; y < height / 2; y++) {
    std::memcpy(uv_target + static_cast<size_t>(mapped.RowPitch) * y,
                uv_source + static_cast<size_t>(frame.pitch) * y, row);
  }
  context_->Unmap(upload_staging_.Get(), 0);
  context_->CopyResource(upload_.Get(), upload_staging_.Get());
  uploaded_ = frame.nv12;
  return true;
}

HRESULT D3DPresenter::BltFrame(const DecodedFrame& frame, ID3D11Texture2D* target, const RECT& dest,
                               const RECT& target_rect) {
  ID3D11Texture2D* input = frame.gpu() ? frame.texture.Get() : upload_.Get();
  if (input == nullptr) return E_UNEXPECTED;
  static const bool kTestFailure = EnvFlag(L"WSN_TEST_BLT_FAIL");  // exercises the GDI fallback
  if (kTestFailure) return E_INVALIDARG;
  D3D11_TEXTURE2D_DESC input_desc = {};
  input->GetDesc(&input_desc);
  D3D11_TEXTURE2D_DESC target_desc = {};
  target->GetDesc(&target_desc);
  if (!EnsureProcessor(static_cast<int>(input_desc.Width), static_cast<int>(input_desc.Height),
                       static_cast<int>(target_desc.Width), static_cast<int>(target_desc.Height))) {
    return E_FAIL;
  }
  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC input_view_desc = {};
  input_view_desc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  input_view_desc.Texture2D.ArraySlice = frame.gpu() ? frame.subresource : 0;
  ComPtr<ID3D11VideoProcessorInputView> input_view;
  HRESULT hr = video_device_->CreateVideoProcessorInputView(input, enumerator_.Get(), &input_view_desc, &input_view);
  if (FAILED(hr)) {
    if (!frame.gpu()) {
      // Try the next kind of upload texture from the next frame on.
      Log("presenter: upload texture (bind 0x%x) not accepted by the video processor (0x%08lx)",
          input_desc.BindFlags, hr);
      upload_bind_++;
      upload_.Reset();
      upload_staging_.Reset();
      uploaded_.reset();
    } else if (blt_failures_ < 3) {
      Log("presenter: input view (%ux%u fmt %d bind 0x%x slice %u) failed (0x%08lx)", input_desc.Width,
          input_desc.Height, input_desc.Format, input_desc.BindFlags, input_view_desc.Texture2D.ArraySlice, hr);
    }
    return hr;
  }
  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC output_view_desc = {};
  output_view_desc.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
  ComPtr<ID3D11VideoProcessorOutputView> output_view;
  hr = video_device_->CreateVideoProcessorOutputView(target, enumerator_.Get(), &output_view_desc, &output_view);
  if (FAILED(hr)) {
    Log("presenter: output view (%ux%u) failed (0x%08lx)", target_desc.Width, target_desc.Height, hr);
    return hr;
  }
  RECT source = frame.visible;
  // Software frames were cropped to even sizes on upload.
  source.right = std::min<LONG>(source.right, static_cast<LONG>(input_desc.Width));
  source.bottom = std::min<LONG>(source.bottom, static_cast<LONG>(input_desc.Height));
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE input_space = {};
  input_space.YCbCr_Matrix = frame.bt709 ? 1 : 0;
  input_space.Nominal_Range =
      frame.full_range ? D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255 : D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE output_space = {};
  output_space.RGB_Range = 0;  // full range RGB
  video_context_->VideoProcessorSetStreamColorSpace(processor_.Get(), 0, &input_space);
  video_context_->VideoProcessorSetOutputColorSpace(processor_.Get(), &output_space);
  video_context_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &source);
  video_context_->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE, &dest);
  video_context_->VideoProcessorSetOutputTargetRect(processor_.Get(), TRUE, &target_rect);
  D3D11_VIDEO_PROCESSOR_STREAM stream = {};
  stream.Enable = TRUE;
  stream.pInputSurface = input_view.Get();
  return video_context_->VideoProcessorBlt(processor_.Get(), output_view.Get(), 0, 1, &stream);
}

bool D3DPresenter::EnsureScene(UINT width, UINT height) {
  if (scene_ != nullptr && scene_width_ == width && scene_height_ == height) return true;
  scene_.Reset();
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  if (FAILED(device_->CreateTexture2D(&desc, nullptr, &scene_))) {
    scene_.Reset();
    return false;
  }
  scene_width_ = width;
  scene_height_ = height;
  return true;
}

HRESULT D3DPresenter::RenderLocked() {
  if (swap_chain_ == nullptr || lost_) return S_OK;
  bool new_frame = false;
  OverlayState overlay;
  double scale;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (pending_.has_value()) {
      current_ = std::move(pending_);
      pending_.reset();
      new_frame = true;
    }
    overlay = overlay_;
    scale = scale_;
  }
  (void)scale;
  // Held while drawing, not across Present: the decoders share the device.
  std::optional<MultithreadLock> mt(std::in_place, multithread_.Get());
  ComPtr<ID3D11Texture2D> back_buffer;
  HRESULT hr = swap_chain_->GetBuffer(0, IID_PPV_ARGS(&back_buffer));
  if (FAILED(hr)) return hr;
  D3D11_TEXTURE2D_DESC back_desc = {};
  back_buffer->GetDesc(&back_desc);
  const UINT width = back_desc.Width;
  const UINT height = back_desc.Height;
  const RECT full = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
  // Live (or still connecting): until the picture is stable a placeholder
  // covers it and its frames are not drawn at all.
  const bool live = overlay.visual == WSN_VISUAL_LIVE || overlay.visual == WSN_VISUAL_CONNECTING;
  Readiness::View view;
  if (readiness_ != nullptr && live) view = readiness_->Evaluate(NowSeconds());
  if (view.became_stable && on_stable_) on_stable_();
  bool have_frame = current_.has_value() && UploadIfNeeded(*current_);
  const bool draw_frame = have_frame && (!live || view.show_frames);
  bool drew = false;
  if (draw_frame) {
    const RECT dest =
        LetterboxRect(static_cast<int>(width), static_cast<int>(height), current_->width(), current_->height());
    if (!live && EnsureScene(width, height)) {
      hr = BltFrame(*current_, scene_.Get(), dest, full);
      drew = SUCCEEDED(hr);
    } else {
      hr = BltFrame(*current_, back_buffer.Get(), dest, full);
      drew = SUCCEEDED(hr);
    }
    if (FAILED(hr)) {
      if (IsDeviceLost(hr)) return hr;
      if (++blt_failures_ <= 3) Log("presenter: VideoProcessorBlt failed (0x%08lx)", hr);
      if (blt_failures_ == 30 && !lost_.exchange(true)) {
        // The picture cannot be shown this way: let the surface fall back.
        Log("presenter: giving up on the video processor");
        if (on_lost_) on_lost_(E_FAIL);
      }
    } else {
      blt_failures_ = 0;
    }
  }
  if (live ? !drew : (!have_frame || !drew)) {
    // Black under whatever comes next (the overlays bring their own).
    ComPtr<ID3D11RenderTargetView> target_view;
    if (SUCCEEDED(device_->CreateRenderTargetView(back_buffer.Get(), nullptr, &target_view))) {
      const float black[4] = {0, 0, 0, 1};
      context_->ClearRenderTargetView(target_view.Get(), black);
    }
  }
  if (!live || view.cover > 0 || (overlay.hud_enabled && !overlay.hud_text.empty())) {
    DrawOverlay(back_buffer.Get(), width, height, have_frame && drew, view);
  }
  if (view.cover <= 0) spinner_epoch_ = -1;
  if (view.animating) SetEvent(wake_);  // the next refresh draws the next step
  back_buffer.Reset();
  mt.reset();
  const double present_started = NowSeconds();
  hr = swap_chain_->Present(1, 0);
  const double present_ms = (NowSeconds() - present_started) * 1000;
  if (present_ms > 8 && ++slow_presents_ % 600 == 1) {
    Log("presenter: Present took %.1f ms (%lld slow so far)", present_ms, static_cast<long long>(slow_presents_));
  }
  if (FAILED(hr)) return hr;
  if (new_frame && current_.has_value()) {
    double latency = (NowSeconds() - current_->decoded_at) * 1000.0;
    std::lock_guard<std::mutex> lock(state_mutex_);
    stats_.presented++;
    stats_.latency_ms = stats_.latency_ms <= 0 ? latency : stats_.latency_ms * 0.9 + latency * 0.1;
  }
  return S_OK;
}

void D3DPresenter::DrawOverlay(ID3D11Texture2D* back_buffer, UINT width, UINT height, bool have_frame,
                               const Readiness::View& view) {
  OverlayState overlay;
  double scale;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    overlay = overlay_;
    scale = scale_ > 0 ? scale_ : 1;
  }
  EnsureTextFormats();
  ComPtr<IDXGISurface> surface;
  if (FAILED(back_buffer->QueryInterface(IID_PPV_ARGS(&surface)))) return;
  const float dpi = static_cast<float>(96.0 * scale);
  D2D1_BITMAP_PROPERTIES1 target_props =
      D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                              D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), dpi, dpi);
  ComPtr<ID2D1Bitmap1> target;
  if (FAILED(d2d_context_->CreateBitmapFromDxgiSurface(surface.Get(), &target_props, &target))) return;
  d2d_context_->SetTarget(target.Get());
  d2d_context_->SetDpi(dpi, dpi);
  d2d_context_->BeginDraw();
  const float w = static_cast<float>(width / scale);
  const float h = static_cast<float>(height / scale);
  const D2D1_RECT_F bounds = D2D1::RectF(0, 0, w, h);
  const bool live = overlay.visual == WSN_VISUAL_LIVE || overlay.visual == WSN_VISUAL_CONNECTING;
  if (live) {
    if (view.cover > 0) DrawCover(w, h, view, overlay);
  } else {
    ComPtr<ID2D1SolidColorBrush> brush;
    if (have_frame && scene_ != nullptr) {
      // The picture, frosted: blurred and darkened, like a HUD panel.
      ComPtr<IDXGISurface> scene_surface;
      ComPtr<ID2D1Bitmap1> scene;
      D2D1_BITMAP_PROPERTIES1 scene_props = D2D1::BitmapProperties1(
          D2D1_BITMAP_OPTIONS_NONE, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), dpi, dpi);
      if (SUCCEEDED(scene_.As(&scene_surface)) &&
          SUCCEEDED(d2d_context_->CreateBitmapFromDxgiSurface(scene_surface.Get(), &scene_props, &scene))) {
        const bool paused = overlay.visual == WSN_VISUAL_PAUSED;
        if (paused) d2d_context_->DrawBitmap(scene.Get());
        ComPtr<ID2D1Effect> blur;
        if (SUCCEEDED(d2d_context_->CreateEffect(kGaussianBlur, &blur))) {
          blur->SetInput(0, scene.Get());
          blur->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION, 18.0f);
          blur->SetValue(D2D1_GAUSSIANBLUR_PROP_BORDER_MODE, D2D1_BORDER_MODE_HARD);
          blur->SetValue(D2D1_GAUSSIANBLUR_PROP_OPTIMIZATION, D2D1_GAUSSIANBLUR_OPTIMIZATION_BALANCED);
        }
        ComPtr<ID2D1Layer> layer;
        if (paused) {
          d2d_context_->PushLayer(D2D1::LayerParameters1(bounds, nullptr, D2D1_ANTIALIAS_MODE_ALIASED,
                                                         D2D1::IdentityMatrix(), 0.86f),
                                  nullptr);
        }
        if (blur != nullptr) {
          d2d_context_->DrawImage(blur.Get());
        } else {
          d2d_context_->DrawBitmap(scene.Get());
        }
        d2d_context_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0.45f), &brush);
        if (brush != nullptr) d2d_context_->FillRectangle(bounds, brush.Get());
        if (paused) d2d_context_->PopLayer();
      }
    } else {
      d2d_context_->CreateSolidColorBrush(D2D1::ColorF(28 / 255.0f, 28 / 255.0f, 30 / 255.0f, 1.0f), &brush);
      if (brush != nullptr) d2d_context_->FillRectangle(bounds, brush.Get());
    }
    if (!overlay.message.empty() && message_format_ != nullptr) {
      ComPtr<ID2D1SolidColorBrush> text;
      d2d_context_->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.95f), &text);
      const float box = std::max(40.0f, std::min(w - 48, 320.0f));
      const D2D1_RECT_F rect = D2D1::RectF((w - box) / 2, h / 2 - 40, (w + box) / 2, h / 2 + 40);
      if (text != nullptr) {
        d2d_context_->DrawText(overlay.message.c_str(), static_cast<UINT32>(overlay.message.size()),
                               message_format_.Get(), rect, text.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
      }
    }
  }
  if (overlay.hud_enabled && !overlay.hud_text.empty() && hud_format_ != nullptr) {
    ComPtr<IDWriteTextLayout> layout;
    if (SUCCEEDED(dwrite_->CreateTextLayout(overlay.hud_text.c_str(), static_cast<UINT32>(overlay.hud_text.size()),
                                            hud_format_.Get(), std::max(10.0f, w - 24), h, &layout))) {
      DWRITE_TEXT_METRICS metrics = {};
      layout->GetMetrics(&metrics);
      ComPtr<ID2D1SolidColorBrush> background;
      ComPtr<ID2D1SolidColorBrush> text;
      d2d_context_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0.55f), &background);
      d2d_context_->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), &text);
      const D2D1_RECT_F panel = D2D1::RectF(8, 8, 8 + metrics.widthIncludingTrailingWhitespace + 8,
                                            8 + metrics.height + 6);
      if (background != nullptr) {
        d2d_context_->FillRoundedRectangle(D2D1::RoundedRect(panel, 3, 3), background.Get());
      }
      if (text != nullptr) d2d_context_->DrawTextLayout(D2D1::Point2F(12, 11), layout.Get(), text.Get());
    }
  }
  HRESULT hr = d2d_context_->EndDraw();
  d2d_context_->SetTarget(nullptr);
  if (FAILED(hr)) Log("presenter: Direct2D EndDraw failed (0x%08lx)", hr);
}

// (By reference: `&comptr` would go through WRL's ComPtrRef, which empties
// the pointer on the way in.)
ID2D1Bitmap1* D3DPresenter::BitmapOf(const std::shared_ptr<const Poster>& image, ComPtr<ID2D1Bitmap1>& bitmap,
                                     const Poster*& made_of) {
  if (image == nullptr) {
    bitmap.Reset();
    made_of = nullptr;
    return nullptr;
  }
  if (image.get() != made_of) {
    bitmap.Reset();
    made_of = image.get();
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
    HRESULT hr = d2d_context_->CreateBitmap(
        D2D1::SizeU(static_cast<UINT32>(image->width), static_cast<UINT32>(image->height)), image->bgra.data(),
        static_cast<UINT32>(image->width) * 4, &props, bitmap.GetAddressOf());
    if (FAILED(hr)) Log("presenter: placeholder bitmap %dx%d failed (0x%08lx)", image->width, image->height, hr);
  }
  return bitmap.Get();
}

void D3DPresenter::DrawCover(float w, float h, const Readiness::View& view, const OverlayState& overlay) {
  const D2D1_RECT_F bounds = D2D1::RectF(0, 0, w, h);
  const float opacity = static_cast<float>(std::clamp(view.cover, 0.0, 1.0));
  d2d_context_->PushLayer(
      D2D1::LayerParameters1(bounds, nullptr, D2D1_ANTIALIAS_MODE_ALIASED, D2D1::IdentityMatrix(), opacity), nullptr);
  ComPtr<ID2D1SolidColorBrush> brush;
  // Where the spinner goes: the middle, or under the icon.
  float spinner_y = h / 2;
  if (view.cover_is_last_frame) {
    // Resuming: the last frame, dimmed, stays under the spinner.
    d2d_context_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0.4f), &brush);
    if (brush != nullptr) d2d_context_->FillRectangle(bounds, brush.Get());
  } else {
    d2d_context_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &brush);
    if (brush != nullptr) d2d_context_->FillRectangle(bounds, brush.Get());
    std::shared_ptr<const Poster> poster;
    std::shared_ptr<const Poster> icon;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      poster = poster_;
      icon = icon_;
    }
    if (ID2D1Bitmap1* picture = BitmapOf(poster, poster_bitmap_, poster_bitmap_of_)) {
      // The window's last picture, aspect-fit and slightly dimmed.
      const double fit = std::min(static_cast<double>(w) / poster->width, static_cast<double>(h) / poster->height);
      const float pw = static_cast<float>(poster->width * fit);
      const float ph = static_cast<float>(poster->height * fit);
      const D2D1_RECT_F rect = D2D1::RectF((w - pw) / 2, (h - ph) / 2, (w + pw) / 2, (h + ph) / 2);
      d2d_context_->DrawBitmap(picture, rect, 1.0f, D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC);
      ComPtr<ID2D1SolidColorBrush> dim;
      d2d_context_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0.35f), &dim);
      if (dim != nullptr) d2d_context_->FillRectangle(rect, dim.Get());
    } else if (ID2D1Bitmap1* app = BitmapOf(icon, icon_bitmap_, icon_bitmap_of_)) {
      // The app's icon, the spinner under it, together in the middle.
      const float group = kPlaceholderIcon + kPlaceholderGap + kSpinnerDiameter;
      const float top = (h - group) / 2;
      const D2D1_RECT_F rect =
          D2D1::RectF((w - kPlaceholderIcon) / 2, top, (w + kPlaceholderIcon) / 2, top + kPlaceholderIcon);
      d2d_context_->DrawBitmap(app, rect, 1.0f, D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC);
      spinner_y = top + kPlaceholderIcon + kPlaceholderGap + kSpinnerDiameter / 2;
    }
  }
  if (view.spinner) DrawSpinner(w / 2, spinner_y, 1.0f);
  if (view.hint && !overlay.message.empty() && message_format_ != nullptr) {
    // Taking long: the visual's own words under the spinner.
    ComPtr<ID2D1SolidColorBrush> text;
    d2d_context_->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.9f), &text);
    const float box = std::max(40.0f, std::min(w - 48, 320.0f));
    const float top = spinner_y + kSpinnerDiameter / 2 + 12;
    const D2D1_RECT_F rect = D2D1::RectF((w - box) / 2, top, (w + box) / 2, top + 60);
    if (text != nullptr) {
      message_format_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
      d2d_context_->DrawText(overlay.message.c_str(), static_cast<UINT32>(overlay.message.size()),
                             message_format_.Get(), rect, text.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
      message_format_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
  }
  d2d_context_->PopLayer();
}

void D3DPresenter::DrawSpinner(float cx, float cy, float opacity) {
  const double now = NowSeconds();
  if (spinner_epoch_ < 0) spinner_epoch_ = now;
  double start = 0;
  double sweep = 0;
  SpinnerArc(now - spinner_epoch_, &start, &sweep);
  const float radius = (kSpinnerDiameter - kSpinnerStroke) / 2;
  constexpr double kRad = 3.14159265358979323846 / 180.0;
  auto at = [&](double degrees) {
    return D2D1::Point2F(cx + radius * static_cast<float>(std::sin(degrees * kRad)),
                         cy - radius * static_cast<float>(std::cos(degrees * kRad)));
  };
  ComPtr<ID2D1PathGeometry> path;
  ComPtr<ID2D1GeometrySink> sink;
  if (FAILED(shared_->d2d_factory->CreatePathGeometry(&path)) || FAILED(path->Open(&sink))) return;
  sink->BeginFigure(at(start), D2D1_FIGURE_BEGIN_HOLLOW);
  sink->AddArc(D2D1::ArcSegment(at(start + sweep), D2D1::SizeF(radius, radius), 0.0f,
                                D2D1_SWEEP_DIRECTION_CLOCKWISE,
                                sweep > 180 ? D2D1_ARC_SIZE_LARGE : D2D1_ARC_SIZE_SMALL));
  sink->EndFigure(D2D1_FIGURE_END_OPEN);
  if (FAILED(sink->Close())) return;
  ComPtr<ID2D1SolidColorBrush> brush;
  d2d_context_->CreateSolidColorBrush(
      D2D1::ColorF(GetRValue(spinner_color_) / 255.0f, GetGValue(spinner_color_) / 255.0f,
                   GetBValue(spinner_color_) / 255.0f, opacity),
      &brush);
  if (brush != nullptr) {
    d2d_context_->DrawGeometry(path.Get(), brush.Get(), kSpinnerStroke, spinner_stroke_.Get());
  }
}

HRESULT D3DPresenter::FrameTexture(int max_edge, ComPtr<ID3D11Texture2D>* out, int* out_width, int* out_height) {
  if (!current_.has_value() || lost_ || device_ == nullptr) return E_UNEXPECTED;
  if (!UploadIfNeeded(*current_)) return E_FAIL;
  int width = current_->width();
  int height = current_->height();
  int longest = std::max(width, height);
  if (max_edge > 0 && longest > max_edge) {
    double scale = static_cast<double>(max_edge) / longest;
    width = std::max(1, static_cast<int>(std::lround(width * scale)));
    height = std::max(1, static_cast<int>(std::lround(height * scale)));
  }
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = static_cast<UINT>(width);
  desc.Height = static_cast<UINT>(height);
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET;
  ComPtr<ID3D11Texture2D> target;
  HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &target);
  if (FAILED(hr)) return hr;
  const RECT rect = {0, 0, width, height};
  // The processor is shaped for the window; this gets its own.
  ComPtr<ID3D11VideoProcessor> saved_processor = processor_;
  ComPtr<ID3D11VideoProcessorEnumerator> saved_enumerator = enumerator_;
  int saved[4] = {processor_in_width_, processor_in_height_, processor_out_width_, processor_out_height_};
  processor_.Reset();
  hr = BltFrame(*current_, target.Get(), rect, rect);
  processor_ = saved_processor;
  enumerator_ = saved_enumerator;
  processor_in_width_ = saved[0];
  processor_in_height_ = saved[1];
  processor_out_width_ = saved[2];
  processor_out_height_ = saved[3];
  if (FAILED(hr)) return hr;
  *out = target;
  *out_width = width;
  *out_height = height;
  return S_OK;
}

bool D3DPresenter::CaptureFrame(int max_edge, Poster* out) {
  std::lock_guard<std::mutex> lock(render_mutex_);
  if (device_ == nullptr) return false;
  MultithreadLock mt(multithread_.Get());
  ComPtr<ID3D11Texture2D> target;
  int width = 0;
  int height = 0;
  if (FAILED(FrameTexture(max_edge, &target, &width, &height))) return false;
  D3D11_TEXTURE2D_DESC desc = {};
  target->GetDesc(&desc);
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> staging;
  if (FAILED(device_->CreateTexture2D(&desc, nullptr, &staging))) return false;
  context_->CopyResource(staging.Get(), target.Get());
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (FAILED(context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return false;
  out->width = width;
  out->height = height;
  out->bgra.resize(static_cast<size_t>(width) * height * 4);
  for (int y = 0; y < height; y++) {
    std::memcpy(out->bgra.data() + static_cast<size_t>(y) * width * 4,
                static_cast<const uint8_t*>(mapped.pData) + static_cast<size_t>(y) * mapped.RowPitch,
                static_cast<size_t>(width) * 4);
  }
  context_->Unmap(staging.Get(), 0);
  for (size_t i = 3; i < out->bgra.size(); i += 4) out->bgra[i] = 255;
  return true;
}

int32_t D3DPresenter::Snapshot(const std::wstring& path, int max_edge) {
  Poster frame;
  if (!CaptureFrame(max_edge, &frame)) {
    Log("snapshot: no frame to capture");
    return -2;
  }
  const bool ok = WriteJpeg(path, frame.bgra.data(), frame.width, frame.height, frame.width * 4, 0);
  if (!ok) Log("snapshot: JPEG encoding failed");
  return ok ? 0 : -2;
}

}  // namespace wsn
