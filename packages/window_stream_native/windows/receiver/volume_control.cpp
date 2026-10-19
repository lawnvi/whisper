#include "volume_control.h"

#include <commctrl.h>
#include <d2d1.h>
#include <dwmapi.h>
#include <dwrite.h>
#include <oleauto.h>
#include <uiautomation.h>
#include <windowsx.h>
#include <winrt/Windows.UI.ViewManagement.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <cwchar>
#include <string>

#include "../common/com.h"
#include "ui_strings.h"

namespace wsn {
namespace {

constexpr wchar_t kButtonClass[] = L"WhisperWindowStreamVolume";
constexpr wchar_t kPopupClass[] = L"WhisperWindowStreamVolumePopup";
constexpr UINT_PTR kTimerFade = 1;
constexpr UINT_PTR kTimerIdle = 2;
constexpr UINT_PTR kTimerReport = 3;
constexpr UINT_PTR kTimerThumb = 4;  // on the flyout
constexpr UINT kFadeTickMs = 15;
constexpr double kFadeSeconds = 0.12;
// The button goes once the pointer has rested this long (not over it).
constexpr UINT kIdleMs = 2000;
// Reports to Dart while a change goes on: at most ten a second.
constexpr double kReportInterval = 0.1;
constexpr double kWheelStep = 0.05;
constexpr int kKeyStep = 2;    // percent, the arrow keys
constexpr int kPageStep = 10;  // percent, Page Up and Page Down

// The round button, in DIPs: the face, the room around it for its shadow,
// and its distance from the client area's top-right corner.
constexpr double kButtonDips = 32;
constexpr double kButtonMarginDips = 4;
constexpr double kInsetDips = 10;
constexpr double kButtonGlyphDips = 16;

// The flyout, in DIPs: a mute button on the left, the slider, the level on
// the right; 6 below the button's face.
constexpr double kPopupWidthDips = 312;
constexpr double kPopupHeightDips = 56;
constexpr double kPopupGapDips = 6;
constexpr double kMuteLeftDips = 8;
constexpr double kMuteDips = 40;
constexpr double kGlyphDips = 16;
constexpr double kSliderLeftDips = 56;
constexpr double kSliderRightDips = 60;
constexpr double kTrackDips = 4;
constexpr double kThumbDips = 20;
constexpr double kThumbDotDips = 12;
constexpr double kValueRightDips = 16;
constexpr double kValueWidthDips = 36;
constexpr double kValueTextDips = 14;
// The thumb's inner dot, as WinUI scales it: at rest, under the pointer,
// pressed.
constexpr double kDotRest = 0.86;
constexpr double kDotHover = 1.167;
constexpr double kDotPressed = 0.71;

// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (10) share these:
// muted, and the speaker with one, two or three waves.
constexpr wchar_t kGlyphMute = 0xE74F;
constexpr wchar_t kGlyphVolume1 = 0xE993;
constexpr wchar_t kGlyphVolume2 = 0xE994;
constexpr wchar_t kGlyphVolume3 = 0xE995;

// DWM attributes by number: older SDKs lack the Windows 11 ones.
constexpr DWORD kDwmUseImmersiveDarkMode = 20;
constexpr DWORD kDwmCloak = 13;
constexpr DWORD kDwmWindowCornerPreference = 33;
constexpr DWORD kDwmCornerRound = 2;
constexpr DWORD kDwmSystemBackdropType = 38;
constexpr DWORD kDwmBackdropNone = 1;
constexpr DWORD kDwmBackdropTransient = 3;

bool Muted(double volume) { return volume <= 0.001; }

wchar_t GlyphFor(double volume) {
  if (Muted(volume)) return kGlyphMute;
  if (volume < 0.34) return kGlyphVolume1;
  if (volume < 0.67) return kGlyphVolume2;
  return kGlyphVolume3;
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

bool HighContrast() {
  HIGHCONTRASTW contrast = {sizeof(contrast)};
  return SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) != FALSE &&
         (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
}

// The accent colour the theme fills with (as WinUI's AccentFillColorDefault:
// a darker shade on light, a lighter one on dark), 0xRRGGBB.
uint32_t AccentFill(bool dark) {
  try {
    using winrt::Windows::UI::ViewManagement::UIColorType;
    using winrt::Windows::UI::ViewManagement::UISettings;
    // Leaked on purpose, like the other process-wide state here (projected
    // types themselves can't be made with new).
    struct Holder {
      UISettings settings;
    };
    static Holder* holder = new Holder();
    const auto color = holder->settings.GetColorValue(dark ? UIColorType::AccentLight2 : UIColorType::AccentDark1);
    return (static_cast<uint32_t>(color.R) << 16) | (static_cast<uint32_t>(color.G) << 8) | color.B;
  } catch (...) {
  }
  DWORD colorization = 0;
  BOOL opaque = FALSE;
  if (SUCCEEDED(DwmGetColorizationColor(&colorization, &opaque))) return colorization & 0xFFFFFF;
  return dark ? 0x4CC2FF : 0x0067C0;
}

bool Animations() {
  BOOL enabled = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0);
  return enabled != FALSE;
}

// Common Controls 6 (the themed tooltips) without a manifest of our own:
// shell32's manifest asks for them.
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
      INITCOMMONCONTROLSEX init = {sizeof(init), ICC_BAR_CLASSES};
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

// Direct2D and DirectWrite for both windows (UI thread, leaked on purpose
// like the other process-wide state here).
struct Graphics {
  ComPtr<ID2D1Factory> d2d;
  ComPtr<IDWriteFactory> dwrite;
  std::wstring glyph_family = L"Segoe MDL2 Assets";
  std::wstring text_family = L"Segoe UI";
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
      exists = FALSE;
      fonts->FindFamilyName(L"Segoe UI Variable Text", &index, &exists);
      if (exists) made->text_family = L"Segoe UI Variable Text";
    }
    return made;
  }();
  return *graphics;
}

ComPtr<IDWriteTextFormat> TextFormat(const std::wstring& family, float size, DWRITE_TEXT_ALIGNMENT alignment) {
  ComPtr<IDWriteTextFormat> format;
  Graphics& graphics = GraphicsOnUiThread();
  if (graphics.dwrite == nullptr ||
      FAILED(graphics.dwrite->CreateTextFormat(family.c_str(), nullptr, DWRITE_FONT_WEIGHT_NORMAL,
                                               DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"",
                                               &format))) {
    return nullptr;
  }
  format->SetTextAlignment(alignment);
  format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
  format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  return format;
}

