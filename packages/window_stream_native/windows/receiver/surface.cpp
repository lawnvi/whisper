#include "surface.h"

#include <dwmapi.h>
#include <imm.h>
#include <propsys.h>
#include <propvarutil.h>
#include <shellapi.h>
#include <shellscalingapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include "../common/com.h"
#include "d3d_device.h"
#include "d3d_presenter.h"
#include "gdi_presenter.h"
#include "h264_decoder.h"
#include "keys.h"
#include "poster_cache.h"
#include "wic_util.h"

namespace wsn {
namespace {

constexpr wchar_t kSurfaceClass[] = L"WhisperWindowStreamSurface";
constexpr DWORD kStyle = WS_OVERLAPPEDWINDOW;
constexpr DWORD kExStyle = 0;
constexpr UINT_PTR kTimerResize = 1;
constexpr UINT_PTR kTimerMove = 2;
constexpr UINT_PTR kTimerAnimate = 3;  // GDI: the spinner and the crossfade
constexpr UINT_PTR kTimerSettle = 4;   // REFLOW: the picture had its chance to follow
constexpr UINT_PTR kTimerSettleStep = 5;
// Longer edge of posters kept for reopening a window.
constexpr int kPosterEdge = 960;
// Above this many packets waiting to be decoded, deltas are dropped until
// the next keyframe so latency never builds up (as on macOS).
constexpr size_t kMaxQueued = 6;
// Before the window is up, a little more may queue.
constexpr size_t kMaxQueuedStarting = 120;
// Pointer moves (hover and drag) are sent at most this often.
constexpr double kMoveInterval = 1.0 / 120.0;
// Size reports while resizing: once the size rests this long, or at least
// this often during a long drag.
constexpr UINT kResizeSettleMs = 120;
constexpr double kResizeMaxInterval = 0.4;
constexpr double kMinContent = 200;  // DIPs, as macOS minSize
// REFLOW: shapes within this much of each other count as the same; after a
// resize the other side has this long to follow before the window settles
// to the picture's shape, which takes this long.
constexpr double kAspectTolerance = 0.02;
constexpr UINT kSettleDelayMs = 2000;
constexpr double kSettleSeconds = 0.18;

// Leaked on purpose (see common/util.cpp).
std::mutex& g_surfaces_mutex = *new std::mutex();
std::map<int64_t, std::shared_ptr<Surface>>& g_surfaces = *new std::map<int64_t, std::shared_ptr<Surface>>();
std::atomic<int64_t> g_next_id{1};
std::atomic<int> g_open_windows{0};

LRESULT CALLBACK SurfaceWndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* surface = reinterpret_cast<Surface*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (surface != nullptr) {
    return surface->HandleMessage(message, wparam, lparam);
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// UI thread.
void RegisterSurfaceClass() {
  static bool registered = false;
  if (registered) return;
  registered = true;
  WNDCLASSEXW surface_class = {};
  surface_class.cbSize = sizeof(surface_class);
  surface_class.lpfnWndProc = SurfaceWndProc;
  surface_class.hInstance = GetModuleHandleW(nullptr);
  surface_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  surface_class.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  surface_class.lpszClassName = kSurfaceClass;
  // The app's own icon until the streamed app's arrives.
  surface_class.hIcon = static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101), IMAGE_ICON,
                                                      0, 0, LR_DEFAULTSIZE | LR_SHARED));
  RegisterClassExW(&surface_class);
}

// PKEY_AppUserModel_ID / _PreventPinning (propkey.h), defined here so no
// GUID library is needed.
const PROPERTYKEY kAppUserModelId = {{0x9F4C2855, 0x9F79, 0x4B39, {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}}, 5};
const PROPERTYKEY kAppUserModelPreventPinning = {
    {0x9F4C2855, 0x9F79, 0x4B39, {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}}, 9};

// Each streamed window gets a taskbar button of its own, which shows the
// streamed app's icon (as macOS shows it on the window's Dock tile), rather
// than being grouped under Whisper's. Not pinnable: it is not an app here.
void SetTaskbarIdentity(HWND hwnd, int64_t surface, bool own) {
  ComPtr<IPropertyStore> store;
  if (FAILED(SHGetPropertyStoreForWindow(hwnd, IID_PPV_ARGS(&store)))) return;
  PROPVARIANT value;
  PropVariantInit(&value);
  if (own) {
    const std::wstring id = L"Vireen.Whisper.Stream." + std::to_wstring(surface);
    InitPropVariantFromString(id.c_str(), &value);
    PROPVARIANT prevent;
    InitPropVariantFromBoolean(TRUE, &prevent);
    store->SetValue(kAppUserModelPreventPinning, prevent);
    PropVariantClear(&prevent);
  }
  store->SetValue(kAppUserModelId, value);  // VT_EMPTY clears it
  PropVariantClear(&value);
  store->Commit();
}

bool SameShape(int client_width, int client_height, int video_width, int video_height) {
  if (client_width <= 0 || client_height <= 0 || video_width <= 0 || video_height <= 0) return true;
  const double client = static_cast<double>(client_width) / client_height;
  const double video = static_cast<double>(video_width) / video_height;
  return std::fabs(client / video - 1) <= kAspectTolerance;
}

bool ClientAreaAnimations() {
  BOOL enabled = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0);
  return enabled != FALSE;
}

bool SystemUsesDarkApps() {
  DWORD value = 1;
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                   L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) {
    return false;
  }
  return value == 0;
}

}  // namespace

Surface::Surface(int64_t id, std::wstring title, int width, int height, bool hud, bool reflow)
    : id_(id),
      hud_(hud),
      reflow_(reflow),
      readiness_(std::make_shared<Readiness>(NowSeconds())),
      poster_key_(title),
      title_(std::move(title)),
      video_width_(width),
      video_height_(height) {
  overlay_.hud_enabled = hud;
  // The same window opened again starts from its last picture.
  poster_ = FindPoster(poster_key_);
  ready_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
}

Surface::~Surface() {
  if (ready_ != nullptr) CloseHandle(ready_);
}

// ---------------------------------------------------------------- lifecycle

void Surface::Start() {
  auto self = shared_from_this();
  // The decode thread starts first: it fetches the shared D3D device and
  // warms up the decoder while the UI thread makes the window.
  decode_thread_ = std::thread([self] { self->DecodeLoop(); });
  if (!RunOnUiThread([self] { self->CreateWindowOnUiThread(); })) {
    SetEvent(ready_);
  }
}

void Surface::Stop() {
  // Like macOS, tearing down does not block the caller: the decode thread
  // (which holds a reference to this surface) finishes on its own, and the
  // audio device closes on a thread of its own.
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    stopping_ = true;
    queue_.clear();
  }
  queue_cv_.notify_all();
  SetEvent(ready_);
  if (decode_thread_.joinable()) {
    decode_thread_.detach();
  }
  std::unique_ptr<AudioOut> audio;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio = std::move(audio_);
  }
  if (audio != nullptr) {
    std::thread([audio = std::move(audio)]() mutable { audio.reset(); }).detach();
  }
}

