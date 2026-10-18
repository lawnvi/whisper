#include "receiver/decoder.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>

#include "common/ffmpeg.h"
#include "common/log.h"

namespace wsn {

namespace {

// AV_INPUT_BUFFER_PADDING_SIZE: the bitstream reader may read this far past
// the end of a packet.
constexpr size_t kInputPadding = 64;
// swscale's SIMD converters write whole groups of pixels: rows start on 64
// bytes and the buffer ends with room to spare (a 540-wide RGB24 row was
// seen written 12 bytes past its end).
constexpr int kRowAlign = 64;
constexpr size_t kOutputPadding = 256;

int AlignedStride(int bytes) { return (bytes + kRowAlign - 1) & ~(kRowAlign - 1); }

constexpr int64_t kAvColRangeJpeg = 2;
constexpr int64_t kAvColSpcBt709 = 1;
constexpr int64_t kAvColSpcUnspecified = 2;
constexpr int64_t kAvColSpcBt2020Ncl = 9;
constexpr int64_t kAvColSpcBt2020Cl = 10;
constexpr int kSwsCsItu709 = 1;
constexpr int kSwsCsItu601 = 5;
constexpr int kSwsCsBt2020 = 9;

int YuvjFormat() {
  static const int format = Libav().ok ? Libav().get_pix_fmt("yuvj420p") : -1;
  return format;
}

}  // namespace

Decoder::~Decoder() { Release(); }

bool Decoder::Available() { return Libav().ok; }

bool Decoder::Ready() {
  const FFmpeg& av = Libav();
  if (!av.ok) return false;
  if (context_ != nullptr) return true;
  const void* codec = av.find_decoder_by_name("h264");
  if (codec == nullptr) {
    WSN_LOG("decoder: FFmpeg has no h264 decoder");
    return false;
  }
  context_ = av.alloc_context(codec);
  if (context_ == nullptr) return false;
  // One picture out for each one in: no frame threading (it holds pictures
  // back); slices decode in parallel when the stream has them.
  av.opt_set(context_, "flags", "+low_delay", 0);
  av.opt_set(context_, "thread_type", "slice", 0);
  // A damaged picture fails instead of being patched over, so a keyframe is
  // asked for at once (VideoToolbox behaves the same on macOS).
  if (strict_) av.opt_set(context_, "err_detect", "+explode", 0);
  unsigned cores = std::max(1u, std::thread::hardware_concurrency());
  av.opt_set_int(context_, "threads", std::min(4u, cores), 0);
  if (av.open(context_, codec, nullptr) < 0) {
    WSN_LOG("decoder: avcodec_open2 failed");
    Release();
    return false;
  }
  packet_ = av.packet_alloc();
  frame_ = av.frame_alloc();
  if (packet_ == nullptr || frame_ == nullptr) {
    Release();
    return false;
  }
  return true;
}

int Decoder::Decode(const uint8_t* data, size_t length, int fit_width, int fit_height,
                    const std::function<void(Picture&)>& on_picture) {
  if (!Ready()) return 1;
  const FFmpeg& av = Libav();
  input_.resize(length + kInputPadding);
  std::memcpy(input_.data(), data, length);
  std::memset(input_.data() + length, 0, kInputPadding);
  auto* packet = static_cast<AVPacketPrefix*>(packet_);
  packet->data = input_.data();
  packet->size = static_cast<int>(length);
  int result = av.send_packet(context_, packet_);
  packet->data = nullptr;
  packet->size = 0;
  if (result < 0 && result != kAvErrorEagain) return result;
  for (;;) {
    int received = av.receive_frame(context_, frame_);
    if (received == kAvErrorEagain || received == kAvErrorEof) break;
    if (received < 0) return received;
    auto* frame = static_cast<AVFramePrefix*>(frame_);
    int video_width = frame->width;
    int video_height = frame->height;
    if (video_width <= 0 || video_height <= 0) {
      av.frame_unref(frame_);
      continue;
    }
    int width = video_width;
    int height = video_height;
    if (fit_width > 0 && fit_height > 0) {
      double scale = std::min(static_cast<double>(fit_width) / video_width,
                              static_cast<double>(fit_height) / video_height);
      width = std::max(1, static_cast<int>(std::lround(video_width * scale)));
      height = std::max(1, static_cast<int>(std::lround(video_height * scale)));
    }
    // Area averaging when shrinking a lot (text stays legible), bilinear
    // otherwise.
    int filter = (width * 2 < video_width || height * 2 < video_height) ? kSwsArea : kSwsBilinear;
    scaler_ = av.sws_get_cached(scaler_, video_width, video_height, frame->format, width, height, av.pix_bgra,
                                filter, nullptr, nullptr, nullptr);
    if (scaler_ == nullptr) {
      av.frame_unref(frame_);
      continue;
    }
    // The stream's colour range and matrix (VUI), so blacks stay black and
    // colours match the source.
    if (av.opt_get_int != nullptr && av.sws_get_coefficients != nullptr && av.sws_set_colorspace != nullptr) {
      int64_t range = 0;
      int64_t space = kAvColSpcUnspecified;
      av.opt_get_int(context_, "color_range", 0, &range);
      av.opt_get_int(context_, "colorspace", 0, &space);
      bool full = range == kAvColRangeJpeg || frame->format == YuvjFormat();
      int64_t colour = (full ? 1000 : 0) + space;
      if (scaler_ != tuned_scaler_ || colour != tuned_colour_) {
        int matrix = kSwsCsItu601;
        if (space == kAvColSpcBt709) {
          matrix = kSwsCsItu709;
        } else if (space == kAvColSpcBt2020Ncl || space == kAvColSpcBt2020Cl) {
          matrix = kSwsCsBt2020;
        } else if (space == kAvColSpcUnspecified && (video_width >= 1280 || video_height > 576)) {
          matrix = kSwsCsItu709;  // what players assume for untagged HD
        }
        const int* table = av.sws_get_coefficients(matrix);
        av.sws_set_colorspace(scaler_, table, full ? 1 : 0, table, 1, 0, 1 << 16, 1 << 16);
        tuned_scaler_ = scaler_;
        tuned_colour_ = colour;
        matrix_ = matrix;
        full_range_ = full;
      }
    }
    Picture picture;
    picture.pixels.swap(spare_);
    picture.stride = AlignedStride(width * 4);
    picture.pixels.resize(static_cast<size_t>(picture.stride) * height + kOutputPadding);
    uint8_t* destination[4] = {picture.pixels.data(), nullptr, nullptr, nullptr};
    int destination_stride[4] = {picture.stride, 0, 0, 0};
    av.sws_scale(scaler_, frame->data, frame->linesize, 0, video_height, destination, destination_stride);
    picture.width = width;
    picture.height = height;
    picture.video_width = video_width;
    picture.video_height = video_height;
    picture.frame = frame_;
    picture.matrix = matrix_;
    picture.full_range = full_range_;
    on_picture(picture);
    av.frame_unref(frame_);
    spare_.swap(picture.pixels);
  }
  return 0;
}

bool Decoder::ToRgb(const void* source, int matrix, bool full_range, int max_edge, std::vector<uint8_t>* rgb,
                    int* width, int* height, int* stride) {
  const FFmpeg& av = Libav();
  if (!av.ok || source == nullptr || av.pix_rgb24 < 0) return false;
  const auto* frame = static_cast<const AVFramePrefix*>(source);
  int video_width = frame->width;
  int video_height = frame->height;
  if (video_width <= 0 || video_height <= 0) return false;
  int w = video_width;
  int h = video_height;
  int longest = std::max(w, h);
  if (max_edge > 0 && longest > max_edge) {
    double scale = static_cast<double>(max_edge) / longest;
    w = std::max(1, static_cast<int>(std::lround(video_width * scale)));
    h = std::max(1, static_cast<int>(std::lround(video_height * scale)));
  }
  void* scaler = av.sws_get_cached(nullptr, video_width, video_height, frame->format, w, h, av.pix_rgb24,
                                   kSwsArea, nullptr, nullptr, nullptr);
  if (scaler == nullptr) return false;
  if (av.sws_get_coefficients != nullptr && av.sws_set_colorspace != nullptr && matrix > 0) {
    const int* table = av.sws_get_coefficients(matrix);
    av.sws_set_colorspace(scaler, table, full_range ? 1 : 0, table, 1, 0, 1 << 16, 1 << 16);
  }
  const int row = AlignedStride(w * 3);
  rgb->assign(static_cast<size_t>(row) * h + kOutputPadding, 0);
  uint8_t* destination[4] = {rgb->data(), nullptr, nullptr, nullptr};
  int destination_stride[4] = {row, 0, 0, 0};
  av.sws_scale(scaler, frame->data, frame->linesize, 0, video_height, destination, destination_stride);
  av.sws_free(scaler);
  *width = w;
  *height = h;
  *stride = row;
  return true;
}

void Decoder::Flush() {
  if (context_ != nullptr) Libav().flush_buffers(context_);
}

void Decoder::Tolerate() {
  if (!strict_) return;
  strict_ = false;
  Release();
  WSN_LOG("decoder: keyframes keep failing strict checks; concealing errors instead");
}

void Decoder::Release() {
  const FFmpeg& av = Libav();
  if (!av.ok) return;
  if (scaler_ != nullptr) av.sws_free(scaler_);
  if (frame_ != nullptr) av.frame_free(&frame_);
  if (packet_ != nullptr) av.packet_free(&packet_);
  if (context_ != nullptr) av.free_context(&context_);
  scaler_ = nullptr;
  tuned_scaler_ = nullptr;
  tuned_colour_ = -1;
}

}  // namespace wsn
