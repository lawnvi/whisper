#include "capture/encoder.h"

#include <glib.h>
#include <pthread.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include "common/callbacks.h"
#include "common/dl.h"
#include "common/ffmpeg.h"
#include "common/log.h"
#include "window_stream_native.h"

namespace wsn::capture {

namespace {

constexpr int kSearchChildren = 1;  // AV_OPT_SEARCH_CHILDREN
constexpr int kPictureTypeNone = 0;
constexpr int kPictureTypeI = 1;
constexpr int kSwsCsItu709 = 1;

// AVFrame members past the stable prefix: pict_type, sample_aspect_ratio
// and pts, in that order. libavutil 60 dropped key_frame, which sat before
// pict_type; 61 (FFmpeg 9) kept 60's layout, which later majors are assumed
// to keep too.
struct FrameLayout {
  int pict_type = -1;
  int pts = -1;
};

constexpr int64_t kNoPts = INT64_MIN;  // AV_NOPTS_VALUE

template <typename T>
T FieldAt(const void* object, int offset) {
  T value;
  std::memcpy(&value, static_cast<const uint8_t*>(object) + offset, sizeof(T));
  return value;
}

// The layout for `avutil_major`, checked against a new frame (`fresh`, from
// av_frame_alloc): pict_type none, sample_aspect_ratio 0/1 right after it,
// pts unset. A release that moved them is refused rather than written into.
FrameLayout LayoutFor(int avutil_major, const void* fresh) {
  if (avutil_major < 56 || fresh == nullptr) return {};
  FrameLayout layout = avutil_major <= 59 ? FrameLayout{124, 136} : FrameLayout{120, 136};
  bool fits = FieldAt<int>(fresh, layout.pict_type) == 0 && FieldAt<int>(fresh, layout.pict_type + 4) == 0 &&
              FieldAt<int>(fresh, layout.pict_type + 8) == 1 && FieldAt<int64_t>(fresh, layout.pts) == kNoPts;
  return fits ? layout : FrameLayout{};
}

struct EncoderApi {
  const void* (*find_encoder_by_name)(const char*) = nullptr;
  void* (*alloc_context)(const void*) = nullptr;
  int (*open)(void*, const void*, void**) = nullptr;
  void (*free_context)(void**) = nullptr;
  int (*send_frame)(void*, const void*) = nullptr;
  int (*receive_packet)(void*, void*) = nullptr;
  void* (*packet_alloc)() = nullptr;
  void (*packet_free)(void**) = nullptr;
  void (*packet_unref)(void*) = nullptr;
  void* (*frame_alloc)() = nullptr;
  void (*frame_free)(void**) = nullptr;
  int (*frame_get_buffer)(void*, int) = nullptr;
  int (*frame_make_writable)(void*) = nullptr;
  int (*opt_set)(void*, const char*, const char*, int) = nullptr;
  int (*opt_set_int)(void*, const char*, int64_t, int) = nullptr;
  unsigned (*avutil_version)() = nullptr;
  FrameLayout layout;
  const void* codec = nullptr;
  std::string codec_name;
  bool ok = false;
};

// Whether `codec` opens at all. Fedora's stand-in libopenh264 (noopenh264,
// installed until the user adds Cisco's) is registered with FFmpeg but fails
// every open.
bool Opens(const EncoderApi& a, const void* codec) {
  void* context = a.alloc_context(codec);
  if (context == nullptr) return false;
  a.opt_set(context, "video_size", "64x64", 0);
  a.opt_set(context, "pixel_format", "yuv420p", 0);
  a.opt_set(context, "time_base", "1/30", 0);
  bool opens = a.open(context, codec, nullptr) >= 0;
  a.free_context(&context);
  return opens;
}

const EncoderApi& Api() {
  static EncoderApi api = [] {
    EncoderApi a;
    const FFmpeg& av = Libav();
    if (!av.ok || av.pix_bgr0 < 0) return a;
    bool ok = true;
    Sym(av.avcodec, "avcodec_find_encoder_by_name", &a.find_encoder_by_name, &ok);
    Sym(av.avcodec, "avcodec_alloc_context3", &a.alloc_context, &ok);
    Sym(av.avcodec, "avcodec_open2", &a.open, &ok);
    Sym(av.avcodec, "avcodec_free_context", &a.free_context, &ok);
    Sym(av.avcodec, "avcodec_send_frame", &a.send_frame, &ok);
    Sym(av.avcodec, "avcodec_receive_packet", &a.receive_packet, &ok);
    Sym(av.avcodec, "av_packet_alloc", &a.packet_alloc, &ok);
    Sym(av.avcodec, "av_packet_free", &a.packet_free, &ok);
    Sym(av.avcodec, "av_packet_unref", &a.packet_unref, &ok);
    Sym(av.avutil, "av_frame_alloc", &a.frame_alloc, &ok);
    Sym(av.avutil, "av_frame_free", &a.frame_free, &ok);
    Sym(av.avutil, "av_frame_get_buffer", &a.frame_get_buffer, &ok);
    Sym(av.avutil, "av_frame_make_writable", &a.frame_make_writable, &ok);
    Sym(av.avutil, "av_opt_set", &a.opt_set, &ok);
    Sym(av.avutil, "av_opt_set_int", &a.opt_set_int, &ok);
    Sym(av.avutil, "avutil_version", &a.avutil_version, &ok);
    if (!ok) return a;
    // The loaded libavutil, not the one this was built against, decides.
    int major = static_cast<int>(a.avutil_version() >> 16);
    void* fresh = a.frame_alloc();
    a.layout = LayoutFor(major, fresh);
    if (fresh != nullptr) a.frame_free(&fresh);
    if (a.layout.pts < 0) {
      WSN_LOG("capture: libavutil %d lays AVFrame out differently; no encoder", major);
      return a;
    }
    for (const char* name : {"libx264", "libopenh264"}) {
      const void* codec = a.find_encoder_by_name(name);
      if (codec == nullptr) continue;
      if (!Opens(a, codec)) {
        WSN_LOG("capture: FFmpeg lists %s, but it does not open", name);
        continue;
      }
      a.codec = codec;
      a.codec_name = name;
      break;
    }
    a.ok = a.codec != nullptr;
    if (!a.ok) WSN_LOG("capture: FFmpeg has no H.264 encoder (libx264, libopenh264)");
    return a;
  }();
  return api;
}

template <typename T>
void SetField(void* object, int offset, T value) {
  std::memcpy(static_cast<uint8_t*>(object) + offset, &value, sizeof(T));
}

// Annex-B NAL units of `data`, as (offset of the NAL header, length).
std::vector<std::pair<int, int>> NalUnits(const uint8_t* data, int size) {
  std::vector<std::pair<int, int>> units;
  int i = 0;
  int start = -1;
  while (i + 3 <= size) {
    bool code3 = data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1;
    if (code3) {
      if (start >= 0) {
        int end = i;
        if (end > start && data[end - 1] == 0) end--;  // 4-byte start code
        units.emplace_back(start, end - start);
      }
      start = i + 3;
      i += 3;
    } else {
      i++;
    }
  }
  if (start >= 0 && start < size) units.emplace_back(start, size - start);
  return units;
}

}  // namespace

bool Encoder::Available(std::string* name) {
  const EncoderApi& api = Api();
  if (name != nullptr) *name = api.codec_name;
  return api.ok;
}

Encoder::Encoder(int64_t capture_id, int max_fps, int bit_rate)
    : id_(capture_id), fps_(max_fps > 0 ? max_fps : 30), bit_rate_(bit_rate > 0 ? bit_rate : 8000000) {
  thread_ = std::thread([this] {
    pthread_setname_np(pthread_self(), "wsn-encode");
    Run();
  });
}

Encoder::~Encoder() { Stop(); }

void Encoder::Stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  wake_.notify_all();
  if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) thread_.join();
}