void Surface::CreateWindowOnUiThread() {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (stopping_) {
      SetEvent(ready_);
      return;
    }
  }
  RegisterSurfaceClass();
  POINT cursor = {};
  GetCursorPos(&cursor);
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info = {sizeof(info)};
  GetMonitorInfoW(monitor, &info);
  const RECT work = info.rcWork;
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) dpi_x = 96;
  dpi_ = dpi_x;
  scale_ = dpi_ / 96.0;
  int video_width;
  int video_height;
  std::wstring title;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    video_width = video_width_ > 0 ? video_width_ : 1080;
    video_height = video_height_ > 0 ? video_height_ : 2400;
    title = title_;
  }
  // As on macOS: 82% of the visible height, at most 900 points tall and 60%
  // of the visible width, in the picture's shape.
  const double visible_width = (work.right - work.left) / scale_;
  const double visible_height = (work.bottom - work.top) / scale_;
  const double max_height = std::max(320.0, visible_height * 0.82);
  const double max_width = std::max(320.0, visible_width * 0.6);
  double height = std::min(max_height, 900.0);
  double width = height * video_width / video_height;
  if (width > max_width) {
    width = max_width;
    height = width * video_height / video_width;
  }
  RECT frame = {0, 0, static_cast<LONG>(std::lround(width * scale_)), static_cast<LONG>(std::lround(height * scale_))};
  AdjustWindowRectExForDpi(&frame, kStyle, FALSE, kExStyle, dpi_);
  const int frame_width = frame.right - frame.left;
  const int frame_height = frame.bottom - frame.top;
  const int stagger = static_cast<int>((g_open_windows.load() % 6) * 28 * scale_);
  int x = work.left + (work.right - work.left - frame_width) / 2 + stagger;
  int y = work.top + (work.bottom - work.top - frame_height) / 2 + stagger;
  x = std::max<int>(work.left, std::min<int>(x, work.right - frame_width));
  y = std::max<int>(work.top, std::min<int>(y, work.bottom - frame_height));
  hwnd_ = CreateWindowExW(kExStyle, kSurfaceClass, title.c_str(), kStyle, x, y, frame_width, frame_height, nullptr,
                          nullptr, GetModuleHandleW(nullptr), nullptr);
  if (hwnd_ == nullptr) {
    Log("surface %lld: CreateWindowEx failed (%lu)", static_cast<long long>(id_), GetLastError());
    SetEvent(ready_);
    return;
  }
  g_open_windows++;
  SetWindowLongPtrW(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  SetTaskbarIdentity(hwnd_, id_, true);
  dpi_ = GetDpiForWindow(hwnd_);
  scale_ = dpi_ / 96.0;
  ApplyDarkTitleBar();
  {
    std::weak_ptr<Surface> weak = weak_from_this();
    const int64_t id = id_;
    volume_control_ = std::make_unique<VolumeControl>(
        [weak](double volume) {
          if (auto self = weak.lock()) self->ApplyVolume(volume);
        },
        [id](double volume) { EmitWindow(id, WSN_WINDOW_VOLUME, volume); });
    double volume;
    {
      std::lock_guard<std::mutex> lock(audio_mutex_);
      volume = volume_;
    }
    volume_control_->SetVolume(volume);
    if (has_sound_) volume_control_->SetAvailable();
    volume_control_->Attach(hwnd_, dpi_);
  }

  std::shared_ptr<D3DPresenter> presenter;
  if (std::shared_ptr<D3DDevice> device = AcquireD3DDevice()) {
    presenter = std::make_shared<D3DPresenter>();
    PreparePresenter(presenter.get());  // the first frame already shows the placeholder
    std::weak_ptr<Surface> weak = weak_from_this();
    if (!presenter->Initialize(hwnd_, scale_, device, [weak](HRESULT reason) {
          if (auto self = weak.lock()) self->OnDeviceLost(reason);
        })) {
      presenter->Shutdown();
      presenter.reset();
    }
  }
  // (Made before taking state_mutex_: it reads the placeholder under it.)
  std::shared_ptr<GdiPresenter> gdi = presenter == nullptr ? MakeGdiPresenter() : nullptr;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    presenter_ = presenter;
    gdi_ = gdi;
  }
  Log("surface %lld: window %dx%d px at %u dpi, %s presenter", static_cast<long long>(id_), frame_width,
      frame_height, dpi_, presenter != nullptr ? "D3D11" : "GDI");
  UpdateGdiTarget();
  OverlayChanged();
  ApplyIcon();
  SetEvent(ready_);
  ShowWindow(hwnd_, SW_SHOW);
  SetForegroundWindow(hwnd_);
  SetVisible(true);
  // The size the window opened at, for the source's viewport.
  EmitResizedIfChanged();
}

void Surface::DestroyWindowOnUiThread() {
  std::shared_ptr<D3DPresenter> presenter;
  std::shared_ptr<GdiPresenter> gdi;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    presenter.swap(presenter_);
    gdi.swap(gdi_);
  }
  if (readiness_->stable()) {
    // Its last picture, for when this window is opened again.
    auto poster = std::make_shared<Poster>();
    if ((presenter != nullptr && presenter->CaptureFrame(kPosterEdge, poster.get())) ||
        (gdi != nullptr && gdi->CaptureFrame(kPosterEdge, poster.get()))) {
      StorePoster(poster_key_, std::move(poster));
    }
  }
  gdi.reset();
  if (presenter != nullptr) presenter->Shutdown();
  presenter.reset();
  if (volume_control_ != nullptr) volume_control_->Detach();
  volume_control_.reset();
  if (hwnd_ != nullptr) {
    KillTimer(hwnd_, kTimerSettle);
    KillTimer(hwnd_, kTimerSettleStep);
    SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
    SetTaskbarIdentity(hwnd_, id_, false);
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
    g_open_windows--;
  }
  if (small_icon_ != nullptr) DestroyIcon(small_icon_);
  if (big_icon_ != nullptr) DestroyIcon(big_icon_);
  small_icon_ = nullptr;
  big_icon_ = nullptr;
}

std::function<void()> Surface::StableCallback() {
  std::weak_ptr<Surface> weak = weak_from_this();
  return [weak] {
    RunOnUiThread([weak] {
      if (auto self = weak.lock()) self->OnStableOnUiThread();
    });
  };
}

void Surface::PreparePresenter(D3DPresenter* presenter) {
  std::shared_ptr<const Poster> poster;
  std::shared_ptr<const Poster> icon;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    poster = poster_;
    icon = icon_;
  }
  presenter->SetReadiness(readiness_, StableCallback());
  presenter->SetPoster(poster);
  presenter->SetIcon(icon);
  presenter->SetOverlay(Overlay());
}

void Surface::OnStableOnUiThread() {
  const double settle = readiness_->settle_seconds();
  Log("surface %lld: picture stable %.0f ms after the first frame", static_cast<long long>(id_),
      settle >= 0 ? settle * 1000 : -1.0);
  // The window takes the settled picture's shape now (it kept its size
  // while the first, wrongly sized frames came in).
  FollowVideoSizeOnUiThread();
}

std::shared_ptr<GdiPresenter> Surface::MakeGdiPresenter() {
  std::weak_ptr<Surface> weak = weak_from_this();
  std::shared_ptr<const Poster> poster;
  std::shared_ptr<const Poster> icon;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    poster = poster_;
    icon = icon_;
  }
  auto gdi = std::make_shared<GdiPresenter>([weak] {
    auto self = weak.lock();
    if (self == nullptr || self->repaint_posted_.exchange(true)) return;
    RunOnUiThread([weak] {
      auto surface = weak.lock();
      if (surface == nullptr) return;
      surface->repaint_posted_ = false;
      if (surface->hwnd_ != nullptr) InvalidateRect(surface->hwnd_, nullptr, FALSE);
    });
  });
  gdi->SetReadiness(readiness_, [weak] {
    RunOnUiThread([weak] {
      if (auto self = weak.lock()) self->OnStableOnUiThread();
    });
  });
  gdi->SetPoster(poster);
  gdi->SetIcon(icon);
  return gdi;
}

std::shared_ptr<D3DPresenter> Surface::presenter() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return presenter_;
}

void Surface::OnDeviceLost(HRESULT reason) {
  // A lost device gets a new one; a presenter that cannot show the picture
  // at all makes way for the GDI fallback.
  const bool use_d3d = reason != E_FAIL;
  std::weak_ptr<Surface> weak = weak_from_this();
  RunOnUiThread([weak, use_d3d] {
    if (auto self = weak.lock()) self->RecreatePresenterOnUiThread(use_d3d);
  });
}

void Surface::RecreatePresenterOnUiThread(bool use_d3d) {
  if (hwnd_ == nullptr) return;
  std::shared_ptr<D3DPresenter> old;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    old.swap(presenter_);
  }
  if (old != nullptr) old->Shutdown();
  old.reset();
  std::shared_ptr<D3DPresenter> presenter;
  std::shared_ptr<D3DDevice> device = use_d3d ? AcquireD3DDevice() : nullptr;
  if (device != nullptr) {
    presenter = std::make_shared<D3DPresenter>();
    PreparePresenter(presenter.get());
    std::weak_ptr<Surface> weak = weak_from_this();
    if (!presenter->Initialize(hwnd_, scale_, device, [weak](HRESULT reason) {
          if (auto self = weak.lock()) self->OnDeviceLost(reason);
        })) {
      presenter->Shutdown();
      presenter.reset();
    }
  }
  if (presenter == nullptr) {
    // A window that had a flip-model swap chain shows nothing GDI paints
    // into it: the GDI fallback gets a fresh window in the same place.
    ReplaceWindowOnUiThread();
  }
  std::shared_ptr<GdiPresenter> gdi;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    gdi = gdi_;
  }
  if (presenter == nullptr && gdi == nullptr) gdi = MakeGdiPresenter();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    presenter_ = presenter;
    if (presenter_ == nullptr) gdi_ = gdi;
  }
  if (!use_d3d) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    software_decode_ = true;
  }
  Log("surface %lld: presenter replaced (%s)", static_cast<long long>(id_), presenter != nullptr ? "D3D11" : "GDI");
  UpdateGdiTarget();
  OverlayChanged();
  InvalidateRect(hwnd_, nullptr, FALSE);
}

