#include "volume_control.h"

#include <commctrl.h>
#include <d2d1.h>
#include <dwmapi.h>
#include <dwrite.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>

#include "../common/com.h"
#include "ui_strings.h"

namespace wsn {
namespace {

constexpr wchar_t kButtonClass[] = L"WhisperWindowStreamVolume";
constexpr wchar_t kPopupClass[] = L"WhisperWindowStreamVolumePopup";
constexpr wchar_t kChildProcProp[] = L"WhisperVolumeChildProc";
constexpr UINT_PTR kTimerFade = 1;
constexpr UINT_PTR kTimerIdle = 2;
constexpr UINT_PTR kTimerReport = 3;
constexpr UINT kFadeTickMs = 15;
constexpr double kFadeSeconds = 0.12;
// The button goes once the pointer has rested this long (not over it).
constexpr UINT kIdleMs = 2000;
// Reports to Dart while a change goes on: at most ten a second.
constexpr double kReportInterval = 0.1;
constexpr double kButtonDips = 32;
constexpr double kInsetDips = 10;
constexpr double kGlyphDips = 15;
constexpr double kPopupWidthDips = 248;
constexpr double kPopupHeightDips = 48;
constexpr double kWheelStep = 0.05;
constexpr int kMuteId = 1;
constexpr int kSliderId = 2;
// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (10) share these.
constexpr wchar_t kGlyphVolume = 0xE767;
constexpr wchar_t kGlyphMute = 0xE74F;

bool SystemUsesDarkApps() {
  DWORD value = 1;
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                   L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) {
    return false;
  }
  return value == 0;
}

bool Animations() {
  BOOL enabled = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0);
  return enabled != FALSE;
}

// Common Controls 6 (the themed trackbar, buttons and tooltips) without a
// manifest of our own: shell32's manifest asks for them.
HANDLE CommonControlsContext() {
  static HANDLE context = [] {
    wchar_t path[MAX_PATH] = {};
    const UINT length = GetSystemDirectoryW(path, MAX_PATH);
    if (length == 0 || length + 16 >= MAX_PATH) return INVALID_HANDLE_VALUE;
    wcscat_s(path, L"\\shell32.dll");
    ACTCTXW act = {};
    act.cbSize = sizeof(act);
    act.dwFlags = ACTCTX_FLAG_RESOURCE_NAME_VALID;
    act.lpSource = path;
    act.lpResourceName = MAKEINTRESOURCEW(124);
    return CreateActCtxW(&act);
  }();
  return context;
}

class ScopedCommonControls {
 public:
  ScopedCommonControls() {
    HANDLE context = CommonControlsContext();
    active_ = context != INVALID_HANDLE_VALUE && ActivateActCtx(context, &cookie_) != FALSE;
    static bool initialized = false;
    if (!initialized) {
      INITCOMMONCONTROLSEX init = {sizeof(init), ICC_BAR_CLASSES | ICC_STANDARD_CLASSES};
      initialized = InitCommonControlsEx(&init) != FALSE;
    }
  }
  ~ScopedCommonControls() {
    if (active_) DeactivateActCtx(0, cookie_);
  }
  ScopedCommonControls(const ScopedCommonControls&) = delete;
  ScopedCommonControls& operator=(const ScopedCommonControls&) = delete;

 private:
  ULONG_PTR cookie_ = 0;
  bool active_ = false;
};

// Direct2D and DirectWrite for the button's face (UI thread, leaked on
// purpose like the other process-wide state here).
struct Graphics {
  ComPtr<ID2D1Factory> d2d;
  ComPtr<IDWriteFactory> dwrite;
  std::wstring glyph_family = L"Segoe MDL2 Assets";
};

Graphics& GraphicsOnUiThread() {
  static Graphics* graphics = [] {
    auto* made = new Graphics();
    D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, made->d2d.GetAddressOf());
    DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                        reinterpret_cast<IUnknown**>(made->dwrite.GetAddressOf()));
    ComPtr<IDWriteFontCollection> fonts;
    if (made->dwrite != nullptr && SUCCEEDED(made->dwrite->GetSystemFontCollection(&fonts, FALSE))) {
      UINT32 index = 0;
      BOOL exists = FALSE;
      fonts->FindFamilyName(L"Segoe Fluent Icons", &index, &exists);
      if (exists) made->glyph_family = L"Segoe Fluent Icons";
    }
    return made;
  }();
  return *graphics;
}