void Encoder::Push(const Frame& frame) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopping_) return;
  if (paused_) return;
  // Rows packed tightly: a cropped frame's rows are narrower than its stride.
  size_t row = static_cast<size_t>(frame.width) * 4;
  // Spare bytes past the last row: swscale's SIMD reads a little beyond it.
  pending_.pixels.resize(row * static_cast<size_t>(frame.height) + 64);
  if (static_cast<size_t>(frame.stride) == row) {
    std::memcpy(pending_.pixels.data(), frame.data, row * static_cast<size_t>(frame.height));
  } else {
    for (int y = 0; y < frame.height; y++) {
      std::memcpy(pending_.pixels.data() + row * static_cast<size_t>(y),
                  frame.data + static_cast<size_t>(frame.stride) * static_cast<size_t>(y), row);
    }
  }
  pending_.stride = static_cast<int>(row);
  pending_.width = frame.width;
  pending_.height = frame.height;
  pending_.format = frame.format;
  pending_.pts_us = frame.pts_us;
  has_pending_ = true;
  wake_.notify_one();
}

void Encoder::RequestKeyframe() {
  std::lock_guard<std::mutex> lock(mutex_);
  keyframe_ = true;
  repeat_ = true;
  wake_.notify_one();
}

void Encoder::SetBusy(bool busy) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (busy_ == busy) return;
  busy_ = busy;
  // Frames that came meanwhile were kept (the newest only): it goes out now.
  wake_.notify_one();
}

void Encoder::SetPaused(bool paused) {
  std::lock_guard<std::mutex> lock(mutex_);
  paused_ = paused;
  if (paused) {
    has_pending_ = false;
  } else {
    keyframe_ = true;
    repeat_ = true;
  }
  wake_.notify_one();
}