void Surface::ReplaceWindowOnUiThread() {
  HWND old = hwnd_;
  if (old == nullptr) return;
  WINDOWPLACEMENT placement = {sizeof(placement)};
  GetWindowPlacement(old, &placement);
  const bool visible = IsWindowVisible(old) != FALSE;
  const bool foreground = GetForegroundWindow() == old;
  wchar_t title[512] = {};
  GetWindowTextW(old, title, 512);
  HWND fresh = CreateWindowExW(kExStyle, kSurfaceClass, title, kStyle, CW_USEDEFAULT, CW_USEDEFAULT, 100, 100,
                               nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (fresh == nullptr) {
    Log("surface %lld: replacement window failed (%lu)", static_cast<long long>(id_), GetLastError());
    return;
  }
  SetWindowLongPtrW(old, GWLP_USERDATA, 0);
  SetTaskbarIdentity(old, id_, false);
  hwnd_ = fresh;
  SetWindowLongPtrW(fresh, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  SetTaskbarIdentity(fresh, id_, true);
  settle_started_ = -1;
  tracking_leave_ = false;
  // Its windows are owned by the window that goes.
  if (volume_control_ != nullptr) volume_control_->Attach(fresh, dpi_);
  ApplyDarkTitleBar();
  if (big_icon_ != nullptr) {
    SendMessageW(fresh, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small_icon_));
    SendMessageW(fresh, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big_icon_));
  }
  programmatic_resize_ = true;
  if (!visible) placement.showCmd = SW_HIDE;
  else if (!foreground && placement.showCmd == SW_SHOWNORMAL) placement.showCmd = SW_SHOWNOACTIVATE;
  SetWindowPlacement(fresh, &placement);
  programmatic_resize_ = false;
  if (foreground) SetForegroundWindow(fresh);
  DestroyWindow(old);
}

void Surface::StringsChangedOnUiThread() {
  if (volume_control_ != nullptr) volume_control_->StringsChanged();
}

void Surface::FocusOnUiThread() {
  if (hwnd_ == nullptr) return;
  if (IsIconic(hwnd_)) {
    ShowWindow(hwnd_, SW_RESTORE);
  } else if (!IsWindowVisible(hwnd_)) {
    ShowWindow(hwnd_, SW_SHOW);
  }
  SetForegroundWindow(hwnd_);
}

// ---------------------------------------------------------------- state from Dart

void Surface::SetTitle(std::wstring title) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    title_ = title;
  }
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    if (audio_ != nullptr) audio_->SetTitle(title);
  }
  std::weak_ptr<Surface> weak = weak_from_this();
  RunOnUiThread([weak, title] {
    auto self = weak.lock();
    if (self != nullptr && self->hwnd_ != nullptr) SetWindowTextW(self->hwnd_, title.c_str());
  });
}

OverlayState Surface::Overlay() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return overlay_;
}

void Surface::OverlayChanged() {
  OverlayState overlay;
  std::shared_ptr<D3DPresenter> presenter;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    overlay = overlay_;
    presenter = presenter_;
  }
  if (presenter != nullptr) {
    presenter->SetOverlay(overlay);
    return;
  }
  if (!repaint_posted_.exchange(true)) {
    std::weak_ptr<Surface> weak = weak_from_this();
    RunOnUiThread([weak] {
      auto self = weak.lock();
      if (self == nullptr) return;
      self->repaint_posted_ = false;
      if (self->hwnd_ != nullptr) InvalidateRect(self->hwnd_, nullptr, FALSE);
    });
  }
}

void Surface::SetVisual(int32_t visual, std::wstring message) {
  readiness_->OnVisual(visual, NowSeconds());
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    overlay_.visual = visual;
    overlay_.message = std::move(message);
  }
  OverlayChanged();
  if (visual != WSN_VISUAL_LIVE) {
    std::weak_ptr<Surface> weak = weak_from_this();
    RunOnUiThread([weak] {
      if (auto self = weak.lock()) self->ReleaseInput();
    });
  }
}

void Surface::SetHud(std::wstring text) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (overlay_.hud_text == text) return;
    overlay_.hud_text = std::move(text);
  }
  if (hud_) OverlayChanged();
}

void Surface::SetIcon(const uint8_t* png, int32_t length) {
  // The app's icon also stands in for the picture while it loads.
  std::shared_ptr<Poster> icon = DecodePoster(png, static_cast<size_t>(length), 256);
  Log("surface %lld: icon %dx%d (%d bytes)", static_cast<long long>(id_), icon ? icon->width : 0,
      icon ? icon->height : 0, length);
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    icon_png_.assign(png, png + length);
  }
  if (icon != nullptr) SetPlaceholderIcon(std::move(icon));
  std::weak_ptr<Surface> weak = weak_from_this();
  RunOnUiThread([weak] {
    if (auto self = weak.lock()) self->ApplyIcon();
  });
}

void Surface::ApplyIcon() {
  if (hwnd_ == nullptr) return;
  std::vector<uint8_t> png;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    png = icon_png_;
  }
  if (png.empty()) return;
  HICON small_icon = IconFromPng(png.data(), png.size(), GetSystemMetricsForDpi(SM_CXSMICON, dpi_));
  HICON big_icon = IconFromPng(png.data(), png.size(), GetSystemMetricsForDpi(SM_CXICON, dpi_));
  if (small_icon == nullptr || big_icon == nullptr) {
    if (small_icon != nullptr) DestroyIcon(small_icon);
    if (big_icon != nullptr) DestroyIcon(big_icon);
    Log("surface %lld: icon PNG could not be decoded", static_cast<long long>(id_));
    return;
  }
  SendMessageW(hwnd_, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small_icon));
  SendMessageW(hwnd_, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big_icon));
  if (small_icon_ != nullptr) DestroyIcon(small_icon_);
  if (big_icon_ != nullptr) DestroyIcon(big_icon_);
  small_icon_ = small_icon;
  big_icon_ = big_icon;
}

void Surface::ApplyDarkTitleBar() {
  if (hwnd_ == nullptr) return;
  BOOL dark = SystemUsesDarkApps() ? TRUE : FALSE;
  // DWMWA_USE_IMMERSIVE_DARK_MODE
  DwmSetWindowAttribute(hwnd_, 20, &dark, sizeof(dark));
}

// ---------------------------------------------------------------- media

void Surface::SetPlaceholderIcon(std::shared_ptr<const Poster> icon) {
  std::shared_ptr<D3DPresenter> presenter;
  std::shared_ptr<GdiPresenter> gdi;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    icon_ = icon;
    presenter = presenter_;
    gdi = gdi_;
  }
  if (presenter != nullptr) presenter->SetIcon(icon);
  if (gdi != nullptr) {
    std::weak_ptr<Surface> weak = weak_from_this();
    RunOnUiThread([weak, gdi, icon] {
      gdi->SetIcon(icon);
      auto self = weak.lock();
      if (self != nullptr && self->hwnd_ != nullptr) InvalidateRect(self->hwnd_, nullptr, FALSE);
    });
  }
}

void Surface::PushVideo(uint8_t* buffer, int32_t length, int64_t pts_us, int32_t flags) {
  Packet packet;
  packet.data.assign(buffer, buffer + length);
  packet.pts_us = pts_us;
  packet.flags = flags;
  std::free(buffer);
  int64_t dropped = 0;
  bool ask = false;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (stopping_) return;
    const bool is_config = (flags & WSN_PACKET_CONFIG) != 0;
    const bool is_key = (flags & WSN_PACKET_KEY) != 0;
    // Until the first picture is out (window, device and decoder warming
    // up) more may wait; after that latency is kept low.
    const size_t limit = steady_ ? kMaxQueued : kMaxQueuedStarting;
    if (is_config) {
      queue_.push_back(std::move(packet));
    } else if (is_key) {
      need_key_ = false;
      queue_.push_back(std::move(packet));
    } else if (need_key_) {
      // Nothing to decode it against: wait for the keyframe asked for.
      dropped = 1;
      ask = true;
    } else if (queue_.size() >= limit) {
      // Behind: what is queued is stale. Skip to the next keyframe.
      dropped = 1 + DropQueuedPicturesLocked();
      ask = true;
    } else {
      queue_.push_back(std::move(packet));
    }
  }
  if (dropped > 0) {
    std::lock_guard<std::mutex> lock(stats_mutex_);
    dropped_ += dropped;
  }
  if (ask) AskKeyframe();
  queue_cv_.notify_one();
}

// queue_mutex_ held. Keeps the newest parameter sets, drops the pictures
// and waits for a keyframe. Returns how many pictures were dropped.
int64_t Surface::DropQueuedPicturesLocked() {
  int64_t dropped = 0;
  std::deque<Packet> kept;
  for (Packet& queued : queue_) {
    if (queued.flags & WSN_PACKET_CONFIG) {
      kept.clear();
      kept.push_back(std::move(queued));
    } else {
      dropped++;
    }
  }
  queue_.swap(kept);
  need_key_ = true;
  return dropped;
}

void Surface::AskKeyframe() {
  // At most every 300 ms, as on macOS. Runs on a native thread already
  // (decode thread) or defers to the callback thread (export threads).
  const double now = NowSeconds();
  {
    std::lock_guard<std::mutex> lock(stats_mutex_);
    if (now - last_keyframe_ask_ < 0.3) return;
    last_keyframe_ask_ = now;
  }
  const int64_t id = id_;
  PostCallback([id] { EmitWindow(id, WSN_WINDOW_NEED_KEYFRAME); });
}

