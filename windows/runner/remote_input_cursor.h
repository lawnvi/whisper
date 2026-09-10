#ifndef WHISPER_REMOTE_INPUT_CURSOR_H_
#define WHISPER_REMOTE_INPUT_CURSOR_H_

#include <windows.h>
#include <algorithm>
#include <cstdint>

// Windows can leave the desktop cursor null when no local mouse is attached.
// A small, click-through window supplies a pointer only during remote injection.
class RemoteInputCursor {
 public:
  RemoteInputCursor() = default;
  RemoteInputCursor(const RemoteInputCursor&) = delete;
  RemoteInputCursor& operator=(const RemoteInputCursor&) = delete;
  ~RemoteInputCursor() { Reset(); }

  void Update(POINT point) {
    CURSORINFO cursor{};
    cursor.cbSize = sizeof(cursor);
    if (GetSystemMetrics(SM_MOUSEPRESENT) != 0 ||
        !GetCursorInfo(&cursor) || (cursor.flags & CURSOR_SHOWING) != 0) {
      Hide();
      return;
    }
    if (!window_ && !Create()) return;
    SetWindowPos(window_, HWND_TOPMOST, point.x - hotspot_.x,
                 point.y - hotspot_.y, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }

  void Reset() {
    if (window_) DestroyWindow(window_);
    window_ = nullptr;
  }

 private:
  void Hide() {
    if (window_) ShowWindow(window_, SW_HIDE);
  }

  bool Create() {
    constexpr wchar_t name[] = L"WhisperRemoteInputCursor";
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = DefWindowProcW;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = name;
    RegisterClassW(&window_class);
    const int width = GetSystemMetrics(SM_CXCURSOR);
    const int height = GetSystemMetrics(SM_CYCURSOR);
    HCURSOR arrow = LoadCursor(nullptr, IDC_ARROW);
    if (!arrow || width <= 0 || height <= 0) return false;
    ICONINFO icon{};
    if (GetIconInfo(arrow, &icon)) {
      hotspot_ = {static_cast<LONG>(icon.xHotspot), static_cast<LONG>(icon.yHotspot)};
      if (icon.hbmColor) DeleteObject(icon.hbmColor);
      if (icon.hbmMask) DeleteObject(icon.hbmMask);
    }
    HDC screen = GetDC(nullptr);
    HDC black = CreateCompatibleDC(screen);
    HDC white = CreateCompatibleDC(screen);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    uint32_t* pixels = nullptr;
    uint32_t* mask_pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
        reinterpret_cast<void**>(&pixels), nullptr, 0);
    HBITMAP mask = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
        reinterpret_cast<void**>(&mask_pixels), nullptr, 0);
    bool rendered = false;
    if (black && white && bitmap && mask && pixels && mask_pixels) {
      const auto old_black = SelectObject(black, bitmap);
      const auto old_white = SelectObject(white, mask);
      PatBlt(black, 0, 0, width, height, BLACKNESS);
      PatBlt(white, 0, 0, width, height, WHITENESS);
      DrawIconEx(black, 0, 0, arrow, width, height, 0, nullptr, DI_NORMAL);
      DrawIconEx(white, 0, 0, arrow, width, height, 0, nullptr, DI_NORMAL);
      GdiFlush();
      // Recover alpha for both color and monochrome system cursor themes.
      for (int i = 0; i < width * height; ++i) {
        const int alpha = 255 - std::clamp<int>(
            static_cast<int>(mask_pixels[i] & 0xff) - static_cast<int>(pixels[i] & 0xff), 0, 255);
        pixels[i] = (pixels[i] & 0x00ffffff) | (static_cast<uint32_t>(alpha) << 24);
      }
      window_ = CreateWindowExW(
          WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
          name, L"", WS_POPUP, 0, 0, width, height, nullptr, nullptr,
          GetModuleHandle(nullptr), nullptr);
      if (window_) {
        POINT origin{};
        SIZE size{width, height};
        BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
        rendered = UpdateLayeredWindow(window_, screen, nullptr, &size, black,
                                      &origin, 0, &blend, ULW_ALPHA) != FALSE;
      }
      SelectObject(black, old_black);
      SelectObject(white, old_white);
    }
    if (black) DeleteDC(black);
    if (white) DeleteDC(white);
    if (bitmap) DeleteObject(bitmap);
    if (mask) DeleteObject(mask);
    ReleaseDC(nullptr, screen);
    if (!rendered) Reset();
    return rendered;
  }

  HWND window_ = nullptr;
  POINT hotspot_{};
};

#endif  // WHISPER_REMOTE_INPUT_CURSOR_H_