LRESULT CALLBACK ButtonProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* control = reinterpret_cast<VolumeControl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (control != nullptr) return control->ButtonMessage(hwnd, message, wparam, lparam);
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK PopupProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* control = reinterpret_cast<VolumeControl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (control != nullptr) return control->PopupMessage(hwnd, message, wparam, lparam);
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// The flyout's trackbar and mute button, subclassed for Escape and Tab
// (the UI thread's message loop has no dialog navigation).
LRESULT CALLBACK ChildProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto original = reinterpret_cast<WNDPROC>(GetPropW(hwnd, kChildProcProp));
  auto* control = reinterpret_cast<VolumeControl*>(GetWindowLongPtrW(GetParent(hwnd), GWLP_USERDATA));
  if (original == nullptr) return DefWindowProcW(hwnd, message, wparam, lparam);
  if (control == nullptr) return CallWindowProcW(original, hwnd, message, wparam, lparam);
  return control->ChildMessage(hwnd, original, message, wparam, lparam);
}

void Subclass(HWND child) {
  if (child == nullptr) return;
  auto original = reinterpret_cast<WNDPROC>(GetWindowLongPtrW(child, GWLP_WNDPROC));
  SetPropW(child, kChildProcProp, reinterpret_cast<HANDLE>(original));
  SetWindowLongPtrW(child, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(ChildProc));
}

void RegisterClasses() {
  static bool registered = false;
  if (registered) return;
  registered = true;
  WNDCLASSEXW button = {};
  button.cbSize = sizeof(button);
  button.lpfnWndProc = ButtonProc;
  button.hInstance = GetModuleHandleW(nullptr);
  button.hCursor = LoadCursor(nullptr, IDC_ARROW);
  button.lpszClassName = kButtonClass;
  RegisterClassExW(&button);
  WNDCLASSEXW popup = {};
  popup.cbSize = sizeof(popup);
  popup.style = CS_DROPSHADOW;
  popup.lpfnWndProc = PopupProc;
  popup.hInstance = GetModuleHandleW(nullptr);
  popup.hCursor = LoadCursor(nullptr, IDC_ARROW);
  popup.lpszClassName = kPopupClass;
  RegisterClassExW(&popup);
}

}  // namespace

VolumeControl::VolumeControl(std::function<void(double)> on_change, std::function<void(double)> on_report)
    : on_change_(std::move(on_change)), on_report_(std::move(on_report)) {}

VolumeControl::~VolumeControl() { Detach(); }

int VolumeControl::Px(double dips) const { return static_cast<int>(std::lround(dips * dpi_ / 96.0)); }

void VolumeControl::Attach(HWND owner, UINT dpi) {
  Detach();
  owner_ = owner;
  dpi_ = dpi > 0 ? dpi : 96;
  CreateButton();
}

void VolumeControl::Detach() {
  popup_open_ = false;
  report_pending_ = false;
  // Owned windows go with their owner; these may be gone already.
  if (popup_ != nullptr && IsWindow(popup_)) DestroyWindow(popup_);
  if (tooltip_ != nullptr && IsWindow(tooltip_)) DestroyWindow(tooltip_);
  if (button_ != nullptr && IsWindow(button_)) DestroyWindow(button_);
  popup_ = nullptr;
  mute_ = nullptr;
  slider_ = nullptr;
  tooltip_ = nullptr;
  button_ = nullptr;
  if (glyph_font_ != nullptr) DeleteObject(glyph_font_);
  if (popup_brush_ != nullptr) DeleteObject(popup_brush_);
  glyph_font_ = nullptr;
  popup_brush_ = nullptr;
  shown_ = false;
  hot_ = false;
  alpha_ = 0;
  owner_ = nullptr;
}

void VolumeControl::SetAvailable() { available_ = true; }