void Surface::ConfigureAudio(int sample_rate, int channels) {
  std::wstring title;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    title = title_;
  }
  // The window has sound: its volume control may show.
  std::weak_ptr<Surface> weak = weak_from_this();
  RunOnUiThread([weak] {
    auto self = weak.lock();
    if (self == nullptr) return;
    self->has_sound_ = true;
    if (self->volume_control_ != nullptr) self->volume_control_->SetAvailable();
  });
  std::unique_ptr<AudioOut> old;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    if (audio_ != nullptr && audio_->Matches(sample_rate, channels)) {
      // The same format again (resume, reconnect): keep the sound stream,
      // start a new timeline.
      audio_->Reset();
      return;
    }
    old = std::move(audio_);
    audio_ = std::make_unique<AudioOut>(sample_rate, channels, std::move(title), volume_);
  }
  // Closing one lets it play out its last few ms: never on the caller's thread.
  if (old != nullptr) std::thread([output = std::move(old)]() mutable { output.reset(); }).detach();
}

void Surface::SetVolume(double volume) {
  const double level = std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 1.0;
  ApplyVolume(level);
  std::weak_ptr<Surface> weak = weak_from_this();
  RunOnUiThread([weak, level] {
    auto self = weak.lock();
    if (self != nullptr && self->volume_control_ != nullptr) self->volume_control_->SetVolume(level);
  });
}

void Surface::ApplyVolume(double volume) {
  std::lock_guard<std::mutex> lock(audio_mutex_);
  volume_ = volume;
  if (audio_ != nullptr) audio_->SetVolume(volume);
}

void Surface::PushAudio(uint8_t* buffer, int32_t length, int64_t pts_us) {
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    if (audio_ != nullptr) audio_->Push(buffer, static_cast<size_t>(length), pts_us);
  }
  std::free(buffer);
}

size_t Surface::QueuedPackets() {
  std::lock_guard<std::mutex> lock(queue_mutex_);
  return queue_.size();
}

int32_t Surface::Stats(double* out, int32_t count) {
  double values[12] = {};
  size_t queued;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queued = queue_.size();
  }
  std::shared_ptr<D3DPresenter> presenter;
  std::shared_ptr<GdiPresenter> gdi;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    presenter = presenter_;
    gdi = gdi_;
  }
  D3DPresenter::Stats present = presenter != nullptr ? presenter->stats() : D3DPresenter::Stats{};
  bool hardware;
  {
    std::lock_guard<std::mutex> lock(stats_mutex_);
    values[0] = fps_;
    values[1] = static_cast<double>(dropped_);
    values[2] = decode_ms_;
    hardware = decoder_hardware_;
  }
  values[3] = static_cast<double>(queued);
  values[4] = presenter != nullptr ? static_cast<double>(present.presented)
                                   : (gdi != nullptr ? static_cast<double>(gdi->painted()) : 0);
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    if (audio_ != nullptr) audio_->Stats(values + 5);
  }
  // Beyond the shared nine (only when asked for): present latency ms,
  // pipeline (2 hardware decode + D3D11, 1 software decode + D3D11,
  // 0 software decode + GDI), frames replaced before they were shown.
  values[9] = present.latency_ms;
  values[10] = presenter != nullptr ? (hardware ? 2 : 1) : 0;
  values[11] = static_cast<double>(present.skipped);
  int32_t written = std::min<int32_t>(count, 12);
  for (int32_t i = 0; i < written; i++) out[i] = values[i];
  return written;
}

int32_t Surface::Snapshot(const char* path, int32_t max_edge) {
  std::wstring wide = Utf8ToWide(path);
  if (wide.empty()) return -1;
  std::shared_ptr<D3DPresenter> presenter;
  std::shared_ptr<GdiPresenter> gdi;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    presenter = presenter_;
    gdi = gdi_;
  }
  if (presenter != nullptr) return presenter->Snapshot(wide, max_edge);
  if (gdi != nullptr) return gdi->Snapshot(wide, max_edge);
  return -2;
}

void Surface::DecodeLoop() {
  ScopedCom com(COINIT_MULTITHREADED);
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
  const bool force_software = EnvFlag(L"WSN_FORCE_SW_DECODE");
  H264Decoder decoder;
  // The device the decoder runs on (null: software).
  std::shared_ptr<D3DDevice> decoder_device;
  {
    // Warm up while the window is being made.
    std::shared_ptr<D3DDevice> device = force_software ? nullptr : AcquireD3DDevice();
    if (decoder.Create(device != nullptr ? device->manager.Get() : nullptr)) {
      decoder_device = device;
      std::lock_guard<std::mutex> lock(stats_mutex_);
      decoder_hardware_ = decoder.hardware();
    }
  }
  WaitForSingleObject(ready_, 5000);
  int hardware_failures = 0;
  std::vector<uint8_t> config;
  double window_start = NowSeconds();
  int window_frames = 0;
  int last_width = 0;
  int last_height = 0;
  std::vector<DecodedFrame> frames;
  for (;;) {
    Packet packet;
    {
      std::unique_lock<std::mutex> lock(queue_mutex_);
      queue_cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
      if (stopping_) break;
      packet = std::move(queue_.front());
      queue_.pop_front();
      // Caught up with what queued while starting: from now on latency is
      // kept low.
      if (first_frame_seen_ && queue_.size() < 2) steady_ = true;
    }
    if (packet.flags & WSN_PACKET_CONFIG) {
      config = std::move(packet.data);
      continue;
    }
    const bool is_key = (packet.flags & WSN_PACKET_KEY) != 0;
    std::shared_ptr<D3DPresenter> presenter;
    std::shared_ptr<GdiPresenter> gdi;
    bool software;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      presenter = presenter_;
      gdi = gdi_;
      software = software_decode_;
    }
    // Decode on the presenter's device, in software without one.
    std::shared_ptr<D3DDevice> wanted =
        (presenter != nullptr && !force_software && !software) ? presenter->shared_device() : nullptr;
    if (!decoder.created() || wanted != decoder_device) {
      if (decoder.created() && !is_key) {
        // Another device (or none): start again from a keyframe.
        decoder.Release();
        decoder_device.reset();
        int64_t dropped;
        {
          std::lock_guard<std::mutex> lock(queue_mutex_);
          dropped = 1 + DropQueuedPicturesLocked();
        }
        {
          std::lock_guard<std::mutex> lock(stats_mutex_);
          dropped_ += dropped;
        }
        AskKeyframe();
        continue;
      }
      decoder.Release();
      if (!decoder.Create(wanted != nullptr ? wanted->manager.Get() : nullptr)) {
        const double now = NowSeconds();
        bool emit;
        {
          std::lock_guard<std::mutex> lock(stats_mutex_);
          emit = now - last_error_emit_ > 2;
          if (emit) last_error_emit_ = now;
        }
        if (emit) EmitWindow(id_, WSN_WINDOW_DECODE_ERROR, static_cast<double>(static_cast<int32_t>(E_FAIL)));
        std::lock_guard<std::mutex> lock(queue_mutex_);
        DropQueuedPicturesLocked();
        continue;
      }
      decoder_device = wanted;
      std::lock_guard<std::mutex> lock(stats_mutex_);
      decoder_hardware_ = decoder.hardware();
    }
    if (is_key && !config.empty()) {
      // The Microsoft decoder takes parameter sets in-band.
      packet.data.insert(packet.data.begin(), config.begin(), config.end());
    }
    const double started = NowSeconds();
    frames.clear();
    HRESULT hr = decoder.Decode(packet.data.data(), packet.data.size(), packet.pts_us, is_key, &frames);
    const double finished = NowSeconds();
    if (FAILED(hr)) {
      Log("surface %lld: decode failed (0x%08lx, %s)", static_cast<long long>(id_), hr,
          decoder.hardware() ? "hardware" : "software");
      const bool was_hardware = decoder.hardware();
      decoder.Release();
      decoder_device.reset();
      if (was_hardware && ++hardware_failures >= 3) {
        Log("surface %lld: hardware decoding keeps failing, using software", static_cast<long long>(id_));
        std::lock_guard<std::mutex> lock(state_mutex_);
        software_decode_ = true;
      }
      int64_t dropped;
      {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        dropped = 1 + DropQueuedPicturesLocked();
      }
      bool emit;
      {
        std::lock_guard<std::mutex> lock(stats_mutex_);
        dropped_ += dropped;
        emit = finished - last_error_emit_ > 1;
        if (emit) last_error_emit_ = finished;
      }
      if (emit) EmitWindow(id_, WSN_WINDOW_DECODE_ERROR, static_cast<double>(static_cast<int32_t>(hr)));
      AskKeyframe();
      continue;
    }
    if (!frames.empty()) hardware_failures = 0;
    if (++decode_count_ % 1800 == 0) {
      Log("surface %lld: decode %.1f ms (input %.1f, output %.1f), %zu queued", static_cast<long long>(id_),
          (finished - started) * 1000, decoder.input_ms(), decoder.output_ms(), QueuedPackets());
    }
    for (DecodedFrame& frame : frames) {
      const int width = frame.width();
      const int height = frame.height();
      bool first;
      {
        std::lock_guard<std::mutex> lock(stats_mutex_);
        decode_ms_ = (finished - started) * 1000.0;
        decoded_++;
        first = !first_frame_;
        first_frame_ = true;
        window_frames++;
        if (finished - window_start >= 1) {
          fps_ = window_frames / (finished - window_start);
          window_frames = 0;
          window_start = finished;
        }
      }
      readiness_->OnFrame(width, height, finished);
      if (finished - av_traced_at_ >= 2 && EnvFlag(L"WHISPER_WSN_TRACE")) {
        // Lip sync, for the log: how far the sound being heard trails the
        // picture just decoded (both pts are on the host's clock).
        av_traced_at_ = finished;
        int64_t heard = -1;
        {
          std::lock_guard<std::mutex> lock(audio_mutex_);
          if (audio_ != nullptr) heard = audio_->HeardPtsUs();
        }
        if (heard >= 0) {
          Log("surface %lld: sound %+.0f ms behind the picture", static_cast<long long>(id_),
              static_cast<double>(frame.pts_us - heard) / 1000);
        }
      }
      if (width != last_width || height != last_height) {
        last_width = width;
        last_height = height;
        VideoSizeChanged(width, height);
      }
      if (presenter != nullptr) {
        presenter->Submit(std::move(frame));
      } else if (gdi != nullptr && !frame.gpu()) {
        gdi->Submit(frame);
      }
      if (first) {
        first_frame_seen_ = true;
        Log("surface %lld: first frame %dx%d (%s decode, %s)", static_cast<long long>(id_), width, height,
            decoder.hardware() ? "hardware" : "software", presenter != nullptr ? "D3D11" : "GDI");
        EmitWindow(id_, WSN_WINDOW_FIRST_FRAME);
      }
    }
  }
  decoder.Release();
}

