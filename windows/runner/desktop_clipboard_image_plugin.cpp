#include "desktop_clipboard_image_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <objidl.h>
#include <shellapi.h>
#include <shlobj.h>
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

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int length = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    return "";
  }
  std::string result(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), length,
                      nullptr, nullptr);
  return result;
}

std::optional<std::wstring> Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::nullopt;
  }
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) {
    return std::nullopt;
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    return std::nullopt;
  }
  return result;
}

bool WriteClipboardFilePaths(HWND window,
                             const std::vector<std::string>& paths,
                             bool as_image) {
  if (paths.empty()) {
    return false;
  }
  std::vector<std::wstring> wide_paths;
  size_t character_count = 1;
  for (const auto& path : paths) {
    auto wide = Utf8ToWide(path);
    if (!wide.has_value() ||
        GetFileAttributesW(wide->c_str()) == INVALID_FILE_ATTRIBUTES) {
      return false;
    }
    character_count += wide->size() + 1;
    wide_paths.push_back(std::move(*wide));
  }
  const SIZE_T bytes = sizeof(DROPFILES) + character_count * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
  if (memory == nullptr) {
    return false;
  }
  {
    ScopedGlobalLock lock(memory);
    if (lock.data() == nullptr) {
      GlobalFree(memory);
      return false;
    }
    auto* drop = static_cast<DROPFILES*>(lock.data());
    drop->pFiles = sizeof(DROPFILES);
    drop->fWide = TRUE;
    auto* output = reinterpret_cast<wchar_t*>(
        static_cast<uint8_t*>(lock.data()) + sizeof(DROPFILES));
    for (const auto& path : wide_paths) {
      std::copy(path.begin(), path.end(), output);
      output += path.size();
      *output++ = L'\0';
    }
    *output = L'\0';
  }
  ScopedClipboard clipboard(window);
  if (!clipboard.opened() || !EmptyClipboard() ||
      SetClipboardData(CF_HDROP, memory) == nullptr) {
    GlobalFree(memory);
    return false;
  }
  if (as_image && paths.size() == 1) {
    auto image = Utf8ToWide(paths.front());
    HANDLE file = image.has_value()
                      ? CreateFileW(image->c_str(), GENERIC_READ, FILE_SHARE_READ,
                                    nullptr, OPEN_EXISTING,
                                    FILE_ATTRIBUTE_NORMAL, nullptr)
                      : INVALID_HANDLE_VALUE;
    if (file != INVALID_HANDLE_VALUE) {
      const DWORD size = GetFileSize(file, nullptr);
      if (size > 0 && size != INVALID_FILE_SIZE) {
        HGLOBAL png_memory = GlobalAlloc(GMEM_MOVEABLE, size);
        if (png_memory != nullptr) {
          DWORD read = 0;
          bool loaded = false;
          {
            ScopedGlobalLock png_lock(png_memory);
            loaded = png_lock.data() != nullptr &&
                     ReadFile(file, png_lock.data(), size, &read, nullptr) &&
                     read == size;
          }
          if (loaded) {
            const UINT png_format = RegisterClipboardFormatW(L"PNG");
            if (png_format == 0 ||
                SetClipboardData(png_format, png_memory) == nullptr) {
              GlobalFree(png_memory);
            }
          } else {
            GlobalFree(png_memory);
          }
        }
      }
      CloseHandle(file);
    }
  }
  return true;
}

std::vector<std::string> ReadClipboardFilePathsFromOpenClipboard() {
  if (!IsClipboardFormatAvailable(CF_HDROP)) {
    return {};
  }
  HANDLE handle = GetClipboardData(CF_HDROP);
  if (handle == nullptr) {
    return {};
  }
  HDROP drop = static_cast<HDROP>(handle);
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  std::vector<std::string> paths;
  paths.reserve(count);
  for (UINT index = 0; index < count; index++) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    if (length == 0) {
      continue;
    }
    std::wstring path(length + 1, L'\0');
    const UINT copied =
        DragQueryFileW(drop, index, path.data(), length + 1);
    if (copied == 0) {
      continue;
    }
    path.resize(copied);
    const auto utf8 = WideToUtf8(path);
    if (!utf8.empty()) {
      paths.push_back(utf8);
    }
  }
  return paths;
}