void VolumeControl::SetVolume(double volume) {
  volume_ = std::clamp(volume, 0.0, 1.0);
  if (volume_ > 0.001) audible_ = volume_;
  // Not a change of the user's: nothing to tell Dart.
  reported_ = volume_;
  report_pending_ = false;
  if (button_ != nullptr) KillTimer(button_, kTimerReport);
  SyncPopup();
  if (button_ != nullptr && IsWindowVisible(button_)) Render();
}

void VolumeControl::SetDpi(UINT dpi) {
  if (dpi == 0 || dpi == dpi_) return;
  HWND owner = owner_;
  if (owner == nullptr) {
    dpi_ = dpi;
    return;
  }
  // Remade at the new size (the flyout too, the next time it opens).
  Attach(owner, dpi);
}

void VolumeControl::StringsChanged() {
  if (button_ != nullptr) SetWindowTextW(button_, UiString("volume").c_str());
  if (tooltip_ != nullptr) {
    std::wstring text = UiString("volume");
    TTTOOLINFOW tool = {};
    tool.cbSize = TTTOOLINFOW_V2_SIZE;
    tool.hwnd = button_;
    tool.uId = reinterpret_cast<UINT_PTR>(button_);
    tool.lpszText = text.data();
    SendMessageW(tooltip_, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&tool));
  }
  if (slider_ != nullptr) SetWindowTextW(slider_, UiString("volume").c_str());
  SyncPopup();
}

// ---------------------------------------------------------------- button

void VolumeControl::CreateButton() {
  if (owner_ == nullptr) return;
  RegisterClasses();
  ScopedCommonControls controls;
  const int size = Px(kButtonDips);
  // Owned by the streamed window: above it, hidden and destroyed with it.
  button_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kButtonClass,
                            UiString("volume").c_str(), WS_POPUP, 0, 0, size, size, owner_, nullptr,
                            GetModuleHandleW(nullptr), this);
  if (button_ == nullptr) {
    Log("volume: button window failed (%lu)", GetLastError());
    return;
  }
  tooltip_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, TOOLTIPS_CLASSW, nullptr,
                             WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
                             CW_USEDEFAULT, button_, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (tooltip_ != nullptr) {
    std::wstring text = UiString("volume");
    TTTOOLINFOW tool = {};
    tool.cbSize = TTTOOLINFOW_V2_SIZE;
    tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    tool.hwnd = button_;
    tool.uId = reinterpret_cast<UINT_PTR>(button_);
    tool.lpszText = text.data();
    SendMessageW(tooltip_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
  }
}

// Draws the round face (dark, translucent, a white speaker) with per-pixel
// alpha at the client area's top-right corner. Fully transparent pixels let
// the pointer through, so only the face is the button's.
void VolumeControl::Render() {
  if (button_ == nullptr || owner_ == nullptr) return;
  const int size = Px(kButtonDips);
  RECT client;
  GetClientRect(owner_, &client);
  POINT corner = {client.right, client.top};
  ClientToScreen(owner_, &corner);
  POINT origin = {corner.x - Px(kInsetDips) - size, corner.y + Px(kInsetDips)};

  HDC screen = GetDC(nullptr);
  HDC memory = CreateCompatibleDC(screen);
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(info.bmiHeader);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap != nullptr && bits != nullptr) {
    HGDIOBJ previous = SelectObject(memory, bitmap);
    std::memset(bits, 0, static_cast<size_t>(size) * size * 4);
    Graphics& graphics = GraphicsOnUiThread();
    const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    ComPtr<ID2D1DCRenderTarget> target;
    if (graphics.d2d != nullptr && SUCCEEDED(graphics.d2d->CreateDCRenderTarget(&props, &target))) {
      RECT bounds = {0, 0, size, size};
      target->BindDC(memory, &bounds);
      target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
      target->BeginDraw();
      target->Clear(D2D1::ColorF(0, 0, 0, 0));
      const float radius = size / 2.0f;
      const float face = popup_open_ ? 0.84f : (hot_ ? 0.74f : 0.56f);
      ComPtr<ID2D1SolidColorBrush> fill;
      ComPtr<ID2D1SolidColorBrush> edge;
      ComPtr<ID2D1SolidColorBrush> ink;
      target->CreateSolidColorBrush(D2D1::ColorF(0.08f, 0.08f, 0.09f, face), &fill);
      target->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.22f), &edge);
      target->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.96f), &ink);
      const D2D1_ELLIPSE circle = D2D1::Ellipse(D2D1::Point2F(radius, radius), radius - 0.75f, radius - 0.75f);
      if (fill != nullptr) target->FillEllipse(circle, fill.Get());
      if (edge != nullptr) target->DrawEllipse(circle, edge.Get(), 1.0f);
      ComPtr<IDWriteTextFormat> format;
      if (graphics.dwrite != nullptr && ink != nullptr &&
          SUCCEEDED(graphics.dwrite->CreateTextFormat(graphics.glyph_family.c_str(), nullptr,
                                                      DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                                      DWRITE_FONT_STRETCH_NORMAL, static_cast<float>(Px(kGlyphDips)),
                                                      L"", &format))) {
        format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        const wchar_t glyph[1] = {volume_ <= 0.001 ? kGlyphMute : kGlyphVolume};
        target->DrawText(glyph, 1, format.Get(), D2D1::RectF(0, 0, static_cast<float>(size), static_cast<float>(size)),
                         ink.Get());
      }
      target->EndDraw();
    }
    SIZE extent = {size, size};
    POINT zero = {0, 0};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, static_cast<BYTE>(std::clamp(alpha_, 0, 255)), AC_SRC_ALPHA};
    UpdateLayeredWindow(button_, screen, &origin, &extent, memory, &zero, 0, &blend, ULW_ALPHA);
    SelectObject(memory, previous);
  }
  if (bitmap != nullptr) DeleteObject(bitmap);
  DeleteDC(memory);
  ReleaseDC(nullptr, screen);
}