void Surface::VideoSizeChanged(int width, int height) {
  if (width <= 0 || height <= 0) return;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (video_width_ == width && video_height_ == height) return;
    video_width_ = width;
    video_height_ = height;
  }
  std::weak_ptr<Surface> weak = weak_from_this();
  RunOnUiThread([weak] {
    auto self = weak.lock();
    if (self == nullptr || self->hwnd_ == nullptr) return;
    self->UpdateGdiTarget();
    // A new picture: the other side answered, nothing to settle.
    if (self->reflow_) self->CancelSettle();
    // While the picture settles the window keeps its size; it follows once
    // the picture is stable (OnStableOnUiThread).
    if (self->readiness_->stable()) self->FollowVideoSizeOnUiThread();
  });
}

void Surface::FollowVideoSizeOnUiThread() {
  HWND hwnd = hwnd_;
  if (hwnd == nullptr) return;
  int width;
  int height;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    width = video_width_;
    height = video_height_;
  }
  if (width <= 0 || height <= 0) return;
  if (IsIconic(hwnd) || IsZoomed(hwnd) || in_size_move_) return;
  // Keep the window's height and centre, take the picture's shape (as
  // macOS does after a rotation or a display resize).
  RECT client;
  GetClientRect(hwnd, &client);
  if (client.bottom <= 0) return;
  // REFLOW: laid out for this window (near enough): it stays as it is.
  if (reflow_ && SameShape(client.right, client.bottom, width, height)) return;
  if (reflow_) CancelSettle();
  int new_height = client.bottom;
  int new_width = static_cast<int>(std::lround(static_cast<double>(new_height) * width / height));
  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {sizeof(info)};
  GetMonitorInfoW(monitor, &info);
  SIZE insets = FrameInsets();
  const int max_width = (info.rcWork.right - info.rcWork.left) - insets.cx;
  if (new_width > max_width) {
    new_width = max_width;
    new_height = static_cast<int>(std::lround(static_cast<double>(new_width) * height / width));
  }
  if (std::abs(new_width - client.right) <= 1 && std::abs(new_height - client.bottom) <= 1) return;
  RECT window;
  GetWindowRect(hwnd, &window);
  const int center = (window.left + window.right) / 2;
  const int frame_width = new_width + insets.cx;
  const int frame_height = new_height + insets.cy;
  int left = center - frame_width / 2;
  left = std::max<int>(info.rcWork.left, std::min<int>(left, info.rcWork.right - frame_width));
  programmatic_resize_ = true;
  SetWindowPos(hwnd, nullptr, left, window.top, frame_width, frame_height, SWP_NOZORDER | SWP_NOACTIVATE);
  programmatic_resize_ = false;
  // Following the picture is not the viewer resizing the window (macOS
  // does not report it either): no RESIZED for it, nor for a report still
  // pending from before.
  KillTimer(hwnd, kTimerResize);
  RECT now;
  GetClientRect(hwnd, &now);
  last_width_ = now.right / scale_;
  last_height_ = now.bottom / scale_;
  last_scale_ = scale_;
  UpdateGdiTarget();
}

void Surface::CancelSettle() {
  settle_started_ = -1;
  if (hwnd_ == nullptr) return;
  KillTimer(hwnd_, kTimerSettle);
  KillTimer(hwnd_, kTimerSettleStep);
}

// The picture kept its shape after the user resized: the window takes it,
// one side shrinking around the window's centre so the picture fits the
// frame, and reports the size it settled at.
void Surface::SettleOnUiThread() {
  HWND hwnd = hwnd_;
  if (hwnd == nullptr || IsIconic(hwnd) || IsZoomed(hwnd) || in_size_move_) return;
  int width;
  int height;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    width = video_width_;
    height = video_height_;
  }
  RECT client;
  GetClientRect(hwnd, &client);
  if (width <= 0 || height <= 0 || client.right <= 0 || client.bottom <= 0) return;
  if (SameShape(client.right, client.bottom, width, height)) return;
  const RECT fit = LetterboxRect(client.right, client.bottom, width, height);
  int new_width = fit.right - fit.left;
  int new_height = fit.bottom - fit.top;
  const double min_content = kMinContent * scale_;
  if (new_width < min_content || new_height < min_content) {
    const double grow = std::max(min_content / std::max(1, new_width), min_content / std::max(1, new_height));
    new_width = static_cast<int>(std::lround(new_width * grow));
    new_height = static_cast<int>(std::lround(new_height * grow));
  }
  const SIZE insets = FrameInsets();
  RECT window;
  GetWindowRect(hwnd, &window);
  const int frame_width = new_width + insets.cx;
  const int frame_height = new_height + insets.cy;
  const int left = (window.left + window.right) / 2 - frame_width / 2;
  const int top = (window.top + window.bottom) / 2 - frame_height / 2;
  settle_from_ = window;
  settle_to_ = {left, top, left + frame_width, top + frame_height};
  Log("surface %lld: settling %ldx%ld to the picture's shape %dx%d", static_cast<long long>(id_), client.right,
      client.bottom, new_width, new_height);
  settle_started_ = ClientAreaAnimations() ? NowSeconds() : NowSeconds() - kSettleSeconds;
  if (volume_control_ != nullptr) volume_control_->OwnerBusy();
  SetTimer(hwnd, kTimerSettleStep, 10, nullptr);
  SettleStep();
}

void Surface::SettleStep() {
  if (hwnd_ == nullptr || settle_started_ < 0) return;
  const double t = std::clamp((NowSeconds() - settle_started_) / kSettleSeconds, 0.0, 1.0);
  const double eased = 1 - std::pow(1 - t, 3);
  auto mix = [eased](LONG from, LONG to) {
    return static_cast<int>(std::lround(from + (to - from) * eased));
  };
  const int left = mix(settle_from_.left, settle_to_.left);
  const int top = mix(settle_from_.top, settle_to_.top);
  const int right = mix(settle_from_.right, settle_to_.right);
  const int bottom = mix(settle_from_.bottom, settle_to_.bottom);
  programmatic_resize_ = true;
  SetWindowPos(hwnd_, nullptr, left, top, right - left, bottom - top, SWP_NOZORDER | SWP_NOACTIVATE);
  programmatic_resize_ = false;
  if (t < 1) return;
  KillTimer(hwnd_, kTimerSettleStep);
  settle_started_ = -1;
  KillTimer(hwnd_, kTimerResize);
  // As any resize: the other side lays the window out for this size.
  EmitResizedIfChanged();
}

// ---------------------------------------------------------------- window

SIZE Surface::FrameInsets() {
  RECT frame = {0, 0, 0, 0};
  AdjustWindowRectExForDpi(&frame, kStyle, FALSE, kExStyle, dpi_);
  return {frame.right - frame.left, frame.bottom - frame.top};
}

void Surface::SetVisible(bool visible) {
  if (visible_ == visible) return;
  visible_ = visible;
  EmitWindow(id_, WSN_WINDOW_VISIBILITY, visible ? 1 : 0);
}

