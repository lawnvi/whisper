#include "audio_share_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <audioclient.h>
#include <comdef.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <ksmedia.h>
#include <mmsystem.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

constexpr REFERENCE_TIME kBufferDuration100ns = 1000000;  // 100 ms.
// How often a running capture or playback checks that it is still on the
// default output.
constexpr auto kDefaultOutputCheckInterval = std::chrono::seconds(1);
// A queued playback buffer this long without any finishing: the stream is tied
// to an output that has gone (a display asleep with its speakers, a device
// unplugged) and plays nothing, while waveOutWrite still takes everything.
constexpr auto kPlaybackStallLimit = std::chrono::milliseconds(1500);
// Between attempts to open playback again when no output would take it.
constexpr auto kPlaybackReopenWait = std::chrono::seconds(1);
// Between attempts to open the default output again after it failed; a display
// waking up or the audio service restarting takes a few seconds.
constexpr auto kCaptureReopenFirstWait = std::chrono::milliseconds(250);
constexpr auto kCaptureReopenLongestWait = std::chrono::milliseconds(4000);

std::string HResultMessage(HRESULT hr) {
  _com_error error(hr);
  const wchar_t* message = error.ErrorMessage();
  if (message == nullptr) {
    return "Windows audio error";
  }
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, message, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return "Windows audio error";
  }
  std::string result(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, message, -1, result.data(), size, nullptr,
                      nullptr);
  return result;
}

std::string WideStringToUtf8(const wchar_t* message) {
  if (message == nullptr) {
    return "";
  }
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, message, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return "";
  }
  std::string result(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, message, -1, result.data(), size, nullptr,
                      nullptr);
  return result;
}

std::string MmResultMessage(MMRESULT result) {
  wchar_t message[MAXERRORLENGTH] = {};
  if (waveOutGetErrorTextW(result, message, MAXERRORLENGTH) == MMSYSERR_NOERROR) {
    auto utf8 = WideStringToUtf8(message);
    if (!utf8.empty()) {
      return utf8;
    }
  }
  return "Windows audio playback error";
}

template <typename T>
const T* GetMapValue(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return std::get_if<T>(&it->second);
}

int GetIntMapValue(const flutter::EncodableMap& map,
                   const char* key,
                   int fallback) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    if (*value > std::numeric_limits<int>::max() ||
        *value < std::numeric_limits<int>::min()) {
      return fallback;
    }
    return static_cast<int>(*value);
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return static_cast<int>(*value);
  }
  return fallback;
}

int16_t ClampFloatToInt16(float sample) {
  const float clamped = std::clamp(sample, -1.0f, 1.0f);
  return static_cast<int16_t>(std::lrintf(clamped * 32767.0f));
}

void AppendInt16(std::vector<uint8_t>& output, int16_t sample) {
  output.push_back(static_cast<uint8_t>(sample & 0xff));
  output.push_back(static_cast<uint8_t>((sample >> 8) & 0xff));
}

bool IsFloatFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    return true;
  }
  if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE) {
    return false;
  }
  const auto* extensible =
      reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
  return extensible->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
}

bool IsPcmFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_PCM) {
    return true;
  }
  if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE) {
    return false;
  }
  const auto* extensible =
      reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
  return extensible->SubFormat == KSDATAFORMAT_SUBTYPE_PCM;
}

std::vector<uint8_t> ConvertToPcm16(const BYTE* data,
                                    UINT32 frame_count,
                                    const WAVEFORMATEX* format,
                                    DWORD flags) {
  const int channels = format->nChannels;
  const size_t sample_count = static_cast<size_t>(frame_count) * channels;
  std::vector<uint8_t> output;
  output.reserve(sample_count * sizeof(int16_t));

  if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
    output.assign(sample_count * sizeof(int16_t), 0);
    return output;
  }

  if (IsFloatFormat(format) && format->wBitsPerSample == 32) {
    const auto* samples = reinterpret_cast<const float*>(data);
    for (size_t i = 0; i < sample_count; ++i) {
      AppendInt16(output, ClampFloatToInt16(samples[i]));
    }
    return output;
  }

  if (IsPcmFormat(format) && format->wBitsPerSample == 16) {
    output.resize(sample_count * sizeof(int16_t));
    std::memcpy(output.data(), data, output.size());
    return output;
  }

  if (IsPcmFormat(format) && format->wBitsPerSample == 24) {
    for (size_t i = 0; i < sample_count; ++i) {
      const BYTE* sample = data + i * 3;
      int32_t value = sample[0] | (sample[1] << 8) | (sample[2] << 16);
      if ((value & 0x800000) != 0) {
        value |= ~0xffffff;
      }
      AppendInt16(output, static_cast<int16_t>(value >> 8));
    }
    return output;
  }

  if (IsPcmFormat(format) && format->wBitsPerSample == 32) {
    const auto* samples = reinterpret_cast<const int32_t*>(data);
    for (size_t i = 0; i < sample_count; ++i) {
      AppendInt16(output, static_cast<int16_t>(samples[i] >> 16));
    }
    return output;
  }

  output.assign(sample_count * sizeof(int16_t), 0);
  return output;
}