void VolumeControl::Show() {
  if (!available_ || owner_ == nullptr || button_ == nullptr) return;
  if (!IsWindowVisible(owner_) || IsIconic(owner_)) return;
  shown_ = true;
  if (!IsWindowVisible(button_)) {
    Render();
    ShowWindow(button_, SW_SHOWNOACTIVATE);
  }
  if (alpha_ >= 255) return;
  if (Animations()) {
    SetTimer(button_, kTimerFade, kFadeTickMs, nullptr);
  } else {
    alpha_ = 255;
    Render();
  }
}

void VolumeControl::Hide(bool now) {
  shown_ = false;
  if (button_ == nullptr) return;
  KillTimer(button_, kTimerIdle);
  if (!IsWindowVisible(button_)) {
    alpha_ = 0;
    return;
  }
  if (now || !Animations()) {
    KillTimer(button_, kTimerFade);
    alpha_ = 0;
    ShowWindow(button_, SW_HIDE);
    return;
  }
  SetTimer(button_, kTimerFade, kFadeTickMs, nullptr);
}

void VolumeControl::FadeStep() {
  const int step = static_cast<int>(std::ceil(255.0 * kFadeTickMs / 1000.0 / kFadeSeconds));
  alpha_ = shown_ ? std::min(255, alpha_ + step) : std::max(0, alpha_ - step);
  if (!shown_ && alpha_ == 0) {
    KillTimer(button_, kTimerFade);
    ShowWindow(button_, SW_HIDE);
    return;
  }
  Render();
  if (shown_ && alpha_ == 255) KillTimer(button_, kTimerFade);
}

bool VolumeControl::CursorOver(HWND window) {
  if (window == nullptr || !IsWindowVisible(window)) return false;
  POINT cursor;
  if (!GetCursorPos(&cursor) || WindowFromPoint(cursor) != window) return false;
  if (window != owner_) return true;
  ScreenToClient(owner_, &cursor);
  RECT client;
  GetClientRect(owner_, &client);
  return PtInRect(&client, cursor) != FALSE;
}

void VolumeControl::OwnerPointerMoved() {
  if (!available_ || button_ == nullptr) return;
  Show();
  if (!hot_ && !popup_open_) SetTimer(button_, kTimerIdle, kIdleMs, nullptr);
}

void VolumeControl::OwnerPointerLeft() {
  // Onto the button itself (a window of its own) is not leaving.
  if (hot_ || popup_open_ || CursorOver(button_)) return;
  Hide();
}

void VolumeControl::OwnerBusy() {
  ClosePopup(false);
  Hide(true);
}

