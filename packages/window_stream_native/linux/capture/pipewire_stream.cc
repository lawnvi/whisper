#include "capture/pipewire_stream.h"

#include "capture/pipewire_core.h"

#include "common/dl.h"
#include "common/log.h"

#ifdef WSN_HAVE_PIPEWIRE_HEADERS

#include <glib.h>
#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>

#include <cerrno>

#include <algorithm>
#include <atomic>
#include <mutex>

namespace wsn::capture {

namespace {

using pwcore::Api;
using pwcore::Lock;
using pwcore::LockCore;
using pwcore::Pw;
using pwcore::Unlock;

class Stream : public PipeWireStream {
 public:
  Stream(FrameCallback on_frame, StateCallback on_state, int max_fps)
      : on_frame_(std::move(on_frame)), on_state_(std::move(on_state)), max_fps_(max_fps) {}

  ~Stream() override {
    const Api& pw = Pw();
    Lock();
    if (stream_ != nullptr) {
      spa_hook_remove(&listener_);
      pw.stream_disconnect(stream_);
      pw.stream_destroy(stream_);
      stream_ = nullptr;
    }
    Unlock();
  }

  bool Start(pw_core* core, uint32_t node, int width, int height) {
    const Api& pw = Pw();
    stream_ = pw.stream_new(core, "Whisper window stream",
                            pw.properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                              PW_KEY_MEDIA_ROLE, "Screen", nullptr));
    if (stream_ == nullptr) return false;
    static const pw_stream_events events = [] {
      pw_stream_events e = {};
      e.version = PW_VERSION_STREAM_EVENTS;
      e.state_changed = [](void* data, pw_stream_state, pw_stream_state state, const char* error) {
        static_cast<Stream*>(data)->OnState(state, error);
      };
      e.param_changed = [](void* data, uint32_t id, const spa_pod* param) {
        static_cast<Stream*>(data)->OnParam(id, param);
      };
      e.process = [](void* data) { static_cast<Stream*>(data)->OnProcess(); };
      return e;
    }();
    pw.stream_add_listener(stream_, &listener_, &events, this);
    uint8_t buffer[1024];
    const spa_pod* params[1] = {FormatParam(buffer, sizeof(buffer), width, height)};
    int result = pw.stream_connect(stream_, SPA_DIRECTION_INPUT, node,
                                   static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS),
                                   params, 1);
    if (result < 0) {
      WSN_LOG("capture: pw_stream_connect failed: %s", spa_strerror(result));
      return false;
    }
    return true;
  }

  void Resize(int width, int height) override {
    Lock();
    if (stream_ != nullptr) {
      uint8_t buffer[1024];
      const spa_pod* params[1] = {FormatParam(buffer, sizeof(buffer), width, height)};
      Pw().stream_update_params(stream_, params, 1);
    }
    Unlock();
  }

