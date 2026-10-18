// CPU pixel conversion for the fallback presenter.

#pragma once

#include "../common/wsn_common.h"

#include <cstdint>
#include <vector>

namespace wsn {

// NV12 (Y rows of `pitch`, `coded_height` of them, then interleaved UV) →
// BGRA of the `visible` part, scaled to `out_width`×`out_height` (bilinear
// luma, nearest chroma). Returns false when the input is too small.
bool Nv12ToBgraScaled(const std::vector<uint8_t>& nv12, int pitch, int coded_height, const RECT& visible,
                      bool bt709, bool full_range, int out_width, int out_height, std::vector<uint8_t>& out);

}  // namespace wsn