void VolumeControl::OwnerMoved() {
  if (popup_open_) ClosePopup(false);
  if (button_ != nullptr && IsWindowVisible(button_)) Render();
}

bool VolumeControl::Wheel(POINT screen, int delta) {
  if (button_ == nullptr || !IsWindowVisible(button_) || alpha_ == 0) return false;
  RECT rect;
  GetWindowRect(button_, &rect);
  if (!PtInRect(&rect, screen)) return false;
  UserChanged(std::clamp(volume_ + kWheelStep * delta / WHEEL_DELTA, 0.0, 1.0), false);
  return true;
}

LRESULT VolumeControl::ButtonMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_MOUSEACTIVATE:
      // Clicking it leaves the streamed window active.
      return MA_NOACTIVATE;
    case WM_MOUSEMOVE:
      if (!hot_) {
        hot_ = true;
        TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&track);
        KillTimer(hwnd, kTimerIdle);
        Show();
        Render();
      }
      return 0;
    case WM_MOUSELEAVE:
      hot_ = false;
      Render();
      if (popup_open_) return 0;
      if (CursorOver(owner_)) {
        SetTimer(hwnd, kTimerIdle, kIdleMs, nullptr);
      } else {
        Hide();
      }
      return 0;
    case WM_LBUTTONDOWN:
      if (popup_open_) {
        ClosePopup(true);
      } else {
        OpenPopup();
      }
      return 0;
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_LBUTTONUP:
      return 0;
    case WM_MOUSEWHEEL:
      UserChanged(std::clamp(volume_ + kWheelStep * GET_WHEEL_DELTA_WPARAM(wparam) / WHEEL_DELTA, 0.0, 1.0), false);
      return 0;
    case WM_TIMER:
      if (wparam == kTimerFade) {
        FadeStep();
      } else if (wparam == kTimerIdle) {
        KillTimer(hwnd, kTimerIdle);
        if (!hot_ && !popup_open_) Hide();
      } else if (wparam == kTimerReport) {
        FlushReport();
      }
      return 0;
    default:
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// ---------------------------------------------------------------- flyout

void VolumeControl::CreatePopup() {
  if (owner_ == nullptr) return;
  RegisterClasses();
  ScopedCommonControls controls;
  popup_dark_ = SystemUsesDarkApps();
  popup_brush_ = CreateSolidBrush(popup_dark_ ? RGB(44, 44, 46) : RGB(249, 249, 249));
  popup_ = CreateWindowExW(WS_EX_TOOLWINDOW, kPopupClass, UiString("volume").c_str(), WS_POPUP | WS_BORDER, 0, 0,
                           Px(kPopupWidthDips), Px(kPopupHeightDips), owner_, nullptr, GetModuleHandleW(nullptr),
                           this);
  if (popup_ == nullptr) {
    Log("volume: flyout window failed (%lu)", GetLastError());
    return;
  }
  const DWORD round = 2;  // DWMWA_WINDOW_CORNER_PREFERENCE: DWMWCP_ROUND (Windows 11)
  DwmSetWindowAttribute(popup_, 33, &round, sizeof(round));
  const int pad = Px(8);
  const int mute = Px(32);
  mute_ = CreateWindowExW(0, L"BUTTON", UiString("mute").c_str(), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                          pad, (Px(kPopupHeightDips) - mute) / 2 - 1, mute, mute, popup_,
                          reinterpret_cast<HMENU>(static_cast<INT_PTR>(kMuteId)), GetModuleHandleW(nullptr), nullptr);
  const int slider_left = pad + mute + Px(6);
  const int slider_height = Px(30);
  slider_ = CreateWindowExW(0, TRACKBAR_CLASSW, UiString("volume").c_str(),
                            WS_CHILD | WS_VISIBLE | WS_TABSTOP | TBS_HORZ | TBS_NOTICKS | TBS_BOTH, slider_left,
                            (Px(kPopupHeightDips) - slider_height) / 2 - 1,
                            Px(kPopupWidthDips) - slider_left - pad, slider_height, popup_,
                            reinterpret_cast<HMENU>(static_cast<INT_PTR>(kSliderId)), GetModuleHandleW(nullptr),
                            nullptr);
  if (slider_ != nullptr) {
    SendMessageW(slider_, TBM_SETRANGE, FALSE, MAKELPARAM(0, 100));
    SendMessageW(slider_, TBM_SETLINESIZE, 0, 2);
    SendMessageW(slider_, TBM_SETPAGESIZE, 0, 10);
  }
  glyph_font_ = CreateFontW(-Px(16), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                            CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH,
                            GraphicsOnUiThread().glyph_family.c_str());
  Subclass(mute_);
  Subclass(slider_);
}

