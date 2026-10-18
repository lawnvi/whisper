#include "receiver/audio_out.h"

#include <glib.h>
#include <pthread.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>

#include "common/log.h"
#include "common/pulse.h"

namespace wsn {

namespace {

constexpr int kPaSampleFloat32le = 5;
constexpr float kHeadroom = 0.5f;          // -6 dB: phones leave this to their volume
constexpr int64_t kBaseLatencyMs = 70;     // queue + PulseAudio + sink
constexpr int64_t kStarveStepMs = 20;      // more room after audio came late
// At most this much behind the picture: past it lip sync suffers more than
// an occasional gap does.
constexpr int64_t kMaxLatencyMs = 150;
// Lead beyond max(this, target + kResyncAboveTargetMs) is dropped.
constexpr double kResyncLeadMs = 150;
constexpr double kResyncAboveTargetMs = 40;
constexpr int64_t kPtsJumpUs = 80000;      // the sender skipped or repeated audio
constexpr int64_t kNewTimelineUs = 1000000;  // the sender started over
constexpr int64_t kMaxSilenceUs = 200000;
constexpr int64_t kCalmUs = 8000000;       // room is given back 10 ms at a time
constexpr int kFadeMs = 4;
// A volume change reaches its new level over this long (never a click).
constexpr int kGainRampMs = 20;
// What PulseAudio itself holds: our own queue keeps the jitter cushion.
constexpr uint32_t kPulseTargetMs = 30;
constexpr uint32_t kPulsePrebufMs = 10;
constexpr uint32_t kPulseMinReqMs = 10;
constexpr int64_t kLatencyPollUs = 100000;

int64_t NowUs() { return g_get_monotonic_time(); }

// Linear up to -3 dBFS, then bends smoothly towards full scale.
float Limit(float value) {
  constexpr float kKnee = 0.7f;
  float magnitude = std::fabs(value);
  if (magnitude <= kKnee) return value;
  float bent = kKnee + (1 - kKnee) * std::tanh((magnitude - kKnee) / (1 - kKnee));
  return value < 0 ? -bent : bent;
}

}  // namespace

AudioOut::AudioOut(int sample_rate, int channels, std::string title, double volume)
    : sample_rate_(std::clamp(sample_rate, 8000, 192000)),
      channels_(std::clamp(channels, 1, 8)),
      title_(std::move(title)),
      fade_frames_(static_cast<size_t>(std::clamp(sample_rate, 8000, 192000) * kFadeMs / 1000)),
      gain_step_(1.0f / static_cast<float>(std::clamp(sample_rate, 8000, 192000) * kGainRampMs / 1000)),
      gain_(GainForVolume(volume)),
      target_gain_(gain_),
      latency_ms_(kBaseLatencyMs) {
  blockers_.resize(static_cast<size_t>(channels_));
  float pole = static_cast<float>(1 - 2 * M_PI * 20 / sample_rate_);
  for (DcBlocker& blocker : blockers_) blocker.pole = pole;
  if (!PulseApi().ok) return;
  thread_ = std::thread([this] { Run(); });
}

AudioOut::~AudioOut() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  cv_.notify_all();
  if (thread_.joinable()) thread_.join();
}

void* AudioOut::OpenStream() {
  const Pulse& pa = PulseApi();
  PaSampleSpec spec = {kPaSampleFloat32le, static_cast<uint32_t>(sample_rate_), static_cast<uint8_t>(channels_)};
  uint32_t bytes_per_ms = static_cast<uint32_t>(sample_rate_ / 1000 * channels_ * 4);
  PaBufferAttr attr = {static_cast<uint32_t>(-1), bytes_per_ms * kPulseTargetMs, bytes_per_ms * kPulsePrebufMs,
                       bytes_per_ms * kPulseMinReqMs, static_cast<uint32_t>(-1)};
  int error = 0;
  // GNOME's sound settings show the application name and the stream name:
  // "Whisper" and the streamed window's title.
  const char* stream_name = title_.empty() ? "Whisper" : title_.c_str();
  void* stream = pa.create(nullptr, "Whisper", kPaStreamPlayback, nullptr, stream_name, &spec, nullptr, &attr, &error);
  if (stream == nullptr) {
    WSN_LOG("audio: pa_simple_new failed (%d %s)", error, pa.strerror != nullptr ? pa.strerror(error) : "");
  }
  return stream;
}

// Lets PulseAudio play out what it holds (it ends on a fade), then closes.
void AudioOut::FinishStream(void* stream) {
  const Pulse& pa = PulseApi();
  int error = 0;
  pa.drain(stream, &error);
  pa.destroy(stream);
}

