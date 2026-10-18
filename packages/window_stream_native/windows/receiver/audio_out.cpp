#include "audio_out.h"

#include <audioclient.h>
#include <audiopolicy.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#pragma comment(lib, "avrt.lib")

namespace wsn {

using Microsoft::WRL::ComPtr;

namespace {

constexpr float kHeadroom = 0.5f;          // -6 dB: phones leave this to their volume
constexpr int64_t kBaseLatencyMs = 70;     // queue + what WASAPI holds
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
constexpr int64_t kIdleAfterUs = 1000000;  // silence bridged this long: the stream stops
constexpr int kFadeMs = 4;
// A volume change reaches its new level over this long (never a click).
constexpr int kGainRampMs = 20;
// The engine period asked for when IAudioClient3 can go below the default
// (smaller costs wake-ups and buys nothing: the total target is fixed).
constexpr double kWantedPeriodMs = 5;
// What WASAPI holds while playing: two periods, at least this.
constexpr double kMinDeviceFillMs = 10;
constexpr REFERENCE_TIME kSharedBuffer = 300000;  // 30 ms (100 ns units)

// {00000003-0000-0010-8000-00aa00389b71}: KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.
constexpr GUID kFloatSubtype = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

// Linear up to -3 dBFS, then bends smoothly towards full scale.
float Limit(float value) {
  constexpr float kKnee = 0.7f;
  float magnitude = std::fabs(value);
  if (magnitude <= kKnee) return value;
  float bent = kKnee + (1 - kKnee) * std::tanh((magnitude - kKnee) / (1 - kKnee));
  return value < 0 ? -bent : bent;
}

// The engine's and endpoint's own delay behind what the device buffer
// holds, learnt while playing and shared by every window's stream (same
// device, same delay), so a start from idle queues just enough.
std::atomic<double> g_engine_ms{-1};

bool Trace() {
  static const bool trace = EnvFlag(L"WHISPER_WSN_TRACE");
  return trace;
}

DWORD ChannelMask(int channels) {
  switch (channels) {
    case 1: return 0x4;                // front centre
    case 2: return 0x3;                // front left, right
    case 4: return 0x33;               // + back left, right
    case 6: return 0x3F;               // 5.1
    case 8: return 0x63F;              // 7.1
    default: return 0;
  }
}

WAVEFORMATEXTENSIBLE FloatFormat(int sample_rate, int channels) {
  WAVEFORMATEXTENSIBLE format = {};
  format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  format.Format.nChannels = static_cast<WORD>(channels);
  format.Format.nSamplesPerSec = static_cast<DWORD>(sample_rate);
  format.Format.wBitsPerSample = 32;
  format.Format.nBlockAlign = static_cast<WORD>(channels * 4);
  format.Format.nAvgBytesPerSec = format.Format.nSamplesPerSec * format.Format.nBlockAlign;
  format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  format.Samples.wValidBitsPerSample = 32;
  format.dwChannelMask = ChannelMask(channels);
  format.SubFormat = kFloatSubtype;
  return format;
}

bool IsFloat32(const WAVEFORMATEX* format) {
  if (format->wBitsPerSample != 32) return false;
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  return format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
         IsEqualGUID(reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format)->SubFormat, kFloatSubtype);
}

// A stable session id per window title, so the mixer remembers a volume
// the user set for that window.
GUID SessionFor(const std::wstring& title) {
  uint64_t a = 1469598103934665603ULL;
  uint64_t b = 1099511628211ULL ^ 0x5768697370657221ULL;  // "Whisper!"
  for (wchar_t c : title) {
    a = (a ^ static_cast<uint64_t>(c)) * 1099511628211ULL;
    b = (b ^ static_cast<uint64_t>(c)) * 0x100000001b3ULL + 0x9E3779B97F4A7C15ULL;
  }
  GUID guid;
  guid.Data1 = static_cast<unsigned long>(a >> 32);
  guid.Data2 = static_cast<unsigned short>(a >> 16);
  guid.Data3 = static_cast<unsigned short>((a & 0x0FFF) | 0x4000);
  for (int k = 0; k < 8; k++) guid.Data4[k] = static_cast<unsigned char>(b >> (8 * k));
  guid.Data4[0] = static_cast<unsigned char>((guid.Data4[0] & 0x3F) | 0x80);
  return guid;
}

std::wstring DisplayName(const std::wstring& title) {
  return title.empty() ? std::wstring(L"Whisper") : L"Whisper — " + title;
}

// Tells the render thread the default output device changed. Owns what it
// touches, so a late callback after unregistering is harmless.
class DeviceWatcher
    : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                          IMMNotificationClient> {
 public:
  explicit DeviceWatcher(HANDLE wake) {
    DuplicateHandle(GetCurrentProcess(), wake, GetCurrentProcess(), &wake_, EVENT_MODIFY_STATE, FALSE, 0);
  }
  ~DeviceWatcher() {
    if (wake_ != nullptr) CloseHandle(wake_);
  }
  bool TakeChanged() { return changed_.exchange(false); }

  STDMETHOD(OnDefaultDeviceChanged)(EDataFlow flow, ERole role, LPCWSTR) override {
    if (flow == eRender && role == eConsole) {
      changed_ = true;
      if (wake_ != nullptr) SetEvent(wake_);
    }
    return S_OK;
  }
  STDMETHOD(OnDeviceAdded)(LPCWSTR) override { return S_OK; }
  STDMETHOD(OnDeviceRemoved)(LPCWSTR) override { return S_OK; }
  STDMETHOD(OnDeviceStateChanged)(LPCWSTR, DWORD) override { return S_OK; }
  STDMETHOD(OnPropertyValueChanged)(LPCWSTR, const PROPERTYKEY) override { return S_OK; }

 private:
  HANDLE wake_ = nullptr;
  std::atomic<bool> changed_{false};
};

// One WASAPI render stream on the default device (render thread only).
class Stream {
 public:
  explicit Stream(int channels) : channels_(channels) { event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr); }
  ~Stream() {
    Close();
    if (event_ != nullptr) CloseHandle(event_);
  }

