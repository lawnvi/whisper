// Pictures in and out: GPU texture → CPU pixels, PNG/JPEG through WIC,
// scaling, PrintWindow snapshots and shell icons.
#pragma once

#include "wsn_d3d.h"

#include <string>
#include <vector>

namespace wsn {

struct Bitmap {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> bgra;  // stride = width * 4
  bool empty() const { return width <= 0 || height <= 0; }
  const uint8_t* pixel(int x, int y) const { return bgra.data() + (static_cast<size_t>(y) * width + x) * 4; }
};

// Copies [width] x [height] from the top left of a BGRA texture.
bool ReadTexture(D3D* d3d, ID3D11Texture2D* texture, int width, int height, Bitmap* out);

// COM must be initialised on the calling thread.
bool EncodeImage(const Bitmap& bitmap, bool jpeg, float quality, std::vector<uint8_t>* out);
bool SaveImage(const std::wstring& path, const Bitmap& bitmap, bool jpeg = false, float quality = 0.85f);
// Fits inside max_edge (0: unchanged), high-quality filter.
Bitmap Scale(const Bitmap& source, int max_edge);
Bitmap Crop(const Bitmap& source, const RECT& rect);

// The window as DWM has it (PW_RENDERFULLCONTENT: DirectComposition and
// GPU content included), cropped to its visible frame.
bool PrintWindowBitmap(HWND window, Bitmap* out);
// A screenshot of [rect] (screen pixels) through GDI.
bool ScreenBitmap(const RECT& rect, Bitmap* out);

// The shell's icon for an app id (AUMID or file path) at [size] px, PNG.
bool ShellIconPng(const std::wstring& parsing_name, int size, std::vector<uint8_t>* out);
// An HICON as PNG at [size] px (drawn onto transparency). COM/WIC on the
// calling thread.
bool IconToPng(HICON icon, int size, std::vector<uint8_t>* out);
// The default icon of an executable (its first resource, or the generic exe
// icon), as PNG.
bool ExeIconPng(const std::wstring& exe_path, int size, std::vector<uint8_t>* out);

}  // namespace wsn