// A 32-bit premultiplied bitmap drawn with Direct2D in pixels: the button's
// layered picture, and each paint of the flyout (whose transparent pixels
// show the backdrop).
class Canvas {
 public:
  Canvas(int width, int height) : width_(width), height_(height) {
    screen_ = GetDC(nullptr);
    dc_ = CreateCompatibleDC(screen_);
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    bitmap_ = CreateDIBSection(screen_, &info, DIB_RGB_COLORS, &bits_, nullptr, 0);
    if (dc_ != nullptr && bitmap_ != nullptr && bits_ != nullptr) {
      previous_ = SelectObject(dc_, bitmap_);
      std::memset(bits_, 0, static_cast<size_t>(width) * height * 4);
    }
  }
  ~Canvas() {
    target_.Reset();  // bound to the DC: goes first
    if (previous_ != nullptr) SelectObject(dc_, previous_);
    if (bitmap_ != nullptr) DeleteObject(bitmap_);
    if (dc_ != nullptr) DeleteDC(dc_);
    ReleaseDC(nullptr, screen_);
  }
  Canvas(const Canvas&) = delete;
  Canvas& operator=(const Canvas&) = delete;

  bool ok() const { return previous_ != nullptr; }
  HDC dc() const { return dc_; }
  HDC screen() const { return screen_; }

  // The target, cleared and drawing; nullptr when there is none.
  ID2D1RenderTarget* Begin() {
    Graphics& graphics = GraphicsOnUiThread();
    if (!ok() || graphics.d2d == nullptr) return nullptr;
    const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96, 96);
    if (FAILED(graphics.d2d->CreateDCRenderTarget(&props, &target_))) return nullptr;
    RECT bounds = {0, 0, width_, height_};
    if (FAILED(target_->BindDC(dc_, &bounds))) return nullptr;
    // Grayscale: ClearType needs an opaque background.
    target_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    target_->BeginDraw();
    target_->Clear(D2D1::ColorF(0, 0, 0, 0));
    return target_.Get();
  }
  bool End() { return target_ != nullptr && SUCCEEDED(target_->EndDraw()); }

 private:
  int width_;
  int height_;
  HDC screen_ = nullptr;
  HDC dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  void* bits_ = nullptr;
  HGDIOBJ previous_ = nullptr;
  ComPtr<ID2D1DCRenderTarget> target_;
};

D2D1_COLOR_F Rgb(uint32_t rgb, float alpha = 1) {
  return D2D1::ColorF(((rgb >> 16) & 0xFF) / 255.0f, ((rgb >> 8) & 0xFF) / 255.0f, (rgb & 0xFF) / 255.0f, alpha);
}

D2D1_COLOR_F SysColor(int index) {
  const COLORREF color = GetSysColor(index);
  return D2D1::ColorF(GetRValue(color) / 255.0f, GetGValue(color) / 255.0f, GetBValue(color) / 255.0f, 1);
}

D2D1_COLOR_F Faded(D2D1_COLOR_F color, float alpha) {
  color.a *= alpha;
  return color;
}

// The colours of both windows, after WinUI's Fluent theme resources (the
// names in the comments); high contrast takes the system's colours.
struct Palette {
  D2D1_COLOR_F surface;         // the flyout without a backdrop (its fallback)
  D2D1_COLOR_F stroke;          // its edge, where the system draws none
  D2D1_COLOR_F text;            // TextFillColorPrimary
  D2D1_COLOR_F text_pressed;    // TextFillColorSecondary
  D2D1_COLOR_F text_hover;
  D2D1_COLOR_F subtle_hover;    // SubtleFillColorSecondary
  D2D1_COLOR_F subtle_pressed;  // SubtleFillColorTertiary
  D2D1_COLOR_F track;           // ControlStrongFillColorDefault
  D2D1_COLOR_F accent;          // AccentFillColorDefault
  D2D1_COLOR_F thumb;           // ControlSolidFillColorDefault
  D2D1_COLOR_F thumb_edge;      // ControlElevationBorder: most of it,
  D2D1_COLOR_F thumb_edge_low;  // and its lower edge
  D2D1_COLOR_F focus_outer;     // FocusStrokeColorOuter
  D2D1_COLOR_F focus_inner;     // FocusStrokeColorInner
  // The round button over the picture: at rest, under the pointer, with
  // its flyout open.
  D2D1_COLOR_F disc;
  D2D1_COLOR_F disc_hot;
  D2D1_COLOR_F disc_open;
  D2D1_COLOR_F disc_edge;
  D2D1_COLOR_F disc_glyph;
  D2D1_COLOR_F disc_glyph_hot;
  float shadow;  // the button's shadow at its darkest
};

Palette MakePalette(bool dark, bool high_contrast, uint32_t accent) {
  Palette p;
  if (high_contrast) {
    const D2D1_COLOR_F window = SysColor(COLOR_WINDOW);
    const D2D1_COLOR_F text = SysColor(COLOR_WINDOWTEXT);
    const D2D1_COLOR_F highlight = SysColor(COLOR_HIGHLIGHT);
    const D2D1_COLOR_F highlight_text = SysColor(COLOR_HIGHLIGHTTEXT);
    p.surface = window;
    p.stroke = text;
    p.text = text;
    p.text_pressed = highlight_text;
    p.text_hover = highlight_text;
    p.subtle_hover = highlight;
    p.subtle_pressed = highlight;
    p.track = text;
    p.accent = highlight;
    p.thumb = window;
    p.thumb_edge = text;
    p.thumb_edge_low = text;
    p.focus_outer = text;
    p.focus_inner = window;
    p.disc = window;
    p.disc_hot = highlight;
    p.disc_open = highlight;
    p.disc_edge = text;
    p.disc_glyph = text;
    p.disc_glyph_hot = highlight_text;
    p.shadow = 0;
    return p;
  }
  if (dark) {
    p.surface = Rgb(0x2C2C2C);
    p.stroke = Rgb(0xFFFFFF, 0.10f);
    p.text = Rgb(0xFFFFFF);
    p.text_pressed = Rgb(0xFFFFFF, 0.786f);
    p.text_hover = p.text;
    p.subtle_hover = Rgb(0xFFFFFF, 0.061f);
    p.subtle_pressed = Rgb(0xFFFFFF, 0.042f);
    p.track = Rgb(0xFFFFFF, 0.545f);
    p.accent = Rgb(accent);
    p.thumb = Rgb(0x454545);
    p.thumb_edge = Rgb(0xFFFFFF, 0.094f);
    p.thumb_edge_low = Rgb(0xFFFFFF, 0.071f);
    p.focus_outer = Rgb(0xFFFFFF);
    p.focus_inner = Rgb(0x000000, 0.702f);
    p.disc = Rgb(0x202020, 0.80f);
    p.disc_hot = Rgb(0x2D2D2D, 0.90f);
    p.disc_open = Rgb(0x383838, 0.94f);
    p.disc_edge = Rgb(0xFFFFFF, 0.12f);
    p.disc_glyph = Rgb(0xFFFFFF);
    p.disc_glyph_hot = p.disc_glyph;
    p.shadow = 0.26f;
    return p;
  }
  p.surface = Rgb(0xF9F9F9);
  p.stroke = Rgb(0x000000, 0.10f);
  p.text = Rgb(0x000000, 0.894f);
  p.text_pressed = Rgb(0x000000, 0.62f);
  p.text_hover = p.text;
  p.subtle_hover = Rgb(0x000000, 0.037f);
  p.subtle_pressed = Rgb(0x000000, 0.024f);
  p.track = Rgb(0x000000, 0.447f);
  p.accent = Rgb(accent);
  p.thumb = Rgb(0xFFFFFF);
  p.thumb_edge = Rgb(0x000000, 0.059f);
  p.thumb_edge_low = Rgb(0x000000, 0.161f);
  p.focus_outer = Rgb(0x000000, 0.894f);
  p.focus_inner = Rgb(0xFFFFFF, 0.702f);
  p.disc = Rgb(0xFAFAFA, 0.86f);
  p.disc_hot = Rgb(0xFFFFFF, 0.96f);
  p.disc_open = Rgb(0xEDEDED, 0.96f);
  p.disc_edge = Rgb(0x000000, 0.10f);
  p.disc_glyph = Rgb(0x000000, 0.894f);
  p.disc_glyph_hot = p.disc_glyph;
  p.shadow = 0.20f;
  return p;
}

