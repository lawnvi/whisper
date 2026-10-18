#include "wic_util.h"

#include <wincodec.h>

#include <algorithm>
#include <cmath>
#include <vector>

#include "../common/com.h"

namespace wsn {
namespace {

ComPtr<IWICImagingFactory> Factory() {
  ComPtr<IWICImagingFactory> factory;
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  return factory;
}

}  // namespace

HICON IconFromPng(const uint8_t* png, size_t length, int size) {
  ScopedCom com;
  if (png == nullptr || length == 0 || size <= 0) return nullptr;
  ComPtr<IWICImagingFactory> factory = Factory();
  if (factory == nullptr) return nullptr;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(png), static_cast<DWORD>(length))) ||
      FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame))) {
    return nullptr;
  }
  UINT width = 0;
  UINT height = 0;
  frame->GetSize(&width, &height);
  if (width == 0 || height == 0) return nullptr;
  double scale = std::min(static_cast<double>(size) / width, static_cast<double>(size) / height);
  UINT fitted_width = std::max<UINT>(1, static_cast<UINT>(std::lround(width * scale)));
  UINT fitted_height = std::max<UINT>(1, static_cast<UINT>(std::lround(height * scale)));
  ComPtr<IWICBitmapScaler> scaler;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateBitmapScaler(&scaler)) ||
      FAILED(scaler->Initialize(frame.Get(), fitted_width, fitted_height, WICBitmapInterpolationModeHighQualityCubic)) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                   WICBitmapPaletteTypeCustom))) {
    return nullptr;
  }
  std::vector<uint8_t> pixels(static_cast<size_t>(fitted_width) * fitted_height * 4);
  if (FAILED(converter->CopyPixels(nullptr, fitted_width * 4, static_cast<UINT>(pixels.size()), pixels.data()))) {
    return nullptr;
  }
  BITMAPV5HEADER header = {};
  header.bV5Size = sizeof(header);
  header.bV5Width = size;
  header.bV5Height = -size;
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;
  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(screen, reinterpret_cast<BITMAPINFO*>(&header), DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, screen);
  if (color == nullptr || bits == nullptr) {
    if (color != nullptr) DeleteObject(color);
    return nullptr;
  }
  auto* target = static_cast<uint8_t*>(bits);
  std::fill(target, target + static_cast<size_t>(size) * size * 4, static_cast<uint8_t>(0));
  UINT offset_x = (size - fitted_width) / 2;
  UINT offset_y = (size - fitted_height) / 2;
  for (UINT y = 0; y < fitted_height; y++) {
    std::copy(pixels.begin() + static_cast<ptrdiff_t>(y) * fitted_width * 4,
              pixels.begin() + static_cast<ptrdiff_t>(y + 1) * fitted_width * 4,
              target + (static_cast<size_t>(offset_y + y) * size + offset_x) * 4);
  }
  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  ICONINFO info = {};
  info.fIcon = TRUE;
  info.hbmMask = mask;
  info.hbmColor = color;
  HICON icon = CreateIconIndirect(&info);
  DeleteObject(mask);
  DeleteObject(color);
  return icon;
}

bool WriteJpeg(const std::wstring& path, const uint8_t* bgra, int width, int height, int stride, int max_edge,
               float quality) {
  ScopedCom com;
  if (bgra == nullptr || width <= 0 || height <= 0) return false;
  ComPtr<IWICImagingFactory> factory = Factory();
  if (factory == nullptr) return false;
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromMemory(static_cast<UINT>(width), static_cast<UINT>(height),
                                             GUID_WICPixelFormat32bppBGRA, static_cast<UINT>(stride),
                                             static_cast<UINT>(stride) * height, const_cast<BYTE*>(bgra), &bitmap))) {
    return false;
  }
  ComPtr<IWICBitmapSource> source = bitmap;
  UINT out_width = static_cast<UINT>(width);
  UINT out_height = static_cast<UINT>(height);
  int longest = std::max(width, height);
  if (max_edge > 0 && longest > max_edge) {
    double scale = static_cast<double>(max_edge) / longest;
    out_width = std::max<UINT>(1, static_cast<UINT>(std::lround(width * scale)));
    out_height = std::max<UINT>(1, static_cast<UINT>(std::lround(height * scale)));
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(factory->CreateBitmapScaler(&scaler)) ||
        FAILED(scaler->Initialize(bitmap.Get(), out_width, out_height, WICBitmapInterpolationModeFant))) {
      return false;
    }
    source = scaler;
  }
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  if (FAILED(factory->CreateStream(&stream)) || FAILED(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE)) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(&frame, &properties))) {
    return false;
  }
  PROPBAG2 option = {};
  wchar_t name[] = L"ImageQuality";
  option.pstrName = name;
  VARIANT value;
  VariantInit(&value);
  value.vt = VT_R4;
  value.fltVal = quality;
  properties->Write(1, &option, &value);
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  if (FAILED(frame->Initialize(properties.Get())) || FAILED(frame->SetSize(out_width, out_height)) ||
      FAILED(frame->SetPixelFormat(&format)) || FAILED(frame->WriteSource(source.Get(), nullptr)) ||
      FAILED(frame->Commit()) || FAILED(encoder->Commit())) {
    return false;
  }
  return true;
}

std::shared_ptr<Poster> DecodePoster(const uint8_t* bytes, size_t length, int max_edge) {
  ScopedCom com;
  if (bytes == nullptr || length == 0) return nullptr;
  ComPtr<IWICImagingFactory> factory = Factory();
  if (factory == nullptr) return nullptr;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(bytes), static_cast<DWORD>(length))) ||
      FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame))) {
    return nullptr;
  }
  UINT width = 0;
  UINT height = 0;
  frame->GetSize(&width, &height);
  if (width == 0 || height == 0) return nullptr;
  ComPtr<IWICBitmapSource> source = frame;
  const UINT longest = std::max(width, height);
  if (max_edge > 0 && longest > static_cast<UINT>(max_edge)) {
    const double scale = static_cast<double>(max_edge) / longest;
    width = std::max<UINT>(1, static_cast<UINT>(std::lround(width * scale)));
    height = std::max<UINT>(1, static_cast<UINT>(std::lround(height * scale)));
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(factory->CreateBitmapScaler(&scaler)) ||
        FAILED(scaler->Initialize(frame.Get(), width, height, WICBitmapInterpolationModeFant))) {
      return nullptr;
    }
    source = scaler;
  }
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                   WICBitmapPaletteTypeCustom))) {
    return nullptr;
  }
  auto poster = std::make_shared<Poster>();
  poster->width = static_cast<int>(width);
  poster->height = static_cast<int>(height);
  poster->bgra.resize(static_cast<size_t>(width) * height * 4);
  if (FAILED(converter->CopyPixels(nullptr, width * 4, static_cast<UINT>(poster->bgra.size()), poster->bgra.data()))) {
    return nullptr;
  }
  // Opaque: whatever was transparent shows black, like the window.
  for (size_t i = 3; i < poster->bgra.size(); i += 4) poster->bgra[i] = 255;
  return poster;
}

}  // namespace wsn