// Feeds PulseAudio in 10 ms writes, which block until it has room, so the
// write itself paces the loop. PulseAudio never runs dry while sound
// plays: when the sender's audio is late, what is left fades out and
// silence bridges the gap (up to 1 s), so a late packet never lands behind
// a stalled stream (PulseAudio would skip into it) and nothing clicks.
// After a longer silence the stream is left idle and flushed before the
// next sound, which then starts from a clean buffer.
void AudioOut::Run() {
  pthread_setname_np(pthread_self(), "wsn-audio");
  const Pulse& pa = PulseApi();
  enum class State { kIdle, kLive, kBridging };
  State state = State::kIdle;
  bool needs_flush = false;
  void* stream = nullptr;
  std::vector<float> chunk;
  int64_t measured_us = 0;
  int64_t traced_us = 0;
  int64_t bridge_start_us = 0;
  const size_t channels = static_cast<size_t>(channels_);
  const size_t chunk_frames = static_cast<size_t>(sample_rate_ / 100);  // 10 ms
  const size_t reserve = fade_frames_;
  std::unique_lock<std::mutex> lock(mutex_);
  while (!stopping_) {
    if (stream == nullptr) {
      lock.unlock();
      stream = OpenStream();
      lock.lock();
      if (stream == nullptr) {
        cv_.wait_for(lock, std::chrono::seconds(1), [this] { return stopping_; });
        continue;
      }
      state = State::kIdle;
      needs_flush = false;
      prebuffering_ = true;
    }
    chunk.clear();
    if (state == State::kIdle) {
      rebuffer_ = false;
      cv_.wait(lock, [this] { return stopping_ || QueuedMsLocked() >= CushionMsLocked(false); });
      if (stopping_) break;
      if (needs_flush) {
        // The buffer ran out while idle: start the next sound clean.
        lock.unlock();
        int error = 0;
        pa.flush(stream, &error);
        lock.lock();
        needs_flush = false;
      }
      state = State::kLive;
      prebuffering_ = false;
      fade_in_next_ = true;
      continue;
    }
    if (state == State::kBridging) {
      rebuffer_ = false;
      if (QueuedMsLocked() >= CushionMsLocked(true)) {
        state = State::kLive;
        prebuffering_ = false;
        fade_in_next_ = true;
        continue;
      }
      if (NowUs() - bridge_start_us > 1000000) {
        // A long silence (the app stopped playing): let the stream idle.
        state = State::kIdle;
        needs_flush = true;
        continue;
      }
      chunk.assign(chunk_frames * channels, 0.0f);
    } else if (rebuffer_) {
      // A new timeline: the old sound's faded tail and silence, then a whole
      // cushion of the new sound. Not a stall: the target stays.
      rebuffer_ = false;
      size_t tail = std::min(flush_tail_frames_, QueuedFramesLocked());
      chunk.assign(queue_.begin(), queue_.begin() + static_cast<ptrdiff_t>(tail * channels));
      queue_.erase(queue_.begin(), queue_.begin() + static_cast<ptrdiff_t>(tail * channels));
      chunk.resize(chunk_frames * channels, 0.0f);
      state = State::kBridging;
      bridge_start_us = NowUs();
      prebuffering_ = true;
      fade_in_next_ = true;
    } else {
      // Live. Keep the last few ms back until more comes, so a stall can end
      // on a fade.
      if (QueuedFramesLocked() <= reserve) {
        cv_.wait_for(lock, std::chrono::milliseconds(8), [this, reserve] {
          return stopping_ || QueuedFramesLocked() > reserve;
        });
        if (stopping_) break;
      }
      size_t queued = QueuedFramesLocked();
      if (queued > reserve) {
        size_t frames = std::min(chunk_frames, queued - reserve);
        chunk.assign(queue_.begin(), queue_.begin() + static_cast<ptrdiff_t>(frames * channels));
        queue_.erase(queue_.begin(), queue_.begin() + static_cast<ptrdiff_t>(frames * channels));
        if (fade_in_next_) {
          size_t fade = std::min(fade_frames_, frames);
          for (size_t frame = 0; frame < fade; frame++) {
            float gain = static_cast<float>(frame + 1) / static_cast<float>(fade);
            for (size_t channel = 0; channel < channels; channel++) chunk[frame * channels + channel] *= gain;
          }
          fade_in_next_ = false;
        }
      } else {
        // The sender's audio is late: what is left fades out, silence follows.
        chunk.assign(queue_.begin(), queue_.end());
        queue_.clear();
        size_t frames = chunk.size() / channels;
        for (size_t frame = 0; frame < frames; frame++) {
          float gain = 1 - static_cast<float>(frame + 1) / static_cast<float>(frames);
          for (size_t channel = 0; channel < channels; channel++) chunk[frame * channels + channel] *= gain;
        }
        chunk.resize(chunk_frames * channels, 0.0f);
        state = State::kBridging;
        bridge_start_us = NowUs();
        StarvedLocked(bridge_start_us);
      }
    }
    // The volume, on what is about to be heard (silence passes through it
    // too, so the ramp is at the new level when sound comes back).
    ApplyGainLocked(chunk);
    lock.unlock();
    int error = 0;
    bool ok = pa.write(stream, chunk.data(), chunk.size() * sizeof(float), &error) >= 0;
    double device = -1;
    int64_t now = NowUs();
    if (ok && now - measured_us >= kLatencyPollUs) {
      measured_us = now;
      uint64_t latency_us = pa.latency(stream, &error);
      if (latency_us != static_cast<uint64_t>(-1)) device = static_cast<double>(latency_us) / 1000;
    }
    if (!ok) {
      WSN_LOG("audio: pa_simple_write failed (%d %s), reopening", error,
              pa.strerror != nullptr ? pa.strerror(error) : "");
      pa.destroy(stream);
      stream = nullptr;
    }
    lock.lock();
    if (device >= 0) device_ms_ = device;
    if (!ok) restarts_++;
    if (now - traced_us >= 2000000) {
      traced_us = now;
      WSN_TRACE("audio: lead %.1f ms (queue %.1f + device %.1f), target %lld, restarts %d, resyncs %d", LeadMsLocked(),
                QueuedMsLocked(), device_ms_, static_cast<long long>(latency_ms_), restarts_, resyncs_);
    }
  }
  // Stopping: what is about to play fades out instead of being cut, and
  // PulseAudio plays out what it holds.
  std::vector<float> tail;
  const bool live = stream != nullptr && state != State::kIdle;
  if (live && state == State::kLive && !queue_.empty()) {
    size_t frames = std::min(fade_frames_, QueuedFramesLocked());
    tail.assign(queue_.begin(), queue_.begin() + static_cast<ptrdiff_t>(frames * channels));
    for (size_t frame = 0; frame < frames; frame++) {
      float gain = 1 - static_cast<float>(frame + 1) / static_cast<float>(frames);
      for (size_t channel = 0; channel < channels; channel++) tail[frame * channels + channel] *= gain;
    }
    ApplyGainLocked(tail);
  }
  queue_.clear();
  lock.unlock();
  if (stream == nullptr) return;
  if (!tail.empty()) {
    int error = 0;
    pa.write(stream, tail.data(), tail.size() * sizeof(float), &error);
  }
  if (live) {
    FinishStream(stream);
  } else {
    pa.destroy(stream);
  }
}

