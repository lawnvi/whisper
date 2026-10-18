#include "convert.h"

#include <algorithm>
#include <cstddef>

namespace wsn {
namespace {

inline uint8_t Clamp(int value) { return static_cast<uint8_t>(value < 0 ? 0 : (value > 255 ? 255 : value)); }

// Runs body(begin, end) over [0, count) in a few slices on the system
// thread pool and waits for all of them.
template <typename Body>
void ParallelRows(int count, const Body& body) {
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  const int slices = std::clamp<int>(static_cast<int>(info.dwNumberOfProcessors) / 2, 1, 8);
  if (slices == 1 || count < 64) {
    body(0, count);
    return;
  }
  struct Slice {
    const Body* body;
    int begin;
    int end;
  };
  std::vector<Slice> work;
  for (int k = 0; k < slices; k++) {
    work.push_back({&body, count * k / slices, count * (k + 1) / slices});
  }
  std::vector<PTP_WORK> items;
  for (size_t k = 1; k < work.size(); k++) {
    PTP_WORK item = CreateThreadpoolWork(
        [](PTP_CALLBACK_INSTANCE, PVOID context, PTP_WORK) {
          auto* slice = static_cast<Slice*>(context);
          (*slice->body)(slice->begin, slice->end);
        },
        &work[k], nullptr);
    if (item == nullptr) {
      body(work[k].begin, work[k].end);
      continue;
    }
    SubmitThreadpoolWork(item);
    items.push_back(item);
  }
  body(work[0].begin, work[0].end);
  for (PTP_WORK item : items) {
    WaitForThreadpoolWorkCallbacks(item, FALSE);
    CloseThreadpoolWork(item);
  }
}

}  // namespace

bool Nv12ToBgraScaled(const std::vector<uint8_t>& nv12, int pitch, int coded_height, const RECT& visible,
                      bool bt709, bool full_range, int out_width, int out_height, std::vector<uint8_t>& out) {
  const int left = std::max<int>(0, visible.left);
  const int top = std::max<int>(0, visible.top);
  const int width = visible.right - left;
  const int height = visible.bottom - top;
  if (width < 2 || height < 2 || pitch < visible.right || out_width <= 0 || out_height <= 0 ||
      coded_height < visible.bottom) {
    return false;
  }
  const size_t needed = static_cast<size_t>(pitch) * coded_height + static_cast<size_t>(pitch) * (coded_height / 2);
  if (nv12.size() < needed) return false;
  out.resize(static_cast<size_t>(out_width) * out_height * 4);
  const uint8_t* y_plane = nv12.data();
  const uint8_t* uv_plane = y_plane + static_cast<size_t>(pitch) * coded_height;
  // Fixed point (x256) coefficients.
  int y_scale, y_offset, rv, gu, gv, bu;
  if (full_range) {
    y_scale = 256;
    y_offset = 0;
    rv = bt709 ? 403 : 359;
    gu = bt709 ? 48 : 88;
    gv = bt709 ? 120 : 183;
    bu = bt709 ? 475 : 454;
  } else {
    y_scale = 298;
    y_offset = 16;
    rv = bt709 ? 459 : 409;
    gu = bt709 ? 55 : 100;
    gv = bt709 ? 136 : 208;
    bu = bt709 ? 541 : 516;
  }
  // Source position of each output column (16.16 fixed point, pixel
  // centres aligned).
  std::vector<int> column(static_cast<size_t>(out_width));
  for (int x = 0; x < out_width; x++) {
    double source = (x + 0.5) * width / out_width - 0.5;
    source = std::clamp(source, 0.0, static_cast<double>(width - 1));
    column[x] = static_cast<int>(source * 65536.0);
  }
  ParallelRows(out_height, [&](int first_row, int end_row) {
  for (int y = first_row; y < end_row; y++) {
    double source_y = (y + 0.5) * height / out_height - 0.5;
    source_y = std::clamp(source_y, 0.0, static_cast<double>(height - 1));
    const int y0 = static_cast<int>(source_y);
    const int y1 = std::min(y0 + 1, height - 1);
    const int fy = static_cast<int>((source_y - y0) * 256);
    const uint8_t* row0 = y_plane + static_cast<size_t>(pitch) * (top + y0) + left;
    const uint8_t* row1 = y_plane + static_cast<size_t>(pitch) * (top + y1) + left;
    const uint8_t* uv_row = uv_plane + static_cast<size_t>(pitch) * ((top + static_cast<int>(source_y + 0.5)) / 2);
    uint8_t* dst = out.data() + static_cast<size_t>(out_width) * 4 * y;
    for (int x = 0; x < out_width; x++) {
      const int sx = column[x];
      const int x0 = sx >> 16;
      const int x1 = std::min(x0 + 1, width - 1);
      const int fx = (sx >> 8) & 0xFF;
      const int top_luma = row0[x0] * (256 - fx) + row0[x1] * fx;
      const int bottom_luma = row1[x0] * (256 - fx) + row1[x1] * fx;
      const int luma = (top_luma * (256 - fy) + bottom_luma * fy) >> 16;
      const int chroma_x = ((left + ((sx + 32768) >> 16)) & ~1);
      const int d = uv_row[chroma_x] - 128;
      const int e = uv_row[chroma_x + 1] - 128;
      const int c = (luma - y_offset) * y_scale + 128;
      dst[0] = Clamp((c + bu * d) >> 8);
      dst[1] = Clamp((c - gu * d - gv * e) >> 8);
      dst[2] = Clamp((c + rv * e) >> 8);
      dst[3] = 255;
      dst += 4;
    }
  }
  });
  return true;
}

}  // namespace wsn