void VolumeControl::SyncPopup() {
  if (popup_ == nullptr) return;
  if (slider_ != nullptr) SendMessageW(slider_, TBM_SETPOS, TRUE, std::lround(volume_ * 100));
  if (mute_ != nullptr) {
    SetWindowTextW(mute_, UiString(volume_ <= 0.001 ? "unmute" : "mute").c_str());
    InvalidateRect(mute_, nullptr, FALSE);
  }
}

void VolumeControl::OpenPopup() {
  if (button_ == nullptr) return;
  // The theme may have changed since it was made.
  if (popup_ != nullptr && popup_dark_ != SystemUsesDarkApps()) {
    DestroyWindow(popup_);
    popup_ = nullptr;
    mute_ = nullptr;
    slider_ = nullptr;
    if (glyph_font_ != nullptr) DeleteObject(glyph_font_);
    if (popup_brush_ != nullptr) DeleteObject(popup_brush_);
    glyph_font_ = nullptr;
    popup_brush_ = nullptr;
  }
  if (popup_ == nullptr) CreatePopup();
  if (popup_ == nullptr) return;
  SyncPopup();
  RECT button;
  GetWindowRect(button_, &button);
  const int width = Px(kPopupWidthDips);
  const int height = Px(kPopupHeightDips);
  MONITORINFO info = {sizeof(info)};
  GetMonitorInfoW(MonitorFromRect(&button, MONITOR_DEFAULTTONEAREST), &info);
  const RECT& work = info.rcWork;
  int x = button.right - width;
  int y = button.bottom + Px(6);
  if (y + height > work.bottom) y = button.top - Px(6) - height;
  x = std::max<int>(work.left, std::min<int>(x, work.right - width));
  y = std::max<int>(work.top, std::min<int>(y, work.bottom - height));
  popup_open_ = true;
  KillTimer(button_, kTimerIdle);
  Show();
  Render();
  // Shown active: keys go to the slider, never to the streamed app.
  SetWindowPos(popup_, HWND_TOP, x, y, width, height, SWP_SHOWWINDOW);
  SetForegroundWindow(popup_);
  if (slider_ != nullptr) SetFocus(slider_);
}

void VolumeControl::ClosePopup(bool refocus_owner) {
  if (!popup_open_) return;
  popup_open_ = false;
  FlushReport();
  if (popup_ != nullptr) ShowWindow(popup_, SW_HIDE);
  if (refocus_owner && owner_ != nullptr) SetForegroundWindow(owner_);
  if (button_ == nullptr) return;
  Render();
  if (CursorOver(button_)) return;
  if (CursorOver(owner_)) {
    SetTimer(button_, kTimerIdle, kIdleMs, nullptr);
  } else {
    Hide();
  }
}