 private:
  const spa_pod* FormatParam(uint8_t* buffer, size_t size, int width, int height) {
    spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, static_cast<uint32_t>(size));
    spa_fraction zero = SPA_FRACTION(0, 1);
    spa_fraction min_rate = SPA_FRACTION(1, 1);
    spa_fraction max_rate = SPA_FRACTION(static_cast<uint32_t>(max_fps_), 1);
    spa_pod_frame frame;
    spa_pod_builder_push_object(&b, &frame, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
    spa_pod_builder_add(&b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), 0);
    spa_pod_builder_add(&b, SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), 0);
    spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_format,
                        SPA_POD_CHOICE_ENUM_Id(3, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA),
                        0);
    if (width > 0 && height > 0) {
      spa_rectangle wanted = SPA_RECTANGLE(static_cast<uint32_t>(width), static_cast<uint32_t>(height));
      spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&wanted), 0);
    } else {
      spa_rectangle def = SPA_RECTANGLE(1280, 720);
      spa_rectangle min = SPA_RECTANGLE(1, 1);
      spa_rectangle max = SPA_RECTANGLE(8192, 8192);
      spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&def, &min, &max), 0);
    }
    spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&zero), 0);
    spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_maxFramerate,
                        SPA_POD_CHOICE_RANGE_Fraction(&max_rate, &min_rate, &max_rate), 0);
    return static_cast<const spa_pod*>(spa_pod_builder_pop(&b, &frame));
  }

  void OnState(pw_stream_state state, const char* error) {
    WSN_TRACE("capture: PipeWire stream state %d %s", static_cast<int>(state), error != nullptr ? error : "");
    if (state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) {
      if (!ended_.exchange(true) && on_state_) on_state_(true, error != nullptr ? error : "", 0, 0);
    }
  }

  void OnParam(uint32_t id, const spa_pod* param) {
    if (param == nullptr || id != SPA_PARAM_Format) return;
    uint32_t media_type = 0;
    uint32_t media_subtype = 0;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0 || media_type != SPA_MEDIA_TYPE_video ||
        media_subtype != SPA_MEDIA_SUBTYPE_raw) {
      return;
    }
    spa_video_info_raw info = {};
    if (spa_format_video_raw_parse(param, &info) < 0) return;
    width_ = static_cast<int>(info.size.width);
    height_ = static_cast<int>(info.size.height);
    format_ = info.format == SPA_VIDEO_FORMAT_BGRA ? PixelFormat::kBgra : PixelFormat::kBgrx;
    uint8_t buffer[512];
    spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const spa_pod* params[3];
    params[0] = static_cast<const spa_pod*>(spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers, SPA_PARAM_BUFFERS_dataType,
        SPA_POD_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd))));
    params[1] = static_cast<const spa_pod*>(spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
        SPA_PARAM_META_size, SPA_POD_Int(sizeof(spa_meta_header))));
    // A window stream marks the window's area inside a larger buffer.
    params[2] = static_cast<const spa_pod*>(spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_VideoCrop),
        SPA_PARAM_META_size, SPA_POD_Int(sizeof(spa_meta_region))));
    Pw().stream_update_params(stream_, params, 3);
    if (on_state_) on_state_(false, nullptr, width_, height_);
  }

  void OnProcess() {
    const Api& pw = Pw();
    pw_buffer* newest = nullptr;
    while (pw_buffer* next = pw.stream_dequeue_buffer(stream_)) {
      if (newest != nullptr) pw.stream_queue_buffer(stream_, newest);
      newest = next;
    }
    if (newest == nullptr) return;
    spa_buffer* buffer = newest->buffer;
    auto* header = static_cast<spa_meta_header*>(spa_buffer_find_meta_data(buffer, SPA_META_Header, sizeof(spa_meta_header)));
    bool usable = buffer->n_datas > 0 && width_ > 0 && height_ > 0;
    if (usable && header != nullptr && (header->flags & SPA_META_HEADER_FLAG_CORRUPTED)) usable = false;
    spa_data* data = usable ? &buffer->datas[0] : nullptr;
    if (data != nullptr && (data->data == nullptr || data->chunk == nullptr || data->chunk->size == 0 ||
                            (data->chunk->flags & SPA_CHUNK_FLAG_CORRUPTED))) {
      data = nullptr;
    }
    if (data != nullptr && (data->type == SPA_DATA_MemFd || data->type == SPA_DATA_MemPtr)) {
      Frame frame;
      frame.stride = data->chunk->stride > 0 ? data->chunk->stride : width_ * 4;
      frame.width = width_;
      frame.height = height_;
      frame.format = format_;
      frame.pts_us = g_get_monotonic_time();
      uint64_t needed = static_cast<uint64_t>(frame.stride) * static_cast<uint64_t>(height_);
      if (data->chunk->offset + needed <= data->maxsize) {
        frame.data = static_cast<const uint8_t*>(data->data) + data->chunk->offset;
        auto* crop = static_cast<spa_meta_region*>(
            spa_buffer_find_meta_data(buffer, SPA_META_VideoCrop, sizeof(spa_meta_region)));
        if (crop != nullptr && spa_meta_region_is_valid(crop)) {
          int x = std::clamp(crop->region.position.x, 0, width_ - 1);
          int y = std::clamp(crop->region.position.y, 0, height_ - 1);
          frame.width = std::min(static_cast<int>(crop->region.size.width), width_ - x);
          frame.height = std::min(static_cast<int>(crop->region.size.height), height_ - y);
          frame.data += static_cast<size_t>(y) * frame.stride + static_cast<size_t>(x) * 4;
        }
        if (frame.width > 0 && frame.height > 0 && on_frame_) on_frame_(frame);
      }
    }
    pw.stream_queue_buffer(stream_, newest);
  }

  FrameCallback on_frame_;
  StateCallback on_state_;
  int max_fps_;
  pw_stream* stream_ = nullptr;
  spa_hook listener_ = {};
  int width_ = 0;
  int height_ = 0;
  PixelFormat format_ = PixelFormat::kBgrx;
  std::atomic<bool> ended_{false};
};

}  // namespace

bool PipeWireStream::Available() { return Pw().ok; }

std::unique_ptr<PipeWireStream> PipeWireStream::Connect(uint32_t node, int width, int height, int max_fps,
                                                        FrameCallback on_frame, StateCallback on_state) {
  if (!Pw().ok) return nullptr;
  pw_core* core = LockCore();
  if (core == nullptr) return nullptr;
  auto stream = std::make_unique<Stream>(std::move(on_frame), std::move(on_state), max_fps > 0 ? max_fps : 30);
  bool started = stream->Start(core, node, width, height);
  Unlock();
  if (!started) return nullptr;
  return stream;
}

}  // namespace wsn::capture

#else  // !WSN_HAVE_PIPEWIRE_HEADERS

namespace wsn::capture {

bool PipeWireStream::Available() { return false; }

std::unique_ptr<PipeWireStream> PipeWireStream::Connect(uint32_t, int, int, int, FrameCallback, StateCallback) {
  return nullptr;
}

}  // namespace wsn::capture

#endif
