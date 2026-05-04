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

    HWAVEOUT wave_out = nullptr;
    const MMRESULT open_result = waveOutOpen(
        &wave_out, WAVE_MAPPER, &wave_format, 0, 0, CALLBACK_NULL);
    if (open_result != MMSYSERR_NOERROR) {
      if (error != nullptr) {
        *error = MmResultMessage(open_result);
      }
      return false;
    }

    std::lock_guard<std::mutex> lock(playback_mutex_);
    wave_out_ = wave_out;
    playback_session_id_ = session_id;
    return true;
  }

  bool WritePlayback(const std::string& session_id,
                     const std::vector<uint8_t>& pcm,
                     std::string* error) {
    std::lock_guard<std::mutex> lock(playback_mutex_);
    if (wave_out_ == nullptr || session_id != playback_session_id_ ||
        pcm.empty()) {
      return true;
    }

    CleanupCompletedPlaybackBuffersLocked();
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
    playback_buffers_.push_back(std::move(buffer));
    return true;
  }

  void StopPlayback(const std::string& session_id = "") {
    std::lock_guard<std::mutex> lock(playback_mutex_);
    if (!session_id.empty() && session_id != playback_session_id_) {
      return;
    }
    if (wave_out_ != nullptr) {
      waveOutReset(wave_out_);
      for (auto& buffer : playback_buffers_) {
        waveOutUnprepareHeader(wave_out_, &buffer->header, sizeof(WAVEHDR));
      }
      playback_buffers_.clear();
      waveOutClose(wave_out_);
      wave_out_ = nullptr;
    }
    playback_session_id_.clear();
  }

  void CleanupCompletedPlaybackBuffersLocked() {
    auto it = playback_buffers_.begin();
    while (it != playback_buffers_.end()) {
      auto& buffer = *it;
      if ((buffer->header.dwFlags & WHDR_DONE) == 0) {
        ++it;
        continue;
      }
      waveOutUnprepareHeader(wave_out_, &buffer->header, sizeof(WAVEHDR));
      it = playback_buffers_.erase(it);
    }
  }

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

    ComPtr<IMMDevice> device;
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) {
      InvokeCaptureError(session_id, hr);
      if (com_initialized) {
        CoUninitialize();
      }
      return;
    }

    ComPtr<IAudioClient> audio_client;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(audio_client.GetAddressOf()));
    if (FAILED(hr)) {
      InvokeCaptureError(session_id, hr);
      if (com_initialized) {
        CoUninitialize();
      }
      return;
    }

    WAVEFORMATEX* mix_format = nullptr;
    hr = audio_client->GetMixFormat(&mix_format);
    if (FAILED(hr)) {
      InvokeCaptureError(session_id, hr);
      if (com_initialized) {
        CoUninitialize();
      }
      return;
    }

    hr = audio_client->Initialize(
        AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
        kBufferDuration100ns, 0, mix_format, nullptr);
    if (FAILED(hr)) {
      CoTaskMemFree(mix_format);
      InvokeCaptureError(session_id, hr);
      if (com_initialized) {
        CoUninitialize();
      }
      return;
    }

    ComPtr<IAudioCaptureClient> capture_client;
    hr = audio_client->GetService(IID_PPV_ARGS(&capture_client));
    if (FAILED(hr)) {
      CoTaskMemFree(mix_format);
      InvokeCaptureError(session_id, hr);
      if (com_initialized) {
        CoUninitialize();
      }
      return;
    }

    hr = audio_client->Start();
    if (FAILED(hr)) {
      CoTaskMemFree(mix_format);
      InvokeCaptureError(session_id, hr);
      if (com_initialized) {
        CoUninitialize();
      }
      return;
    }

    uint64_t sequence = 0;
    while (capture_running_.load()) {
      UINT32 packet_frames = 0;
      hr = capture_client->GetNextPacketSize(&packet_frames);
      if (FAILED(hr)) {
        break;
      }
      while (packet_frames > 0 && capture_running_.load()) {
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
        InvokeCapturePcm(session_id, sequence++,
                         static_cast<int>(mix_format->nSamplesPerSec),
                         static_cast<int>(mix_format->nChannels),
                         std::move(pcm));
        hr = capture_client->GetNextPacketSize(&packet_frames);
        if (FAILED(hr)) {
          break;
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    audio_client->Stop();
    CoTaskMemFree(mix_format);
    if (com_initialized) {
      CoUninitialize();
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