void AudioOut::Push(const uint8_t* data, size_t length, int64_t pts_us) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopping_ || !thread_.joinable()) return;
  carry_.insert(carry_.end(), data, data + length);
  const size_t channels = static_cast<size_t>(channels_);
  const size_t frame_bytes = channels * 2;
  const size_t frames = carry_.size() / frame_bytes;
  if (frames < 2) return;
  const int64_t now = NowUs();

  // Back after running dry: if the sender's pts jumped by most of the
  // outage it had simply gone quiet; otherwise audio came late and the
  // target grows.
  if (starve_pending_) {
    starve_pending_ = false;
    int64_t outage = now - starved_us_;
    int64_t quiet = pts_us - starved_expected_us_;
    if (have_sender_ && quiet * 2 < outage) {
      latency_ms_ = std::min(std::max(latency_ms_, kBaseLatencyMs) + kStarveStepMs, kMaxLatencyMs);
      last_starve_us_ = now;
      restarts_++;
    }
  }

  // The sender skipped, repeated or restarted audio: follow it, so sound
  // stays with the picture.
  bool fade_new = false;
  if (have_sender_) {
    int64_t gap = pts_us - next_sender_us_;
    int64_t magnitude = std::llabs(gap);
    if (magnitude > kNewTimelineUs) {
      resyncs_++;
      FlushLocked();
      rebuffer_ = true;
      fade_new = true;
    } else if (magnitude > kPtsJumpUs && !prebuffering_ && !queue_.empty()) {
      resyncs_++;
      size_t queued = QueuedFramesLocked();
      if (gap > 0) {
        size_t fade = std::min(fade_frames_, queued);
        FadeLocked(queued - fade, fade, false);
        size_t silence = static_cast<size_t>(std::min(gap, kMaxSilenceUs) * sample_rate_ / 1000000);
        queue_.insert(queue_.end(), silence * channels, 0.0f);
      } else {
        DropNewestLocked(std::min(queued, static_cast<size_t>(-gap * sample_rate_ / 1000000)));
      }
      fade_new = true;
    }
  }
  have_sender_ = true;
  next_sender_us_ = pts_us + static_cast<int64_t>(frames) * 1000000 / sample_rate_;

  const int adjust = DriftAdjustmentLocked();
  const size_t out_frames = frames + adjust;
  std::vector<float> out(out_frames * channels);
  const uint8_t* raw = carry_.data();
  for (size_t index = 0; index < frames * channels; index++) {
    auto value = static_cast<int16_t>(static_cast<uint16_t>(raw[2 * index]) |
                                      static_cast<uint16_t>(raw[2 * index + 1] << 8));
    float sample = Limit(blockers_[index % channels].Process(value / 32768.0f) * kHeadroom);
    if (index < out_frames * channels) {
      out[index] = sample;
    } else {
      // Trimming: the last frame blends into the one before it.
      size_t into = index - channels;
      out[into] = (out[into] + sample) / 2;
    }
  }
  if (adjust > 0) {
    // Padding: one more frame, between the last two.
    size_t last = (frames - 1) * channels;
    for (size_t channel = 0; channel < channels; channel++) {
      float a = out[last - channels + channel];
      float b = out[last + channel];
      out[last + channels + channel] = b;
      out[last + channel] = (a + b) / 2;
    }
  }
  if (fade_new) {
    size_t fade = std::min(fade_frames_, out_frames);
    for (size_t frame = 0; frame < fade; frame++) {
      float gain = static_cast<float>(frame + 1) / static_cast<float>(fade);
      for (size_t channel = 0; channel < channels; channel++) out[frame * channels + channel] *= gain;
    }
  }
  carry_.erase(carry_.begin(), carry_.begin() + static_cast<ptrdiff_t>(frames * frame_bytes));
  queue_.insert(queue_.end(), out.begin(), out.end());

  double lead = LeadMsLocked();
  if (lead > std::max(kResyncLeadMs, static_cast<double>(latency_ms_) + kResyncAboveTargetMs)) {
    // Far ahead (a burst after a stall, or clock skew): drop the oldest
    // down to the target.
    double excess_ms = lead - static_cast<double>(latency_ms_);
    DropOldestLocked(static_cast<size_t>(excess_ms * sample_rate_ / 1000));
    resyncs_++;
    smoothed_lead_ms_ = -1;
    trimming_ = padding_ = false;
    lead = LeadMsLocked();
  } else if (!prebuffering_) {
    TrackLocked(lead, now);
  }
  lead_ms_ = lead;
  cv_.notify_one();
}

