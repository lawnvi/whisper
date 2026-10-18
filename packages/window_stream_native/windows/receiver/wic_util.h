// WIC helpers: icons from PNG, JPEG snapshots.

#pragma once

#include "../common/wsn_common.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include "frame.h"

namespace wsn {

// A `size`×`size` icon of the PNG (fitted, centred, transparent around).
// nullptr on failure. Any thread.
HICON IconFromPng(const uint8_t* png, size_t length, int size);

// Encodes 32-bit BGRA pixels as JPEG at `path`, scaled down so the longer
// edge is at most `max_edge` (0 = as is). Any thread.
bool WriteJpeg(const std::wstring& path, const uint8_t* bgra, int width, int height, int stride, int max_edge,
               float quality = 0.85f);

// A JPEG or PNG decoded for use as a poster, its longer edge at most
// `max_edge`. Null on failure. Any thread.
std::shared_ptr<Poster> DecodePoster(const uint8_t* bytes, size_t length, int max_edge);

}  // namespace wsn
