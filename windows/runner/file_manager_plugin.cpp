// FILE_MANAGER_THUMBNAIL_TEST builds only the thumbnail code (a test
// harness includes this file without Flutter).
#ifndef FILE_MANAGER_THUMBNAIL_TEST
#include "file_manager_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#endif
#include <objbase.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <windows.h>

#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

#ifndef FILE_MANAGER_THUMBNAIL_TEST
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;
#endif

constexpr UINT kReplyMessage = WM_APP + 0x31;
constexpr wchar_t kReplyWindowClass[] = L"WhisperFileManagerReplies";
// The shell runs thumbnail handlers; a folder full of videos should not
// start one per file at once.
constexpr size_t kWorkers = 3;
constexpr float kJpegQuality = 0.85f;

std::wstring Widen(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      out.data(), length);
  return out;
}

template <typename T>
void SafeRelease(T** pointer) {
  if (*pointer != nullptr) {
    (*pointer)->Release();
    *pointer = nullptr;
  }
}


// Top-down 32-bit BGRA pixels of an HBITMAP, composited over white (JPEG
// has no alpha; the shell hands out premultiplied or straight alpha).
bool OpaquePixels(HBITMAP bitmap, int* width, int* height,
                  std::vector<uint8_t>* pixels) {
  BITMAP info = {};
  if (GetObjectW(bitmap, sizeof(info), &info) == 0 || info.bmWidth <= 0 ||
      info.bmHeight == 0) {
    return false;
  }
  const int w = info.bmWidth;
  const int h = info.bmHeight < 0 ? -info.bmHeight : info.bmHeight;
  BITMAPINFO header = {};
  header.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  header.bmiHeader.biWidth = w;
  header.bmiHeader.biHeight = -h;
  header.bmiHeader.biPlanes = 1;
  header.bmiHeader.biBitCount = 32;
  header.bmiHeader.biCompression = BI_RGB;
  pixels->assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
  HDC dc = GetDC(nullptr);
  const int rows = GetDIBits(dc, bitmap, 0, static_cast<UINT>(h), pixels->data(),
                             &header, DIB_RGB_COLORS);
  ReleaseDC(nullptr, dc);
  if (rows == 0) return false;
  const bool has_alpha = info.bmBitsPixel == 32;
  bool premultiplied = true;
  bool any_alpha = false;
  for (size_t i = 0; has_alpha && i < pixels->size(); i += 4) {
    const uint8_t a = (*pixels)[i + 3];
    if (a != 0) any_alpha = true;
    if ((*pixels)[i] > a || (*pixels)[i + 1] > a || (*pixels)[i + 2] > a) {
      premultiplied = false;
    }
  }
  for (size_t i = 0; i < pixels->size(); i += 4) {
    uint8_t* p = pixels->data() + i;
    const int a = (has_alpha && any_alpha) ? p[3] : 255;
    for (int c = 0; c < 3; c++) {
      const int value = premultiplied && has_alpha && any_alpha
                            ? p[c] + (255 - a)
                            : (p[c] * a + 255 * (255 - a)) / 255;
      p[c] = static_cast<uint8_t>(std::min(255, value));
    }
    p[3] = 255;
  }
  *width = w;
  *height = h;
  return true;
}

bool EncodeJpeg(IWICImagingFactory* factory, IWICBitmapSource* source,
                std::vector<uint8_t>* out) {
  IStream* stream = nullptr;
  IWICBitmapEncoder* encoder = nullptr;
  IWICBitmapFrameEncode* frame = nullptr;
  IPropertyBag2* properties = nullptr;
  UINT width = 0;
  UINT height = 0;
  source->GetSize(&width, &height);
  bool ok = SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) &&
            SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr,
                                             &encoder)) &&
            SUCCEEDED(encoder->Initialize(stream, WICBitmapEncoderNoCache)) &&
            SUCCEEDED(encoder->CreateNewFrame(&frame, &properties));
  if (ok) {
    PROPBAG2 option = {};
    wchar_t name[] = L"ImageQuality";
    option.pstrName = name;
    VARIANT value = {};
    value.vt = VT_R4;
    value.fltVal = kJpegQuality;
    properties->Write(1, &option, &value);
    WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
    ok = SUCCEEDED(frame->Initialize(properties)) &&
         SUCCEEDED(frame->SetSize(width, height)) &&
         SUCCEEDED(frame->SetPixelFormat(&format)) &&
         SUCCEEDED(frame->WriteSource(source, nullptr)) &&
         SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit());
  }
  if (ok) {
    HGLOBAL memory = nullptr;
    ok = SUCCEEDED(GetHGlobalFromStream(stream, &memory));
    STATSTG stat = {};
    if (ok) ok = SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME));
    if (ok) {
      const auto* bytes = static_cast<const uint8_t*>(GlobalLock(memory));
      ok = bytes != nullptr;
      if (ok) {
        out->assign(bytes, bytes + static_cast<size_t>(stat.cbSize.QuadPart));
        GlobalUnlock(memory);
      }
    }
  }
  SafeRelease(&properties);
  SafeRelease(&frame);
  SafeRelease(&encoder);
  SafeRelease(&stream);
  return ok && !out->empty();
}

