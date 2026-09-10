#include "screenshot_plugin.h"
#include "../../native/screenshot_selection.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;
using whisper::CapturePoint;
using whisper::CaptureRect;
using whisper::ScreenshotSelection;
constexpr wchar_t kOverlayClass[] = L"WhisperRegionScreenshot";

class ScreenshotPlugin : public flutter::Plugin {
 public:
  ScreenshotPlugin(flutter::PluginRegistrarWindows* registrar, HWND window)
      : registrar_(registrar), window_(window),
        channel_(registrar->messenger(), "com.vireen.whisper/screenshot",
                 &flutter::StandardMethodCodec::GetInstance()) {
    delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND, UINT message, WPARAM wparam, LPARAM) -> std::optional<LRESULT> {
          if (message == WM_HOTKEY && registered_ &&
              wparam == static_cast<WPARAM>(hotkey_id_)) {
            channel_.InvokeMethod("shortcutPressed", nullptr);
            return 0;
          }
          return std::nullopt;
        });
    channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "setShortcut") {
        SetShortcut(call.arguments(), std::move(result));
      } else if (call.method_name() == "captureRegion") {
        hint_ = Label(call.arguments(), "hint");
        adjust_hint_ = Label(call.arguments(), "adjustHint");
        dark_ = Label(call.arguments(), "appearance") == L"dark";
        CaptureRegion(std::move(result));
      } else {
        result->NotImplemented();
      }
    });
  }

  ~ScreenshotPlugin() override {
    channel_.SetMethodCallHandler(nullptr);
    Finish(false);
    if (registered_) UnregisterHotKey(window_, hotkey_id_);
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }

 private:
  static bool Flag(const flutter::EncodableMap& args, const char* key) {
    const auto entry = args.find(Value(key));
    return entry != args.end() && std::get_if<bool>(&entry->second) &&
        std::get<bool>(entry->second);
  }

  void SetShortcut(const Value* args, std::unique_ptr<Result> result) {
    if (args == nullptr || std::holds_alternative<std::monostate>(*args)) {
      if (registered_) UnregisterHotKey(window_, hotkey_id_);
      registered_ = false;
      result->Success();
      return;
    }
    const auto* map = std::get_if<flutter::EncodableMap>(args);
    if (map == nullptr) { result->Error("shortcut-invalid"); return; }
    const auto entry = map->find(Value("key"));
    const auto* key = entry == map->end() ? nullptr : std::get_if<std::string>(&entry->second);
    UINT code = 0;
    if (key != nullptr) {
      if (key->size() == 1 && ((*key >= "A" && *key <= "Z") ||
                              (*key >= "0" && *key <= "9"))) {
        code = static_cast<UINT>((*key)[0]);
      } else {
        for (UINT index = 1; index <= 12; ++index) {
          if (*key == "F" + std::to_string(index)) code = VK_F1 + index - 1;
        }
      }
    }
    UINT modifiers = MOD_NOREPEAT;
    if (Flag(*map, "control")) modifiers |= MOD_CONTROL;
    if (Flag(*map, "alt")) modifiers |= MOD_ALT;
    if (Flag(*map, "shift")) modifiers |= MOD_SHIFT;
    if (Flag(*map, "meta")) modifiers |= MOD_WIN;
    if (!code || !(modifiers & (MOD_CONTROL | MOD_ALT | MOD_WIN))) {
      result->Error("shortcut-invalid"); return;
    }
    if (registered_ && code == key_code_ && modifiers == modifiers_) {
      result->Success(); return;
    }
    // Alternate private IDs so a failed registration leaves the old key active.
    const int replacement = hotkey_id_ == 0x5750 ? 0x5751 : 0x5750;
    if (!RegisterHotKey(window_, replacement, modifiers, code)) {
      result->Error("shortcut-unavailable"); return;
    }
    if (registered_) UnregisterHotKey(window_, hotkey_id_);
    registered_ = true;
    hotkey_id_ = replacement;
    key_code_ = code;
    modifiers_ = modifiers;
    result->Success();
  }

  void CaptureRegion(std::unique_ptr<Result> result) {
    if (pending_) { result->Error("capture-busy"); return; }
    pending_ = std::move(result);
    const auto previous_dpi = SetThreadDpiAwarenessContext(
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    origin_.x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    origin_.y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    width_ = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    height_ = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    selection_.Reset(width_, height_);
    pointer_ = action_point_ = CursorPoint();
    // Bound the single transient desktop bitmap, including unusual display layouts.
    if (width_ <= 0 || height_ <= 0 ||
        static_cast<int64_t>(width_) * height_ > 128 * 1024 * 1024) {
      SetThreadDpiAwarenessContext(previous_dpi);
      Finish(false, "capture-failed"); return;
    }
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width_;
    info.bmiHeader.biHeight = -height_;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    HDC desktop = GetDC(nullptr);
    snapshot_dc_ = CreateCompatibleDC(desktop);
    bitmap_ = CreateDIBSection(desktop, &info, DIB_RGB_COLORS,
        reinterpret_cast<void**>(&pixels_), nullptr, 0);
    bool captured = false;
    if (snapshot_dc_ && bitmap_ && pixels_) {
      old_bitmap_ = SelectObject(snapshot_dc_, bitmap_);
      captured = BitBlt(snapshot_dc_, 0, 0, width_, height_, desktop,
          origin_.x, origin_.y, SRCCOPY | CAPTUREBLT) != FALSE;
    }
    ReleaseDC(nullptr, desktop);
    if (!captured) {
      SetThreadDpiAwarenessContext(previous_dpi);
      Finish(false, "capture-failed"); return;
    }
    GdiFlush();
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hCursor = LoadCursor(nullptr, IDC_CROSS);
    window_class.lpszClassName = kOverlayClass;
    RegisterClassW(&window_class);
    foreground_ = GetForegroundWindow();
    overlay_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        kOverlayClass, L"Whisper", WS_POPUP, origin_.x, origin_.y,
        width_, height_, nullptr, nullptr, GetModuleHandle(nullptr), this);
    SetThreadDpiAwarenessContext(previous_dpi);
    if (!overlay_) { Finish(false, "capture-failed"); return; }
    ShowWindow(overlay_, SW_SHOW);
    SetForegroundWindow(overlay_);
    SetFocus(overlay_);
  }

  CapturePoint CursorPoint() const {
    POINT point{};
    GetCursorPos(&point);
    point.x = std::clamp<LONG>(point.x - origin_.x, 0, width_);
    point.y = std::clamp<LONG>(point.y - origin_.y, 0, height_);
    return {static_cast<double>(point.x), static_cast<double>(point.y)};
  }

  RECT Selection() const {
    return NativeRect(selection_.rect());
  }

  static RECT NativeRect(CaptureRect rect) {
    return {static_cast<LONG>(rect.left), static_cast<LONG>(rect.top),
            static_cast<LONG>(rect.right), static_cast<LONG>(rect.bottom)};
  }

  double UiScale() const { return overlay_ ? GetDpiForWindow(overlay_) / 96.0 : 1.0; }

  CaptureRect MonitorBounds() const {
    POINT point{static_cast<LONG>(action_point_.x + origin_.x),
                static_cast<LONG>(action_point_.y + origin_.y)};
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfo(MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST), &info)) {
      return {0, 0, static_cast<double>(width_), static_cast<double>(height_)};
    }
    return {static_cast<double>(info.rcMonitor.left - origin_.x),
            static_cast<double>(info.rcMonitor.top - origin_.y),
            static_cast<double>(info.rcMonitor.right - origin_.x),
            static_cast<double>(info.rcMonitor.bottom - origin_.y)};
  }

  CaptureRect Toolbar() const {
    const auto rect = selection_.rect(), monitor = MonitorBounds();
    const double s = UiScale();
    const double left = std::max(monitor.left + 12 * s,
        std::min(rect.right - 84 * s, monitor.right - 96 * s));
    double top = rect.bottom + 12 * s;
    if (top + 38 * s > monitor.bottom - 12 * s) top = rect.top - 50 * s;
    top = std::max(monitor.top + 12 * s, std::min(top, monitor.bottom - 50 * s));
    return {left, top, left + 84 * s, top + 38 * s};
  }

  static std::wstring Label(const Value* args, const char* name) {
    const auto* map = args ? std::get_if<flutter::EncodableMap>(args) : nullptr;
    if (!map) return L"";
    const auto entry = map->find(Value(name));
    const auto* text = entry == map->end() ? nullptr : std::get_if<std::string>(&entry->second);
    if (!text || text->empty()) return L"";
    const int size = MultiByteToWideChar(CP_UTF8, 0, text->data(), static_cast<int>(text->size()), nullptr, 0);
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text->data(), static_cast<int>(text->size()), result.data(), size);
    return result;
  }

  static void FillRounded(HDC dc, CaptureRect rect, COLORREF color, int radius) {
    const auto brush = CreateSolidBrush(color);
    const auto old_brush = SelectObject(dc, brush);
    const auto old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
    const auto r = NativeRect(rect);
    RoundRect(dc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
    SelectObject(dc, old_brush); SelectObject(dc, old_pen); DeleteObject(brush);
  }

  static void FillCircle(HDC dc, CapturePoint center, double radius, COLORREF color) {
    const auto brush = CreateSolidBrush(color);
    const auto old_brush = SelectObject(dc, brush);
    const auto old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
    const auto r = NativeRect({center.x - radius, center.y - radius,
                              center.x + radius, center.y + radius});
    Ellipse(dc, r.left, r.top, r.right, r.bottom);
    SelectObject(dc, old_brush); SelectObject(dc, old_pen); DeleteObject(brush);
  }

  void DrawTextLabel(HDC dc, const std::wstring& text, CaptureRect rect, int size) const {
    const auto font = CreateFontW(-static_cast<int>(size * UiScale()), 0, 0, 0, FW_MEDIUM,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    const auto old = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT); SetTextColor(dc, TextColor());
    auto r = NativeRect(rect);
    DrawTextW(dc, text.c_str(), -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    SelectObject(dc, old); DeleteObject(font);
  }

  COLORREF TextColor() const { return dark_ ? RGB(230, 230, 230) : RGB(100, 116, 139); }
  COLORREF SurfaceColor() const { return dark_ ? RGB(31, 31, 31) : RGB(248, 250, 252); }

  void UpdateCursor() {
    const int hit = selection_.HitTest(pointer_, 9 * UiScale());
    LPCWSTR name = IDC_CROSS;
    if (selection_.selected() && !selection_.dragging() && Toolbar().contains(pointer_)) name = IDC_HAND;
    else if (hit == ScreenshotSelection::kMove) name = IDC_SIZEALL;
    else if (hit == 1 || hit == 2) name = IDC_SIZEWE;
    else if (hit == 4 || hit == 8) name = IDC_SIZENS;
    else if (hit == 5 || hit == 10) name = IDC_SIZENWSE;
    else if (hit == 6 || hit == 9) name = IDC_SIZENESW;
    SetCursor(LoadCursorW(nullptr, name));
  }

  void Paint(HWND window) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(window, &paint);
    BitBlt(dc, 0, 0, width_, height_, snapshot_dc_, 0, 0, SRCCOPY);
    HDC dim = CreateCompatibleDC(dc);
    HBITMAP black = CreateCompatibleBitmap(dc, 1, 1);
    if (dim && black) {
      const auto old = SelectObject(dim, black);
      PatBlt(dim, 0, 0, 1, 1, BLACKNESS);
      BLENDFUNCTION blend{AC_SRC_OVER, 0, 90, 0};
      AlphaBlend(dc, 0, 0, width_, height_, dim, 0, 0, 1, 1, blend);
      SelectObject(dim, old);
    }
    if (black) DeleteObject(black);
    if (dim) DeleteDC(dim);
    const double s = UiScale();
    const auto selected = selection_.rect();
    if (selected.width() > 0 && selected.height() > 0) {
      RECT rect = Selection();
      BitBlt(dc, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
             snapshot_dc_, rect.left, rect.top, SRCCOPY);
      const auto old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
      const auto pen = CreatePen(PS_SOLID, static_cast<int>(2 * s), RGB(37, 99, 235));
      const auto old_pen = SelectObject(dc, pen);
      Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom);
      SelectObject(dc, old_pen); DeleteObject(pen);
      SelectObject(dc, old_brush);
      for (double x : {selected.left, (selected.left + selected.right) / 2, selected.right}) {
        for (double y : {selected.top, (selected.top + selected.bottom) / 2, selected.bottom}) {
          if (x == (selected.left + selected.right) / 2 && y == (selected.top + selected.bottom) / 2) continue;
          FillCircle(dc, {x, y}, 4.25 * s, RGB(37, 99, 235));
          FillCircle(dc, {x, y}, 2.75 * s, RGB(255, 255, 255));
        }
      }
    }
    const auto monitor = MonitorBounds();
    const double hint_width = std::min(600 * s, monitor.width() - 32 * s);
    CaptureRect hint{monitor.left + (monitor.width() - hint_width) / 2, monitor.top + 24 * s,
      monitor.left + (monitor.width() + hint_width) / 2, monitor.top + 58 * s};
    FillRounded(dc, hint, SurfaceColor(), static_cast<int>(9 * s));
    DrawTextLabel(dc, selection_.selected() ? adjust_hint_ : hint_, hint, 13);
    if (selection_.selected() && !selection_.dragging()) {
      const auto toolbar = Toolbar();
      FillRounded(dc, toolbar, SurfaceColor(), static_cast<int>(12 * s));
      CaptureRect cancel{toolbar.left + 4 * s, toolbar.top + 4 * s, toolbar.left + 40 * s, toolbar.bottom - 4 * s};
      CaptureRect confirm{toolbar.left + 44 * s, toolbar.top + 4 * s, toolbar.right - 4 * s, toolbar.bottom - 4 * s};
      if (cancel.contains(pointer_)) FillRounded(dc, cancel, dark_ ? RGB(55, 55, 55) : RGB(233, 237, 242), static_cast<int>(7 * s));
      if (confirm.contains(pointer_)) FillRounded(dc, confirm, dark_ ? RGB(32, 45, 72) : RGB(226, 235, 250), static_cast<int>(7 * s));
      const double cx = (cancel.left + cancel.right) / 2, cy = (cancel.top + cancel.bottom) / 2;
      auto pen = CreatePen(PS_SOLID, std::max(1, static_cast<int>(1.6 * s)), TextColor());
      auto old_pen = SelectObject(dc, pen);
      MoveToEx(dc, static_cast<int>(cx - 4 * s), static_cast<int>(cy - 4 * s), nullptr);
      LineTo(dc, static_cast<int>(cx + 4 * s), static_cast<int>(cy + 4 * s));
      MoveToEx(dc, static_cast<int>(cx - 4 * s), static_cast<int>(cy + 4 * s), nullptr);
      LineTo(dc, static_cast<int>(cx + 4 * s), static_cast<int>(cy - 4 * s));
      SelectObject(dc, old_pen); DeleteObject(pen);
      const double x = (confirm.left + confirm.right) / 2, y = (confirm.top + confirm.bottom) / 2;
      pen = CreatePen(PS_SOLID, std::max(1, static_cast<int>(1.6 * s)), RGB(37, 99, 235));
      old_pen = SelectObject(dc, pen);
      MoveToEx(dc, static_cast<int>(x - 3 * s), static_cast<int>(y - 7 * s), nullptr);
      LineTo(dc, static_cast<int>(x + 5 * s), static_cast<int>(y - 7 * s));
      LineTo(dc, static_cast<int>(x + 5 * s), static_cast<int>(y + 3 * s));
      const auto old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
      RoundRect(dc, static_cast<int>(x - 6 * s), static_cast<int>(y - 4 * s), static_cast<int>(x + 3 * s),
          static_cast<int>(y + 7 * s), static_cast<int>(3 * s), static_cast<int>(3 * s));
      SelectObject(dc, old_brush); SelectObject(dc, old_pen); DeleteObject(pen);
    }
    EndPaint(window, &paint);
  }

  bool CopySelection() {
    const RECT rect = Selection();
    const LONG width = rect.right - rect.left;
    const LONG height = rect.bottom - rect.top;
    if (width < 2 || height < 2) return false;
    const SIZE_T bytes = static_cast<SIZE_T>(width) * height * 4;
    HGLOBAL dib = GlobalAlloc(GMEM_MOVEABLE, sizeof(BITMAPINFOHEADER) + bytes);
    if (!dib) return false;
    auto* header = static_cast<BITMAPINFOHEADER*>(GlobalLock(dib));
    if (!header) { GlobalFree(dib); return false; }
    *header = {};
    header->biSize = sizeof(BITMAPINFOHEADER);
    header->biWidth = width;
    header->biHeight = height;
    header->biPlanes = 1;
    header->biBitCount = 32;
    header->biCompression = BI_RGB;
    auto* destination = reinterpret_cast<uint32_t*>(header + 1);
    // CF_DIB uses bottom-up rows; the captured desktop uses top-down rows.
    for (LONG row = 0; row < height; ++row) {
      const auto* source = pixels_ + static_cast<size_t>(rect.bottom - row - 1) * width_ + rect.left;
      std::memcpy(destination + static_cast<size_t>(row) * width, source,
                  static_cast<size_t>(width) * 4);
    }
    GlobalUnlock(dib);
    if (!OpenClipboard(window_)) { GlobalFree(dib); return false; }
    const bool copied = EmptyClipboard() && SetClipboardData(CF_DIB, dib) != nullptr;
    CloseClipboard();
    if (!copied) GlobalFree(dib);
    return copied;
  }

  void Finish(bool copy, const char* error = nullptr) {
    if (!pending_) return;
    auto result = std::move(pending_);
    const bool copied = copy && CopySelection();
    const HWND overlay = overlay_;
    const bool restore_focus = overlay && GetForegroundWindow() == overlay;
    overlay_ = nullptr;
    selection_.Reset(0, 0);
    if (GetCapture() == overlay) ReleaseCapture();
    if (overlay) DestroyWindow(overlay);
    if (snapshot_dc_) {
      if (old_bitmap_) SelectObject(snapshot_dc_, old_bitmap_);
      DeleteDC(snapshot_dc_);
    }
    if (bitmap_) DeleteObject(bitmap_);
    snapshot_dc_ = nullptr;
    bitmap_ = nullptr;
    old_bitmap_ = nullptr;
    pixels_ = nullptr;
    if (restore_focus && IsWindow(foreground_)) SetForegroundWindow(foreground_);
    if (error) result->Error(error);
    else if (copy && !copied) result->Error("clipboard-failed");
    else result->Success(Value(copied));
  }

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* self = reinterpret_cast<ScreenshotPlugin*>(GetWindowLongPtr(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      self = static_cast<ScreenshotPlugin*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
      SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (!self) return DefWindowProc(window, message, wparam, lparam);
    switch (message) {
      case WM_PAINT: self->Paint(window); return 0;
      case WM_ERASEBKGND: return 1;
      case WM_LBUTTONDOWN:
        self->pointer_ = self->CursorPoint();
        if (self->selection_.selected() && self->Toolbar().contains(self->pointer_)) {
          self->Finish(self->pointer_.x >= self->Toolbar().left + 42 * self->UiScale());
          return 0;
        }
        self->action_point_ = self->pointer_;
        self->selection_.Begin(self->pointer_, 9 * self->UiScale());
        SetCapture(window);
        InvalidateRect(window, nullptr, FALSE);
        return 0;
      case WM_MOUSEMOVE:
        self->pointer_ = self->CursorPoint();
        self->selection_.Update(self->pointer_);
        self->UpdateCursor();
        InvalidateRect(window, nullptr, FALSE);
        return 0;
      case WM_LBUTTONUP:
        if (self->selection_.dragging()) {
          self->pointer_ = self->action_point_ = self->CursorPoint();
          self->selection_.End(self->pointer_);
          ReleaseCapture();
          InvalidateRect(window, nullptr, FALSE);
        }
        return 0;
      case WM_KEYDOWN:
        if (wparam == VK_ESCAPE) self->Finish(false);
        else if (wparam == VK_RETURN && self->selection_.selected() && !self->selection_.dragging()) self->Finish(true);
        return 0;
      case WM_SETCURSOR: self->UpdateCursor(); return TRUE;
      case WM_RBUTTONDOWN:
      case WM_CLOSE:
      case WM_DISPLAYCHANGE:
        self->Finish(false); return 0;
      case WM_ACTIVATE:
        if (LOWORD(wparam) == WA_INACTIVE) self->Finish(false);
        return 0;
      case WM_DPICHANGED: return 0;
    }
    return DefWindowProc(window, message, wparam, lparam);
  }

  flutter::PluginRegistrarWindows* registrar_;
  HWND window_;
  flutter::MethodChannel<Value> channel_;
  int delegate_ = -1;
  int hotkey_id_ = 0x5751;
  bool registered_ = false;
  UINT key_code_ = 0;
  UINT modifiers_ = 0;
  HWND overlay_ = nullptr;
  HWND foreground_ = nullptr;
  HDC snapshot_dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ old_bitmap_ = nullptr;
  uint32_t* pixels_ = nullptr;
  LONG width_ = 0;
  LONG height_ = 0;
  POINT origin_{};
  ScreenshotSelection selection_;
  CapturePoint pointer_, action_point_;
  std::wstring hint_, adjust_hint_;
  bool dark_ = false;
  std::unique_ptr<Result> pending_;
};
}  // namespace

void ScreenshotPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar, HWND window) {
  auto* plugin_registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  plugin_registrar->AddPlugin(std::make_unique<ScreenshotPlugin>(plugin_registrar, window));
}