struct WaveOutBuffer {
  explicit WaveOutBuffer(std::vector<uint8_t> data) : bytes(std::move(data)) {
    header.lpData = reinterpret_cast<LPSTR>(bytes.data());
    header.dwBufferLength = static_cast<DWORD>(bytes.size());
  }

  WAVEHDR header = {};
  std::vector<uint8_t> bytes;
};

class AudioSharePlugin : public flutter::Plugin {
 public:
  explicit AudioSharePlugin(flutter::PluginRegistrarWindows* registrar)
      : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "com.vireen.whisper/audio_share",
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
  }

  ~AudioSharePlugin() override {
    StopCapture();
    StopPlayback();
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();
    if (method == "startCapture") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args == nullptr) {
        result->Error("bad-arguments", "startCapture requires arguments");
        return;
      }
      const auto* session_id = GetMapValue<std::string>(*args, "sessionId");
      if (session_id == nullptr || session_id->empty()) {
        result->Error("bad-arguments", "startCapture requires sessionId");
        return;
      }
      StopCapture();
      StartCapture(*session_id);
      result->Success();
      return;
    }

    if (method == "stopCapture") {
      StopCapture();
      result->Success();
      return;
    }

    if (method == "startPlayback") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args == nullptr) {
        result->Error("bad-arguments", "startPlayback requires arguments");
        return;
      }
      const auto* session_id = GetMapValue<std::string>(*args, "sessionId");
      const auto* format = GetMapValue<flutter::EncodableMap>(*args, "format");
      if (session_id == nullptr || session_id->empty() || format == nullptr) {
        result->Error("bad-arguments",
                      "startPlayback requires sessionId and format");
        return;
      }
      std::string error;
      if (!StartPlayback(*session_id, *format, &error)) {
        result->Error("audio-playback", error);
        return;
      }
      result->Success();
      return;
    }

    if (method == "writePcm") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args == nullptr) {
        result->Error("bad-arguments", "writePcm requires arguments");
        return;
      }
      const auto* session_id = GetMapValue<std::string>(*args, "sessionId");
      const auto* pcm = GetMapValue<std::vector<uint8_t>>(*args, "pcm");
      if (session_id == nullptr || pcm == nullptr) {
        result->Error("bad-arguments", "writePcm requires sessionId and pcm");
        return;
      }
      std::string error;
      if (!WritePlayback(*session_id, *pcm, &error)) {
        result->Error("audio-playback", error);
        return;
      }
      result->Success();
      return;
    }

    if (method == "stopPlayback") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto* session_id =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "sessionId");
      StopPlayback(session_id == nullptr ? "" : *session_id);
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  void StartCapture(std::string session_id) {
    capture_running_.store(true);
    capture_thread_ = std::thread([this, session_id = std::move(session_id)] {
      CaptureLoop(session_id);
    });
  }

  void StopCapture() {
    capture_running_.store(false);
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }
  }

  bool StartPlayback(const std::string& session_id,
                     const flutter::EncodableMap& format,
                     std::string* error) {
    StopPlayback();

    const int sample_rate = GetIntMapValue(format, "sampleRate", 48000);
    const int channels = std::clamp(GetIntMapValue(format, "channels", 2), 1, 2);

    WAVEFORMATEX wave_format = {};
    wave_format.wFormatTag = WAVE_FORMAT_PCM;
    wave_format.nChannels = static_cast<WORD>(channels);
    wave_format.nSamplesPerSec = static_cast<DWORD>(sample_rate);
    wave_format.wBitsPerSample = 16;
    wave_format.nBlockAlign =
        static_cast<WORD>(wave_format.nChannels * wave_format.wBitsPerSample / 8);
    wave_format.nAvgBytesPerSec =
        wave_format.nSamplesPerSec * wave_format.nBlockAlign;

    std::lock_guard<std::mutex> lock(playback_mutex_);
    playback_format_ = wave_format;
    const MMRESULT open_result = OpenPlaybackLocked();
    if (open_result != MMSYSERR_NOERROR) {
      if (error != nullptr) {
        *error = MmResultMessage(open_result);
      }
      return false;
    }
    playback_session_id_ = session_id;
    return true;
  }

  // Each write also looks after the stream: waking from sleep or a display
  // that turns off can leave it on an output that is gone, silent and taking
  // every buffer for good. It is opened again on whatever the default output
  // is then; with no output at all, what arrives is dropped until one comes.
  bool WritePlayback(const std::string& session_id,
                     const std::vector<uint8_t>& pcm,
                     std::string* error) {
    std::lock_guard<std::mutex> lock(playback_mutex_);
    if (playback_session_id_.empty() || session_id != playback_session_id_ ||
        pcm.empty()) {
      return true;
    }

    const auto now = std::chrono::steady_clock::now();
    if (wave_out_ != nullptr) {
      CleanupCompletedPlaybackBuffersLocked(now);
      if (PlaybackNeedsReopenLocked(now)) {
        ClosePlaybackLocked();
        next_playback_reopen_ = now;
      }
    }
    if (wave_out_ == nullptr) {
      if (now < next_playback_reopen_) {
        return true;
      }
      if (OpenPlaybackLocked() != MMSYSERR_NOERROR) {
        next_playback_reopen_ = now + kPlaybackReopenWait;
        return true;
      }
    }

    auto buffer = std::make_unique<WaveOutBuffer>(pcm);
    const MMRESULT prepare_result =
        waveOutPrepareHeader(wave_out_, &buffer->header, sizeof(WAVEHDR));
    if (prepare_result != MMSYSERR_NOERROR) {
      if (error != nullptr) {
        *error = MmResultMessage(prepare_result);
      }
      return false;
    }

    const MMRESULT write_result =
        waveOutWrite(wave_out_, &buffer->header, sizeof(WAVEHDR));
    if (write_result != MMSYSERR_NOERROR) {
      waveOutUnprepareHeader(wave_out_, &buffer->header, sizeof(WAVEHDR));
      if (error != nullptr) {
        *error = MmResultMessage(write_result);
      }
      return false;
    }
    if (playback_buffers_.empty()) {
      playback_progress_at_ = now;
    }
    playback_buffers_.push_back(std::move(buffer));
    return true;
  }

  void StopPlayback(const std::string& session_id = "") {
    std::lock_guard<std::mutex> lock(playback_mutex_);
    if (!session_id.empty() && session_id != playback_session_id_) {
      return;
    }
    ClosePlaybackLocked();
    playback_session_id_.clear();
  }

  // On the default output, as WAVE_MAPPER picks it, in [playback_format_].
  MMRESULT OpenPlaybackLocked() {
    HWAVEOUT wave_out = nullptr;
    const MMRESULT result = waveOutOpen(&wave_out, WAVE_MAPPER,
                                        &playback_format_, 0, 0, CALLBACK_NULL);
    if (result != MMSYSERR_NOERROR) {
      return result;
    }
    wave_out_ = wave_out;
    playback_device_id_ = DefaultOutputId();
    const auto now = std::chrono::steady_clock::now();
    playback_progress_at_ = now;
    next_playback_device_check_ = now + kDefaultOutputCheckInterval;
    return MMSYSERR_NOERROR;
  }

  void ClosePlaybackLocked() {
    if (wave_out_ == nullptr) {
      return;
    }
    waveOutReset(wave_out_);
    for (auto& buffer : playback_buffers_) {
      waveOutUnprepareHeader(wave_out_, &buffer->header, sizeof(WAVEHDR));
    }
    playback_buffers_.clear();
    waveOutClose(wave_out_);
    wave_out_ = nullptr;
  }

  bool PlaybackNeedsReopenLocked(std::chrono::steady_clock::time_point now) {
    if (!playback_buffers_.empty() &&
        now - playback_progress_at_ > kPlaybackStallLimit) {
      return true;
    }
    if (now < next_playback_device_check_) {
      return false;
    }
    next_playback_device_check_ = now + kDefaultOutputCheckInterval;
    return DefaultOutputId() != playback_device_id_;
  }

  // Empty when there is no output, or it can't be asked.
  std::wstring DefaultOutputId() {
    if (playback_enumerator_ == nullptr &&
        FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL,
                                IID_PPV_ARGS(&playback_enumerator_)))) {
      return std::wstring();
    }
    ComPtr<IMMDevice> device;
    if (FAILED(playback_enumerator_->GetDefaultAudioEndpoint(eRender, eConsole,
                                                             &device))) {
      return std::wstring();
    }
    return DeviceId(device.Get());
  }

  void CleanupCompletedPlaybackBuffersLocked(
      std::chrono::steady_clock::time_point now) {
    auto it = playback_buffers_.begin();
    while (it != playback_buffers_.end()) {
      auto& buffer = *it;
      if ((buffer->header.dwFlags & WHDR_DONE) == 0) {
        ++it;
        continue;
      }
      waveOutUnprepareHeader(wave_out_, &buffer->header, sizeof(WAVEHDR));
      it = playback_buffers_.erase(it);
      playback_progress_at_ = now;
    }
  }

  // Runs for as long as sharing is on. Waking from sleep, a display that
  // turns off and takes its speakers with it, or another default output all
  // end a WASAPI stream with an error; the stream is opened again on whatever
  // the default output is then, rather than ending in silence that nothing
  // reports. Only a first open that fails is reported, as before.
  void CaptureLoop(const std::string& session_id) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool com_initialized = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      InvokeCaptureError(session_id, hr);
      return;
    }

    ComPtr<IMMDeviceEnumerator> enumerator;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      InvokeCaptureError(session_id, hr);
      if (com_initialized) {
        CoUninitialize();
      }
      return;
    }

    uint64_t sequence = 0;
    bool started = false;
    auto backoff = kCaptureReopenFirstWait;
    while (capture_running_.load()) {
      hr = CaptureDefaultOutput(enumerator.Get(), session_id, &sequence,
                                &started);
      if (!capture_running_.load()) {
        break;
      }
      if (SUCCEEDED(hr)) {
        // The default output changed: open the new one straight away.
        backoff = kCaptureReopenFirstWait;
        continue;
      }
      if (!started) {
        InvokeCaptureError(session_id, hr);
        break;
      }
      WaitWhileCapturing(backoff);
      backoff = (std::min)(backoff * 2, kCaptureReopenLongestWait);
    }

    if (com_initialized) {
      CoUninitialize();
    }
  }

  // Captures the current default output until it fails, sharing stops (both
  // S_OK) or another output becomes the default (S_OK).
  HRESULT CaptureDefaultOutput(IMMDeviceEnumerator* enumerator,
                               const std::string& session_id,
                               uint64_t* sequence,
                               bool* started) {
    ComPtr<IMMDevice> device;
    HRESULT hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) {
      return hr;
    }
    const std::wstring device_id = DeviceId(device.Get());

    ComPtr<IAudioClient> audio_client;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(audio_client.GetAddressOf()));
    if (FAILED(hr)) {
      return hr;
    }

    WAVEFORMATEX* mix_format = nullptr;
    hr = audio_client->GetMixFormat(&mix_format);
    if (FAILED(hr)) {
      return hr;
    }
    std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> format_owner(
        mix_format, &CoTaskMemFree);

    hr = audio_client->Initialize(
        AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
        kBufferDuration100ns, 0, mix_format, nullptr);
    if (FAILED(hr)) {
      return hr;
    }

    ComPtr<IAudioCaptureClient> capture_client;
    hr = audio_client->GetService(IID_PPV_ARGS(&capture_client));
    if (FAILED(hr)) {
      return hr;
    }

    hr = audio_client->Start();
    if (FAILED(hr)) {
      return hr;
    }
    *started = true;

    auto next_device_check =
        std::chrono::steady_clock::now() + kDefaultOutputCheckInterval;
    while (capture_running_.load()) {
      UINT32 packet_frames = 0;
      hr = capture_client->GetNextPacketSize(&packet_frames);
      while (SUCCEEDED(hr) && packet_frames > 0 && capture_running_.load()) {
        BYTE* data = nullptr;
        UINT32 frame_count = 0;
        DWORD flags = 0;
        hr = capture_client->GetBuffer(&data, &frame_count, &flags, nullptr,
                                       nullptr);
        if (FAILED(hr)) {
          break;
        }
        auto pcm = ConvertToPcm16(data, frame_count, mix_format, flags);
        capture_client->ReleaseBuffer(frame_count);
        InvokeCapturePcm(session_id, (*sequence)++,
                         static_cast<int>(mix_format->nSamplesPerSec),
                         static_cast<int>(mix_format->nChannels),
                         std::move(pcm));
        hr = capture_client->GetNextPacketSize(&packet_frames);
      }
      if (FAILED(hr)) {
        break;
      }
      const auto now = std::chrono::steady_clock::now();
      if (now >= next_device_check) {
        next_device_check = now + kDefaultOutputCheckInterval;
        ComPtr<IMMDevice> current;
        if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                       &current)) ||
            DeviceId(current.Get()) != device_id) {
          hr = S_OK;
          break;
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    audio_client->Stop();
    return capture_running_.load() ? hr : S_OK;
  }

  static std::wstring DeviceId(IMMDevice* device) {
    LPWSTR id = nullptr;
    if (device == nullptr || FAILED(device->GetId(&id)) || id == nullptr) {
      return std::wstring();
    }
    std::wstring value(id);
    CoTaskMemFree(id);
    return value;
  }

  void WaitWhileCapturing(std::chrono::milliseconds wait) {
    const auto until = std::chrono::steady_clock::now() + wait;
    while (capture_running_.load() &&
           std::chrono::steady_clock::now() < until) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
  }

  void InvokeCapturePcm(const std::string& session_id,
                        uint64_t sequence,
                        int sample_rate,
                        int channels,
                        std::vector<uint8_t> pcm) {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(session_id);
    arguments[flutter::EncodableValue("sequence")] =
        flutter::EncodableValue(static_cast<int64_t>(sequence));
    arguments[flutter::EncodableValue("captureTimeMicros")] =
        flutter::EncodableValue(static_cast<int64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now().time_since_epoch())
                .count()));
    arguments[flutter::EncodableValue("sampleRate")] =
        flutter::EncodableValue(sample_rate);
    arguments[flutter::EncodableValue("channels")] =
        flutter::EncodableValue(channels);
    arguments[flutter::EncodableValue("pcm")] = flutter::EncodableValue(pcm);

    std::lock_guard<std::mutex> lock(channel_mutex_);
    channel_->InvokeMethod(
        "onCapturePcm",
        std::make_unique<flutter::EncodableValue>(std::move(arguments)));
  }

  void InvokeCaptureError(const std::string& session_id, HRESULT hr) {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(session_id);
    arguments[flutter::EncodableValue("message")] =
        flutter::EncodableValue(HResultMessage(hr));

    std::lock_guard<std::mutex> lock(channel_mutex_);
    channel_->InvokeMethod(
        "onCaptureError",
        std::make_unique<flutter::EncodableValue>(std::move(arguments)));
  }

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::mutex channel_mutex_;
  std::mutex playback_mutex_;
  HWAVEOUT wave_out_ = nullptr;
  std::string playback_session_id_;
  std::deque<std::unique_ptr<WaveOutBuffer>> playback_buffers_;
  WAVEFORMATEX playback_format_ = {};
  // The default output when the stream was opened, to notice another one.
  std::wstring playback_device_id_;
  // On the platform thread, whose COM apartment main() sets up.
  ComPtr<IMMDeviceEnumerator> playback_enumerator_;
  // When a buffer last finished, or the first of a queue was written.
  std::chrono::steady_clock::time_point playback_progress_at_;
  std::chrono::steady_clock::time_point next_playback_device_check_;
  std::chrono::steady_clock::time_point next_playback_reopen_;
  std::atomic<bool> capture_running_{false};
  std::thread capture_thread_;
};

}  // namespace

void AudioSharePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  auto plugin = std::make_unique<AudioSharePlugin>(plugin_registrar);
  plugin_registrar->AddPlugin(std::move(plugin));
}