// The shell's thumbnail (never its file-type icon).
bool ShellThumbnail(IWICImagingFactory* factory, const std::wstring& path,
                    int size, std::vector<uint8_t>* out) {
  IShellItemImageFactory* images = nullptr;
  if (FAILED(SHCreateItemFromParsingName(path.c_str(), nullptr,
                                         IID_PPV_ARGS(&images)))) {
    return false;
  }
  HBITMAP bitmap = nullptr;
  const SIZE wanted = {size, size};
  HRESULT hr = images->GetImage(wanted, SIIGBF_THUMBNAILONLY, &bitmap);
  images->Release();
  if (FAILED(hr) || bitmap == nullptr) return false;
  int width = 0;
  int height = 0;
  std::vector<uint8_t> pixels;
  const bool read = OpaquePixels(bitmap, &width, &height, &pixels);
  DeleteObject(bitmap);
  if (!read) return false;
  IWICBitmap* wic = nullptr;
  if (FAILED(factory->CreateBitmapFromMemory(
          static_cast<UINT>(width), static_cast<UINT>(height),
          GUID_WICPixelFormat32bppBGRA, static_cast<UINT>(width) * 4,
          static_cast<UINT>(pixels.size()), pixels.data(), &wic))) {
    return false;
  }
  IWICBitmapSource* source = wic;
  IWICBitmapScaler* scaler = nullptr;
  const int longest = std::max(width, height);
  if (longest > size) {
    // GetImage may hand back a larger cached thumbnail.
    const UINT scaled_width = static_cast<UINT>(std::max(1, width * size / longest));
    const UINT scaled_height = static_cast<UINT>(std::max(1, height * size / longest));
    if (SUCCEEDED(factory->CreateBitmapScaler(&scaler)) &&
        SUCCEEDED(scaler->Initialize(wic, scaled_width, scaled_height,
                                     WICBitmapInterpolationModeFant))) {
      source = scaler;
    }
  }
  const bool ok = EncodeJpeg(factory, source, out);
  SafeRelease(&scaler);
  SafeRelease(&wic);
  return ok;
}

