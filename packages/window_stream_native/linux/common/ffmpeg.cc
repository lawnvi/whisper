#include "common/ffmpeg.h"

#include <dlfcn.h>

#include <vector>

#include "common/dl.h"
#include "common/log.h"

namespace wsn {

namespace {

// libavcodec majors, newest first. FFmpeg 4 (58) is the oldest with the
// send/receive API used here; majors past the newest release are tried too,
// so a new FFmpeg works as long as these functions are still in it.
constexpr int kNewestAvcodec = 75;
constexpr int kOldestAvcodec = 58;

// The file `symbol` (looked up through `handle` and its dependencies) lives
// in, or empty.
std::string FileOf(void* handle, const char* symbol) {
  void* address = dlsym(handle, symbol);
  Dl_info info{};
  if (address == nullptr || dladdr(address, &info) == 0 || info.dli_fname == nullptr) return {};
  return info.dli_fname;
}

// libswscale built against the libavutil at `avutil_file`: a libswscale of
// another release would pull in its own libavutil, and the two must never
// mix in one process. Tries the major that ships with this libavcodec first
// (61 ↔ 8, 62 ↔ 9, 63 ↔ 10, …), then the others.
void* OpenSwscale(int avcodec_major, const std::string& avutil_file, int* major) {
  std::vector<int> majors = {avcodec_major - 53};
  for (int m = avcodec_major - 50; m >= 5; m--) {
    if (m != avcodec_major - 53) majors.push_back(m);
  }
  for (int m : majors) {
    void* handle = Open("libswscale.so." + std::to_string(m));
    if (handle == nullptr) continue;
    if (FileOf(handle, "avutil_version") == avutil_file) {
      *major = m;
      return handle;
    }
    dlclose(handle);
  }
  return nullptr;
}

FFmpeg Load() {
  FFmpeg f;
  for (int major = kNewestAvcodec; major >= kOldestAvcodec && f.avcodec == nullptr; major--) {
    std::string name = "libavcodec.so." + std::to_string(major);
    if ((f.avcodec = Open(name)) != nullptr) f.avcodec_name = name;
  }
  if (f.avcodec == nullptr && (f.avcodec = Open("libavcodec.so")) != nullptr) f.avcodec_name = "libavcodec.so";
  if (f.avcodec == nullptr) {
    WSN_LOG("ffmpeg: libavcodec not found");
    return f;
  }
  unsigned (*codec_version)() = nullptr;
  if (!Sym(f.avcodec, "avcodec_version", &codec_version)) {
    WSN_LOG("ffmpeg: %s has no avcodec_version", f.avcodec_name.c_str());
    return f;
  }
  f.avcodec_major = static_cast<int>(codec_version() >> 16);
  if (f.avcodec_major < kOldestAvcodec) {
    WSN_LOG("ffmpeg: libavcodec %d is too old", f.avcodec_major);
    return f;
  }
  // The libavutil libavcodec itself was linked against (a dependency, so
  // already loaded), rather than a table of which majors go together.
  std::string avutil_file = FileOf(f.avcodec, "avutil_version");
  unsigned (*util_version)() = nullptr;
  if (!avutil_file.empty()) f.avutil = Open(avutil_file);
  if (f.avutil == nullptr || !Sym(f.avutil, "avutil_version", &util_version)) {
    WSN_LOG("ffmpeg: no libavutil for %s", f.avcodec_name.c_str());
    return f;
  }
  f.avutil_major = static_cast<int>(util_version() >> 16);
  f.swscale = OpenSwscale(f.avcodec_major, avutil_file, &f.swscale_major);
  if (f.swscale == nullptr) {
    WSN_LOG("ffmpeg: no libswscale built with %s", avutil_file.c_str());
    return f;
  }

  bool ok = true;
  Sym(f.avcodec, "avcodec_find_decoder_by_name", &f.find_decoder_by_name, &ok);
  Sym(f.avcodec, "avcodec_alloc_context3", &f.alloc_context, &ok);
  Sym(f.avcodec, "avcodec_open2", &f.open, &ok);
  Sym(f.avcodec, "avcodec_free_context", &f.free_context, &ok);
  Sym(f.avcodec, "avcodec_flush_buffers", &f.flush_buffers, &ok);
  Sym(f.avcodec, "av_packet_alloc", &f.packet_alloc, &ok);
  Sym(f.avcodec, "av_packet_free", &f.packet_free, &ok);
  Sym(f.avcodec, "avcodec_send_packet", &f.send_packet, &ok);
  Sym(f.avcodec, "avcodec_receive_frame", &f.receive_frame, &ok);
  Sym(f.avutil, "av_frame_alloc", &f.frame_alloc, &ok);
  Sym(f.avutil, "av_frame_free", &f.frame_free, &ok);
  Sym(f.avutil, "av_frame_unref", &f.frame_unref, &ok);
  Sym(f.avutil, "av_get_pix_fmt", &f.get_pix_fmt, &ok);
  Sym(f.avutil, "av_log_set_level", &f.log_set_level, &ok);
  Sym(f.avutil, "av_opt_set", &f.opt_set, &ok);
  Sym(f.avutil, "av_opt_set_int", &f.opt_set_int, &ok);
  Sym(f.swscale, "sws_getCachedContext", &f.sws_get_cached, &ok);
  Sym(f.swscale, "sws_scale", &f.sws_scale, &ok);
  Sym(f.swscale, "sws_freeContext", &f.sws_free, &ok);
  Sym(f.avutil, "av_opt_get_int", &f.opt_get_int);
  Sym(f.avutil, "av_frame_clone", &f.frame_clone);
  Sym(f.swscale, "sws_getCoefficients", &f.sws_get_coefficients);
  Sym(f.swscale, "sws_setColorspaceDetails", &f.sws_set_colorspace);
  if (!ok) {
    WSN_LOG("ffmpeg: %s is missing symbols", f.avcodec_name.c_str());
    return f;
  }
  f.pix_yuv420p = f.get_pix_fmt("yuv420p");
  f.pix_bgra = f.get_pix_fmt("bgra");
  f.pix_bgr0 = f.get_pix_fmt("bgr0");
  f.pix_rgb24 = f.get_pix_fmt("rgb24");
  if (f.pix_bgra < 0) {
    WSN_LOG("ffmpeg: no bgra pixel format");
    return f;
  }
  // Damaged packets are handled (DECODE_ERROR, keyframe request); keep
  // FFmpeg from printing each one to the journal.
  f.log_set_level(8 /* AV_LOG_FATAL */);
  f.ok = true;
  WSN_LOG("ffmpeg: %s (avutil %d, swscale %d)", f.avcodec_name.c_str(), f.avutil_major, f.swscale_major);
  return f;
}

}  // namespace

const FFmpeg& Libav() {
  static const FFmpeg api = Load();
  return api;
}

}  // namespace wsn