  HANDLE event() const { return event_; }
  UINT32 fill_frames() const { return fill_frames_; }
  UINT32 buffer_frames() const { return buffer_frames_; }
  UINT32 period_frames() const { return period_frames_; }
  double latency_ms() const { return latency_ms_; }
  bool started() const { return started_; }

  bool Open(int sample_rate, const GUID& session, const std::wstring& name) {
    Close();
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
    if (SUCCEEDED(hr)) hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) {
      Log("audio: no output device (0x%08lx)", static_cast<unsigned long>(hr));
      return false;
    }
    WAVEFORMATEXTENSIBLE ours = FloatFormat(sample_rate, channels_);
    const char* mode = "shared";
    // The device's own format when it is ours (no converter in the path:
    // its look-ahead would hold back the end of every sound).
    bool native = false;
    // Low latency (IAudioClient3): the device's own format, a short period.
    ComPtr<IAudioClient3> client3;
    if (SUCCEEDED(device->Activate(__uuidof(IAudioClient3), CLSCTX_ALL, nullptr,
                                   reinterpret_cast<void**>(client3.GetAddressOf())))) {
      WAVEFORMATEX* mix = nullptr;
      UINT32 standard = 0, fundamental = 0, smallest = 0, largest = 0;
      if (SUCCEEDED(client3->GetMixFormat(&mix)) && mix != nullptr) {
        native = mix->nSamplesPerSec == static_cast<DWORD>(sample_rate) && mix->nChannels == channels_ && IsFloat32(mix);
        if (native) std::memcpy(&ours, mix, std::min<size_t>(sizeof(ours), sizeof(WAVEFORMATEX) + mix->cbSize));
        if (SUCCEEDED(client3->GetSharedModeEnginePeriod(mix, &standard, &fundamental, &smallest, &largest))) {
          Log("audio: device mix %lu Hz %u ch %u bit%s, engine periods %u..%u step %u (standard %u) frames",
              mix->nSamplesPerSec, mix->nChannels, mix->wBitsPerSample, IsFloat32(mix) ? " float" : "", smallest,
              largest, fundamental, standard);
        }
        if (mix->nSamplesPerSec == static_cast<DWORD>(sample_rate) && mix->nChannels == channels_ && IsFloat32(mix) &&
            SUCCEEDED(client3->GetSharedModeEnginePeriod(mix, &standard, &fundamental, &smallest, &largest)) &&
            fundamental > 0) {
          UINT32 wanted = static_cast<UINT32>(kWantedPeriodMs * sample_rate / 1000);
          UINT32 period = std::clamp(wanted, smallest, largest);
          period = smallest + (period - smallest + fundamental - 1) / fundamental * fundamental;
          period = std::min(period, largest);
          if (period < standard &&
              SUCCEEDED(client3->InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period, mix, &session))) {
            client_ = client3;
            period_frames_ = period;
            mode = "low latency";
          }
        }
        CoTaskMemFree(mix);
      }
    }
    if (client_ == nullptr) {
      // The standard period; the engine converts our format if it must.
      DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
      if (!native) flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
      hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client_.GetAddressOf()));
      WAVEFORMATEX* mix = nullptr;
      if (SUCCEEDED(hr) && client3 == nullptr && SUCCEEDED(client_->GetMixFormat(&mix)) && mix != nullptr) {
        native = mix->nSamplesPerSec == static_cast<DWORD>(sample_rate) && mix->nChannels == channels_ && IsFloat32(mix);
        if (native) {
          std::memcpy(&ours, mix, std::min<size_t>(sizeof(ours), sizeof(WAVEFORMATEX) + mix->cbSize));
          flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
        }
        CoTaskMemFree(mix);
      }
      if (FAILED(hr) ||
          FAILED(hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, kSharedBuffer, 0, &ours.Format, &session))) {
        Log("audio: IAudioClient::Initialize failed (0x%08lx)", static_cast<unsigned long>(hr));
        client_.Reset();
        return false;
      }
      REFERENCE_TIME period = 0;
      client_->GetDevicePeriod(&period, nullptr);
      period_frames_ = static_cast<UINT32>(std::max<REFERENCE_TIME>(period, 10000) * sample_rate / 10000000);
    }
    REFERENCE_TIME latency = 0;
    if (FAILED(hr = client_->SetEventHandle(event_)) || FAILED(hr = client_->GetBufferSize(&buffer_frames_)) ||
        FAILED(hr = client_->GetService(IID_PPV_ARGS(&render_)))) {
      Log("audio: stream setup failed (0x%08lx)", static_cast<unsigned long>(hr));
      Close();
      return false;
    }
    client_->GetStreamLatency(&latency);
    latency_ms_ = static_cast<double>(latency) / 10000;
    const UINT32 minimum = static_cast<UINT32>(kMinDeviceFillMs * sample_rate / 1000);
    fill_frames_ = std::min(buffer_frames_, std::max(2 * period_frames_, minimum));
    if (SUCCEEDED(client_->GetService(IID_PPV_ARGS(&session_)))) SetName(name);
    if (FAILED(client_->GetService(IID_PPV_ARGS(&clock_))) || FAILED(clock_->GetFrequency(&clock_frequency_)) ||
        clock_frequency_ == 0) {
      clock_.Reset();
    }
    sample_rate_ = sample_rate;
    written_ = 0;
    Log("audio: WASAPI %s%s, %d Hz %d ch, period %.1f ms, holds %.1f of %.1f ms, stream latency %.1f ms", mode,
        native ? "" : " (converted)", sample_rate, channels_, period_frames_ * 1000.0 / sample_rate, fill_frames_ * 1000.0 / sample_rate,
        buffer_frames_ * 1000.0 / sample_rate, latency_ms_);
    return true;
  }

  void SetName(const std::wstring& name) {
    if (session_ != nullptr) session_->SetDisplayName(name.c_str(), nullptr);
  }

  // How long until what was written so far has been heard (ms): what the
  // device holds plus the engine's and the endpoint's own delay, from the
  // stream clock; `held_ms` when there is no clock.
  double AheadMs(double held_ms) {
    UINT64 position = 0;
    UINT64 at = 0;
    if (clock_ == nullptr || !started_ || FAILED(clock_->GetPosition(&position, &at))) return held_ms;
    LARGE_INTEGER counter;
    LARGE_INTEGER frequency;
    QueryPerformanceCounter(&counter);
    QueryPerformanceFrequency(&frequency);
    const double now_100ns = static_cast<double>(counter.QuadPart) / static_cast<double>(frequency.QuadPart) * 1e7;
    const double played_s = static_cast<double>(position) / static_cast<double>(clock_frequency_) +
                            std::max(0.0, now_100ns - static_cast<double>(at)) / 1e7;
    const double ahead = (static_cast<double>(written_) / sample_rate_ - played_s) * 1000;
    // The clock may lag a start or stall; never claim less than is held.
    return std::clamp(ahead, held_ms, held_ms + 200);
  }

  // Everything written has been played (by the stream clock; by the
  // buffer when there is no clock).
  bool PlayedOut() {
    UINT64 position = 0;
    if (clock_ == nullptr || FAILED(clock_->GetPosition(&position, nullptr))) {
      UINT32 held = 0;
      return !Padding(&held) || held == 0;
    }
    return static_cast<double>(position) / static_cast<double>(clock_frequency_) * sample_rate_ >=
           static_cast<double>(written_);
  }

  void Close() {
    if (client_ != nullptr && started_) client_->Stop();
    started_ = false;
    clock_.Reset();
    render_.Reset();
    session_.Reset();
    client_.Reset();
  }

  // Frames queued in the device; false when the device went away.
  bool Padding(UINT32* frames) {
    *frames = 0;
    return client_ != nullptr && SUCCEEDED(client_->GetCurrentPadding(frames));
  }

  bool Write(const float* samples, UINT32 frames) {
    if (frames == 0) return true;
    BYTE* data = nullptr;
    if (FAILED(render_->GetBuffer(frames, &data))) return false;
    std::memcpy(data, samples, static_cast<size_t>(frames) * channels_ * sizeof(float));
    if (FAILED(render_->ReleaseBuffer(frames, 0))) return false;
    written_ += frames;
    return true;
  }

  // Real zeros, not AUDCLNT_BUFFERFLAGS_SILENT: they pass through the same
  // path as the sound before them.
  bool WriteSilence(UINT32 frames) {
    if (frames == 0) return true;
    BYTE* data = nullptr;
    if (FAILED(render_->GetBuffer(frames, &data))) return false;
    std::memset(data, 0, static_cast<size_t>(frames) * channels_ * sizeof(float));
    if (FAILED(render_->ReleaseBuffer(frames, 0))) return false;
    written_ += frames;
    return true;
  }

  bool Start() {
    if (started_) return true;
    started_ = SUCCEEDED(client_->Start());
    return started_;
  }

  // Stops and empties the device buffer (the engine may idle).
  void StopAndFlush() {
    if (client_ == nullptr) return;
    if (started_) client_->Stop();
    started_ = false;
    client_->Reset();
    written_ = 0;
  }

 private:
  const int channels_;
  HANDLE event_ = nullptr;
  ComPtr<IAudioClient> client_;
  ComPtr<IAudioRenderClient> render_;
  ComPtr<IAudioSessionControl> session_;
  ComPtr<IAudioClock> clock_;
  UINT64 clock_frequency_ = 0;
  UINT64 written_ = 0;
  int sample_rate_ = 48000;
  UINT32 buffer_frames_ = 0;
  UINT32 period_frames_ = 480;
  UINT32 fill_frames_ = 960;
  double latency_ms_ = 10;
  bool started_ = false;
};

}  // namespace

