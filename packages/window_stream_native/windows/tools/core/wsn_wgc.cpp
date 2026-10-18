#include "wsn_wgc.h"

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <thread>

#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Security.Authorization.AppCapabilityAccess.h>

namespace wsn {

using namespace winrt::Windows::Graphics::Capture;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;

namespace {
thread_local bool t_in_frame_callback = false;

WgcSupport Probe() {
  WgcSupport s;
  try {
    s.supported = GraphicsCaptureSession::IsSupported();
    using winrt::Windows::Foundation::Metadata::ApiInformation;
    const wchar_t* type = L"Windows.Graphics.Capture.GraphicsCaptureSession";
    s.border_property = ApiInformation::IsPropertyPresent(type, L"IsBorderRequired");
    s.secondary_property = ApiInformation::IsPropertyPresent(type, L"IncludeSecondaryWindows");
    s.min_interval_property = ApiInformation::IsPropertyPresent(type, L"MinUpdateInterval");
    s.cursor_property = ApiInformation::IsPropertyPresent(type, L"IsCursorCaptureEnabled");
    if (s.supported && s.border_property) {
      // Unpackaged desktop apps get this without a prompt.
      auto status = GraphicsCaptureAccess::RequestAccessAsync(GraphicsCaptureAccessKind::Borderless).get();
      s.access_status = static_cast<int>(status);
      s.borderless_allowed =
          status == winrt::Windows::Security::Authorization::AppCapabilityAccess::AppCapabilityAccessStatus::Allowed;
    }
  } catch (...) {
  }
  return s;
}
}  // namespace

const WgcSupport& QueryWgcSupport() {
  static WgcSupport support = [] {
    // A blocking wait on a WinRT operation is not allowed on an STA
    // thread (the Flutter platform thread is one): ask from a fresh MTA one.
    WgcSupport result;
    std::thread worker([&result] {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      result = Probe();
      winrt::uninit_apartment();
    });
    worker.join();
    return result;
  }();
  return support;
}

WgcCapture::~WgcCapture() { Stop(); }

bool WgcCapture::Start(HWND window, const Options& options, FrameFn on_frame, ClosedFn on_closed,
                       std::string* error) {
  Stop();
  d3d_ = D3D::Shared();
  if (d3d_ == nullptr) {
    if (error) *error = "no Direct3D 11 device";
    return false;
  }
  const WgcSupport& support = QueryWgcSupport();
  if (!support.supported) {
    if (error) *error = "Windows.Graphics.Capture not supported";
    return false;
  }
  try {
    auto interop = winrt::get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    GraphicsCaptureItem item{nullptr};
    winrt::check_hresult(
        interop->CreateForWindow(window, winrt::guid_of<GraphicsCaptureItem>(), winrt::put_abi(item)));
    auto size = item.Size();
    if (size.Width <= 0 || size.Height <= 0) size = {16, 16};
    auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        d3d_->winrt_device(), DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    auto session = pool.CreateCaptureSession(item);
    if (support.cursor_property) {
      session.IsCursorCaptureEnabled(options.cursor);
    }
    if (support.border_property && support.borderless_allowed && !options.border) {
      try {
        session.IsBorderRequired(false);
      } catch (...) {
      }
    }
    if (support.secondary_property) {
      try {
        session.IncludeSecondaryWindows(options.secondary);
      } catch (...) {
      }
    }
    if (support.min_interval_property && options.min_interval_ms > 0) {
      try {
        session.MinUpdateInterval(winrt::Windows::Foundation::TimeSpan(options.min_interval_ms * 10000LL));
      } catch (...) {
      }
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      item_ = item;
      pool_ = pool;
      session_ = session;
      pool_size_ = size;
      on_frame_ = std::move(on_frame);
      on_closed_ = std::move(on_closed);
    }
    running_ = true;
    frame_token_ = pool.FrameArrived([this](auto&&, auto&&) { OnFrame(); });
    closed_token_ = item.Closed([this](auto&&, auto&&) {
      ClosedFn closed;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        closed = on_closed_;
      }
      if (running_ && closed) closed();
    });
    session.StartCapture();
    return true;
  } catch (winrt::hresult_error const& e) {
    if (error) *error = HrText(e.code()) + " " + Narrow(e.message());
  } catch (...) {
    if (error) *error = "unknown error";
  }
  Stop();
  return false;
}

void WgcCapture::Stop() {
  running_ = false;
  GraphicsCaptureItem item{nullptr};
  Direct3D11CaptureFramePool pool{nullptr};
  GraphicsCaptureSession session{nullptr};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    item = item_;
    pool = pool_;
    session = session_;
    item_ = nullptr;
    pool_ = nullptr;
    session_ = nullptr;
  }
  try {
    if (pool) pool.FrameArrived(frame_token_);
    if (item) item.Closed(closed_token_);
    if (session) session.Close();
    if (pool) pool.Close();
  } catch (...) {
  }
  // A frame callback may still be running on a pool thread.
  if (!t_in_frame_callback) {
    for (int i = 0; i < 2000 && in_callback_.load() > 0; ++i) Sleep(1);
  }
  std::lock_guard<std::mutex> lock(mutex_);
  on_frame_ = nullptr;
  on_closed_ = nullptr;
}

SIZE WgcCapture::item_size() const {
  auto* self = const_cast<WgcCapture*>(this);
  std::lock_guard<std::mutex> lock(self->mutex_);
  if (!item_) return SIZE{0, 0};
  try {
    auto size = item_.Size();
    return SIZE{size.Width, size.Height};
  } catch (...) {
    return SIZE{0, 0};
  }
}

void WgcCapture::SetMinInterval(int ms) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!session_ || !QueryWgcSupport().min_interval_property) return;
  try {
    session_.MinUpdateInterval(winrt::Windows::Foundation::TimeSpan(static_cast<int64_t>(ms) * 10000LL));
  } catch (...) {
  }
}

void WgcCapture::OnFrame() {
  in_callback_++;
  t_in_frame_callback = true;
  struct Leave {
    std::atomic<int>& count;
    ~Leave() {
      t_in_frame_callback = false;
      count--;
    }
  } leave{in_callback_};
  if (!running_) return;
  Direct3D11CaptureFramePool pool{nullptr};
  FrameFn on_frame;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pool = pool_;
    on_frame = on_frame_;
  }
  if (!pool) return;
  try {
    auto frame = pool.TryGetNextFrame();
    if (!frame) return;
    auto content = frame.ContentSize();
    auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> texture;
    winrt::check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));
    int64_t time_us = frame.SystemRelativeTime().count() / 10;
    if (on_frame && running_) on_frame(texture.get(), SIZE{content.Width, content.Height}, time_us);
    texture = nullptr;
    frame.Close();
    bool resize = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (content.Width > 0 && content.Height > 0 &&
          (content.Width != pool_size_.Width || content.Height != pool_size_.Height)) {
        pool_size_ = content;
        resize = true;
      }
    }
    if (resize && running_) {
      pool.Recreate(d3d_->winrt_device(), DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, content);
    }
  } catch (...) {
  }
}

}  // namespace wsn
