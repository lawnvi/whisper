// The system FFmpeg (libavcodec, libavutil, libswscale), opened at run time.
//
// The newest libavcodec decides the release: libavutil is the one it was
// linked against, and libswscale one linked against that same libavutil, so
// a machine with two FFmpeg releases installed never mixes them. No table of
// releases: a new FFmpeg works as long as the functions below are in it.
//
// Only the decode/scale entry points the receiver needs are resolved here.
// Other code (the capture side) resolves what it needs itself from the
// handles with wsn::Sym, e.g. Sym(Libav().avcodec, "avcodec_send_frame", &f).
//
// Only the leading, ABI-stable members of FFmpeg's structs are declared.

#ifndef WSN_COMMON_FFMPEG_H_
#define WSN_COMMON_FFMPEG_H_

#include <cstdint>
#include <string>

namespace wsn {

struct AVFramePrefix {
  uint8_t* data[8];
  int linesize[8];
  uint8_t** extended_data;
  int width;
  int height;
  int nb_samples;
  int format;
};

struct AVPacketPrefix {
  void* buf;
  int64_t pts;
  int64_t dts;
  uint8_t* data;
  int size;
  int stream_index;
  int flags;
};

constexpr int kSwsFastBilinear = 1;
constexpr int kSwsBilinear = 2;
constexpr int kSwsBicubic = 4;
constexpr int kSwsArea = 0x20;
constexpr int kAvErrorEagain = -11;
constexpr int kAvErrorEof = -541478725;  // FFERRTAG('E','O','F',' ')

struct FFmpeg {
  void* avcodec = nullptr;
  void* avutil = nullptr;
  void* swscale = nullptr;
  int avcodec_major = 0;
  int avutil_major = 0;
  int swscale_major = 0;
  std::string avcodec_name;

  // Pixel formats, looked up by name (enum values moved between releases).
  int pix_yuv420p = 0;
  int pix_bgra = -1;
  int pix_bgr0 = -1;
  int pix_rgb24 = -1;

  // libavcodec
  // By name ("h264"): codec ids moved between releases (FF_API_XVMC).
  void* (*find_decoder_by_name)(const char*) = nullptr;
  void* (*alloc_context)(const void*) = nullptr;
  int (*open)(void*, const void*, void**) = nullptr;
  void (*free_context)(void**) = nullptr;
  void (*flush_buffers)(void*) = nullptr;
  void* (*packet_alloc)() = nullptr;
  void (*packet_free)(void**) = nullptr;
  int (*send_packet)(void*, const void*) = nullptr;
  int (*receive_frame)(void*, void*) = nullptr;

  // libavutil
  void* (*frame_alloc)() = nullptr;
  void (*frame_free)(void**) = nullptr;
  void (*frame_unref)(void*) = nullptr;
  int (*get_pix_fmt)(const char*) = nullptr;
  void (*log_set_level)(int) = nullptr;
  int (*opt_set)(void*, const char*, const char*, int) = nullptr;
  int (*opt_set_int)(void*, const char*, int64_t, int) = nullptr;

  // libswscale
  void* (*sws_get_cached)(void*, int, int, int, int, int, int, int, void*, void*, const double*) = nullptr;
  int (*sws_scale)(void*, const uint8_t* const*, const int*, int, int, uint8_t* const*, const int*) = nullptr;
  void (*sws_free)(void*) = nullptr;

  // Everything above resolved.
  bool ok = false;

  // Optional (null when missing): colour range and matrix of the stream.
  int (*opt_get_int)(void*, const char*, int, int64_t*) = nullptr;
  void* (*frame_clone)(const void*) = nullptr;
  const int* (*sws_get_coefficients)(int) = nullptr;
  int (*sws_set_colorspace)(void*, const int*, int, const int*, int, int, int, int) = nullptr;
};

// Loaded once, on first use; thread-safe. `ok` is false when FFmpeg (or a
// matching libavutil/libswscale) is not installed.
const FFmpeg& Libav();

}  // namespace wsn

#endif  // WSN_COMMON_FFMPEG_H_