void AudioOut::Reset() {
  std::lock_guard<std::mutex> lock(mutex_);
  FlushLocked();
  rebuffer_ = true;
  carry_.clear();
  have_sender_ = false;
  next_sender_us_ = 0;
  cv_.notify_one();
}

void AudioOut::SetVolume(double volume) {
  std::lock_guard<std::mutex> lock(mutex_);
  target_gain_ = GainForVolume(volume);
}

float AudioOut::GainForVolume(double volume) {
  const float level = static_cast<float>(std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 1.0);
  return level * level * level;
}

void AudioOut::ApplyGainLocked(std::vector<float>& samples) {
  const size_t channels = static_cast<size_t>(channels_);
  const size_t frames = samples.size() / channels;
  if (gain_ == target_gain_ && gain_ == 1.0f) return;
  for (size_t frame = 0; frame < frames; frame++) {
    if (gain_ < target_gain_) {
      gain_ = std::min(target_gain_, gain_ + gain_step_);
    } else if (gain_ > target_gain_) {
      gain_ = std::max(target_gain_, gain_ - gain_step_);
    }
    for (size_t channel = 0; channel < channels; channel++) samples[frame * channels + channel] *= gain_;
  }
}

double AudioOut::QueuedMsLocked() const {
  return static_cast<double>(QueuedFramesLocked()) * 1000 / sample_rate_;
}

// How much to queue before sound (re)starts so the lead reaches the target:
// from idle PulseAudio's buffer is empty and fills from the queue (only the
// sink's own latency adds); after bridging it is full of silence.
double AudioOut::CushionMsLocked(bool pulse_full) const {
  double ahead = pulse_full ? device_ms_ : std::max(0.0, device_ms_ - kPulseTargetMs);
  return std::max(15.0, static_cast<double>(latency_ms_) - ahead);
}

