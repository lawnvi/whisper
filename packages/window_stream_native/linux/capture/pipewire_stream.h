// Consumes one PipeWire video node (a Mutter screencast stream).
//
// libpipewire is opened at run time (dlopen); its headers are only needed at
// build time (WSN_HAVE_PIPEWIRE_HEADERS). One pw_thread_loop serves every
// stream. Only shared-memory buffers (MemFd / MemPtr, BGRx or BGRA) are
// asked for: no GPU import, so it works on any driver. Corrupted and empty
// buffers are skipped; when several buffers are waiting, the newest wins.

#ifndef WSN_CAPTURE_PIPEWIRE_STREAM_H_
#define WSN_CAPTURE_PIPEWIRE_STREAM_H_

#include <cstdint>
#include <functional>
#include <memory>

namespace wsn::capture {

// Pixel layouts handed to the frame callback.
enum class PixelFormat { kBgrx, kBgra };

struct Frame {
  const uint8_t* data = nullptr;
  int stride = 0;
  int width = 0;
  int height = 0;
  PixelFormat format = PixelFormat::kBgrx;
  int64_t pts_us = 0;
};

class PipeWireStream {
 public:
  // Runs on the PipeWire thread; `frame` is only valid during the call.
  using FrameCallback = std::function<void(const Frame& frame)>;
  // Runs on the PipeWire thread: the stream failed or ended (`error` may be
  // empty) or its size was settled (`width`, `height`).
  using StateCallback = std::function<void(bool failed, const char* error, int width, int height)>;

  // libpipewire can be loaded (and was built with headers).
  static bool Available();

  // `width`/`height` 0 means "whatever the producer offers" (a window).
  static std::unique_ptr<PipeWireStream> Connect(uint32_t node, int width, int height, int max_fps,
                                                 FrameCallback on_frame, StateCallback on_state);

  virtual ~PipeWireStream() = default;

  // Asks the producer for a new size (a virtual monitor resizes itself).
  virtual void Resize(int width, int height) = 0;
};

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_PIPEWIRE_STREAM_H_
