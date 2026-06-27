#include "desktop_clipboard_image_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <objidl.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

constexpr char kDesktopClipboardImageChannel[] =
    "com.vireen.whisper/desktop_clipboard_image";

class ScopedClipboard {
 public:
  explicit ScopedClipboard(HWND window) : opened_(OpenClipboard(window)) {}
  ~ScopedClipboard() {
    if (opened_) {
      CloseClipboard();
    }
  }

  bool opened() const { return opened_; }

 private:
  bool opened_ = false;
};

class ScopedGlobalLock {
 public:
  explicit ScopedGlobalLock(HGLOBAL handle)
      : handle_(handle), data_(GlobalLock(handle)) {}
  ~ScopedGlobalLock() {
    if (data_ != nullptr) {
      GlobalUnlock(handle_);
    }
  }

  void* data() const { return data_; }

 private:
  HGLOBAL handle_ = nullptr;
  void* data_ = nullptr;
};

class ScopedCom {
 public:
  ScopedCom() {
    const HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    initialized_ = SUCCEEDED(hr);
  }
  ~ScopedCom() {
    if (initialized_) {
      CoUninitialize();
    }
  }

 private:
  bool initialized_ = false;
};

std::optional<std::vector<uint8_t>> ReadClipboardGlobalBytes(UINT format) {
  HANDLE handle = GetClipboardData(format);
  if (handle == nullptr) {
    return std::nullopt;
  }
  HGLOBAL global = static_cast<HGLOBAL>(handle);
  const SIZE_T size = GlobalSize(global);
  if (size == 0) {
    return std::nullopt;
  }
  ScopedGlobalLock lock(global);
  if (lock.data() == nullptr) {
    return std::nullopt;
  }
  const auto* bytes = static_cast<const uint8_t*>(lock.data());
  return std::vector<uint8_t>(bytes, bytes + size);
}

size_t DibColorTableSize(const BITMAPINFOHEADER& header) {
  if (header.biBitCount > 8) {
    return header.biClrUsed == 0
               ? 0
               : static_cast<size_t>(header.biClrUsed) * sizeof(RGBQUAD);
  }
  const DWORD color_count =
      header.biClrUsed == 0 ? (1u << header.biBitCount) : header.biClrUsed;
  return static_cast<size_t>(color_count) * sizeof(RGBQUAD);
}

std::optional<std::vector<uint8_t>> EncodeBgraAsPng(
    int width,
    int height,
    const std::vector<uint8_t>& bgra) {
  if (width <= 0 || height <= 0 || bgra.empty()) {
    return std::nullopt;
  }

  ScopedCom com;
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    return std::nullopt;
  }

  ComPtr<IStream> stream;
  hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  if (FAILED(hr)) {
    return std::nullopt;
  }

  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (FAILED(hr)) {
    return std::nullopt;
  }
  hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) {
    return std::nullopt;
  }

  ComPtr<IWICBitmapFrameEncode> frame;
  hr = encoder->CreateNewFrame(&frame, nullptr);
  if (FAILED(hr)) {
    return std::nullopt;
  }
  hr = frame->Initialize(nullptr);
  if (FAILED(hr)) {
    return std::nullopt;
  }
  hr = frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height));
  if (FAILED(hr)) {
    return std::nullopt;
  }
  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
  hr = frame->SetPixelFormat(&pixel_format);
  if (FAILED(hr)) {
    return std::nullopt;
  }
  const UINT stride = static_cast<UINT>(width * 4);
  hr = frame->WritePixels(static_cast<UINT>(height), stride,
                          static_cast<UINT>(bgra.size()),
                          const_cast<BYTE*>(bgra.data()));
  if (FAILED(hr)) {
    return std::nullopt;
  }
  hr = frame->Commit();
  if (FAILED(hr)) {
    return std::nullopt;
  }
  hr = encoder->Commit();
  if (FAILED(hr)) {
    return std::nullopt;
  }

  LARGE_INTEGER start = {};
  hr = stream->Seek(start, STREAM_SEEK_SET, nullptr);
  if (FAILED(hr)) {
    return std::nullopt;
  }
  STATSTG stat = {};
  hr = stream->Stat(&stat, STATFLAG_NONAME);
  if (FAILED(hr) || stat.cbSize.QuadPart <= 0 ||
      stat.cbSize.QuadPart > static_cast<ULONGLONG>(UINT32_MAX)) {
    return std::nullopt;
  }
  std::vector<uint8_t> png(static_cast<size_t>(stat.cbSize.QuadPart));
  ULONG read = 0;
  hr = stream->Read(png.data(), static_cast<ULONG>(png.size()), &read);
  if (FAILED(hr) || read != png.size()) {
    return std::nullopt;
  }
  return png;
}