// The flyout's geometry in pixels, snapped so that edges fall on pixels.
struct FlyoutLayout {
  float width;
  float height;
  D2D1_RECT_F mute;
  D2D1_RECT_F slider;  // what takes the pointer for the slider
  float track_left;
  float track_right;
  float track_top;
  float track_height;
  float center_y;
  float thumb_radius;
  D2D1_RECT_F value;
};

FlyoutLayout LayoutFor(UINT dpi) {
  auto px = [dpi](double dips) { return static_cast<float>(std::lround(dips * dpi / 96.0)); };
  FlyoutLayout l;
  l.width = px(kPopupWidthDips);
  l.height = px(kPopupHeightDips);
  l.thumb_radius = px(kThumbDips) / 2;
  // On a pixel's middle for an odd thumb (125 %, 175 %), so that its edge and
  // the rail are crisp there too.
  const bool odd = std::fmod(l.thumb_radius * 2, 2.0f) >= 0.5f;
  l.center_y = odd ? std::floor(l.height / 2) + 0.5f : std::round(l.height / 2);
  const float mute = px(kMuteDips);
  const float mute_top = std::round((l.height - mute) / 2);
  l.mute = D2D1::RectF(px(kMuteLeftDips), mute_top, px(kMuteLeftDips) + mute, mute_top + mute);
  l.track_left = px(kSliderLeftDips);
  l.track_right = l.width - px(kSliderRightDips);
  l.track_height = px(kTrackDips);
  l.track_top = std::round(l.center_y - l.track_height / 2);
  const float reach = px(16);
  l.slider = D2D1::RectF(l.track_left - px(4), l.center_y - reach, l.track_right + px(4), l.center_y + reach);
  const float value_right = l.width - px(kValueRightDips);
  l.value = D2D1::RectF(value_right - px(kValueWidthDips), 0, value_right, l.height);
  return l;
}

// The thumb's centre for `volume`, on whole pixels (half ones for an odd
// diameter) so that its edge stays crisp at rest.
float ThumbX(const FlyoutLayout& l, double volume) {
  const float travel = l.track_right - l.track_left - 2 * l.thumb_radius;
  const float x = l.track_left + l.thumb_radius + static_cast<float>(std::clamp(volume, 0.0, 1.0)) * travel;
  const bool odd = std::fmod(l.thumb_radius * 2, 2.0f) >= 0.5f;
  return odd ? std::floor(x) + 0.5f : std::round(x);
}

bool Contains(const D2D1_RECT_F& rect, POINT point) {
  return point.x >= rect.left && point.x < rect.right && point.y >= rect.top && point.y < rect.bottom;
}

// Fluent's focus visual: a 2 px outer and a 1 px inner ring around `rect`.
void DrawFocus(ID2D1RenderTarget* target, ID2D1SolidColorBrush* brush, const Palette& palette, D2D1_RECT_F rect,
               float radius, float unit) {
  const float outer = std::max(1.0f, std::round(2 * unit));
  const float inner = std::max(1.0f, std::round(unit));
  D2D1_RECT_F ring = D2D1::RectF(rect.left + outer / 2, rect.top + outer / 2, rect.right - outer / 2,
                                 rect.bottom - outer / 2);
  brush->SetColor(palette.focus_outer);
  target->DrawRoundedRectangle(D2D1::RoundedRect(ring, radius, radius), brush, outer);
  ring = D2D1::RectF(rect.left + outer + inner / 2, rect.top + outer + inner / 2, rect.right - outer - inner / 2,
                     rect.bottom - outer - inner / 2);
  brush->SetColor(palette.focus_inner);
  target->DrawRoundedRectangle(D2D1::RoundedRect(ring, std::max(0.0f, radius - outer), std::max(0.0f, radius - outer)),
                               brush, inner);
}

// ---------------------------------------------------------------- dismissal

// While a flyout is open, a WH_MOUSE hook on the UI thread sees each mouse
// message for this thread's windows before they do, and before a click
// activates one: a click outside the flyout closes it and goes no further
// (its button-up neither), as with a menu.
struct Dismissal {
  HHOOK hook = nullptr;
  VolumeControl* control = nullptr;  // whose flyout is open
  UINT owed_up = 0;                  // the button-up of a click it took
  UINT taken = 0;                    // that click's button-down, and where
  POINT taken_at = {};
};
Dismissal g_dismissal;

UINT ButtonUpFor(UINT message) {
  switch (message) {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
      return WM_LBUTTONUP;
    case WM_RBUTTONDOWN:
    case WM_RBUTTONDBLCLK:
      return WM_RBUTTONUP;
    case WM_MBUTTONDOWN:
    case WM_MBUTTONDBLCLK:
      return WM_MBUTTONUP;
    case WM_XBUTTONDOWN:
    case WM_XBUTTONDBLCLK:
      return WM_XBUTTONUP;
    default:
      return 0;
  }
}

void StopHook() {
  if (g_dismissal.hook != nullptr) UnhookWindowsHookEx(g_dismissal.hook);
  g_dismissal.hook = nullptr;
  g_dismissal.owed_up = 0;
}

