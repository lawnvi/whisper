// H.264 (Annex-B) → BGRA with the system FFmpeg. One per surface, used only
// from that surface's decode thread.

#ifndef WSN_RECEIVER_DECODER_H_
#define WSN_RECEIVER_DECODER_H_

#include <cstdint>
#include <functional>
#include <vector>

namespace wsn {

class Decoder {
 public:
  Decoder() = default;
  Decoder(const Decoder&) = delete;
  Decoder& operator=(const Decoder&) = delete;
  ~Decoder();

  // A decoded picture: BGRx rows (cairo's RGB24) `stride` bytes apart, at
  // `width` × `height`, the size it was scaled to; `video_width` ×
  // `video_height` is the coded size.
  struct Picture {
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
    int stride = 0;
    int video_width = 0;
    int video_height = 0;
    // The decoded AVFrame (valid during the callback only; av_frame_clone
    // it to keep it), and the SWS_CS_* matrix and range it was converted
    // with.
    const void* frame = nullptr;
    int matrix = 0;
    bool full_range = false;
  };

  // Converts `frame` (an AVFrame) to RGB24 rows `*stride` bytes apart that
  // fit `max_edge` (0 = full size). Thread-safe; for snapshots.
  static bool ToRgb(const void* frame, int matrix, bool full_range, int max_edge, std::vector<uint8_t>* rgb,
                    int* width, int* height, int* stride);

  // Decodes one access unit. Each picture it yields is scaled to fit
  // `fit_width` × `fit_height` (keeping its shape; 0 = coded size) and passed
  // to `on_picture`, which may swap the pixels out (the decoder reuses what
  // it gets back for the next picture). Returns 0, or a negative FFmpeg
  // error (the decoder then needs a keyframe), or 1 when FFmpeg is missing.
  int Decode(const uint8_t* data, size_t length, int fit_width, int fit_height,
             const std::function<void(Picture&)>& on_picture);

  // Drops reference frames after an error, so the next keyframe starts clean.
  void Flush();

  // Damaged pictures are reported as errors (so the surface asks for a
  // keyframe at once) unless the stream proved that too strict: then
  // FFmpeg conceals the damage until the next keyframe instead.
  void Tolerate();

  static bool Available();

 private:
  bool Ready();
  void Release();

  void* context_ = nullptr;
  void* packet_ = nullptr;
  void* frame_ = nullptr;
  void* scaler_ = nullptr;
  bool strict_ = true;
  void* tuned_scaler_ = nullptr;
  int64_t tuned_colour_ = -1;
  int matrix_ = 5;
  bool full_range_ = false;
  std::vector<uint8_t> input_;
  std::vector<uint8_t> spare_;
};

}  // namespace wsn

#endif  // WSN_RECEIVER_DECODER_H_