std::vector<std::string> ReadClipboardFilePaths(HWND window) {
  ScopedClipboard clipboard(window);
  if (!clipboard.opened()) {
    return {};
  }
  return ReadClipboardFilePathsFromOpenClipboard();
}

std::optional<std::string> ReadClipboardUnicodeTextFromOpenClipboard() {
  if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    return std::nullopt;
  }
  HANDLE handle = GetClipboardData(CF_UNICODETEXT);
  if (handle == nullptr) {
    return std::nullopt;
  }
  HGLOBAL global = static_cast<HGLOBAL>(handle);
  const SIZE_T size = GlobalSize(global);
  if (size < sizeof(wchar_t)) {
    return std::nullopt;
  }
  ScopedGlobalLock lock(global);
  if (lock.data() == nullptr) {
    return std::nullopt;
  }
  const auto* text = static_cast<const wchar_t*>(lock.data());
  const size_t capacity = size / sizeof(wchar_t);
  const auto* terminator = std::find(text, text + capacity, L'\0');
  if (terminator == text + capacity || terminator == text) {
    return std::nullopt;
  }
  const std::string utf8 = WideToUtf8(std::wstring(text, terminator));
  return utf8.empty() ? std::nullopt
                      : std::optional<std::string>(utf8);
}

std::optional<std::vector<std::string>>
ReadClipboardQuickSendArguments(HWND window) {
  ScopedClipboard clipboard(window);
  if (!clipboard.opened()) {
    return std::nullopt;
  }

  const auto paths = ReadClipboardFilePathsFromOpenClipboard();
  if (!paths.empty()) {
    std::vector<std::string> arguments;
    arguments.reserve(paths.size() * 2);
    for (const auto& path : paths) {
      arguments.emplace_back("--quick-send-file");
      arguments.emplace_back(path);
    }
    return arguments;
  }

  const auto text = ReadClipboardUnicodeTextFromOpenClipboard();
  if (!text.has_value()) {
    return std::nullopt;
  }
  return std::vector<std::string>{"--quick-send-text", *text};
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
    if (call.method_name() == "readFilePaths") {
      flutter::EncodableList values;
      for (const auto& path : ReadClipboardFilePaths(window_)) {
        values.emplace_back(path);
      }
      result->Success(flutter::EncodableValue(std::move(values)));
      return;
    }
    if (call.method_name() == "writeFilePaths") {
      const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto paths_key = flutter::EncodableValue("paths");
      if (arguments == nullptr || arguments->find(paths_key) == arguments->end()) {
        result->Error("invalid_paths");
        return;
      }
      const auto* values = std::get_if<flutter::EncodableList>(
          &arguments->at(paths_key));
      if (values == nullptr) {
        result->Error("invalid_paths");
        return;
      }
      std::vector<std::string> paths;
      for (const auto& value : *values) {
        const auto* path = std::get_if<std::string>(&value);
        if (path == nullptr) {
          result->Error("invalid_paths");
          return;
        }
        paths.push_back(*path);
      }
      bool as_image = false;
      const auto image_key = flutter::EncodableValue("asImage");
      const auto image_entry = arguments->find(image_key);
      if (image_entry != arguments->end()) {
        if (const auto* value = std::get_if<bool>(&image_entry->second)) {
          as_image = *value;
        }
      }
      result->Success(flutter::EncodableValue(
          WriteClipboardFilePaths(window_, paths, as_image)));
      return;
    }
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

std::optional<std::vector<std::string>>
DesktopClipboardSnapshotQuickSendArguments() {
  return ReadClipboardQuickSendArguments(nullptr);
}