LRESULT CALLBACK DismissalHook(int code, WPARAM wparam, LPARAM lparam) {
  if (code >= 0) {
    const UINT message = static_cast<UINT>(wparam);
    const auto* mouse = reinterpret_cast<const MOUSEHOOKSTRUCT*>(lparam);
    if (g_dismissal.owed_up != 0 && message == g_dismissal.owed_up) {
      g_dismissal.owed_up = 0;
      if (g_dismissal.control == nullptr) StopHook();
      return 1;
    }
    // The taken click again (looked at before it was removed): still taken.
    if (g_dismissal.owed_up != 0 && message == g_dismissal.taken && mouse->pt.x == g_dismissal.taken_at.x &&
        mouse->pt.y == g_dismissal.taken_at.y) {
      return 1;
    }
    const UINT up = ButtonUpFor(message);
    if (up != 0) {
      // Owed before the flyout closes, so the hook stays for it.
      g_dismissal.owed_up = up;
      g_dismissal.taken = message;
      g_dismissal.taken_at = mouse->pt;
      if (g_dismissal.control != nullptr && g_dismissal.control->DismissingClick(mouse->hwnd, mouse->wHitTestCode)) {
        return 1;
      }
      g_dismissal.owed_up = 0;
      if (g_dismissal.control == nullptr) StopHook();
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

void StartDismissal(VolumeControl* control) {
  g_dismissal.control = control;
  g_dismissal.owed_up = 0;
  if (g_dismissal.hook == nullptr) {
    g_dismissal.hook = SetWindowsHookExW(WH_MOUSE, DismissalHook, nullptr, GetCurrentThreadId());
    if (g_dismissal.hook == nullptr) Log("volume: mouse hook failed (%lu)", GetLastError());
  }
}

// `now`: the windows go, so no button-up is waited for.
void EndDismissal(VolumeControl* control, bool now) {
  if (g_dismissal.control != control) return;
  g_dismissal.control = nullptr;
  if (now || g_dismissal.owed_up == 0) StopHook();
}

// ---------------------------------------------------------------- classes

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

// ---------------------------------------------------------------- automation

// The flyout for UI Automation (Narrator and the like): a slider named
// "Volume" from 0 to 100, as the trackbar it replaces was. Mute is M.
class VolumeAutomation final : public IRawElementProviderSimple, public IRangeValueProvider {
 public:
  VolumeAutomation(VolumeControl* control, HWND hwnd) : control_(control), hwnd_(hwnd) {}
  void Disconnect() { control_ = nullptr; }

  ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG left = InterlockedDecrement(&references_);
    if (left == 0) delete this;
    return left;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (out == nullptr) return E_POINTER;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IRawElementProviderSimple)) {
      *out = static_cast<IRawElementProviderSimple*>(this);
    } else if (iid == __uuidof(IRangeValueProvider)) {
      *out = static_cast<IRangeValueProvider*>(this);
    } else {
      *out = nullptr;
      return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions* options) override {
    if (options == nullptr) return E_POINTER;
    *options = static_cast<ProviderOptions>(ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern, IUnknown** out) override {
    if (out == nullptr) return E_POINTER;
    *out = nullptr;
    if (control_ == nullptr) return UIA_E_ELEMENTNOTAVAILABLE;
    if (pattern == UIA_RangeValuePatternId) {
      *out = static_cast<IRangeValueProvider*>(this);
      AddRef();
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT* out) override {
    if (out == nullptr) return E_POINTER;
    VariantInit(out);
    if (control_ == nullptr) return UIA_E_ELEMENTNOTAVAILABLE;
    switch (property) {
      case UIA_ControlTypePropertyId:
        out->vt = VT_I4;
        out->lVal = UIA_SliderControlTypeId;
        break;
      case UIA_NamePropertyId:
        out->vt = VT_BSTR;
        out->bstrVal = SysAllocString(UiString("volume").c_str());
        break;
      case UIA_IsKeyboardFocusablePropertyId:
        out->vt = VT_BOOL;
        out->boolVal = VARIANT_TRUE;
        break;
      case UIA_HasKeyboardFocusPropertyId:
        out->vt = VT_BOOL;
        out->boolVal = GetFocus() == hwnd_ ? VARIANT_TRUE : VARIANT_FALSE;
        break;
      default:
        break;
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple** out) override {
    if (out == nullptr) return E_POINTER;
    return UiaHostProviderFromHwnd(hwnd_, out);
  }

  HRESULT STDMETHODCALLTYPE SetValue(double value) override {
    if (control_ == nullptr) return UIA_E_ELEMENTNOTAVAILABLE;
    if (!std::isfinite(value) || value < 0 || value > 100) return E_INVALIDARG;
    control_->SetPercent(std::lround(value));
    control_->FlushReport();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_Value(double* out) override {
    if (out == nullptr) return E_POINTER;
    if (control_ == nullptr) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = static_cast<double>(std::lround(control_->volume_ * 100));
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL* out) override { return Put(out, FALSE); }
  HRESULT STDMETHODCALLTYPE get_Maximum(double* out) override { return Put(out, 100.0); }
  HRESULT STDMETHODCALLTYPE get_Minimum(double* out) override { return Put(out, 0.0); }
  HRESULT STDMETHODCALLTYPE get_LargeChange(double* out) override { return Put(out, double{kPageStep}); }
  HRESULT STDMETHODCALLTYPE get_SmallChange(double* out) override { return Put(out, double{kKeyStep}); }

 private:
  template <typename T>
  HRESULT Put(T* out, T value) {
    if (out == nullptr) return E_POINTER;
    *out = value;
    return S_OK;
  }

  LONG references_ = 1;
  VolumeControl* control_;
  HWND hwnd_;
};

// ---------------------------------------------------------------- control

VolumeControl::VolumeControl(std::function<void(double)> on_change, std::function<void(double)> on_report)
    : on_change_(std::move(on_change)), on_report_(std::move(on_report)) {}

VolumeControl::~VolumeControl() { Detach(); }

int VolumeControl::Px(double dips) const { return static_cast<int>(std::lround(dips * dpi_ / 96.0)); }

float VolumeControl::Dp(double dips) const { return static_cast<float>(dips * dpi_ / 96.0); }

void VolumeControl::Attach(HWND owner, UINT dpi) {
  Detach();
  owner_ = owner;
  dpi_ = dpi > 0 ? dpi : 96;
  ReadTheme();
  CreateButton();
}

void VolumeControl::Detach() {
  EndDismissal(this, true);
  popup_open_ = false;
  report_pending_ = false;
  dragging_ = false;
  // Owned windows go with their owner; these may be gone already.
  if (popup_ != nullptr && IsWindow(popup_)) DestroyWindow(popup_);
  if (tooltip_ != nullptr && IsWindow(tooltip_)) DestroyWindow(tooltip_);
  if (button_ != nullptr && IsWindow(button_)) DestroyWindow(button_);
  popup_ = nullptr;
  popup_tip_ = nullptr;
  tooltip_ = nullptr;
  button_ = nullptr;
  shown_ = false;
  hot_ = false;
  alpha_ = 0;
  owner_ = nullptr;
}

void VolumeControl::SetAvailable() { available_ = true; }

void VolumeControl::SetVolume(double volume) {
  const double previous = volume_;
  volume_ = std::clamp(volume, 0.0, 1.0);
  if (!Muted(volume_)) audible_ = volume_;
  // Not a change of the user's: nothing to tell Dart.
  reported_ = volume_;
  report_pending_ = false;
  if (button_ != nullptr) KillTimer(button_, kTimerReport);
  SyncPopup();
  VolumeShown(previous);
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
  if (popup_ != nullptr) SetWindowTextW(popup_, UiString("volume").c_str());
  SyncPopup();
}

void VolumeControl::ReadTheme() {
  high_contrast_ = HighContrast();
  dark_ = SystemUsesDarkApps();
  accent_ = AccentFill(dark_);
}

// Also when nothing here changed: high contrast themes differ in colours
// only, which are read as each picture is drawn.
void VolumeControl::ThemeChanged() {
  ReadTheme();
  ApplyPopupTheme();
  if (button_ != nullptr && IsWindowVisible(button_)) Render();
}

// ---------------------------------------------------------------- button

void VolumeControl::CreateButton() {
  if (owner_ == nullptr) return;
  RegisterClasses();
  ScopedCommonControls controls;
  const int size = Px(kButtonDips) + 2 * Px(kButtonMarginDips);
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

// The round face on the screen (the window has room around it for the
// shadow).
RECT VolumeControl::ButtonFace() const {
  RECT rect = {};
  if (button_ == nullptr) return rect;
  GetWindowRect(button_, &rect);
  const int margin = Px(kButtonMarginDips);
  InflateRect(&rect, -margin, -margin);
  return rect;
}

// Draws the round face (a translucent disc in the theme's colours with a
// soft shadow, the speaker showing the level) with per-pixel alpha at the
// client area's top-right corner. Only the disc takes the pointer.
void VolumeControl::Render() {
  if (button_ == nullptr || owner_ == nullptr) return;
  const int face = Px(kButtonDips);
  const int margin = Px(kButtonMarginDips);
  const int size = face + 2 * margin;
  RECT client;
  GetClientRect(owner_, &client);
  POINT corner = {client.right, client.top};
  ClientToScreen(owner_, &corner);
  POINT origin = {corner.x - Px(kInsetDips) - face - margin, corner.y + Px(kInsetDips) - margin};

  Canvas canvas(size, size);
  if (!canvas.ok()) return;
  if (ID2D1RenderTarget* target = canvas.Begin()) {
    const Palette palette = MakePalette(dark_, high_contrast_, accent_);
    const float center = size / 2.0f;
    const float radius = face / 2.0f;
    const float hairline = std::max(1.0f, std::floor(Dp(1)));
    ComPtr<ID2D1SolidColorBrush> brush;
    target->CreateSolidColorBrush(palette.disc, &brush);
    // A soft shadow just outside the face (a little lower), so that it
    // reads over any picture.
    if (palette.shadow > 0) {
      const float outer = radius + margin;
      const D2D1_GRADIENT_STOP stops[] = {
          {0.0f, D2D1::ColorF(0, 0, 0, 0)},
          {(radius - 1) / outer, D2D1::ColorF(0, 0, 0, 0)},
          {radius / outer, D2D1::ColorF(0, 0, 0, palette.shadow)},
          {1.0f, D2D1::ColorF(0, 0, 0, 0)},
      };
      ComPtr<ID2D1GradientStopCollection> collection;
      ComPtr<ID2D1RadialGradientBrush> shadow;
      if (SUCCEEDED(target->CreateGradientStopCollection(stops, 4, &collection)) &&
          SUCCEEDED(target->CreateRadialGradientBrush(
              D2D1::RadialGradientBrushProperties(D2D1::Point2F(center, center + Dp(1)), D2D1::Point2F(0, 0), outer,
                                                  outer),
              collection.Get(), &shadow))) {
        target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(center, center + Dp(1)), outer, outer), shadow.Get());
      }
    }
    const bool lit = popup_open_ || hot_;
    if (brush != nullptr) {
      const D2D1_ELLIPSE disc = D2D1::Ellipse(D2D1::Point2F(center, center), radius, radius);
      brush->SetColor(popup_open_ ? palette.disc_open : (hot_ ? palette.disc_hot : palette.disc));
      target->FillEllipse(disc, brush.Get());
      const float inner = radius - hairline / 2;
      brush->SetColor(palette.disc_edge);
      target->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(center, center), inner, inner), brush.Get(), hairline);
      ComPtr<IDWriteTextFormat> format =
          TextFormat(GraphicsOnUiThread().glyph_family, static_cast<float>(Px(kButtonGlyphDips)),
                     DWRITE_TEXT_ALIGNMENT_CENTER);
      if (format != nullptr) {
        const wchar_t glyph[1] = {GlyphFor(volume_)};
        brush->SetColor(lit ? palette.disc_glyph_hot : palette.disc_glyph);
        target->DrawText(glyph, 1, format.Get(),
                         D2D1::RectF(static_cast<float>(margin), static_cast<float>(margin),
                                     static_cast<float>(margin + face), static_cast<float>(margin + face)),
                         brush.Get());
      }
    }
    canvas.End();
  }
  SIZE extent = {size, size};
  POINT zero = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, static_cast<BYTE>(std::clamp(alpha_, 0, 255)), AC_SRC_ALPHA};
  UpdateLayeredWindow(button_, canvas.screen(), &origin, &extent, canvas.dc(), &zero, 0, &blend, ULW_ALPHA);
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
  const RECT face = ButtonFace();
  if (!PtInRect(&face, screen)) return false;
  UserChanged(std::clamp(volume_ + kWheelStep * delta / WHEEL_DELTA, 0.0, 1.0), false);
  return true;
}

LRESULT VolumeControl::ButtonMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST: {
      // The round face only: the corners of the square (and the shadow)
      // are the streamed window's.
      const RECT face = ButtonFace();
      const double radius = (face.right - face.left) / 2.0;
      const double dx = GET_X_LPARAM(lparam) - (face.left + radius);
      const double dy = GET_Y_LPARAM(lparam) - (face.top + radius);
      return dx * dx + dy * dy <= radius * radius ? HTCLIENT : HTTRANSPARENT;
    }
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
    // Broadcasts to top-level windows (this one lives as long as the
    // control is attached): the app theme, the accent colour or high
    // contrast changed.
    case WM_SETTINGCHANGE:
      if (wparam == SPI_SETHIGHCONTRAST ||
          (lparam != 0 && std::wcscmp(reinterpret_cast<const wchar_t*>(lparam), L"ImmersiveColorSet") == 0)) {
        ThemeChanged();
      }
      break;
    case WM_DWMCOLORIZATIONCOLORCHANGED:
    case WM_SYSCOLORCHANGE:
    case WM_THEMECHANGED:
      ThemeChanged();
      break;
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
  popup_ = CreateWindowExW(WS_EX_TOOLWINDOW, kPopupClass, UiString("volume").c_str(), WS_POPUP, 0, 0,
                           Px(kPopupWidthDips), Px(kPopupHeightDips), owner_, nullptr, GetModuleHandleW(nullptr),
                           this);
  if (popup_ == nullptr) {
    Log("volume: flyout window failed (%lu)", GetLastError());
    return;
  }
  // Rounded like Windows 11's flyouts; the system then draws the border.
  const DWORD round = kDwmCornerRound;
  rounded_ = SUCCEEDED(DwmSetWindowAttribute(popup_, kDwmWindowCornerPreference, &round, sizeof(round)));
  ApplyPopupTheme();
  automation_ = new VolumeAutomation(this, popup_);
  popup_tip_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, TOOLTIPS_CLASSW, nullptr,
                               WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
                               CW_USEDEFAULT, popup_, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (popup_tip_ != nullptr) {
    const FlyoutLayout layout = LayoutFor(dpi_);
    std::wstring text = UiString(Muted(volume_) ? "unmute" : "mute");
    TTTOOLINFOW tool = {};
    tool.cbSize = TTTOOLINFOW_V2_SIZE;
    tool.uFlags = TTF_SUBCLASS;
    tool.hwnd = popup_;
    tool.uId = 1;
    tool.rect = {static_cast<LONG>(layout.mute.left), static_cast<LONG>(layout.mute.top),
                 static_cast<LONG>(layout.mute.right), static_cast<LONG>(layout.mute.bottom)};
    tool.lpszText = text.data();
    SendMessageW(popup_tip_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
  }
}

// The flyout's backdrop and frame for the theme: dark or light acrylic for
// transient windows (Windows 11 22H2 and later; the system shows a plain
// colour itself while transparency effects are off), none in high contrast
// or where there is no such backdrop, where the flyout paints its own.
//
// On a popup the system draws that backdrop only when the value changes
// while the popup is shown: given while it is hidden, or given again after
// a hiding, it stays an opaque grey (Windows 11 24H2). So it goes from none
// to acrylic each time here once shown, and back to none while hidden.
void VolumeControl::ApplyPopupTheme() {
  if (popup_ == nullptr) return;
  const BOOL dark = dark_ && !high_contrast_ ? TRUE : FALSE;
  DwmSetWindowAttribute(popup_, kDwmUseImmersiveDarkMode, &dark, sizeof(dark));
  const DWORD none = kDwmBackdropNone;
  backdrop_ =
      SUCCEEDED(DwmSetWindowAttribute(popup_, kDwmSystemBackdropType, &none, sizeof(none))) && !high_contrast_;
  if (backdrop_ && IsWindowVisible(popup_)) {
    const DWORD acrylic = kDwmBackdropTransient;
    DwmSetWindowAttribute(popup_, kDwmSystemBackdropType, &acrylic, sizeof(acrylic));
  }
  // The backdrop shows through the client area's transparent pixels.
  const MARGINS margins = backdrop_ ? MARGINS{-1, -1, -1, -1} : MARGINS{0, 0, 0, 0};
  DwmExtendFrameIntoClientArea(popup_, &margins);
  InvalidateRect(popup_, nullptr, FALSE);
}

void VolumeControl::SyncPopup() {
  if (popup_ == nullptr) return;
  if (popup_tip_ != nullptr) {
    std::wstring text = UiString(Muted(volume_) ? "unmute" : "mute");
    TTTOOLINFOW tool = {};
    tool.cbSize = TTTOOLINFOW_V2_SIZE;
    tool.hwnd = popup_;
    tool.uId = 1;
    tool.lpszText = text.data();
    SendMessageW(popup_tip_, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&tool));
  }
  InvalidateRect(popup_, nullptr, FALSE);
}

