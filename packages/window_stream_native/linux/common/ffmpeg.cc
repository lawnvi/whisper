#include "common/ffmpeg.h"

#include "common/dl.h"
#include "common/log.h"

namespace wsn {

namespace {

// libavcodec major → the libavutil and libswscale majors of that release.
struct Release {
  int avcodec;
  int avutil;
  int swscale;
};

constexpr Release kReleases[] = {
    {62, 60, 9},  // FFmpeg 8
    {61, 59, 8},  // FFmpeg 7
    {60, 58, 7},  // FFmpeg 6
    {59, 57, 6},  // FFmpeg 5
    {58, 56, 5},  // FFmpeg 4
};

const Release* ReleaseFor(int avcodec_major) {
  for (const Release& release : kReleases) {
    if (release.avcodec == avcodec_major) return &release;
  }
  return nullptr;
}

FFmpeg Load() {
  FFmpeg f;
  for (const Release& release : kReleases) {
    std::string name = "libavcodec.so." + std::to_string(release.avcodec);
    if ((f.avcodec = Open(name)) != nullptr) {
      f.avcodec_name = name;
      break;
    }
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
  const Release* release = ReleaseFor(f.avcodec_major);
  if (release == nullptr) {
    WSN_LOG("ffmpeg: unknown libavcodec major %d", f.avcodec_major);
    return f;
  }
  f.avutil = Open("libavutil.so." + std::to_string(release->avutil));
  f.swscale = Open("libswscale.so." + std::to_string(release->swscale));
  if (f.avutil == nullptr || f.swscale == nullptr) {
    WSN_LOG("ffmpeg: %s without libavutil.so.%d / libswscale.so.%d", f.avcodec_name.c_str(), release->avutil,
            release->swscale);
    return f;
  }
  f.avutil_major = release->avutil;
  f.swscale_major = release->swscale;

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
