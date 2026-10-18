// Types shared by the decoder and the presenters of a streamed window.

#pragma once

#include "../common/com.h"

#include <d3d11.h>
#include <mfobjects.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace wsn {

// One decoded picture: an NV12 texture slice (hardware decoding) or NV12
// bytes in memory (software decoding).
struct DecodedFrame {
  // GPU: the decoder's texture array and slice. `sample` keeps the slice
  // from being reused by the decoder while the frame is held.
  ComPtr<IMFSample> sample;
  ComPtr<ID3D11Texture2D> texture;
  UINT subresource = 0;
  // CPU: Y plane (`pitch` per row, `coded_height` rows) then the
  // interleaved UV plane.
  std::shared_ptr<std::vector<uint8_t>> nv12;
  int pitch = 0;
  // Size of the decoded buffer and the part of it that is picture (H.264
  // codes 1080p as 1088 rows, for instance).
  int coded_width = 0;
  int coded_height = 0;
  RECT visible = {};
  bool bt709 = false;
  bool full_range = false;
  int64_t pts_us = 0;
  double decoded_at = 0;  // NowSeconds()

  bool gpu() const { return texture != nullptr; }
  int width() const { return visible.right - visible.left; }
  int height() const { return visible.bottom - visible.top; }
};

// A still picture shown while a stream opens: the window's last known
// picture (top-down, opaque BGRA).
struct Poster {
  std::vector<uint8_t> bgra;
  int width = 0;
  int height = 0;
};

// What is drawn over the video.
struct OverlayState {
  int32_t visual = WSN_VISUAL_CONNECTING;
  std::wstring message;
  bool hud_enabled = false;
  std::wstring hud_text;
};

// The largest rect with the video's aspect ratio centred in the client
// area (black bars on the other axis).
inline RECT LetterboxRect(int client_width, int client_height, int video_width, int video_height) {
  RECT rect = {0, 0, client_width, client_height};
  if (video_width <= 0 || video_height <= 0 || client_width <= 0 || client_height <= 0) {
    return rect;
  }
  double scale = std::min(static_cast<double>(client_width) / video_width,
                          static_cast<double>(client_height) / video_height);
  int width = std::min(client_width, static_cast<int>(std::lround(video_width * scale)));
  int height = std::min(client_height, static_cast<int>(std::lround(video_height * scale)));
  rect.left = (client_width - width) / 2;
  rect.top = (client_height - height) / 2;
  rect.right = rect.left + width;
  rect.bottom = rect.top + height;
  return rect;
}

}  // namespace wsn