void VolumeControl::OpenPopup() {
  if (button_ == nullptr) return;
  // A change of theme missed while it was closed (cheap to look again).
  ReadTheme();
  if (popup_ == nullptr) CreatePopup();
  if (popup_ == nullptr) return;
  hover_ = Part::kNone;
  pressed_ = Part::kNone;
  focus_ = Part::kSlider;
  focus_visible_ = false;
  dragging_ = false;
  thumb_scale_ = kDotRest;
  SyncPopup();
  const RECT face = ButtonFace();
  const int width = Px(kPopupWidthDips);
  const int height = Px(kPopupHeightDips);
  MONITORINFO info = {sizeof(info)};
  GetMonitorInfoW(MonitorFromRect(&face, MONITOR_DEFAULTTONEAREST), &info);
  const RECT& work = info.rcWork;
  int x = face.right - width;
  int y = face.bottom + Px(kPopupGapDips);
  if (y + height > work.bottom) y = face.top - Px(kPopupGapDips) - height;
  x = std::max<int>(work.left, std::min<int>(x, work.right - width));
  y = std::max<int>(work.top, std::min<int>(y, work.bottom - height));
  popup_open_ = true;
  KillTimer(button_, kTimerIdle);
  Show();
  Render();
  // Shown cloaked until the backdrop is on and the content drawn, so that
  // its first frame is the finished one (see ApplyPopupTheme).
  const BOOL cloak = TRUE;
  const BOOL uncloak = FALSE;
  DwmSetWindowAttribute(popup_, kDwmCloak, &cloak, sizeof(cloak));
  SetWindowPos(popup_, HWND_TOP, x, y, width, height, SWP_SHOWWINDOW);
  ApplyPopupTheme();
  UpdateWindow(popup_);
  DwmSetWindowAttribute(popup_, kDwmCloak, &uncloak, sizeof(uncloak));
  // Shown active: keys go to the flyout, never to the streamed app.
  SetForegroundWindow(popup_);
  SetFocus(popup_);
  StartDismissal(this);
}