std::optional<std::vector<uint8_t>> ConvertDibToPng(
    const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) {
    return std::nullopt;
  }
  BITMAPINFOHEADER header = {};
  std::memcpy(&header, dib.data(), sizeof(BITMAPINFOHEADER));
  if (header.biSize < sizeof(BITMAPINFOHEADER) || header.biWidth == 0 ||
      header.biHeight == 0) {
    return std::nullopt;
  }
  if (header.biBitCount != 24 && header.biBitCount != 32) {
    return std::nullopt;
  }
  if (header.biCompression != BI_RGB &&
      header.biCompression != BI_BITFIELDS) {
    return std::nullopt;
  }

  const int width = std::abs(header.biWidth);
  const int height = std::abs(header.biHeight);
  const size_t source_stride =
      ((static_cast<size_t>(width) * header.biBitCount + 31) / 32) * 4;
  size_t pixel_offset = header.biSize;
  if (header.biCompression == BI_BITFIELDS &&
      header.biSize == sizeof(BITMAPINFOHEADER)) {
    pixel_offset += 3 * sizeof(DWORD);
  }
  pixel_offset += DibColorTableSize(header);
  const size_t source_size = source_stride * static_cast<size_t>(height);
  if (pixel_offset > dib.size() || source_size > dib.size() - pixel_offset) {
    return std::nullopt;
  }

  std::vector<uint8_t> bgra(static_cast<size_t>(width) * height * 4);
  const bool top_down = header.biHeight < 0;
  bool has_alpha = false;
  for (int y = 0; y < height; y++) {
    const int source_y = top_down ? y : height - 1 - y;
    const uint8_t* source =
        dib.data() + pixel_offset + source_stride * source_y;
    uint8_t* target =
        bgra.data() + static_cast<size_t>(y) * width * 4;
    for (int x = 0; x < width; x++) {
      if (header.biBitCount == 32) {
        target[x * 4 + 0] = source[x * 4 + 0];
        target[x * 4 + 1] = source[x * 4 + 1];
        target[x * 4 + 2] = source[x * 4 + 2];
        target[x * 4 + 3] = source[x * 4 + 3];
        has_alpha = has_alpha || source[x * 4 + 3] != 0;
      } else {
        target[x * 4 + 0] = source[x * 3 + 0];
        target[x * 4 + 1] = source[x * 3 + 1];
        target[x * 4 + 2] = source[x * 3 + 2];
        target[x * 4 + 3] = 0xff;
      }
    }
  }
  if (header.biBitCount == 32 && !has_alpha) {
    for (size_t index = 3; index < bgra.size(); index += 4) {
      bgra[index] = 0xff;
    }
  }
  return EncodeBgraAsPng(width, height, bgra);
}

std::optional<std::vector<uint8_t>> ReadClipboardImagePng(HWND window) {
  ScopedClipboard clipboard(window);
  if (!clipboard.opened()) {
    return std::nullopt;
  }

  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (png_format != 0 && IsClipboardFormatAvailable(png_format)) {
    auto png = ReadClipboardGlobalBytes(png_format);
    if (png.has_value() && !png->empty()) {
      return png;
    }
  }

  for (UINT format : {static_cast<UINT>(CF_DIBV5),
                      static_cast<UINT>(CF_DIB)}) {
    if (!IsClipboardFormatAvailable(format)) {
      continue;
    }
    auto dib = ReadClipboardGlobalBytes(format);
    if (!dib.has_value()) {
      continue;
    }
    auto png = ConvertDibToPng(*dib);
    if (png.has_value() && !png->empty()) {
      return png;
    }
  }
  return std::nullopt;
}

class DesktopClipboardImagePlugin : public flutter::Plugin {
 public:
  DesktopClipboardImagePlugin(flutter::PluginRegistrarWindows* registrar,
                              HWND window)
      : window_(window),
        channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), kDesktopClipboardImageChannel,
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
  }

  ~DesktopClipboardImagePlugin() override = default;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() != "readImagePng") {
      result->NotImplemented();
      return;
    }
    auto png = ReadClipboardImagePng(window_);
    if (!png.has_value()) {
      result->Success();
      return;
    }
    result->Success(flutter::EncodableValue(std::move(*png)));
  }

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

void DesktopClipboardImagePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar,
    HWND window) {
  auto plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  auto plugin =
      std::make_unique<DesktopClipboardImagePlugin>(plugin_registrar, window);
  plugin_registrar->AddPlugin(std::move(plugin));
}
