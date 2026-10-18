#include "wsn_image.h"

#include "wsn_window.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>

#include <algorithm>
#include <cmath>

namespace wsn {

namespace {
winrt::com_ptr<IWICImagingFactory> Factory() {
  winrt::com_ptr<IWICImagingFactory> factory;
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IWICImagingFactory),
                   factory.put_void());
  return factory;
}

bool StreamBytes(IStream* stream, std::vector<uint8_t>* out) {
  HGLOBAL global = nullptr;
  if (FAILED(GetHGlobalFromStream(stream, &global))) return false;
  STATSTG stat{};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) return false;
  size_t size = static_cast<size_t>(stat.cbSize.QuadPart);
  void* data = GlobalLock(global);
  if (data == nullptr) return false;
  out->assign(static_cast<uint8_t*>(data), static_cast<uint8_t*>(data) + size);
  GlobalUnlock(global);
  return true;
}
}  // namespace

bool ReadTexture(D3D* d3d, ID3D11Texture2D* texture, int width, int height, Bitmap* out) {
  D3D11_TEXTURE2D_DESC desc{};
  texture->GetDesc(&desc);
  width = std::min<int>(width, static_cast<int>(desc.Width));
  height = std::min<int>(height, static_cast<int>(desc.Height));
  if (width <= 0 || height <= 0) return false;
  auto staging = d3d->CreateTexture(desc.Width, desc.Height, desc.Format, 0, D3D11_USAGE_STAGING,
                                    D3D11_CPU_ACCESS_READ);
  if (!staging) return false;
  D3DLock lock(d3d);
  d3d->context()->CopyResource(staging.get(), texture);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(d3d->context()->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) return false;
  out->width = width;
  out->height = height;
  out->bgra.resize(static_cast<size_t>(width) * height * 4);
  for (int row = 0; row < height; ++row) {
    memcpy(out->bgra.data() + static_cast<size_t>(row) * width * 4,
           static_cast<const uint8_t*>(mapped.pData) + static_cast<size_t>(row) * mapped.RowPitch,
           static_cast<size_t>(width) * 4);
  }
  d3d->context()->Unmap(staging.get(), 0);
  return true;
}

bool EncodeImage(const Bitmap& bitmap, bool jpeg, float quality, std::vector<uint8_t>* out) {
  if (bitmap.empty()) return false;
  auto factory = Factory();
  if (!factory) return false;
  winrt::com_ptr<IStream> stream;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, stream.put()))) return false;
  winrt::com_ptr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(jpeg ? GUID_ContainerFormatJpeg : GUID_ContainerFormatPng, nullptr,
                                    encoder.put()))) {
    return false;
  }
  if (FAILED(encoder->Initialize(stream.get(), WICBitmapEncoderNoCache))) return false;
  winrt::com_ptr<IWICBitmapFrameEncode> frame;
  winrt::com_ptr<IPropertyBag2> options;
  if (FAILED(encoder->CreateNewFrame(frame.put(), options.put()))) return false;
  if (jpeg && options) {
    PROPBAG2 option{};
    wchar_t name[] = L"ImageQuality";
    option.pstrName = name;
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_R4;
    value.fltVal = quality;
    options->Write(1, &option, &value);
  }
  if (FAILED(frame->Initialize(options.get()))) return false;
  frame->SetSize(bitmap.width, bitmap.height);
  WICPixelFormatGUID format = jpeg ? GUID_WICPixelFormat24bppBGR : GUID_WICPixelFormat32bppBGRA;
  frame->SetPixelFormat(&format);
  if (jpeg) {
    // JPEG has no alpha: convert through a WIC bitmap.
    winrt::com_ptr<IWICBitmap> source;
    if (FAILED(factory->CreateBitmapFromMemory(bitmap.width, bitmap.height, GUID_WICPixelFormat32bppBGRA,
                                               bitmap.width * 4, static_cast<UINT>(bitmap.bgra.size()),
                                               const_cast<BYTE*>(bitmap.bgra.data()), source.put()))) {
      return false;
    }
    winrt::com_ptr<IWICFormatConverter> converter;
    if (FAILED(factory->CreateFormatConverter(converter.put())) ||
        FAILED(converter->Initialize(source.get(), GUID_WICPixelFormat24bppBGR, WICBitmapDitherTypeNone, nullptr,
                                     0, WICBitmapPaletteTypeCustom)) ||
        FAILED(frame->WriteSource(converter.get(), nullptr))) {
      return false;
    }
  } else {
    if (FAILED(frame->WritePixels(bitmap.height, bitmap.width * 4, static_cast<UINT>(bitmap.bgra.size()),
                                  const_cast<BYTE*>(bitmap.bgra.data())))) {
      return false;
    }
  }
  if (FAILED(frame->Commit()) || FAILED(encoder->Commit())) return false;
  return StreamBytes(stream.get(), out);
}