AudioOut::AudioOut(int sample_rate, int channels, std::wstring title, double volume)
    : sample_rate_(std::clamp(sample_rate, 8000, 192000)),
      channels_(std::clamp(channels, 1, 8)),
      fade_frames_(static_cast<size_t>(std::clamp(sample_rate, 8000, 192000) * kFadeMs / 1000)),
      gain_step_(1.0f / static_cast<float>(std::clamp(sample_rate, 8000, 192000) * kGainRampMs / 1000)),
      session_(SessionFor(title)),
      gain_(GainForVolume(volume)),
      target_gain_(gain_),
      title_(std::move(title)),
      latency_ms_(kBaseLatencyMs) {
  blockers_.resize(static_cast<size_t>(channels_));
  float pole = static_cast<float>(1 - 2 * 3.14159265358979 * 20 / sample_rate_);
  for (DcBlocker& blocker : blockers_) blocker.pole = pole;
  wake_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (wake_ == nullptr) return;
  thread_ = std::thread([this] { Run(); });
}

AudioOut::~AudioOut() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  if (wake_ != nullptr) SetEvent(wake_);
  if (thread_.joinable()) thread_.join();
  if (wake_ != nullptr) CloseHandle(wake_);
}

// Keeps what the device holds at `fill` frames (two engine periods), woken
// by the device every period and by new audio. The device never runs dry
// while sound plays: when the sender's audio is late, what is left fades
// out and silence bridges the gap (up to 1 s), so a late packet never lands
// behind an underrun and nothing clicks. After a longer silence the stream
// stops and is flushed; the next sound starts from a clean buffer.
void AudioOut::Run() {
  SetThreadDescription(GetCurrentThread(), L"wsn-audio");
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  DWORD task_index = 0;
  HANDLE task = AvSetMmThreadCharacteristicsW(L"Audio", &task_index);
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<DeviceWatcher> watcher = Microsoft::WRL::Make<DeviceWatcher>(wake_);
  if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator))) &&
      watcher != nullptr && FAILED(enumerator->RegisterEndpointNotificationCallback(watcher.Get()))) {
    watcher.Reset();
  }

  enum class State { kIdle, kLive, kBridging };
  State state = State::kIdle;
  Stream stream(channels_);
  bool open = false;
  std::vector<float> chunk;
  const size_t channels = static_cast<size_t>(channels_);
  const size_t reserve = fade_frames_;
  int64_t bridge_start_us = 0;
  int64_t traced_us = 0;
  double traced_cpu_ms = 0;
  int64_t wakes = 0;
  int64_t retry_at_us = 0;
  int64_t clock_read_us = 0;
  // WSN_AUDIO_DUMP=<file>: what the device is given, as s16, for checking
  // fades and gaps offline.
  FILE* dump = nullptr;
  wchar_t dump_path[MAX_PATH] = {};
  if (GetEnvironmentVariableW(L"WSN_AUDIO_DUMP", dump_path, MAX_PATH) > 0 && _wfopen_s(&dump, dump_path, L"wb") != 0) {
    dump = nullptr;
  }
  std::vector<int16_t> dumped;
  auto record = [&](const std::vector<float>& samples, size_t silent_frames) {
    if (dump == nullptr) return;
    dumped.resize(samples.size() + silent_frames * channels);
    for (size_t k = 0; k < samples.size(); k++) {
      dumped[k] = static_cast<int16_t>(std::lrintf(std::clamp(samples[k], -1.0f, 1.0f) * 32767.0f));
    }
    std::fill(dumped.begin() + static_cast<ptrdiff_t>(samples.size()), dumped.end(), static_cast<int16_t>(0));
    std::fwrite(dumped.data(), sizeof(int16_t), dumped.size(), dump);
  };

  std::unique_lock<std::mutex> lock(mutex_);
  while (!stopping_) {
    if (watcher != nullptr && watcher->TakeChanged() && open) {
      Log("audio: default output device changed, reopening");
      lock.unlock();
      stream.Close();
      lock.lock();
      open = false;
      restarts_++;
    }
    if (!open) {
      if (NowMicros() < retry_at_us) {
        lock.unlock();
        WaitForSingleObject(wake_, static_cast<DWORD>((retry_at_us - NowMicros()) / 1000 + 1));
        lock.lock();
        continue;
      }
      std::wstring name = DisplayName(title_);
      title_changed_ = false;
      lock.unlock();
      const bool ok = stream.Open(sample_rate_, session_, name);
      lock.lock();
      if (!ok) {
        retry_at_us = NowMicros() + 1000000;
        continue;
      }
      open = true;
      state = State::kIdle;
      prebuffering_ = true;
      // Until measured: the engine is about two periods behind the device buffer.
      const double learnt = g_engine_ms.load();
      stream_latency_ms_ =
          std::max(stream.latency_ms(), learnt >= 0 ? learnt : 2 * stream.period_frames() * 1000.0 / sample_rate_);
      period_ms_ = stream.period_frames() * 1000.0 / sample_rate_;
      device_ms_ = stream_latency_ms_;
    }
    if (title_changed_) {
      title_changed_ = false;
      std::wstring name = DisplayName(title_);
      lock.unlock();
      stream.SetName(name);
      lock.lock();
      continue;
    }

    // What the device holds now.
    UINT32 held = 0;
    if (stream.started()) {
      lock.unlock();
      const bool alive = stream.Padding(&held);
      lock.lock();
      if (!alive) {
        Log("audio: output device lost, reopening");
        lock.unlock();
        stream.Close();
        lock.lock();
        open = false;
        restarts_++;
        continue;
      }
    }
    const UINT32 fill = stream.fill_frames();
    const UINT32 period = stream.period_frames();
    const UINT32 room = stream.buffer_frames() > held ? stream.buffer_frames() - held : 0;
    size_t want = held < fill ? fill - held : 0;
    size_t lead_in = 0;  // zeros before the chunk
    size_t silence = 0;  // zeros after it
    bool start = false;
    bool stop = false;
    chunk.clear();

    if (state == State::kIdle) {
      rebuffer_ = false;
      const double cushion = CushionMsLocked(false);
      if (QueuedMsLocked() >= cushion) {
        // More than a cushion waited (opening the device took a while, or a
        // burst): start from the newest, so sound does not begin late.
        const double excess_ms = QueuedMsLocked() - cushion;
        if (excess_ms >= 10) {
          DropOldestLocked(static_cast<size_t>(excess_ms * sample_rate_ / 1000));
          resyncs_++;
        }
        // The device is empty: what it will hold comes from the queue,
        // after one period of zeros (a stream that starts loses its first
        // few ms otherwise, fade-in and all).
        state = State::kLive;
        prebuffering_ = false;
        fade_in_next_ = true;
        start = true;
        lead_in = period;
        want = fill > period ? fill - period : 0;
      }
    } else if (state == State::kBridging) {
      rebuffer_ = false;
      if (QueuedMsLocked() >= CushionMsLocked(true)) {
        state = State::kLive;
        prebuffering_ = false;
        fade_in_next_ = true;
      } else if (NowMicros() - bridge_start_us > kIdleAfterUs) {
        // A long silence (the app stopped playing): let the stream idle.
        state = State::kIdle;
        stop = true;
        want = 0;
      } else {
        silence = want;
        want = 0;
      }
    }
    if (state == State::kLive && rebuffer_) {
      // A new timeline: the old sound's faded tail and silence, then a whole
      // cushion of the new sound. Not a stall: the target stays.
      rebuffer_ = false;
      // All of the faded tail, even past the usual fill.
      size_t tail = std::min({flush_tail_frames_, QueuedFramesLocked(), static_cast<size_t>(room)});
      TakeLocked(tail, chunk);
      silence = want > tail ? want - tail : 0;
      want = 0;
      state = State::kBridging;
      bridge_start_us = NowMicros();
      prebuffering_ = true;
      fade_in_next_ = true;
    } else if (state == State::kLive && want > 0) {
      const size_t queued = QueuedFramesLocked();
      const size_t spare = queued > reserve ? queued - reserve : 0;
      if (spare >= want) {
        TakeLocked(want, chunk);
      } else if (!start && held + spare >= period) {
        // Short, but the device lasts through the engine's next pass: wait
        // for more.
        TakeLocked(spare, chunk);
      } else if (start) {
        TakeLocked(std::min(spare, want), chunk);
      } else {
        // The sender's audio is late: what is left fades out now, while the
        // device still holds sound for the engine's next pass, and silence
        // follows.
        TakeLocked(std::min(queued, static_cast<size_t>(room)), chunk);
        const size_t frames = chunk.size() / channels;
        for (size_t frame = 0; frame < frames; frame++) {
          float gain = 1 - static_cast<float>(frame + 1) / static_cast<float>(frames);
          for (size_t channel = 0; channel < channels; channel++) chunk[frame * channels + channel] *= gain;
        }
        silence = want > frames ? want - frames : 0;
        state = State::kBridging;
        bridge_start_us = NowMicros();
        StarvedLocked(bridge_start_us);
      }
      if (fade_in_next_ && !chunk.empty() && state == State::kLive) {
        const size_t frames = chunk.size() / channels;
        const size_t fade = std::min(fade_frames_, frames);
        for (size_t frame = 0; frame < fade; frame++) {
          float gain = static_cast<float>(frame + 1) / static_cast<float>(fade);
          for (size_t channel = 0; channel < channels; channel++) chunk[frame * channels + channel] *= gain;
        }
        fade_in_next_ = false;
      }
    }
    // The volume, on what is about to be heard. While nothing sounds the
    // ramp jumps to the new level (a full device takes nothing either, but
    // sound plays on: the ramp waits for the next chunk).
    if (!chunk.empty()) {
      ApplyGainLocked(chunk);
    } else if (state != State::kLive) {
      gain_ = target_gain_;
    }
    const State waiting_state = state;
    lock.unlock();

    bool ok = true;
    const UINT32 frames = static_cast<UINT32>(chunk.size() / channels);
    if (lead_in > 0) ok = stream.WriteSilence(static_cast<UINT32>(lead_in));
    if (ok && frames > 0) ok = stream.Write(chunk.data(), frames);
    if (ok && silence > 0) ok = stream.WriteSilence(static_cast<UINT32>(silence));
    if (ok && start) ok = stream.Start();
    if (stop) stream.StopAndFlush();
    if (ok) {
      if (lead_in > 0) record({}, lead_in);
      record(chunk, silence);
    }
    const UINT32 now_held = held + static_cast<UINT32>(lead_in) + frames + static_cast<UINT32>(silence);

    lock.lock();
    if (!ok) {
      Log("audio: write failed, reopening");
      lock.unlock();
      stream.Close();
      lock.lock();
      open = false;
      restarts_++;
      continue;
    }
    if (stream.started()) {
      // The stream clock costs a call into the engine: read it ten times a
      // second; between reads the delay behind the buffer is the learnt one.
      const double held_ms = now_held * 1000.0 / sample_rate_;
      double ahead = held_ms + stream_latency_ms_;
      if (NowMicros() - clock_read_us >= 100000) {
        clock_read_us = NowMicros();
        lock.unlock();
        ahead = stream.AheadMs(held_ms);
        lock.lock();
        // The engine's and endpoint's own delay, learnt while playing, so
        // the next start from idle queues just enough.
        if (state == State::kLive) {
          stream_latency_ms_ = std::max(stream.latency_ms(), stream_latency_ms_ * 0.8 + (ahead - held_ms) * 0.2);
          g_engine_ms = stream_latency_ms_;
        }
      }
      device_ms_ = std::max(ahead, held_ms + stream.latency_ms());
    } else {
      device_ms_ = stream_latency_ms_;
    }
    const int64_t now = NowMicros();
    wakes++;
    if (Trace() && now - traced_us >= 2000000) {
      FILETIME created, exited, kernel, user;
      GetThreadTimes(GetCurrentThread(), &created, &exited, &kernel, &user);
      const double cpu = (static_cast<double>((static_cast<uint64_t>(kernel.dwHighDateTime) << 32) | kernel.dwLowDateTime) +
                          static_cast<double>((static_cast<uint64_t>(user.dwHighDateTime) << 32) | user.dwLowDateTime)) / 1e4;
      const double span_ms = (now - traced_us) / 1000.0;
      Log("audio: lead %.1f ms (queue %.1f + device %.1f), target %lld, restarts %d, resyncs %d, %.0f wakes/s, cpu %.2f%%",
          LeadMsLocked(), QueuedMsLocked(), device_ms_, static_cast<long long>(latency_ms_), restarts_, resyncs_,
          traced_us > 0 ? wakes * 1000.0 / span_ms : 0.0, traced_us > 0 ? (cpu - traced_cpu_ms) / span_ms * 100 : 0.0);
      traced_us = now;
      traced_cpu_ms = cpu;
      wakes = 0;
    }
    if (stopping_) break;
    lock.unlock();
    if (waiting_state == State::kIdle || !stream.started()) {
      // Nothing plays: only new audio, a title or stopping wakes us.
      WaitForSingleObject(wake_, INFINITE);
    } else {
      HANDLE handles[2] = {stream.event(), wake_};
      WaitForMultipleObjects(2, handles, FALSE, 200);
    }
    lock.lock();
  }

  // Stopping: what is about to play fades out instead of being cut, and the
  // device plays out what it holds.
  std::vector<float> tail;
  const bool live = open && stream.started() && state == State::kLive;
  if (live && !queue_.empty()) {
    TakeLocked(std::min(fade_frames_, QueuedFramesLocked()), tail);
    const size_t frames = tail.size() / channels;
    for (size_t frame = 0; frame < frames; frame++) {
      float gain = 1 - static_cast<float>(frame + 1) / static_cast<float>(frames);
      for (size_t channel = 0; channel < channels; channel++) tail[frame * channels + channel] *= gain;
    }
    ApplyGainLocked(tail);
  }
  queue_.clear();
  lock.unlock();
  if (live) {
    UINT32 held = 0;
    if (stream.Padding(&held)) {  // (and `held` for the log)
      // Beyond the usual fill if need be: the fade must follow what plays,
      // and a period of zeros carries it through the engine.
      UINT32 room = stream.buffer_frames() > held ? stream.buffer_frames() - held : 0;
      const UINT32 frames = std::min<UINT32>(room, static_cast<UINT32>(tail.size() / channels));
      if (frames > 0 && stream.Write(tail.data(), frames)) {
        tail.resize(static_cast<size_t>(frames) * channels);
        room -= frames;
      } else {
        tail.clear();
      }
      const UINT32 zeros = std::min(room, stream.period_frames());
      if (stream.WriteSilence(zeros)) record(tail, zeros);
    }
    // Stops once the fade has been heard (by the stream clock, which
    // counts the engine's and endpoint's delay too).
    const int64_t began = NowMicros();
    const int64_t deadline = began + 300000;
    while (!stream.PlayedOut() && NowMicros() < deadline) Sleep(2);
    // A little more: the engine's loopback taps (screen recorders, a call
    // app sharing sound) trail the clock, and would lose the fade.
    Sleep(30);
    if (Trace()) {
      Log("audio: closing: %u frames held, %zu faded out, played out after %.1f ms", held, tail.size() / channels,
          (NowMicros() - began) / 1000.0);
    }
  }
  stream.Close();
  if (dump != nullptr) std::fclose(dump);
  if (watcher != nullptr && enumerator != nullptr) enumerator->UnregisterEndpointNotificationCallback(watcher.Get());
  watcher.Reset();
  enumerator.Reset();
  if (task != nullptr) AvRevertMmThreadCharacteristics(task);
  if (SUCCEEDED(com)) CoUninitialize();
}

