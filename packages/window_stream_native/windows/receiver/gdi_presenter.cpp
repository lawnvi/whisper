#include "gdi_presenter.h"

#include <algorithm>
#include <cmath>

#include "convert.h"
#include "spinner.h"
#include "wic_util.h"

namespace wsn {

GdiPresenter::GdiPresenter(std::function<void()> on_ready) : on_ready_(std::move(on_ready)) {
  converter_ = std::thread([this] { ConvertLoop(); });
}

GdiPresenter::~GdiPresenter() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  convert_cv_.notify_all();
  if (converter_.joinable()) {
    if (converter_.get_id() == std::this_thread::get_id()) {
      converter_.detach();
    } else {
      converter_.join();
    }
  }
  if (message_font_ != nullptr) DeleteObject(message_font_);
  if (hud_font_ != nullptr) DeleteObject(hud_font_);
}

void GdiPresenter::SetReadiness(std::shared_ptr<Readiness> readiness, std::function<void()> on_stable) {
  readiness_ = std::move(readiness);
  on_stable_ = std::move(on_stable);
  spinner_color_ = SpinnerColor();
}

void GdiPresenter::SetPoster(std::shared_ptr<const Poster> poster) { poster_ = std::move(poster); }

void GdiPresenter::SetIcon(std::shared_ptr<const Poster> icon) { icon_ = std::move(icon); }

void GdiPresenter::SetTargetSize(int width, int height) {
  target_width_ = width;
  target_height_ = height;
}

void GdiPresenter::Submit(const DecodedFrame& frame) {
  if (frame.nv12 == nullptr || frame.width() <= 1 || frame.height() <= 1) return;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_ = frame;
    have_pending_ = true;
    source_ = frame;
  }
  convert_cv_.notify_one();
}

void GdiPresenter::ConvertLoop() {
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
  for (;;) {
    DecodedFrame frame;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      convert_cv_.wait(lock, [this] { return stopping_ || have_pending_; });
      if (stopping_) return;
      frame = std::move(pending_);
      pending_ = DecodedFrame();
      have_pending_ = false;
    }
    int width = target_width_;
    int height = target_height_;
    if (width <= 0 || height <= 0) {
      width = frame.width();
      height = frame.height();
    }
    auto picture = std::make_shared<Picture>();
    const double started = NowSeconds();
    if (!Nv12ToBgraScaled(*frame.nv12, frame.pitch, frame.coded_height, frame.visible, frame.bt709,
                          frame.full_range, width, height, picture->bgra)) {
      continue;
    }
    picture->width = width;
    picture->height = height;
    if (++converted_ % 1800 == 1) {
      Log("gdi: %dx%d -> %dx%d converted in %.1f ms", frame.width(), frame.height(), width, height,
          (NowSeconds() - started) * 1000);
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      picture_ = std::move(picture);
      fresh_ = true;
    }
    if (on_ready_) on_ready_();
  }
}

void GdiPresenter::EnsureFonts(double scale) {
  if (message_font_ != nullptr && font_scale_ == scale) return;
  if (message_font_ != nullptr) DeleteObject(message_font_);
  if (hud_font_ != nullptr) DeleteObject(hud_font_);
  font_scale_ = scale;
  message_font_ = CreateFontW(-static_cast<int>(15 * scale + 0.5), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                              DEFAULT_PITCH, L"Segoe UI");
  hud_font_ = CreateFontW(-static_cast<int>(11 * scale + 0.5), 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE,
                          DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH,
                          L"Consolas");
}