void Encoder::SetBitRate(int bit_rate) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (bit_rate <= 0 || bit_rate == bit_rate_) return;
  bit_rate_ = bit_rate;
  bit_rate_changed_ = true;
}

void Encoder::Run() {
  for (;;) {
    Slot work;
    bool repeat = false;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      // A keyframe asked for while the picture is still: give a new frame
      // 60 ms to turn up, then send the last one again.
      auto ready = [this] { return stopping_ || (has_pending_ && !busy_ && !paused_); };
      if (repeat_ && !paused_ && !busy_) {
        wake_.wait_for(lock, std::chrono::milliseconds(60), ready);
      } else {
        wake_.wait(lock, [&] { return ready() || (repeat_ && !paused_ && !busy_); });
      }
      if (stopping_) break;
      if (has_pending_ && !busy_ && !paused_) {
        work = std::move(pending_);
        pending_ = Slot();
        has_pending_ = false;
        repeat_ = false;
      } else if (repeat_ && !paused_ && !busy_ && has_last_) {
        repeat_ = false;
        repeat = true;
      } else {
        if (!busy_ && !paused_) repeat_ = false;
        continue;
      }
      if (bit_rate_changed_ && context_ != nullptr) {
        bit_rate_changed_ = false;
        const EncoderApi& api = Api();
        // libx264 reconfigures itself when these change between frames.
        api.opt_set_int(context_, "b", bit_rate_, 0);
        api.opt_set_int(context_, "maxrate", bit_rate_, 0);
        api.opt_set_int(context_, "bufsize", bit_rate_ / 2, 0);
      }
    }
    if (repeat) {
      Encode(last_, true);
    } else {
      if (Encode(work, false)) {
        last_ = std::move(work);
        has_last_ = true;
      }
    }
  }
  Close();
}

bool Encoder::Open(int width, int height) {
  Close();
  const EncoderApi& api = Api();
  const FFmpeg& av = Libav();
  if (!api.ok) return false;
  context_ = api.alloc_context(api.codec);
  if (context_ == nullptr) return false;
  int bit_rate;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    bit_rate = bit_rate_;
    bit_rate_changed_ = false;
  }
  gchar* size = g_strdup_printf("%dx%d", width, height);
  api.opt_set(context_, "video_size", size, 0);
  g_free(size);
  api.opt_set(context_, "pixel_format", "yuv420p", 0);
  api.opt_set(context_, "time_base", "1/1000000", 0);
  api.opt_set_int(context_, "b", bit_rate, 0);
  api.opt_set_int(context_, "maxrate", bit_rate, 0);
  api.opt_set_int(context_, "bufsize", bit_rate / 2, 0);
  api.opt_set_int(context_, "g", fps_ * 4, 0);
  api.opt_set_int(context_, "bf", 0, 0);
  api.opt_set_int(context_, "threads", 0, 0);
  api.opt_set(context_, "colorspace", "bt709", 0);
  api.opt_set(context_, "color_primaries", "bt709", 0);
  api.opt_set(context_, "color_trc", "bt709", 0);
  api.opt_set(context_, "color_range", "tv", 0);
  if (api.codec_name == "libx264") {
    api.opt_set(context_, "preset", "ultrafast", kSearchChildren);
    api.opt_set(context_, "tune", "zerolatency", kSearchChildren);
    // Parameter sets with every IDR (we split them off as a config packet),
    // keyframes only when asked or every 4 s, rate control by timestamps.
    gchar* params = g_strdup_printf("repeat-headers=1:scenecut=0:forced-idr=1:fps=%d:crf=21", fps_);
    api.opt_set(context_, "x264-params", params, kSearchChildren);
    g_free(params);
  } else {
    api.opt_set(context_, "allow_skip_frames", "0", kSearchChildren);
  }
  if (api.open(context_, api.codec, nullptr) < 0) {
    WSN_LOG("capture: %s failed to open at %dx%d", api.codec_name.c_str(), width, height);
    Close();
    return false;
  }
  frame_ = api.frame_alloc();
  packet_ = api.packet_alloc();
  if (frame_ == nullptr || packet_ == nullptr) {
    Close();
    return false;
  }
  auto* prefix = static_cast<AVFramePrefix*>(frame_);
  prefix->width = width;
  prefix->height = height;
  prefix->format = av.pix_yuv420p;
  if (api.frame_get_buffer(frame_, 32) < 0) {
    Close();
    return false;
  }
  width_ = width;
  height_ = height;
  config_.clear();
  WSN_LOG("capture %lld: %s %dx%d up to %d fps, %d kbit/s", static_cast<long long>(id_), api.codec_name.c_str(), width,
          height, fps_, bit_rate / 1000);
  return true;
}