void VolumeControl::ClosePopup(bool refocus_owner) {
  if (!popup_open_) return;
  popup_open_ = false;
  EndDismissal(this, false);
  dragging_ = false;
  pressed_ = Part::kNone;
  hover_ = Part::kNone;
  popup_tracking_ = false;
  if (popup_ != nullptr && GetCapture() == popup_) ReleaseCapture();
  FlushReport();
  if (popup_ != nullptr) {
    KillTimer(popup_, kTimerThumb);
    ShowWindow(popup_, SW_HIDE);
    ApplyPopupTheme();  // the backdrop back to none while hidden
  }
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

bool VolumeControl::DismissingClick(HWND target, UINT hit_test) {
  if (!popup_open_ || target == nullptr) return false;
  HWND root = GetAncestor(target, GA_ROOT);
  if (root == popup_ || root == button_ || target == popup_tip_ || target == tooltip_) return false;
  // On a frame (title bar, borders, caption buttons) the click does what
  // it always does; activating that window closes the flyout as well.
  if (hit_test != HTCLIENT) return false;
  ClosePopup(false);
  if (root != nullptr) SetForegroundWindow(root);
  return true;
}

VolumeControl::Part VolumeControl::PartAt(POINT client) const {
  const FlyoutLayout layout = LayoutFor(dpi_);
  if (Contains(layout.mute, client)) return Part::kMute;
  if (Contains(layout.slider, client)) return Part::kSlider;
  return Part::kNone;
}

void VolumeControl::SetHover(Part part) {
  if (hover_ == part) return;
  hover_ = part;
  AnimateThumb();
  if (popup_ != nullptr) InvalidateRect(popup_, nullptr, FALSE);
}

// The thumb follows the pointer (less where it was taken hold of), in
// whole percent like the trackbar before it.
void VolumeControl::DragTo(int x) {
  const FlyoutLayout layout = LayoutFor(dpi_);
  const float travel = layout.track_right - layout.track_left - 2 * layout.thumb_radius;
  if (travel <= 0) return;
  const double fraction = (x - grab_ - (layout.track_left + layout.thumb_radius)) / travel;
  SetPercent(std::lround(std::clamp(fraction, 0.0, 1.0) * 100));
}

// One step of the thumb's dot towards its size for the state (WinUI eases
// it the same way): bigger under the pointer, smaller while held.
void VolumeControl::AnimateThumb() {
  if (popup_ == nullptr) return;
  const double target = (dragging_ || pressed_ == Part::kSlider)
                            ? kDotPressed
                            : (hover_ == Part::kSlider ? kDotHover : kDotRest);
  if (!Animations() || std::abs(target - thumb_scale_) < 0.02) {
    thumb_scale_ = target;
    KillTimer(popup_, kTimerThumb);
  } else {
    thumb_scale_ += (target - thumb_scale_) * 0.45;
    SetTimer(popup_, kTimerThumb, kFadeTickMs, nullptr);
  }
  InvalidateRect(popup_, nullptr, FALSE);
}

void VolumeControl::StepPercent(int delta) {
  SetPercent(std::clamp(std::lround(volume_ * 100) + delta, 0L, 100L));
}

void VolumeControl::SetPercent(long percent) {
  if (std::lround(volume_ * 100) == percent) return;
  UserChanged(percent / 100.0, false);
}

void VolumeControl::ToggleMute() { UserChanged(Muted(volume_) ? audible_ : 0.0, true); }

void VolumeControl::PaintPopup(HDC dc) {
  RECT client;
  GetClientRect(popup_, &client);
  const int width = client.right;
  const int height = client.bottom;
  if (width <= 0 || height <= 0) return;
  Canvas canvas(width, height);
  ID2D1RenderTarget* target = canvas.Begin();
  if (target == nullptr) return;
  const Palette palette = MakePalette(dark_, high_contrast_, accent_);
  const FlyoutLayout layout = LayoutFor(dpi_);
  const float unit = Dp(1);
  const float hairline = std::max(1.0f, std::floor(unit));
  ComPtr<ID2D1SolidColorBrush> brush;
  if (FAILED(target->CreateSolidColorBrush(palette.surface, &brush))) {
    canvas.End();
    return;
  }
  // Without the backdrop: the theme's plain colour, and an edge where the
  // system draws none (Windows 10).
  if (!backdrop_) target->Clear(palette.surface);
  if (!rounded_) {
    brush->SetColor(palette.stroke);
    target->DrawRectangle(D2D1::RectF(hairline / 2, hairline / 2, width - hairline / 2, height - hairline / 2),
                          brush.Get(), hairline);
  }

  // The mute button: a subtle button, as quick settings' speaker.
  const bool mute_held = pressed_ == Part::kMute && hover_ == Part::kMute;
  const float corner = Dp(4);
  if (mute_held || hover_ == Part::kMute) {
    brush->SetColor(mute_held ? palette.subtle_pressed : palette.subtle_hover);
    target->FillRoundedRectangle(D2D1::RoundedRect(layout.mute, corner, corner), brush.Get());
  }
  if (ComPtr<IDWriteTextFormat> glyphs = TextFormat(GraphicsOnUiThread().glyph_family,
                                                    static_cast<float>(Px(kGlyphDips)), DWRITE_TEXT_ALIGNMENT_CENTER)) {
    const wchar_t glyph[1] = {GlyphFor(volume_)};
    brush->SetColor(mute_held ? palette.text_pressed : (hover_ == Part::kMute ? palette.text_hover : palette.text));
    target->DrawText(glyph, 1, glyphs.Get(), layout.mute, brush.Get());
  }
  if (focus_visible_ && focus_ == Part::kMute) DrawFocus(target, brush.Get(), palette, layout.mute, corner, unit);

  // The slider: the rail, its filled part up to the thumb, the thumb.
  const float thumb_x = ThumbX(layout, volume_);
  const float rail = layout.track_height / 2;
  brush->SetColor(palette.track);
  target->FillRoundedRectangle(
      D2D1::RoundedRect(D2D1::RectF(layout.track_left, layout.track_top, layout.track_right,
                                    layout.track_top + layout.track_height),
                        rail, rail),
      brush.Get());
  brush->SetColor(palette.accent);
  target->FillRoundedRectangle(
      D2D1::RoundedRect(
          D2D1::RectF(layout.track_left, layout.track_top, thumb_x, layout.track_top + layout.track_height), rail,
          rail),
      brush.Get());
  const D2D1_POINT_2F thumb = D2D1::Point2F(thumb_x, layout.center_y);
  const float radius = layout.thumb_radius;
  brush->SetColor(palette.thumb);
  target->FillEllipse(D2D1::Ellipse(thumb, radius, radius), brush.Get());
  // Its edge, darker along the bottom (Fluent's elevation border).
  const D2D1_GRADIENT_STOP stops[] = {{0.0f, palette.thumb_edge}, {1.0f, palette.thumb_edge_low}};
  ComPtr<ID2D1GradientStopCollection> collection;
  ComPtr<ID2D1LinearGradientBrush> edge;
  const float edge_radius = radius - hairline / 2;
  if (SUCCEEDED(target->CreateGradientStopCollection(stops, 2, &collection)) &&
      SUCCEEDED(target->CreateLinearGradientBrush(
          D2D1::LinearGradientBrushProperties(D2D1::Point2F(0, layout.center_y + radius - Dp(3)),
                                              D2D1::Point2F(0, layout.center_y + radius)),
          collection.Get(), &edge))) {
    target->DrawEllipse(D2D1::Ellipse(thumb, edge_radius, edge_radius), edge.Get(), hairline);
  }
  const bool held = dragging_ || pressed_ == Part::kSlider;
  const float dot = static_cast<float>(Dp(kThumbDotDips) / 2 * thumb_scale_);
  // AccentFillColorSecondary and Tertiary: the accent at 90 and 80 %.
  const float dot_alpha = high_contrast_ ? 1.0f : (held ? 0.8f : (hover_ == Part::kSlider ? 0.9f : 1.0f));
  brush->SetColor(Faded(palette.accent, dot_alpha));
  target->FillEllipse(D2D1::Ellipse(thumb, dot, dot), brush.Get());
  if (focus_visible_ && focus_ == Part::kSlider) {
    const float pad = Dp(4);
    const D2D1_RECT_F ring = D2D1::RectF(layout.track_left - pad, layout.center_y - radius - pad,
                                         layout.track_right + pad, layout.center_y + radius + pad);
    DrawFocus(target, brush.Get(), palette, ring, Dp(6), unit);
  }

  // The level in percent.
  if (ComPtr<IDWriteTextFormat> text = TextFormat(GraphicsOnUiThread().text_family, Dp(kValueTextDips),
                                                  DWRITE_TEXT_ALIGNMENT_TRAILING)) {
    const std::wstring level = std::to_wstring(std::lround(volume_ * 100));
    brush->SetColor(palette.text);
    target->DrawText(level.c_str(), static_cast<UINT32>(level.size()), text.Get(), layout.value, brush.Get());
  }
  if (!canvas.End()) return;
  BitBlt(dc, 0, 0, width, height, canvas.dc(), 0, 0, SRCCOPY);
}

LRESULT VolumeControl::PopupMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint;
      HDC dc = BeginPaint(hwnd, &paint);
      PaintPopup(dc);
      EndPaint(hwnd, &paint);
      return 0;
    }
    case WM_MOUSEMOVE: {
      const POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (!popup_tracking_) {
        TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, hwnd, 0};
        popup_tracking_ = TrackMouseEvent(&track) != FALSE;
      }
      if (dragging_) {
        DragTo(point.x);
      } else {
        SetHover(PartAt(point));
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      popup_tracking_ = false;
      if (!dragging_) SetHover(Part::kNone);
      return 0;
    case WM_LBUTTONDOWN: {
      const POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      focus_visible_ = false;
      pressed_ = PartAt(point);
      hover_ = pressed_;
      if (pressed_ == Part::kNone) {
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      }
      focus_ = pressed_;
      SetCapture(hwnd);
      if (pressed_ == Part::kSlider) {
        // Taken by the thumb: it keeps its place under the pointer.
        // Anywhere else on the track: it jumps there.
        const float thumb_x = ThumbX(LayoutFor(dpi_), volume_);
        grab_ = std::abs(point.x - thumb_x) <= LayoutFor(dpi_).thumb_radius ? point.x - thumb_x : 0.0f;
        dragging_ = true;
        DragTo(point.x);
      }
      AnimateThumb();
      InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    }
    case WM_LBUTTONUP: {
      const POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const Part pressed = pressed_;
      const bool dragged = dragging_;
      pressed_ = Part::kNone;
      dragging_ = false;
      if (GetCapture() == hwnd) ReleaseCapture();
      if (dragged) {
        FlushReport();  // the value it reached is the last
      } else if (pressed == Part::kMute && PartAt(point) == Part::kMute) {
        ToggleMute();
      }
      hover_ = Part::kNone;
      SetHover(PartAt(point));
      AnimateThumb();
      return 0;
    }
    case WM_CAPTURECHANGED:
      // Taken away mid-drag: the value it reached is the last.
      if (reinterpret_cast<HWND>(lparam) != hwnd && (dragging_ || pressed_ != Part::kNone)) {
        const bool dragged = dragging_;
        dragging_ = false;
        pressed_ = Part::kNone;
        if (dragged) FlushReport();
        AnimateThumb();
      }
      return 0;
    case WM_MOUSEWHEEL:
      UserChanged(std::clamp(volume_ + kWheelStep * GET_WHEEL_DELTA_WPARAM(wparam) / WHEEL_DELTA, 0.0, 1.0), false);
      return 0;
    case WM_KEYDOWN:
      switch (wparam) {
        case VK_ESCAPE:
          ClosePopup(true);
          return 0;
        case VK_TAB:
          focus_ = focus_ == Part::kSlider ? Part::kMute : Part::kSlider;
          focus_visible_ = true;
          InvalidateRect(hwnd, nullptr, FALSE);
          return 0;
        case VK_LEFT:
        case VK_DOWN:
          StepPercent(-kKeyStep);
          return 0;
        case VK_RIGHT:
        case VK_UP:
          StepPercent(kKeyStep);
          return 0;
        case VK_NEXT:
          StepPercent(-kPageStep);
          return 0;
        case VK_PRIOR:
          StepPercent(kPageStep);
          return 0;
        case VK_HOME:
          SetPercent(0);
          return 0;
        case VK_END:
          SetPercent(100);
          return 0;
        case 'M':
        case VK_SPACE:
          if ((lparam & (1 << 30)) == 0) ToggleMute();  // not again while held
          return 0;
        case VK_RETURN:
          if (focus_ == Part::kMute && (lparam & (1 << 30)) == 0) ToggleMute();
          return 0;
        default:
          break;
      }
      break;
    case WM_KEYUP:
      // A key held sends a stream of changes: the last one is reported now.
      FlushReport();
      return 0;
    case WM_TIMER:
      if (wparam == kTimerThumb) AnimateThumb();
      return 0;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        // Another window was activated: the flyout goes, like a menu.
        ClosePopup(false);
      } else {
        SetFocus(hwnd);
      }
      return 0;
    case WM_GETOBJECT:
      if (static_cast<long>(lparam) == static_cast<long>(UiaRootObjectId) && automation_ != nullptr) {
        return UiaReturnRawElementProvider(hwnd, wparam, lparam, automation_);
      }
      break;
    case WM_CLOSE:
      ClosePopup(true);
      return 0;
    case WM_DPICHANGED:
      // Transient, at the button's DPI; it closes when the window moves.
      return 0;
    case WM_DESTROY:
      KillTimer(hwnd, kTimerThumb);
      if (automation_ != nullptr) {
        UiaReturnRawElementProvider(hwnd, 0, 0, nullptr);
        automation_->Disconnect();
        UiaDisconnectProvider(automation_);
        automation_->Release();
        automation_ = nullptr;
      }
      break;
    default:
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// ---------------------------------------------------------------- changes

void VolumeControl::UserChanged(double volume, bool final) {
  const double previous = volume_;
  volume_ = volume;
  if (!Muted(volume)) audible_ = volume;
  if (on_change_) on_change_(volume);
  SyncPopup();
  VolumeShown(previous);
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

// The level shown changed: UI Automation clients hear of it.
void VolumeControl::VolumeShown(double previous) {
  if (automation_ == nullptr || !popup_open_ || !UiaClientsAreListening()) return;
  const long before = std::lround(previous * 100);
  const long after = std::lround(volume_ * 100);
  if (before == after) return;
  VARIANT old_value;
  VARIANT new_value;
  VariantInit(&old_value);
  VariantInit(&new_value);
  old_value.vt = VT_R8;
  old_value.dblVal = static_cast<double>(before);
  new_value.vt = VT_R8;
  new_value.dblVal = static_cast<double>(after);
  UiaRaiseAutomationPropertyChangedEvent(automation_, UIA_RangeValueValuePropertyId, old_value, new_value);
}

}  // namespace wsn