void Surface::ScheduleResized() {
  if (programmatic_resize_) return;
  const double now = NowSeconds();
  if (in_size_move_ && now - last_resized_at_ > kResizeMaxInterval) {
    EmitResizedIfChanged();
  }
  SetTimer(hwnd_, kTimerResize, kResizeSettleMs, nullptr);
}

void Surface::EmitResizedIfChanged() {
  if (hwnd_ == nullptr || IsIconic(hwnd_)) return;
  RECT client;
  GetClientRect(hwnd_, &client);
  if (client.right <= 0 || client.bottom <= 0) return;
  const double width = client.right / scale_;
  const double height = client.bottom / scale_;
  last_resized_at_ = NowSeconds();
  if (std::fabs(width - last_width_) < 0.5 && std::fabs(height - last_height_) < 0.5 && scale_ == last_scale_) {
    return;
  }
  last_width_ = width;
  last_height_ = height;
  last_scale_ = scale_;
  EmitWindow(id_, WSN_WINDOW_RESIZED, std::round(width * 100) / 100, std::round(height * 100) / 100, scale_);
}

void Surface::UpdateGdiTarget() {
  std::shared_ptr<GdiPresenter> gdi;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    gdi = gdi_;
  }
  if (gdi == nullptr || hwnd_ == nullptr) return;
  RECT rect = VideoRect();
  gdi->SetTargetSize(rect.right - rect.left, rect.bottom - rect.top);
}

RECT Surface::VideoRect() {
  RECT client;
  GetClientRect(hwnd_, &client);
  int width;
  int height;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    width = video_width_;
    height = video_height_;
  }
  return LetterboxRect(client.right, client.bottom, width, height);
}

bool Surface::Normalized(int px, int py, bool clamp, double* x, double* y) {
  RECT rect = VideoRect();
  if (rect.right <= rect.left || rect.bottom <= rect.top) return false;
  if (!clamp && (px < rect.left || px >= rect.right || py < rect.top || py >= rect.bottom)) return false;
  *x = std::clamp(static_cast<double>(px - rect.left) / (rect.right - rect.left), 0.0, 1.0);
  *y = std::clamp(static_cast<double>(py - rect.top) / (rect.bottom - rect.top), 0.0, 1.0);
  return true;
}

void Surface::SendPointer(int32_t kind, int32_t button, int px, int py) {
  double x = 0;
  double y = 0;
  if (Normalized(px, py, true, &x, &y)) {
    EmitInput(id_, kind, button, CurrentModifiers(), x, y, 0, 0, 0, nullptr);
  }
}

void Surface::QueueMove(int px, int py) {
  pending_move_ = {px, py};
  move_pending_ = true;
  const double now = NowSeconds();
  const double wait = kMoveInterval - (now - last_move_sent_);
  if (wait <= 0) {
    FlushMove();
  } else {
    SetTimer(hwnd_, kTimerMove, std::max<UINT>(1, static_cast<UINT>(std::ceil(wait * 1000))), nullptr);
  }
}

void Surface::FlushMove() {
  KillTimer(hwnd_, kTimerMove);
  if (!move_pending_) return;
  move_pending_ = false;
  last_move_sent_ = NowSeconds();
  // -1: no button held (hover).
  SendPointer(WSN_INPUT_POINTER_MOVE, pressed_button_ >= 0 ? pressed_button_ : -1, pending_move_.x, pending_move_.y);
}

void Surface::ReleaseInput() {
  if (hwnd_ == nullptr) return;
  move_pending_ = false;
  KillTimer(hwnd_, kTimerMove);
  if (pressed_button_ >= 0) {
    int32_t button = pressed_button_;
    pressed_button_ = -1;
    if (GetCapture() == hwnd_) ReleaseCapture();
    SendPointer(WSN_INPUT_POINTER_CANCEL, button, last_pointer_.x, last_pointer_.y);
  }
  for (int32_t mac : keys_down_) {
    EmitInput(id_, WSN_INPUT_KEY_UP, mac, 0, 0, 0, 0, 0, 0, nullptr);
  }
  keys_down_.clear();
  pending_key_ = {};
  high_surrogate_ = 0;
}

void Surface::UpdateImeWindow() {
  if (hwnd_ == nullptr) return;
  HIMC context = ImmGetContext(hwnd_);
  if (context == nullptr) return;
  RECT video = VideoRect();
  POINT anchor;
  if (last_click_.x >= 0) {
    // Where the user last clicked, most likely the field being typed into.
    anchor = last_click_;
  } else {
    // Low in the middle of the picture, as on macOS.
    anchor = {(video.left + video.right) / 2 - static_cast<LONG>(120 * scale_),
              video.bottom - static_cast<LONG>(78 * scale_)};
  }
  const LONG line = static_cast<LONG>(22 * scale_);
  COMPOSITIONFORM composition = {};
  composition.dwStyle = CFS_POINT;
  composition.ptCurrentPos = {anchor.x, anchor.y - line / 2};
  ImmSetCompositionWindow(context, &composition);
  CANDIDATEFORM candidate = {};
  candidate.dwIndex = 0;
  candidate.dwStyle = CFS_EXCLUDE;
  candidate.ptCurrentPos = {anchor.x, anchor.y + line / 2};
  candidate.rcArea = {anchor.x, anchor.y - line / 2, anchor.x + 1, anchor.y + line / 2};
  ImmSetCandidateWindow(context, &candidate);
  ImmReleaseContext(hwnd_, context);
}

// ---------------------------------------------------------------- keyboard

void Surface::SendKeyDown(int32_t mac, int32_t modifiers, bool repeat, const std::wstring& characters) {
  keys_down_.insert(mac);
  std::string text = WideToUtf8(characters);
  EmitInput(id_, WSN_INPUT_KEY_DOWN, mac, modifiers, 0, 0, 0, 0, repeat ? 1 : 0, text.empty() ? nullptr : &text);
}

void Surface::SendText(const std::wstring& text, bool paste) {
  if (text.empty()) return;
  std::string utf8 = WideToUtf8(text);
  EmitInput(id_, WSN_INPUT_TEXT, paste ? 1 : 0, 0, 0, 0, 0, 0, 0, &utf8);
}

void Surface::Paste() {
  if (!OpenClipboard(hwnd_)) return;
  HANDLE data = GetClipboardData(CF_UNICODETEXT);
  if (data != nullptr) {
    auto* text = static_cast<const wchar_t*>(GlobalLock(data));
    if (text != nullptr) {
      SendText(std::wstring(text), true);
      GlobalUnlock(data);
    }
  }
  CloseClipboard();
}