bool GdiPresenter::Paint(HWND hwnd, const OverlayState& overlay, double scale) {
  PAINTSTRUCT paint;
  HDC dc = BeginPaint(hwnd, &paint);
  RECT client;
  GetClientRect(hwnd, &client);
  if (client.right <= 0 || client.bottom <= 0) {
    EndPaint(hwnd, &paint);
    return false;
  }
  const bool live = overlay.visual == WSN_VISUAL_LIVE || overlay.visual == WSN_VISUAL_CONNECTING;
  Readiness::View view;
  if (readiness_ != nullptr && live) view = readiness_->Evaluate(NowSeconds());
  if (view.became_stable && on_stable_) on_stable_();
  EnsureFonts(scale);
  HDC memory = CreateCompatibleDC(dc);
  HBITMAP bitmap = CreateCompatibleBitmap(dc, client.right, client.bottom);
  HGDIOBJ old = SelectObject(memory, bitmap);
  FillRect(memory, &client, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
  std::shared_ptr<const Picture> picture;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    picture = picture_;
    if (fresh_ && picture != nullptr) {
      fresh_ = false;
      painted_++;
    }
  }
  const bool have_frame = picture != nullptr;
  if (have_frame && (!live || view.show_frames)) {
    RECT rect = LetterboxRect(client.right, client.bottom, picture->width, picture->height);
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = picture->width;
    info.bmiHeader.biHeight = -picture->height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    if (rect.right - rect.left == picture->width && rect.bottom - rect.top == picture->height) {
      SetDIBitsToDevice(memory, rect.left, rect.top, picture->width, picture->height, 0, 0, 0, picture->height,
                        picture->bgra.data(), &info, DIB_RGB_COLORS);
    } else {
      // Until a frame converted at the new size arrives.
      SetStretchBltMode(memory, HALFTONE);
      SetBrushOrgEx(memory, 0, 0, nullptr);
      StretchDIBits(memory, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, 0, 0,
                    picture->width, picture->height, picture->bgra.data(), &info, DIB_RGB_COLORS, SRCCOPY);
    }
  }
  SetBkMode(memory, TRANSPARENT);
  if (live) {
    if (view.cover > 0) DrawCover(memory, client, scale, view, overlay);
  } else {
    if (have_frame) {
      // Dim the last frame.
      BLENDFUNCTION blend = {AC_SRC_OVER, 0, static_cast<BYTE>(overlay.visual == WSN_VISUAL_PAUSED ? 130 : 160), 0};
      HDC shade = CreateCompatibleDC(memory);
      HBITMAP black = CreateCompatibleBitmap(memory, 1, 1);
      HGDIOBJ previous = SelectObject(shade, black);
      AlphaBlend(memory, 0, 0, client.right, client.bottom, shade, 0, 0, 1, 1, blend);
      SelectObject(shade, previous);
      DeleteObject(black);
      DeleteDC(shade);
    } else {
      HBRUSH panel = CreateSolidBrush(RGB(28, 28, 30));
      FillRect(memory, &client, panel);
      DeleteObject(panel);
    }
    if (!overlay.message.empty()) {
      HGDIOBJ previous_font = SelectObject(memory, message_font_);
      SetTextColor(memory, RGB(242, 242, 242));
      int box = static_cast<int>(std::max(40.0, std::min(client.right / scale - 48, 320.0)) * scale);
      RECT measure = {0, 0, box, 0};
      DrawTextW(memory, overlay.message.c_str(), -1, &measure, DT_CENTER | DT_WORDBREAK | DT_CALCRECT);
      int text_height = std::min<int>(measure.bottom, static_cast<int>(80 * scale));
      RECT text = {(client.right - box) / 2, (client.bottom - text_height) / 2, (client.right + box) / 2,
                   (client.bottom + text_height) / 2};
      DrawTextW(memory, overlay.message.c_str(), -1, &text, DT_CENTER | DT_WORDBREAK | DT_END_ELLIPSIS);
      SelectObject(memory, previous_font);
    }
  }
  if (overlay.hud_enabled && !overlay.hud_text.empty()) {
    HGDIOBJ previous_font = SelectObject(memory, hud_font_);
    const int margin = static_cast<int>(8 * scale);
    RECT measure = {0, 0, client.right - margin * 3, 0};
    DrawTextW(memory, overlay.hud_text.c_str(), -1, &measure, DT_LEFT | DT_WORDBREAK | DT_CALCRECT);
    RECT panel = {margin, margin, margin + measure.right + margin, margin + measure.bottom + margin * 3 / 4};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, 140, 0};
    HDC shade = CreateCompatibleDC(memory);
    HBITMAP black = CreateCompatibleBitmap(memory, 1, 1);
    HGDIOBJ previous = SelectObject(shade, black);
    AlphaBlend(memory, panel.left, panel.top, panel.right - panel.left, panel.bottom - panel.top, shade, 0, 0, 1, 1,
               blend);
    SelectObject(shade, previous);
    DeleteObject(black);
    DeleteDC(shade);
    SetTextColor(memory, RGB(255, 255, 255));
    RECT text = {margin + margin / 2, margin + margin * 3 / 8, panel.right, panel.bottom};
    DrawTextW(memory, overlay.hud_text.c_str(), -1, &text, DT_LEFT | DT_WORDBREAK);
    SelectObject(memory, previous_font);
  }
  BitBlt(dc, 0, 0, client.right, client.bottom, memory, 0, 0, SRCCOPY);
  SelectObject(memory, old);
  DeleteObject(bitmap);
  DeleteDC(memory);
  EndPaint(hwnd, &paint);
  if (view.cover <= 0) spinner_epoch_ = -1;
  return view.animating;
}