void AudioOut::StarvedLocked(int64_t now_us) {
  prebuffering_ = true;
  fade_in_next_ = true;
  starve_pending_ = true;
  starved_us_ = now_us;
  starved_expected_us_ = next_sender_us_;
  smoothed_lead_ms_ = -1;
  trimming_ = padding_ = false;
}

void AudioOut::TrackLocked(double lead_ms, int64_t now_us) {
  smoothed_lead_ms_ = smoothed_lead_ms_ < 0 ? lead_ms : smoothed_lead_ms_ * 0.95 + lead_ms * 0.05;
  if (latency_ms_ > kBaseLatencyMs && now_us - last_starve_us_ > kCalmUs) {
    latency_ms_ = std::max(kBaseLatencyMs, latency_ms_ - 10);
    // Another step only after another calm spell.
    last_starve_us_ = now_us - kCalmUs / 2;
  }
}

// -1: blend one frame away from this packet; +1: add one; 0: as is. Wide
// bands, so it only acts on real drift, not on network jitter.
int AudioOut::DriftAdjustmentLocked() {
  if (prebuffering_ || smoothed_lead_ms_ < 0) return 0;
  double target = static_cast<double>(latency_ms_);
  double lead = smoothed_lead_ms_;
  trimming_ = trimming_ ? lead > target + 15 : lead > target + 40;
  padding_ = padding_ ? lead < target - 10 : lead < target - 25;
  return trimming_ ? -1 : (padding_ ? 1 : 0);
}

void AudioOut::FadeLocked(size_t first_frame, size_t frames, bool in) {
  const size_t channels = static_cast<size_t>(channels_);
  for (size_t frame = 0; frame < frames; frame++) {
    float step = static_cast<float>(frame + 1) / static_cast<float>(frames);
    float gain = in ? step : 1 - step;
    for (size_t channel = 0; channel < channels; channel++) queue_[(first_frame + frame) * channels + channel] *= gain;
  }
}

// Drops `frames` from the oldest end. While playing, the first few ms stay
// and fade out, and what follows the cut fades in.
void AudioOut::DropOldestLocked(size_t frames) {
  const size_t channels = static_cast<size_t>(channels_);
  size_t queued = QueuedFramesLocked();
  frames = std::min(frames, queued);
  if (frames == 0) return;
  if (prebuffering_) {
    queue_.erase(queue_.begin(), queue_.begin() + static_cast<ptrdiff_t>(frames * channels));
    fade_in_next_ = true;
    return;
  }
  size_t keep = std::min(fade_frames_, queued - frames);
  FadeLocked(0, keep, false);
  queue_.erase(queue_.begin() + static_cast<ptrdiff_t>(keep * channels),
               queue_.begin() + static_cast<ptrdiff_t>((keep + frames) * channels));
  FadeLocked(keep, std::min(fade_frames_, QueuedFramesLocked() - keep), true);
}

void AudioOut::DropNewestLocked(size_t frames) {
  const size_t channels = static_cast<size_t>(channels_);
  frames = std::min(frames, QueuedFramesLocked());
  queue_.erase(queue_.end() - static_cast<ptrdiff_t>(frames * channels), queue_.end());
  size_t queued = QueuedFramesLocked();
  size_t fade = std::min(fade_frames_, queued);
  FadeLocked(queued - fade, fade, false);
}

// A new timeline: what is queued goes (fading out what is about to play).
void AudioOut::FlushLocked() {
  const size_t channels = static_cast<size_t>(channels_);
  flush_tail_frames_ = 0;
  if (!prebuffering_ && !queue_.empty()) {
    size_t keep = std::min(fade_frames_, QueuedFramesLocked());
    FadeLocked(0, keep, false);
    queue_.resize(keep * channels);
    flush_tail_frames_ = keep;
  } else {
    queue_.clear();
    fade_in_next_ = true;
  }
  starve_pending_ = false;
  smoothed_lead_ms_ = -1;
  trimming_ = padding_ = false;
}

void AudioOut::Stats(double out[4]) {
  std::lock_guard<std::mutex> lock(mutex_);
  out[0] = restarts_;
  out[1] = resyncs_;
  out[2] = lead_ms_;
  out[3] = static_cast<double>(latency_ms_);
}

int64_t AudioOut::HeardPtsUs() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!have_sender_ || prebuffering_) return -1;
  return next_sender_us_ - static_cast<int64_t>(LeadMsLocked() * 1000);
}

}  // namespace wsn