bool SaveImage(const std::wstring& path, const Bitmap& bitmap, bool jpeg, float quality) {
  std::vector<uint8_t> bytes;
  if (!EncodeImage(bitmap, jpeg, quality, &bytes)) return false;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  BOOL ok = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr);
  CloseHandle(file);
  return ok && written == bytes.size();
}

Bitmap Scale(const Bitmap& source, int max_edge) {
  int longest = std::max(source.width, source.height);
  if (source.empty() || max_edge <= 0 || longest <= max_edge) return source;
  double factor = static_cast<double>(max_edge) / longest;
  int width = std::max(1, static_cast<int>(std::lround(source.width * factor)));
  int height = std::max(1, static_cast<int>(std::lround(source.height * factor)));
  Bitmap out;
  auto factory = Factory();
  if (!factory) return out;
  winrt::com_ptr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromMemory(source.width, source.height, GUID_WICPixelFormat32bppBGRA,
                                             source.width * 4, static_cast<UINT>(source.bgra.size()),
                                             const_cast<BYTE*>(source.bgra.data()), bitmap.put()))) {
    return out;
  }
  winrt::com_ptr<IWICBitmapScaler> scaler;
  if (FAILED(factory->CreateBitmapScaler(scaler.put())) ||
      FAILED(scaler->Initialize(bitmap.get(), width, height, WICBitmapInterpolationModeHighQualityCubic))) {
    return out;
  }
  out.width = width;
  out.height = height;
  out.bgra.resize(static_cast<size_t>(width) * height * 4);
  if (FAILED(scaler->CopyPixels(nullptr, width * 4, static_cast<UINT>(out.bgra.size()), out.bgra.data()))) {
    return Bitmap();
  }
  return out;
}

Bitmap Crop(const Bitmap& source, const RECT& rect) {
  RECT r{std::max<LONG>(0, rect.left), std::max<LONG>(0, rect.top), std::min<LONG>(source.width, rect.right),
         std::min<LONG>(source.height, rect.bottom)};
  Bitmap out;
  if (r.right <= r.left || r.bottom <= r.top) return out;
  out.width = r.right - r.left;
  out.height = r.bottom - r.top;
  out.bgra.resize(static_cast<size_t>(out.width) * out.height * 4);
  for (int row = 0; row < out.height; ++row) {
    memcpy(out.bgra.data() + static_cast<size_t>(row) * out.width * 4, source.pixel(r.left, r.top + row),
           static_cast<size_t>(out.width) * 4);
  }
  return out;
}

namespace {
bool DibToBitmap(HDC dc, HBITMAP dib, const uint8_t* bits, int width, int height, Bitmap* out) {
  (void)dc;
  (void)dib;
  out->width = width;
  out->height = height;
  out->bgra.assign(bits, bits + static_cast<size_t>(width) * height * 4);
  // GDI leaves alpha undefined: make it opaque.
  for (size_t i = 3; i < out->bgra.size(); i += 4) out->bgra[i] = 255;
  return true;
}
}  // namespace

bool PrintWindowBitmap(HWND window, Bitmap* out) {
  RECT rect{};
  if (!GetWindowRect(window, &rect)) return false;
  int width = RectWidth(rect), height = RectHeight(rect);
  if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return false;
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  bool ok = false;
  if (dib != nullptr) {
    HGDIOBJ old = SelectObject(dc, dib);
    // PW_RENDERFULLCONTENT = 2.
    ok = PrintWindow(window, dc, 2) != FALSE;
    GdiFlush();
    if (ok) {
      Bitmap full;
      DibToBitmap(dc, dib, static_cast<const uint8_t*>(bits), width, height, &full);
      RECT frame = FrameBounds(window);
      RECT crop{frame.left - rect.left, frame.top - rect.top, frame.right - rect.left, frame.bottom - rect.top};
      *out = Crop(full, crop);
      ok = !out->empty();
    }
    SelectObject(dc, old);
    DeleteObject(dib);
  }
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
  return ok;
}

bool ScreenBitmap(const RECT& rect, Bitmap* out) {
  int width = RectWidth(rect), height = RectHeight(rect);
  if (width <= 0 || height <= 0) return false;
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  bool ok = false;
  if (dib != nullptr) {
    HGDIOBJ old = SelectObject(dc, dib);
    ok = BitBlt(dc, 0, 0, width, height, screen, rect.left, rect.top, SRCCOPY | CAPTUREBLT) != FALSE;
    GdiFlush();
    if (ok) DibToBitmap(dc, dib, static_cast<const uint8_t*>(bits), width, height, out);
    SelectObject(dc, old);
    DeleteObject(dib);
  }
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
  return ok;
}