void AudioOut::Push(const uint8_t* data, size_t length, int64_t pts_us) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_ || !thread_.joinable()) return;
    carry_.insert(carry_.end(), data, data + length);
    const size_t channels = static_cast<size_t>(channels_);
    const size_t frame_bytes = channels * 2;
    const size_t frames = carry_.size() / frame_bytes;
    if (frames < 2) return;
    const int64_t now = NowMicros();

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

    // Drift: up to a few frames in or out of this packet, resampled across
    // it (first and last sample kept, so packets still join smoothly).
    const int adjust = frames >= 64 ? DriftAdjustmentLocked() : 0;  // not on scraps
    const size_t out_frames = frames + adjust;
    std::vector<float> processed(frames * channels);
    const uint8_t* raw = carry_.data();
    for (size_t index = 0; index < frames * channels; index++) {
      auto value = static_cast<int16_t>(static_cast<uint16_t>(raw[2 * index]) |
                                        static_cast<uint16_t>(raw[2 * index + 1] << 8));
      processed[index] = Limit(blockers_[index % channels].Process(value / 32768.0f) * kHeadroom);
    }
    std::vector<float> resampled;
    if (adjust != 0) {
      resampled.resize(out_frames * channels);
      const double step = static_cast<double>(frames - 1) / static_cast<double>(out_frames - 1);
      for (size_t frame = 0; frame < out_frames; frame++) {
        const double position = frame * step;
        const size_t first = std::min(static_cast<size_t>(position), frames - 1);
        const size_t second = std::min(first + 1, frames - 1);
        const float t = static_cast<float>(position - static_cast<double>(first));
        for (size_t channel = 0; channel < channels; channel++) {
          const float a = processed[first * channels + channel];
          const float b = processed[second * channels + channel];
          resampled[frame * channels + channel] = a + (b - a) * t;
        }
      }
    }
    std::vector<float>& out = adjust != 0 ? resampled : processed;
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
    // While playing, the device's own wake-ups pick the new audio up; only
    // a waiting stream needs a nudge.
    if (!prebuffering_ && !rebuffer_) return;
  }
  SetEvent(wake_);
}