void GdiPresenter::DrawCover(HDC memory, const RECT& client, double scale, const Readiness::View& view,
                             const OverlayState& overlay) {
  // The cover is drawn on its own and blended in, so it can fade.
  HDC layer = CreateCompatibleDC(memory);
  HBITMAP bitmap = CreateCompatibleBitmap(memory, client.right, client.bottom);
  HGDIOBJ old = SelectObject(layer, bitmap);
  BLENDFUNCTION dim = {AC_SRC_OVER, 0, 0, 0};
  HDC shade = CreateCompatibleDC(layer);
  HBITMAP black = CreateCompatibleBitmap(layer, 1, 1);
  HGDIOBJ previous = SelectObject(shade, black);
  if (view.cover_is_last_frame) {
    BitBlt(layer, 0, 0, client.right, client.bottom, memory, 0, 0, SRCCOPY);
    dim.SourceConstantAlpha = 102;  // 40%
    AlphaBlend(layer, 0, 0, client.right, client.bottom, shade, 0, 0, 1, 1, dim);
  } else {
    FillRect(layer, &client, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    if (poster_ != nullptr) {
      const RECT rect = LetterboxRect(client.right, client.bottom, poster_->width, poster_->height);
      BITMAPINFO info = {};
      info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      info.bmiHeader.biWidth = poster_->width;
      info.bmiHeader.biHeight = -poster_->height;
      info.bmiHeader.biPlanes = 1;
      info.bmiHeader.biBitCount = 32;
      info.bmiHeader.biCompression = BI_RGB;
      SetStretchBltMode(layer, HALFTONE);
      SetBrushOrgEx(layer, 0, 0, nullptr);
      StretchDIBits(layer, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, 0, 0, poster_->width,
                    poster_->height, poster_->bgra.data(), &info, DIB_RGB_COLORS, SRCCOPY);
      dim.SourceConstantAlpha = 89;  // 35%
      AlphaBlend(layer, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, shade, 0, 0, 1, 1, dim);
    }
  }
  int cy = client.bottom / 2;
  if (!view.cover_is_last_frame && poster_ == nullptr && icon_ != nullptr) {
    // The app's icon, the spinner under it, together in the middle.
    const int icon = static_cast<int>(std::lround(kPlaceholderIcon * scale));
    const int group = static_cast<int>(std::lround((kPlaceholderIcon + kPlaceholderGap + kSpinnerDiameter) * scale));
    const int top = (client.bottom - group) / 2;
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = icon_->width;
    info.bmiHeader.biHeight = -icon_->height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    SetStretchBltMode(layer, HALFTONE);
    SetBrushOrgEx(layer, 0, 0, nullptr);
    StretchDIBits(layer, (client.right - icon) / 2, top, icon, icon, 0, 0, icon_->width, icon_->height,
                  icon_->bgra.data(), &info, DIB_RGB_COLORS, SRCCOPY);
    cy = top + static_cast<int>(std::lround((kPlaceholderIcon + kPlaceholderGap + kSpinnerDiameter / 2) * scale));
  }
  SelectObject(shade, previous);
  DeleteObject(black);
  DeleteDC(shade);
  const int cx = client.right / 2;
  if (view.spinner) {
    const double now = NowSeconds();
    if (spinner_epoch_ < 0) spinner_epoch_ = now;
    double start = 0;
    double sweep = 0;
    SpinnerArc(now - spinner_epoch_, &start, &sweep);
    const int stroke = std::max(2, static_cast<int>(std::lround(kSpinnerStroke * scale)));
    const int radius = static_cast<int>(std::lround((kSpinnerDiameter - kSpinnerStroke) / 2 * scale));
    LOGBRUSH brush = {BS_SOLID, spinner_color_, 0};
    HPEN pen = ExtCreatePen(PS_GEOMETRIC | PS_SOLID | PS_ENDCAP_ROUND, static_cast<DWORD>(stroke), &brush, 0, nullptr);
    HGDIOBJ previous_pen = SelectObject(layer, pen);
    constexpr double kRad = 3.14159265358979323846 / 180.0;
    MoveToEx(layer, cx + static_cast<int>(std::lround(radius * std::sin(start * kRad))),
             cy - static_cast<int>(std::lround(radius * std::cos(start * kRad))), nullptr);
    AngleArc(layer, cx, cy, static_cast<DWORD>(radius), static_cast<FLOAT>(90 - start), static_cast<FLOAT>(-sweep));
    SelectObject(layer, previous_pen);
    DeleteObject(pen);
  }
  if (view.hint && !overlay.message.empty()) {
    HGDIOBJ previous_font = SelectObject(layer, message_font_);
    SetBkMode(layer, TRANSPARENT);
    SetTextColor(layer, RGB(230, 230, 230));
    const int box = static_cast<int>(std::max(40.0, std::min(client.right / scale - 48, 320.0)) * scale);
    const int top = cy + static_cast<int>((kSpinnerDiameter / 2 + 12) * scale);
    RECT text = {(client.right - box) / 2, top, (client.right + box) / 2, top + static_cast<int>(60 * scale)};
    DrawTextW(layer, overlay.message.c_str(), -1, &text, DT_CENTER | DT_WORDBREAK | DT_END_ELLIPSIS);
    SelectObject(layer, previous_font);
  }
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, static_cast<BYTE>(std::lround(std::clamp(view.cover, 0.0, 1.0) * 255)), 0};
  AlphaBlend(memory, 0, 0, client.right, client.bottom, layer, 0, 0, client.right, client.bottom, blend);
  SelectObject(layer, old);
  DeleteObject(bitmap);
  DeleteDC(layer);
}