void Encoder::Close() {
  const EncoderApi& api = Api();
  const FFmpeg& av = Libav();
  if (scaler_ != nullptr) av.sws_free(scaler_);
  scaler_ = nullptr;
  if (frame_ != nullptr) api.frame_free(&frame_);
  if (packet_ != nullptr) api.packet_free(&packet_);
  if (context_ != nullptr) api.free_context(&context_);
  frame_ = packet_ = context_ = nullptr;
  width_ = height_ = 0;
}

bool Encoder::Encode(const Slot& slot, bool repeat) {
  const EncoderApi& api = Api();
  const FFmpeg& av = Libav();
  if (!api.ok || slot.width < 16 || slot.height < 16) return false;
  // H.264 wants even sizes: an odd last row or column is left out.
  int width = slot.width & ~1;
  int height = slot.height & ~1;
  if (context_ == nullptr || width != width_ || height != height_) {
    if (!Open(width, height)) {
      EmitCapture(id_, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_ENCODER);
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
      return false;
    }
    EmitCapture(id_, WSN_CAPTURE_SIZE, nullptr, 0, 0, 0, width, height);
    std::lock_guard<std::mutex> lock(mutex_);
    keyframe_ = true;
  }
  int source_format = slot.format == PixelFormat::kBgra ? av.pix_bgra : av.pix_bgr0;
  scaler_ = av.sws_get_cached(scaler_, width, height, source_format, width, height, av.pix_yuv420p, kSwsBilinear,
                              nullptr, nullptr, nullptr);
  if (scaler_ == nullptr) return false;
  if (av.sws_set_colorspace != nullptr && av.sws_get_coefficients != nullptr) {
    const int* bt709 = av.sws_get_coefficients(kSwsCsItu709);
    av.sws_set_colorspace(scaler_, bt709, 1, bt709, 0, 0, 1 << 16, 1 << 16);
  }
  if (api.frame_make_writable(frame_) < 0) return false;
  auto* prefix = static_cast<AVFramePrefix*>(frame_);
  const uint8_t* source[4] = {slot.pixels.data(), nullptr, nullptr, nullptr};
  int stride[4] = {slot.stride, 0, 0, 0};
  av.sws_scale(scaler_, source, stride, 0, height, prefix->data, prefix->linesize);

  int64_t pts = slot.pts_us;
  if (repeat || pts <= last_pts_) pts = last_pts_ + 1000;
  last_pts_ = pts;
  bool key;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    key = keyframe_;
    keyframe_ = false;
  }
  SetField<int64_t>(frame_, api.layout.pts, pts);
  SetField<int>(frame_, api.layout.pict_type, key ? kPictureTypeI : kPictureTypeNone);
  if (api.send_frame(context_, frame_) < 0) {
    std::lock_guard<std::mutex> lock(mutex_);
    keyframe_ = true;
    return false;
  }
  for (;;) {
    int result = api.receive_packet(context_, packet_);
    if (result < 0) break;
    auto* packet = static_cast<AVPacketPrefix*>(packet_);
    EmitPacket(packet->data, packet->size, packet->pts);
    api.packet_unref(packet_);
  }
  return true;
}

void Encoder::EmitPacket(const uint8_t* data, int size, int64_t pts_us) {
  if (data == nullptr || size <= 0) return;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return;
  }
  // Parameter sets travel alone (WSN_PACKET_CONFIG), right before the IDR.
  std::vector<uint8_t> config;
  std::vector<uint8_t> body;
  body.reserve(static_cast<size_t>(size) + 16);
  bool idr = false;
  static const uint8_t kStart[4] = {0, 0, 0, 1};
  for (auto [offset, length] : NalUnits(data, size)) {
    if (length <= 0) continue;
    int type = data[offset] & 0x1f;
    std::vector<uint8_t>& out = (type == 7 || type == 8) ? config : body;
    if (type == 5) idr = true;
    out.insert(out.end(), kStart, kStart + 4);
    out.insert(out.end(), data + offset, data + offset + length);
  }
  if (!config.empty()) config_ = config;
  if (idr && !config_.empty()) {
    EmitCapture(id_, WSN_CAPTURE_PACKET, config_.data(), static_cast<int32_t>(config_.size()), 0, WSN_PACKET_CONFIG,
                width_, height_);
  }
  if (body.empty()) return;
  auto* copy = static_cast<uint8_t*>(std::malloc(body.size()));
  if (copy == nullptr) return;
  std::memcpy(copy, body.data(), body.size());
  EmitCaptureOwned(id_, WSN_CAPTURE_PACKET, copy, static_cast<int32_t>(body.size()), pts_us, idr ? WSN_PACKET_KEY : 0,
                   width_, height_);
}

}  // namespace wsn::capture
