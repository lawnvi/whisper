// Plays a streamed window's sound: 16-bit interleaved PCM (the viewer
// decodes the host's Opus into 20 ms frames whose pts are on the host's
// video clock) through PulseAudio — pipewire-pulse on current desktops,
// where GNOME's sound settings list it as "Whisper" with the window's title.
//
// - A jitter buffer holds about 70 ms in all (our queue + PulseAudio + the
//   sink), laid end to end on one local timeline; the sender's clock is
//   only followed when it jumps (a lost or repeated stretch: silence in or
//   samples out) or starts over (a reconnect: a new timeline).
// - PulseAudio never runs dry while sound plays: late audio fades out and
//   silence bridges the gap, so nothing is skipped or clicks.
// - When the queue runs dry, playback waits for a whole cushion again. If
//   the sender's pts show it simply went quiet (the app stopped playing, a
//   pause) that costs nothing; if audio was late (a network hiccup) the
//   target grows by 20 ms (to 150 ms at most, for lip sync), and shrinks
//   back 10 ms at a time once things are calm.
// - What piles up beyond 150 ms (or target + 40) — a burst after a Wi-Fi
//   stall, clock skew — is dropped from the oldest end, so sound stays with
//   the picture; slow drift is absorbed by blending one frame away from, or
//   into, a packet.
// - Every cut, gap and restart gets a 4 ms fade, so none of them clicks.
// - Samples pass a 20 Hz DC blocker, 6 dB of headroom and a soft limiter
//   (phones hand over audio before their volume and limiter), and are
//   played as float so several windows mix without clipping.
// - The window's volume (its own control, or wsn_surface_set_volume) scales
//   what is written, ramping over 20 ms so no change clicks.

#ifndef WSN_RECEIVER_AUDIO_OUT_H_
#define WSN_RECEIVER_AUDIO_OUT_H_

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace wsn {

class AudioOut {
 public:
  // `title` names the stream in the desktop's sound settings; `volume` as
  // SetVolume.
  AudioOut(int sample_rate, int channels, std::string title, double volume = 1);
  AudioOut(const AudioOut&) = delete;
  AudioOut& operator=(const AudioOut&) = delete;
  // Fades out what is playing and lets PulseAudio finish it (a few tens of
  // ms). May block that long: destroy it off the caller's thread.
  ~AudioOut();

  bool Matches(int sample_rate, int channels) const {
    return sample_rate == sample_rate_ && channels == channels_;
  }

  // Any thread. `pts_us` is the sender's timestamp of the first sample.
  void Push(const uint8_t* data, size_t length, int64_t pts_us);

  // A new timeline (the stream was configured again, or reconnected):
  // what is queued is dropped and playback starts over with the next packet.
  void Reset();

  // The window's volume, 0 (silent) to 1 (as sent), from the next samples
  // written on. Any thread.
  void SetVolume(double volume);
  // Volume to gain: a cubic taper (as PulseAudio's), half is about -18 dB.
  static float GainForVolume(double volume);

  // restarts, resyncs, lead over the playhead (ms), target latency (ms).
  void Stats(double out[4]);

  // The sender pts being heard now (for A/V sync logs), -1 when unknown.
  int64_t HeardPtsUs();

 private:
  struct DcBlocker {
    float pole = 0;
    float last_in = 0;
    float last_out = 0;
    float Process(float in) {
      float out = in - last_in + pole * last_out;
      last_in = in;
      last_out = out;
      return out;
    }
  };

  void Run();
  void* OpenStream();
  void FinishStream(void* stream);
  size_t QueuedFramesLocked() const { return queue_.size() / static_cast<size_t>(channels_); }
  double QueuedMsLocked() const;
  double LeadMsLocked() const { return QueuedMsLocked() + device_ms_; }
  double CushionMsLocked(bool pulse_full) const;
  int DriftAdjustmentLocked();
  void StarvedLocked(int64_t now_us);
  void TrackLocked(double lead_ms, int64_t now_us);
  void FadeLocked(size_t first_frame, size_t frames, bool in);
  void DropOldestLocked(size_t frames);
  void DropNewestLocked(size_t frames);
  void FlushLocked();
  // Scales samples about to be written by the volume, ramping towards it.
  void ApplyGainLocked(std::vector<float>& samples);

  const int sample_rate_;
  const int channels_;
  const std::string title_;
  const size_t fade_frames_;
  const float gain_step_;  // per frame: silence to full in 20 ms

  std::thread thread_;
  std::mutex mutex_;
  std::condition_variable cv_;

  // Guarded by mutex_.
  bool stopping_ = false;
  float gain_ = 1;         // what samples are scaled by now
  float target_gain_ = 1;  // the volume's gain
  std::vector<DcBlocker> blockers_;
  std::deque<float> queue_;     // interleaved samples, ready to play
  std::vector<uint8_t> carry_;  // bytes short of a whole frame
  bool prebuffering_ = true;
  bool fade_in_next_ = true;   // the next written chunk starts a sound
  bool rebuffer_ = false;      // a new timeline: refill the cushion first
  size_t flush_tail_frames_ = 0;  // the old sound's faded tail left in front
  bool have_sender_ = false;
  int64_t next_sender_us_ = 0;
  double device_ms_ = 30;      // PulseAudio's buffer + the sink, last measured
  int64_t latency_ms_;
  int64_t last_starve_us_ = 0;
  bool starve_pending_ = false;  // ran dry; judged when audio comes back
  int64_t starved_us_ = 0;
  int64_t starved_expected_us_ = 0;
  double smoothed_lead_ms_ = -1;
  bool trimming_ = false;
  bool padding_ = false;
  int restarts_ = 0;
  int resyncs_ = 0;
  double lead_ms_ = 0;
};

}  // namespace wsn

#endif  // WSN_RECEIVER_AUDIO_OUT_H_
