// Captures one process tree's audio (the streamed window's app) with WASAPI
// process loopback, as 48 kHz stereo s16le, and hands it to a sink with a
// pts on the same clock as the video (QueryPerformanceCounter 100 ns / 10).
//
// Process loopback needs Windows 10 2004 (build 19041) or newer; on older
// systems Start() reports unsupported and no audio flows.
//
// Mode 2 ("silent here") additionally mutes the app's own render sessions so
// the sound plays only on the viewer — but only if muting does not also
// silence the loopback capture (it is checked once and reported); otherwise
// the sound stays audible locally and the note says so.
#pragma once

#include "wsn_util.h"

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace wsn {

class AudioCapture {
 public:
  // [pid] is the window's process (its tree is captured). [on_pcm] gets
  // interleaved s16le, [frames] samples per channel, at 48000 Hz stereo,
  // [pts_us] on the video clock. [on_note] logs. Called on a worker thread.
  AudioCapture(DWORD pid, std::function<void(const int16_t* pcm, int frames, int64_t pts_us)> on_pcm,
               std::function<void(const std::string&)> on_note);
  ~AudioCapture();
  AudioCapture(const AudioCapture&) = delete;
  AudioCapture& operator=(const AudioCapture&) = delete;

  // mode: WSN_CAPTURE_AUDIO_ON (1) or _ON_SILENT_HERE (2). Idempotent.
  // Returns false (and notes why) when process loopback is unavailable.
  bool Start(int mode);
  // Stops the capture and restores any local muting.
  void Stop();
  // Changes between mode 1 and 2 without restarting the capture.
  void SetMode(int mode);

  static bool Supported();

 private:
  void Run();
  void ApplyLocalMute(bool mute);        // mode 2: mute/unmute the app's sessions

  const DWORD pid_;
  std::function<void(const int16_t*, int, int64_t)> on_pcm_;
  std::function<void(const std::string&)> on_note_;
  std::atomic<int> mode_{0};
  std::atomic<bool> running_{false};
  std::atomic<bool> muted_{false};
  std::atomic<bool> mute_kills_capture_{false};
  std::atomic<bool> mute_checked_{false};
  std::thread thread_;
  void* ready_event_ = nullptr;
};

}  // namespace wsn