// An image the shell would not thumbnail, decoded with WIC (first frame,
// EXIF orientation applied where the codec reports it).
bool DecodedThumbnail(IWICImagingFactory* factory, const std::wstring& path,
                      int size, std::vector<uint8_t>* out) {
  IWICBitmapDecoder* decoder = nullptr;
  IWICBitmapFrameDecode* frame = nullptr;
  IWICBitmapScaler* scaler = nullptr;
  IWICBitmapFlipRotator* rotator = nullptr;
  IWICFormatConverter* converter = nullptr;
  bool ok = SUCCEEDED(factory->CreateDecoderFromFilename(
                path.c_str(), nullptr, GENERIC_READ,
                WICDecodeMetadataCacheOnDemand, &decoder)) &&
            SUCCEEDED(decoder->GetFrame(0, &frame));
  UINT width = 0;
  UINT height = 0;
  if (ok) ok = SUCCEEDED(frame->GetSize(&width, &height)) && width > 0 && height > 0;
  if (ok) {
    const UINT longest = std::max(width, height);
    const UINT target = static_cast<UINT>(size);
    UINT scaled_width = width;
    UINT scaled_height = height;
    if (longest > target) {
      scaled_width = std::max<UINT>(1, width * target / longest);
      scaled_height = std::max<UINT>(1, height * target / longest);
    }
    ok = SUCCEEDED(factory->CreateBitmapScaler(&scaler)) &&
         SUCCEEDED(scaler->Initialize(frame, scaled_width, scaled_height,
                                      WICBitmapInterpolationModeFant));
  }
  IWICBitmapSource* source = scaler;
  if (ok) {
    // EXIF orientation (System.Photo.Orientation), when present.
    IWICMetadataQueryReader* metadata = nullptr;
    UINT orientation = 1;
    if (SUCCEEDED(frame->GetMetadataQueryReader(&metadata))) {
      PROPVARIANT value;
      PropVariantInit(&value);
      if (SUCCEEDED(metadata->GetMetadataByName(L"System.Photo.Orientation",
                                                &value)) &&
          value.vt == VT_UI2) {
        orientation = value.uiVal;
      }
      PropVariantClear(&value);
      metadata->Release();
    }
    WICBitmapTransformOptions transform = WICBitmapTransformRotate0;
    switch (orientation) {
      case 2: transform = WICBitmapTransformFlipHorizontal; break;
      case 3: transform = WICBitmapTransformRotate180; break;
      case 4: transform = WICBitmapTransformFlipVertical; break;
      case 5: transform = static_cast<WICBitmapTransformOptions>(
                  WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal);
        break;
      case 6: transform = WICBitmapTransformRotate90; break;
      case 7: transform = static_cast<WICBitmapTransformOptions>(
                  WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal);
        break;
      case 8: transform = WICBitmapTransformRotate270; break;
      default: break;
    }
    if (transform != WICBitmapTransformRotate0 &&
        SUCCEEDED(factory->CreateBitmapFlipRotator(&rotator)) &&
        SUCCEEDED(rotator->Initialize(scaler, transform))) {
      source = rotator;
    }
    ok = SUCCEEDED(factory->CreateFormatConverter(&converter)) &&
         SUCCEEDED(converter->Initialize(source, GUID_WICPixelFormat32bppPBGRA,
                                         WICBitmapDitherTypeNone, nullptr, 0,
                                         WICBitmapPaletteTypeCustom));
  }
  IWICBitmap* opaque = nullptr;
  if (ok) {
    // Transparent parts over white, as the shell's own thumbnails are.
    UINT out_width = 0;
    UINT out_height = 0;
    converter->GetSize(&out_width, &out_height);
    std::vector<uint8_t> pixels(static_cast<size_t>(out_width) * out_height * 4);
    ok = SUCCEEDED(converter->CopyPixels(nullptr, out_width * 4,
                                         static_cast<UINT>(pixels.size()),
                                         pixels.data()));
    for (size_t i = 0; ok && i < pixels.size(); i += 4) {
      const int a = pixels[i + 3];
      for (int c = 0; c < 3; c++) {
        pixels[i + c] = static_cast<uint8_t>(std::min(255, pixels[i + c] + (255 - a)));
      }
      pixels[i + 3] = 255;
    }
    ok = ok && SUCCEEDED(factory->CreateBitmapFromMemory(
                   out_width, out_height, GUID_WICPixelFormat32bppBGRA,
                   out_width * 4, static_cast<UINT>(pixels.size()),
                   pixels.data(), &opaque));
  }
  if (ok) ok = EncodeJpeg(factory, opaque, out);
  SafeRelease(&opaque);
  SafeRelease(&converter);
  SafeRelease(&rotator);
  SafeRelease(&scaler);
  SafeRelease(&frame);
  SafeRelease(&decoder);
  return ok;
}

#ifndef FILE_MANAGER_THUMBNAIL_TEST
struct Job {
  std::wstring path;
  int size = 256;
  bool video = false;
  std::unique_ptr<Result> result;
  std::optional<std::vector<uint8_t>> jpeg;
};

// Work shared between the plugin and its worker threads (which outlive it
// if a thumbnail handler is slow when the app quits).
struct Workers {
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<std::unique_ptr<Job>> jobs;
  size_t threads = 0;
  size_t idle = 0;
  bool stopping = false;
  HWND reply_window = nullptr;  // mutex
};

void WorkLoop(std::shared_ptr<Workers> workers) {
  // The shell's thumbnail handlers expect an apartment-threaded caller.
  const HRESULT com =
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  IWICImagingFactory* factory = nullptr;
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                   IID_PPV_ARGS(&factory));
  for (;;) {
    std::unique_ptr<Job> job;
    {
      std::unique_lock<std::mutex> lock(workers->mutex);
      workers->idle++;
      workers->wake.wait(lock, [&] { return workers->stopping || !workers->jobs.empty(); });
      workers->idle--;
      if (workers->stopping) break;
      job = std::move(workers->jobs.front());
      workers->jobs.pop_front();
    }
    std::vector<uint8_t> jpeg;
    bool ok = factory != nullptr &&
              ShellThumbnail(factory, job->path, job->size, &jpeg);
    if (!ok && !job->video && factory != nullptr) {
      jpeg.clear();
      ok = DecodedThumbnail(factory, job->path, job->size, &jpeg);
    }
    if (ok) job->jpeg = std::move(jpeg);
    // Answered on the platform thread; dropped if the plugin is gone.
    {
      std::lock_guard<std::mutex> lock(workers->mutex);
      Job* raw = job.release();
      if (workers->reply_window == nullptr ||
          !PostMessageW(workers->reply_window, kReplyMessage, 0,
                        reinterpret_cast<LPARAM>(raw))) {
        job.reset(raw);
      }
    }
    if (job != nullptr) {
      // Not answered (the app is closing): drop it without touching Flutter.
      static_cast<void>(job->result.release());
    }
    // Keep the apartment responsive between jobs.
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }
  SafeRelease(&factory);
  if (SUCCEEDED(com)) CoUninitialize();
}