bool IconToPng(HICON icon, int size, std::vector<uint8_t>* out) {
  if (icon == nullptr) return false;
  int px = std::max(16, std::min(size, 512));
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = px;
  info.bmiHeader.biHeight = -px;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  bool ok = false;
  Bitmap image;
  if (dib != nullptr) {
    HGDIOBJ old = SelectObject(dc, dib);
    memset(bits, 0, static_cast<size_t>(px) * px * 4);
    ok = DrawIconEx(dc, 0, 0, icon, px, px, 0, nullptr, DI_NORMAL) != FALSE;
    GdiFlush();
    if (ok) {
      image.width = px;
      image.height = px;
      image.bgra.assign(static_cast<uint8_t*>(bits), static_cast<uint8_t*>(bits) + static_cast<size_t>(px) * px * 4);
    }
    SelectObject(dc, old);
    DeleteObject(dib);
  }
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
  if (!ok) return false;
  // DrawIconEx on a 32-bit DIB keeps the alpha for alpha icons; some icons
  // come back fully opaque, which is fine.
  return EncodeImage(image, false, 1.0f, out);
}

bool ExeIconPng(const std::wstring& exe_path, int size, std::vector<uint8_t>* out) {
  HICON large = nullptr;
  UINT got = ExtractIconExW(exe_path.c_str(), 0, &large, nullptr, 1);
  if (got == 0 || large == nullptr) {
    SHFILEINFOW fi{};
    if (SHGetFileInfoW(exe_path.c_str(), 0, &fi, sizeof(fi), SHGFI_ICON | SHGFI_LARGEICON) && fi.hIcon) {
      large = fi.hIcon;
    }
  }
  if (large == nullptr) return false;
  bool ok = IconToPng(large, size, out);
  DestroyIcon(large);
  return ok;
}

bool ShellIconPng(const std::wstring& parsing_name, int size, std::vector<uint8_t>* out) {
  winrt::com_ptr<IShellItemImageFactory> factory;
  if (FAILED(SHCreateItemFromParsingName(parsing_name.c_str(), nullptr, __uuidof(IShellItemImageFactory),
                                         factory.put_void()))) {
    return false;
  }
  HBITMAP bitmap = nullptr;
  SIZE wanted{size, size};
  HRESULT hr = factory->GetImage(wanted, SIIGBF_ICONONLY | SIIGBF_BIGGERSIZEOK, &bitmap);
  if (FAILED(hr) || bitmap == nullptr) {
    hr = factory->GetImage(wanted, SIIGBF_BIGGERSIZEOK, &bitmap);
  }
  if (FAILED(hr) || bitmap == nullptr) return false;
  BITMAP info{};
  GetObjectW(bitmap, sizeof(info), &info);
  Bitmap image;
  bool ok = false;
  if (info.bmWidth > 0 && info.bmHeight != 0) {
    int width = info.bmWidth;
    int height = std::abs(info.bmHeight);
    image.width = width;
    image.height = height;
    image.bgra.resize(static_cast<size_t>(width) * height * 4);
    BITMAPINFO header{};
    header.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    header.bmiHeader.biWidth = width;
    header.bmiHeader.biHeight = -height;
    header.bmiHeader.biPlanes = 1;
    header.bmiHeader.biBitCount = 32;
    header.bmiHeader.biCompression = BI_RGB;
    HDC dc = GetDC(nullptr);
    ok = GetDIBits(dc, bitmap, 0, height, image.bgra.data(), &header, DIB_RGB_COLORS) == height;
    ReleaseDC(nullptr, dc);
    if (ok) {
      // The shell hands back premultiplied alpha; PNG wants it straight.
      bool any_alpha = false;
      for (size_t i = 3; i < image.bgra.size(); i += 4) {
        if (image.bgra[i] != 0) {
          any_alpha = true;
          break;
        }
      }
      for (size_t i = 0; i < image.bgra.size(); i += 4) {
        uint8_t a = image.bgra[i + 3];
        if (!any_alpha) {
          image.bgra[i + 3] = 255;
        } else if (a > 0 && a < 255) {
          for (int c = 0; c < 3; ++c) {
            image.bgra[i + c] = static_cast<uint8_t>(std::min(255, image.bgra[i + c] * 255 / a));
          }
        }
      }
    }
  }
  DeleteObject(bitmap);
  if (!ok) return false;
  if (std::max(image.width, image.height) > size) image = Scale(image, size);
  return EncodeImage(image, false, 1.0f, out);
}

}  // namespace wsn