// Returns true when the message was handled (*result is the reply).
bool Surface::OnKey(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result) {
  const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
  const bool system = message == WM_SYSKEYDOWN || message == WM_SYSKEYUP;
  const bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
  // Alt+F4 closes this window, Alt+Space opens its system menu.
  if (system && alt && (wparam == VK_F4 || wparam == VK_SPACE)) return false;
  *result = 0;
  const bool live = Overlay().visual == WSN_VISUAL_LIVE;
  if (!down) {
    const int32_t mac = MacKeyFromMessage(wparam, lparam);
    if (mac >= 0 && keys_down_.erase(mac) > 0) {
      int32_t modifiers = CurrentModifiers();
      if (modifiers & WSN_MOD_CONTROL) modifiers = (modifiers & ~WSN_MOD_CONTROL) | WSN_MOD_COMMAND;
      EmitInput(id_, WSN_INPUT_KEY_UP, mac, modifiers, 0, 0, 0, 0, 0, nullptr);
    }
    return true;  // also keeps Alt / F10 from opening the menu
  }
  if (!live) return true;
  if (wparam == VK_PROCESSKEY) {
    // The input method has it; committed text follows.
    return false;
  }
  if (wparam == VK_PACKET) return true;  // text arrives as WM_CHAR
  if (IsModifierKey(wparam)) return true;
  if (NowSeconds() - ime_echo_at_ > 0.5) ime_echo_.clear();
  pending_key_ = {};
  const bool repeat = (lparam & 0x40000000) != 0;
  const bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
  const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
  const bool win = ((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) != 0;
  int32_t modifiers = CurrentModifiers();
  if (wparam == 'V' && ctrl && !shift && !alt && !win) {
    if (!repeat) Paste();
    return true;
  }
  const int32_t mac = MacKeyFromMessage(wparam, lparam);
  if (mac < 0) return false;
  const UINT scan = static_cast<UINT>((lparam >> 16) & 0xFF) | (((lparam >> 24) & 1) ? 0xE000 : 0);
  std::wstring typed;
  const int typed_count = TypedCharacters(static_cast<UINT>(wparam), scan, &typed);
  const bool printable = typed_count > 0 && typed[0] >= 0x20 && typed[0] != 0x7f;
  const bool alt_gr = ctrl && alt && printable;
  if ((ctrl || alt || win) && !alt_gr) {
    // A shortcut: the key itself, Ctrl as Command (sources see one
    // convention), with what it types unmodified.
    if (ctrl) modifiers = (modifiers & ~WSN_MOD_CONTROL) | WSN_MOD_COMMAND;
    SendKeyDown(mac, modifiers, repeat, KeyCharacters(static_cast<UINT>(wparam), scan));
    return true;
  }
  if (typed_count < 0) return true;  // a dead key: what it composes comes as WM_CHAR
  if (printable) {
    // Decided on WM_CHAR, which TranslateMessage already queued.
    pending_key_ = {mac, modifiers & ~(WSN_MOD_CONTROL | WSN_MOD_OPTION), repeat, true};
    if (alt_gr) pending_key_.mac = -1;  // always text
    return true;
  }
  // Return, Tab, Backspace, Escape, arrows, F-keys…
  std::wstring characters = typed_count > 0 ? typed : std::wstring();
  SendKeyDown(mac, modifiers, repeat, characters);
  return true;
}

void Surface::OnChar(wchar_t character) {
  if (character >= 0xD800 && character <= 0xDBFF) {
    high_surrogate_ = character;
    return;
  }
  std::wstring text;
  if (character >= 0xDC00 && character <= 0xDFFF) {
    if (high_surrogate_ == 0) return;
    text.push_back(high_surrogate_);
    text.push_back(character);
    high_surrogate_ = 0;
  } else {
    high_surrogate_ = 0;
    if (character < 0x20 || character == 0x7f) {
      pending_key_ = {};
      return;
    }
    text.push_back(character);
  }
  // Committed input method text was already sent; this is its echo.
  if (!ime_echo_.empty() && ime_echo_.compare(0, text.size(), text) == 0) {
    ime_echo_.erase(0, text.size());
    return;
  }
  PendingKey key = pending_key_;
  pending_key_ = {};
  if (key.active && key.mac >= 0 && text.size() == 1) {
    // A plain keystroke stays a key (games and shortcuts keep working) when
    // the key means the same thing on a US layout; anything else is text.
    const bool shift = (key.modifiers & WSN_MOD_SHIFT) != 0;
    const bool caps = (key.modifiers & WSN_MOD_CAPS_LOCK) != 0;
    if (UsCharacter(key.mac, shift, caps) == text[0]) {
      SendKeyDown(key.mac, key.modifiers, key.repeat, text);
      return;
    }
  }
  SendText(text, false);
}

// ---------------------------------------------------------------- messages

LRESULT Surface::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_PAINT: {
      std::shared_ptr<D3DPresenter> presenter;
      std::shared_ptr<GdiPresenter> gdi;
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        presenter = presenter_;
        gdi = gdi_;
      }
      if (presenter != nullptr) {
        ValidateRect(hwnd_, nullptr);
        presenter->Redraw();
      } else if (gdi != nullptr) {
        if (gdi->Paint(hwnd_, Overlay(), scale_)) {
          SetTimer(hwnd_, kTimerAnimate, 15, nullptr);
        } else {
          KillTimer(hwnd_, kTimerAnimate);
        }
      } else {
        ValidateRect(hwnd_, nullptr);
      }
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_CLOSE:
      ReleaseInput();
      CancelSettle();
      if (volume_control_ != nullptr) volume_control_->OwnerBusy();
      EmitWindow(id_, WSN_WINDOW_CLOSE_REQUESTED);
      ShowWindow(hwnd_, SW_HIDE);
      SetVisible(false);
      return 0;
    case WM_ACTIVATE: {
      const bool active = LOWORD(wparam) != WA_INACTIVE;
      if (!active) ReleaseInput();
      if (active != active_) {
        active_ = active;
        EmitWindow(id_, WSN_WINDOW_FOCUS, active ? 1 : 0);
      }
      break;
    }
    case WM_SHOWWINDOW:
      if (wparam == FALSE) {
        SetVisible(false);
        if (volume_control_ != nullptr) volume_control_->OwnerBusy();
      }
      break;
    case WM_MOVE:
      if (volume_control_ != nullptr) volume_control_->OwnerMoved();
      break;
    case WM_SIZE: {
      if (wparam == SIZE_MINIMIZED) {
        SetVisible(false);
        if (volume_control_ != nullptr) volume_control_->OwnerBusy();
        return 0;
      }
      if (in_size_move_) resized_in_move_ = true;
      if (volume_control_ != nullptr) volume_control_->OwnerMoved();
      SetVisible(IsWindowVisible(hwnd_) != FALSE);
      std::shared_ptr<D3DPresenter> presenter = this->presenter();
      if (presenter != nullptr) {
        presenter->Resize();
      } else {
        UpdateGdiTarget();
        InvalidateRect(hwnd_, nullptr, FALSE);
      }
      ScheduleResized();
      return 0;
    }
    case WM_ENTERSIZEMOVE:
      in_size_move_ = true;
      resized_in_move_ = false;
      CancelSettle();
      if (volume_control_ != nullptr) volume_control_->OwnerBusy();
      break;
    case WM_EXITSIZEMOVE:
      in_size_move_ = false;
      KillTimer(hwnd_, kTimerResize);
      EmitResizedIfChanged();
      // REFLOW: the other side has a moment to lay the window out for its
      // new size; if the picture keeps its shape, the window takes it.
      if (reflow_ && resized_in_move_) SetTimer(hwnd_, kTimerSettle, kSettleDelayMs, nullptr);
      resized_in_move_ = false;
      break;
    case WM_TIMER:
      if (wparam == kTimerResize) {
        KillTimer(hwnd_, kTimerResize);
        EmitResizedIfChanged();
        return 0;
      }
      if (wparam == kTimerMove) {
        FlushMove();
        return 0;
      }
      if (wparam == kTimerAnimate) {
        InvalidateRect(hwnd_, nullptr, FALSE);
        return 0;
      }
      if (wparam == kTimerSettle) {
        KillTimer(hwnd_, kTimerSettle);
        SettleOnUiThread();
        return 0;
      }
      if (wparam == kTimerSettleStep) {
        SettleStep();
        return 0;
      }
      break;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      SIZE insets = FrameInsets();
      info->ptMinTrackSize.x = static_cast<LONG>(kMinContent * scale_) + insets.cx;
      info->ptMinTrackSize.y = static_cast<LONG>(kMinContent * scale_) + insets.cy;
      return 0;
    }
    case WM_SIZING: {
      // REFLOW: any shape (the picture letterboxes until it follows).
      if (reflow_) break;
      int width;
      int height;
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        width = video_width_;
        height = video_height_;
      }
      if (width <= 0 || height <= 0) break;
      // Keep the picture's shape (macOS: contentAspectRatio).
      auto* rect = reinterpret_cast<RECT*>(lparam);
      SIZE insets = FrameInsets();
      const double aspect = static_cast<double>(width) / height;
      const double min_content = kMinContent * scale_;
      double content_width = std::max<double>(min_content, (rect->right - rect->left) - insets.cx);
      double content_height = std::max<double>(min_content, (rect->bottom - rect->top) - insets.cy);
      if (wparam == WMSZ_TOP || wparam == WMSZ_BOTTOM) {
        content_width = content_height * aspect;
      } else {
        content_height = content_width / aspect;
      }
      if (content_width < min_content) {
        content_width = min_content;
        content_height = content_width / aspect;
      }
      if (content_height < min_content) {
        content_height = min_content;
        content_width = content_height * aspect;
      }
      const LONG frame_width = static_cast<LONG>(std::lround(content_width)) + insets.cx;
      const LONG frame_height = static_cast<LONG>(std::lround(content_height)) + insets.cy;
      switch (wparam) {
        case WMSZ_LEFT:
        case WMSZ_TOPLEFT:
        case WMSZ_BOTTOMLEFT:
          rect->left = rect->right - frame_width;
          break;
        default:
          rect->right = rect->left + frame_width;
          break;
      }
      switch (wparam) {
        case WMSZ_TOP:
        case WMSZ_TOPLEFT:
        case WMSZ_TOPRIGHT:
          rect->top = rect->bottom - frame_height;
          break;
        default:
          rect->bottom = rect->top + frame_height;
          break;
      }
      return TRUE;
    }
    case WM_DPICHANGED: {
      dpi_ = HIWORD(wparam);
      scale_ = dpi_ / 96.0;
      if (volume_control_ != nullptr) volume_control_->SetDpi(dpi_);
      auto* suggested = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd_, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                   suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
      if (std::shared_ptr<D3DPresenter> presenter = this->presenter()) presenter->SetScale(scale_);
      InvalidateRect(hwnd_, nullptr, FALSE);
      ApplyIcon();
      EmitResizedIfChanged();
      return 0;
    }
    case WM_SETTINGCHANGE:
      if (lparam != 0 && std::wcscmp(reinterpret_cast<const wchar_t*>(lparam), L"ImmersiveColorSet") == 0) {
        ApplyDarkTitleBar();
      }
      break;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN: {
      const int32_t button = message == WM_LBUTTONDOWN ? 0 : (message == WM_RBUTTONDOWN ? 1 : 2);
      const int32_t visual = Overlay().visual;
      if (visual == WSN_VISUAL_PAUSED || visual == WSN_VISUAL_DISPLACED) {
        EmitWindow(id_, WSN_WINDOW_ACTION, visual == WSN_VISUAL_PAUSED ? 1 : 2);
        return 0;
      }
      const int px = GET_X_LPARAM(lparam);
      const int py = GET_Y_LPARAM(lparam);
      double x;
      double y;
      // Nothing to aim at while the placeholder covers the picture.
      if (visual != WSN_VISUAL_LIVE || pressed_button_ >= 0 || !readiness_->stable() ||
          !Normalized(px, py, false, &x, &y)) {
        return 0;
      }
      FlushMove();
      SetCapture(hwnd_);
      pressed_button_ = button;
      last_pointer_ = {px, py};
      last_click_ = {px, py};
      // A drag in the app: the volume button steps aside.
      if (volume_control_ != nullptr) volume_control_->OwnerBusy();
      SendPointer(WSN_INPUT_POINTER_DOWN, button, px, py);
      return 0;
    }
    case WM_MOUSEMOVE: {
      if (!tracking_leave_) {
        TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, hwnd_, 0};
        tracking_leave_ = TrackMouseEvent(&track) != FALSE;
      }
      const int px = GET_X_LPARAM(lparam);
      const int py = GET_Y_LPARAM(lparam);
      if (px == last_pointer_.x && py == last_pointer_.y) return 0;
      last_pointer_ = {px, py};
      // The pointer moving over the window brings the volume button (when
      // the window has sound); it is a window of its own, so what the
      // pointer does over it never arrives here.
      if (volume_control_ != nullptr && pressed_button_ < 0) volume_control_->OwnerPointerMoved();
      if (Overlay().visual != WSN_VISUAL_LIVE) return 0;
      double x;
      double y;
      if (pressed_button_ >= 0) {
        QueueMove(px, py);  // drag
      } else if (active_ && readiness_->stable() && Normalized(px, py, false, &x, &y)) {
        QueueMove(px, py);  // hover, while this window is the one in use
      }
      return 0;
    }
    case WM_LBUTTONUP:
    case WM_RBUTTONUP:
    case WM_MBUTTONUP: {
      const int32_t button = message == WM_LBUTTONUP ? 0 : (message == WM_RBUTTONUP ? 1 : 2);
      if (pressed_button_ != button) return 0;
      const int px = GET_X_LPARAM(lparam);
      const int py = GET_Y_LPARAM(lparam);
      if (move_pending_) pending_move_ = {px, py};
      FlushMove();
      pressed_button_ = -1;
      ReleaseCapture();
      SendPointer(WSN_INPUT_POINTER_UP, button, px, py);
      return 0;
    }
    case WM_MOUSELEAVE:
      tracking_leave_ = false;
      if (volume_control_ != nullptr) volume_control_->OwnerPointerLeft();
      return 0;
    case WM_CAPTURECHANGED:
      if (pressed_button_ >= 0 && reinterpret_cast<HWND>(lparam) != hwnd_) {
        const int32_t button = pressed_button_;
        pressed_button_ = -1;
        move_pending_ = false;
        SendPointer(WSN_INPUT_POINTER_CANCEL, button, last_pointer_.x, last_pointer_.y);
      }
      return 0;
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL: {
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      // Over the volume button (wheel messages go to the focused window
      // when inactive windows are not scrolled): the volume, not the app.
      if (message == WM_MOUSEWHEEL && volume_control_ != nullptr &&
          volume_control_->Wheel(point, GET_WHEEL_DELTA_WPARAM(wparam))) {
        return 0;
      }
      if (Overlay().visual != WSN_VISUAL_LIVE || !readiness_->stable()) return 0;
      ScreenToClient(hwnd_, &point);
      double x = 0;
      double y = 0;
      if (!Normalized(point.x, point.y, true, &x, &y)) return 0;
      FlushMove();
      // Lines (fractions from high-resolution wheels and touchpads);
      // positive dy moves content down, as NSEvent's scrollingDeltaY.
      const double lines = GET_WHEEL_DELTA_WPARAM(wparam) / static_cast<double>(WHEEL_DELTA);
      EmitInput(id_, WSN_INPUT_SCROLL, 0, CurrentModifiers(), x, y, message == WM_MOUSEHWHEEL ? -lines : 0,
                message == WM_MOUSEWHEEL ? lines : 0, 0, nullptr);
      return 0;
    }
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYUP: {
      LRESULT result = 0;
      if (OnKey(message, wparam, lparam, &result)) return result;
      break;
    }
    case WM_CHAR:
      if (Overlay().visual == WSN_VISUAL_LIVE) OnChar(static_cast<wchar_t>(wparam));
      return 0;
    case WM_SYSCHAR:
    case WM_DEADCHAR:
    case WM_SYSDEADCHAR:
      return 0;
    case WM_SYSCOMMAND:
      // Alt or F10 alone would open the (empty) menu and swallow keys.
      if ((wparam & 0xFFF0) == SC_KEYMENU && lparam == 0) return 0;
      break;
    case WM_IME_STARTCOMPOSITION:
      UpdateImeWindow();
      break;
    case WM_IME_COMPOSITION:
      if ((lparam & GCS_RESULTSTR) && Overlay().visual == WSN_VISUAL_LIVE) {
        HIMC context = ImmGetContext(hwnd_);
        if (context != nullptr) {
          LONG bytes = ImmGetCompositionStringW(context, GCS_RESULTSTR, nullptr, 0);
          if (bytes > 0) {
            std::wstring text(static_cast<size_t>(bytes) / sizeof(wchar_t), L'\0');
            ImmGetCompositionStringW(context, GCS_RESULTSTR, text.data(), static_cast<DWORD>(bytes));
            SendText(text, false);
            ime_echo_ += text;
            ime_echo_at_ = NowSeconds();
          }
          ImmReleaseContext(hwnd_, context);
        }
      }
      UpdateImeWindow();
      break;  // DefWindowProc keeps the input method's own window up to date
    case WM_IME_CHAR: {
      // Committed text was sent from WM_IME_COMPOSITION; anything else an
      // input method types this way is sent here. Never passed on, so no
      // WM_CHAR copy follows.
      const wchar_t character = static_cast<wchar_t>(wparam);
      if (!ime_echo_.empty() && ime_echo_[0] == character) {
        ime_echo_.erase(0, 1);
      } else if (Overlay().visual == WSN_VISUAL_LIVE) {
        OnChar(character);
      }
      return 0;
    }
    default:
      break;
  }
  return DefWindowProcW(hwnd_, message, wparam, lparam);
}