bool GdiPresenter::CaptureFrame(int max_edge, Poster* out) {
  DecodedFrame source;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    source = source_;
  }
  if (source.nv12 == nullptr) return false;
  int width = source.width();
  int height = source.height();
  int longest = std::max(width, height);
  if (max_edge > 0 && longest > max_edge) {
    width = std::max(1, width * max_edge / longest);
    height = std::max(1, height * max_edge / longest);
  }
  if (!Nv12ToBgraScaled(*source.nv12, source.pitch, source.coded_height, source.visible, source.bt709,
                        source.full_range, width, height, out->bgra)) {
    return false;
  }
  out->width = width;
  out->height = height;
  return true;
}

int32_t GdiPresenter::Snapshot(const std::wstring& path, int max_edge) {
  DecodedFrame source;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    source = source_;
  }
  if (source.nv12 == nullptr) return -2;
  int width = source.width();
  int height = source.height();
  int longest = std::max(width, height);
  if (max_edge > 0 && longest > max_edge) {
    width = std::max(1, width * max_edge / longest);
    height = std::max(1, height * max_edge / longest);
  }
  std::vector<uint8_t> bgra;
  if (!Nv12ToBgraScaled(*source.nv12, source.pitch, source.coded_height, source.visible, source.bt709,
                        source.full_range, width, height, bgra)) {
    return -2;
  }
  return WriteJpeg(path, bgra.data(), width, height, width * 4, 0) ? 0 : -2;
}

}  // namespace wsn