LRESULT VolumeControl::PopupMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND: {
      RECT rect;
      GetClientRect(hwnd, &rect);
      FillRect(reinterpret_cast<HDC>(wparam), &rect, popup_brush_);
      return 1;
    }
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN: {
      // The trackbar's (and button's) background.
      HDC dc = reinterpret_cast<HDC>(wparam);
      SetBkColor(dc, popup_dark_ ? RGB(44, 44, 46) : RGB(249, 249, 249));
      return reinterpret_cast<LRESULT>(popup_brush_);
    }
    case WM_DRAWITEM: {
      auto* item = reinterpret_cast<DRAWITEMSTRUCT*>(lparam);
      if (item->CtlID != kMuteId) break;
      FillRect(item->hDC, &item->rcItem, popup_brush_);
      if (item->itemState & ODS_SELECTED) {
        HBRUSH pressed = CreateSolidBrush(popup_dark_ ? RGB(70, 70, 74) : RGB(224, 224, 224));
        HGDIOBJ old_brush = SelectObject(item->hDC, pressed);
        HGDIOBJ old_pen = SelectObject(item->hDC, GetStockObject(NULL_PEN));
        RoundRect(item->hDC, item->rcItem.left, item->rcItem.top, item->rcItem.right, item->rcItem.bottom, Px(8),
                  Px(8));
        SelectObject(item->hDC, old_pen);
        SelectObject(item->hDC, old_brush);
        DeleteObject(pressed);
      }
      SetBkMode(item->hDC, TRANSPARENT);
      SetTextColor(item->hDC, popup_dark_ ? RGB(255, 255, 255) : RGB(24, 24, 24));
      HGDIOBJ old_font = SelectObject(item->hDC, glyph_font_);
      const wchar_t glyph[1] = {volume_ <= 0.001 ? kGlyphMute : kGlyphVolume};
      RECT text = item->rcItem;
      DrawTextW(item->hDC, glyph, 1, &text, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
      SelectObject(item->hDC, old_font);
      if ((item->itemState & ODS_FOCUS) && !(item->itemState & ODS_NOFOCUSRECT)) {
        RECT focus = item->rcItem;
        InflateRect(&focus, -Px(2), -Px(2));
        DrawFocusRect(item->hDC, &focus);
      }
      return TRUE;
    }
    case WM_COMMAND:
      if (LOWORD(wparam) == kMuteId && HIWORD(wparam) == BN_CLICKED) {
        UserChanged(volume_ > 0.001 ? 0.0 : audible_, true);
        return 0;
      }
      break;
    case WM_HSCROLL:
      if (reinterpret_cast<HWND>(lparam) == slider_ && slider_ != nullptr) {
        const double value = std::clamp(SendMessageW(slider_, TBM_GETPOS, 0, 0) / 100.0, 0.0, 1.0);
        // A drag (or a key held) sends a stream of these, then TB_ENDTRACK.
        const bool final = LOWORD(wparam) == TB_ENDTRACK;
        if (final || value != volume_) UserChanged(value, final);
        return 0;
      }
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        // A click elsewhere: the flyout goes, like a menu.
        ClosePopup(false);
      } else if (slider_ != nullptr) {
        SetFocus(slider_);
      }
      return 0;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        ClosePopup(true);
        return 0;
      }
      break;
    case WM_CLOSE:
      ClosePopup(true);
      return 0;
    case WM_DPICHANGED:
      // Transient, at the button's DPI; it closes when the window moves.
      return 0;
    default:
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT VolumeControl::ChildMessage(HWND child, WNDPROC original, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        ClosePopup(true);
        return 0;
      }
      if (wparam == VK_TAB) {
        HWND next = child == slider_ ? mute_ : slider_;
        if (next != nullptr) SetFocus(next);
        return 0;
      }
      break;
    case WM_CHAR:
      if (wparam == VK_ESCAPE || wparam == VK_TAB) return 0;
      break;
    case WM_NCDESTROY:
      SetWindowLongPtrW(child, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(original));
      RemovePropW(child, kChildProcProp);
      break;
    default:
      break;
  }
  return CallWindowProcW(original, child, message, wparam, lparam);
}

// ---------------------------------------------------------------- changes

void VolumeControl::UserChanged(double volume, bool final) {
  volume_ = volume;
  if (volume > 0.001) audible_ = volume;
  if (on_change_) on_change_(volume);
  SyncPopup();
  if (button_ != nullptr && IsWindowVisible(button_)) Render();
  const double now = NowSeconds();
  if (final || now - last_report_ >= kReportInterval) {
    FlushReport();
  } else if (!report_pending_ && button_ != nullptr) {
    report_pending_ = true;
    const double wait = last_report_ + kReportInterval - now;
    SetTimer(button_, kTimerReport, std::max<UINT>(1, static_cast<UINT>(std::ceil(wait * 1000))), nullptr);
  }
}

void VolumeControl::FlushReport() {
  if (button_ != nullptr) KillTimer(button_, kTimerReport);
  report_pending_ = false;
  if (reported_ == volume_) return;
  reported_ = volume_;
  last_report_ = NowSeconds();
  if (on_report_) on_report_(volume_);
}

}  // namespace wsn