class FileManagerPlugin : public flutter::Plugin {
 public:
  explicit FileManagerPlugin(flutter::PluginRegistrarWindows* registrar)
      : channel_(registrar->messenger(), "com.vireen.whisper/file_manager",
                 &flutter::StandardMethodCodec::GetInstance()),
        workers_(std::make_shared<Workers>()) {
    WNDCLASSW window_class = {};
    window_class.lpfnWndProc = ReplyWindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = kReplyWindowClass;
    RegisterClassW(&window_class);
    workers_->reply_window =
        CreateWindowExW(0, kReplyWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                        nullptr, GetModuleHandleW(nullptr), nullptr);
    channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "thumbnail") {
        Thumbnail(call.arguments(), std::move(result));
      } else {
        result->NotImplemented();
      }
    });
  }

  ~FileManagerPlugin() override {
    channel_.SetMethodCallHandler(nullptr);
    HWND reply_window;
    {
      std::lock_guard<std::mutex> lock(workers_->mutex);
      workers_->stopping = true;
      reply_window = workers_->reply_window;
      workers_->reply_window = nullptr;
      for (auto& job : workers_->jobs) static_cast<void>(job->result.release());
      workers_->jobs.clear();
    }
    workers_->wake.notify_all();
    if (reply_window != nullptr) DestroyWindow(reply_window);
  }

 private:
  static LRESULT CALLBACK ReplyWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam) {
    if (message == kReplyMessage) {
      std::unique_ptr<Job> job(reinterpret_cast<Job*>(lparam));
      if (job->jpeg.has_value()) {
        job->result->Success(Value(std::move(*job->jpeg)));
      } else {
        job->result->Success();
      }
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  static const Value* Field(const flutter::EncodableMap& map, const char* key) {
    const auto entry = map.find(Value(key));
    return entry == map.end() ? nullptr : &entry->second;
  }

  void Thumbnail(const Value* arguments, std::unique_ptr<Result> result) {
    const auto* map = arguments == nullptr
                          ? nullptr
                          : std::get_if<flutter::EncodableMap>(arguments);
    const Value* path = map == nullptr ? nullptr : Field(*map, "path");
    const auto* text = path == nullptr ? nullptr : std::get_if<std::string>(path);
    if (text == nullptr || text->empty()) {
      result->Success();
      return;
    }
    auto job = std::make_unique<Job>();
    job->path = Widen(*text);
    if (const Value* size = Field(*map, "size")) {
      if (const auto* value = std::get_if<int32_t>(size)) job->size = *value;
      if (const auto* value = std::get_if<int64_t>(size)) {
        job->size = static_cast<int>(std::clamp<int64_t>(*value, 0, 4096));
      }
    }
    job->size = std::clamp(job->size, 16, 1024);
    if (const Value* video = Field(*map, "video")) {
      if (const auto* value = std::get_if<bool>(video)) job->video = *value;
    }
    job->result = std::move(result);
    bool start_thread = false;
    {
      std::lock_guard<std::mutex> lock(workers_->mutex);
      if (workers_->reply_window == nullptr) {
        job->result->Success();
        return;
      }
      workers_->jobs.push_back(std::move(job));
      if (workers_->idle == 0 && workers_->threads < kWorkers) {
        workers_->threads++;
        start_thread = true;
      }
    }
    if (start_thread) {
      std::thread(WorkLoop, workers_).detach();
    }
    workers_->wake.notify_one();
  }

  flutter::MethodChannel<Value> channel_;
  std::shared_ptr<Workers> workers_;
};

#endif  // FILE_MANAGER_THUMBNAIL_TEST

}  // namespace

#ifndef FILE_MANAGER_THUMBNAIL_TEST
void FileManagerPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  plugin_registrar->AddPlugin(
      std::make_unique<FileManagerPlugin>(plugin_registrar));
}
#endif  // FILE_MANAGER_THUMBNAIL_TEST
