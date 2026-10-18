// H.264 encoder for one capture: BGRx frames in, Annex-B packets out through
// the capture callback (a config packet with SPS/PPS before every IDR).
//
// System FFmpeg, opened at run time (common/ffmpeg.h): libx264 (ultrafast,
// zerolatency, no B-frames, sliced threads), else libopenh264. The encoder
// runs on its own thread; a new frame replaces one still waiting, so a slow
// moment never builds a backlog.

#ifndef WSN_CAPTURE_ENCODER_H_
#define WSN_CAPTURE_ENCODER_H_

#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "capture/pipewire_stream.h"

namespace wsn::capture {

class Encoder {
 public:
  // An encoder can be made on this machine (FFmpeg with an H.264 encoder
  // whose structs this build knows). `name` receives the encoder's name.
  static bool Available(std::string* name = nullptr);

  Encoder(int64_t capture_id, int max_fps, int bit_rate);
  ~Encoder();

  // Copies the frame (any thread).
  void Push(const Frame& frame);

  void RequestKeyframe();
  void SetBusy(bool busy);
  void SetPaused(bool paused);
  void SetBitRate(int bit_rate);

  // Ends the thread; no packet is emitted afterwards.
  void Stop();

 private:
  struct Slot {
    std::vector<uint8_t> pixels;
    int stride = 0;
    int width = 0;
    int height = 0;
    PixelFormat format = PixelFormat::kBgrx;
    int64_t pts_us = 0;
  };

  void Run();
  bool Open(int width, int height);
  void Close();
  bool Encode(const Slot& slot, bool repeat);
  void EmitPacket(const uint8_t* data, int size, int64_t pts_us);

  const int64_t id_;
  const int fps_;

  std::mutex mutex_;
  std::condition_variable wake_;
  Slot pending_;
  bool has_pending_ = false;
  bool stopping_ = false;
  bool busy_ = false;
  bool paused_ = false;
  bool keyframe_ = true;
  bool repeat_ = false;
  int bit_rate_ = 0;
  bool bit_rate_changed_ = false;

  // Encoder thread only.
  Slot last_;
  bool has_last_ = false;
  void* context_ = nullptr;
  void* frame_ = nullptr;
  void* packet_ = nullptr;
  void* scaler_ = nullptr;
  int width_ = 0;
  int height_ = 0;
  int64_t last_pts_ = 0;
  std::vector<uint8_t> config_;
  std::thread thread_;
};

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_ENCODER_H_