void AudioOut::Reset() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    FlushLocked();
    rebuffer_ = true;
    carry_.clear();
    have_sender_ = false;
    next_sender_us_ = 0;
  }
  if (wake_ != nullptr) SetEvent(wake_);
}

void AudioOut::SetTitle(std::wstring title) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (title == title_) return;
    title_ = std::move(title);
    title_changed_ = true;
  }
  if (wake_ != nullptr) SetEvent(wake_);
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
// from idle the device is empty and fills from the queue (only the engine's
// own latency adds); after bridging it is full of silence.
double AudioOut::CushionMsLocked(bool device_full) const {
  // From idle the device starts with a period of zeros, then sound.
  double ahead = device_full ? device_ms_ : stream_latency_ms_ + period_ms_;
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

// Frames to take out of (< 0) or add to (> 0) this 20 ms packet: up to 4
// out (0.4 %, about 4 ms a second, a pitch change nobody hears) when the
// lead is well above the target, 1 in when below. Bands wide enough that
// network jitter alone does not trigger it.
int AudioOut::DriftAdjustmentLocked() {
  if (prebuffering_ || smoothed_lead_ms_ < 0) return 0;
  double target = static_cast<double>(latency_ms_);
  double lead = smoothed_lead_ms_;
  trimming_ = trimming_ ? lead > target + 8 : lead > target + 25;
  padding_ = padding_ ? lead < target - 10 : lead < target - 25;
  if (trimming_) return -static_cast<int>(std::clamp((lead - target) / 10.0, 1.0, 4.0));
  return padding_ ? 1 : 0;
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

void AudioOut::TakeLocked(size_t frames, std::vector<float>& chunk) {
  const size_t samples = std::min(frames * static_cast<size_t>(channels_), queue_.size());
  chunk.insert(chunk.end(), queue_.begin(), queue_.begin() + static_cast<ptrdiff_t>(samples));
  queue_.erase(queue_.begin(), queue_.begin() + static_cast<ptrdiff_t>(samples));
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