// ---------------------------------------------------------------- registry

int64_t AddSurface(const std::wstring& title, int width, int height, int32_t flags) {
  EnsureUiThread();
  int64_t id = g_next_id++;
  auto surface = std::make_shared<Surface>(id, title, width, height, (flags & WSN_FLAG_SHOW_HUD) != 0,
                                          (flags & WSN_FLAG_REFLOW) != 0);
  {
    std::lock_guard<std::mutex> lock(g_surfaces_mutex);
    g_surfaces[id] = surface;
  }
  surface->Start();
  return id;
}

std::shared_ptr<Surface> FindSurface(int64_t id) {
  std::lock_guard<std::mutex> lock(g_surfaces_mutex);
  auto it = g_surfaces.find(id);
  return it == g_surfaces.end() ? nullptr : it->second;
}

void RefreshSurfaceStrings() {
  std::vector<std::shared_ptr<Surface>> all;
  {
    std::lock_guard<std::mutex> lock(g_surfaces_mutex);
    for (auto& entry : g_surfaces) all.push_back(entry.second);
  }
  for (std::shared_ptr<Surface>& surface : all) {
    RunOnUiThread([surface] { surface->StringsChangedOnUiThread(); });
  }
}

void DestroySurface(int64_t id) {
  std::shared_ptr<Surface> target;
  {
    std::lock_guard<std::mutex> lock(g_surfaces_mutex);
    auto it = g_surfaces.find(id);
    if (it == g_surfaces.end()) return;
    target = it->second;
    g_surfaces.erase(it);
  }
  target->Stop();
  RunOnUiThread([target] { target->DestroyWindowOnUiThread(); });
}

void DestroyAllSurfaces() {
  std::map<int64_t, std::shared_ptr<Surface>> all;
  {
    std::lock_guard<std::mutex> lock(g_surfaces_mutex);
    all.swap(g_surfaces);
  }
  for (auto& entry : all) {
    entry.second->Stop();
    std::shared_ptr<Surface> target = entry.second;
    RunOnUiThread([target] { target->DestroyWindowOnUiThread(); });
  }
}

}  // namespace wsn
