// wsn_play: receiver test harness for window_stream_native.dll (Windows).
//
// Loads the DLL from the Flutter build output (or any path), opens a
// surface, pushes an Annex-B H.264 file in real time the way a source
// does (a config packet before every IDR, keyframes flagged), prints every
// window / input callback, the surface stats once a second, and runs a
// small timed script: visuals, HUD, snapshots, window resizes, synthetic
// input (SendInput) and screen captures of the window.
//
//   wsn_play.exe --dll <window_stream_native.dll> --stream <file.h264>
//                [--fps 60] [--seconds 12] [--loop] [--hud] [--out <dir>]
//                [--title <text>] [--icon <png>] [--audio]
//                [--at <seconds>:<action>]... [--script <utf8 file of such lines>]
//
// Actions: live | connecting=<msg> | paused=<msg> | reconnecting=<msg> |
//   error=<msg> | snapshot=<name>[@<max_edge>] | shot=<name> |
//   resize=<w>x<h> (client size in pixels) | move=<x>,<y> | focus |
//   hover | click | rclick | drag | wheel | keys | text=<utf8> |
//   title=<text> | icon=<png> | close | ime
//
// Sound (a 440 Hz tone in 20 ms packets with a 10 ms 2 kHz marker every
// second, through a fake network; markers are logged as
// {"marker_pts":..,"pushed_us":..} on the QPC microsecond clock):
//   audio=on|off | audioconfigure | audiojitter=<ms> | audiostall=<ms> |
//   audiosilence=<ms> | audiolose=<ms> | audiorestartpts | audioskew=<ppm> |
//   record=<name>@<seconds> (process loopback of this process into a WAV,
//   placed by QPC; logs start_us) | sessions | cpu | destroy
//   --no-video: no picture packets (audio-only runs).
//
// Build (agent B's own build dir, not part of the plugin):
//   cl /std:c++20 /EHsc /utf-8 /O2 wsn_play.cpp user32.lib gdi32.lib ole32.lib
//      windowscodecs.lib shcore.lib imm32.lib mmdevapi.lib

#ifndef UNICODE
#define UNICODE
#endif
#define _CRT_SECURE_NO_WARNINGS
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <imm.h>
#include <shellscalingapi.h>
#include <wincodec.h>
#include <mmsystem.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <wrl/implements.h>
#include <dbghelp.h>
#include <tlhelp32.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using InputCallback = void (*)(int64_t, int32_t, int32_t, int32_t, double, double, double, double, int32_t, char*);
using WindowCallback = void (*)(int64_t, int32_t, double, double, double, double);

struct Api {
  int32_t (*api_version)();
  void (*reset_all)();
  void (*set_input_callback)(InputCallback);
  void (*set_window_callback)(WindowCallback);
  void (*free_)(void*);
  int64_t (*surface_create)(const char*, int32_t, int32_t, int32_t);
  void (*surface_set_title)(int64_t, const char*);
  void (*surface_set_visual)(int64_t, int32_t, const char*);
  void (*surface_set_hud)(int64_t, const char*);
  void (*surface_set_icon)(int64_t, const uint8_t*, int32_t);
  void (*surface_focus)(int64_t);
  void (*surface_destroy)(int64_t);
  int32_t (*surface_stats)(int64_t, double*, int32_t);
  int32_t (*surface_snapshot)(int64_t, const char*, int32_t);
  uint8_t* (*buffer_alloc)(int32_t);
  void (*video_push)(int64_t, uint8_t*, int32_t, int64_t, int32_t);
  void (*audio_configure)(int64_t, int32_t, int32_t, int32_t);
  void (*audio_push)(int64_t, uint8_t*, int32_t, int64_t);
};

Api g_api;
std::chrono::steady_clock::time_point g_start;
std::mutex g_print_mutex;
FILE* g_log = nullptr;
std::atomic<double> g_first_frame_ms{-1};
std::atomic<double> g_first_push_ms{-1};
std::atomic<int> g_input_events{0};
std::atomic<int> g_keyframe_requests{0};
std::atomic<bool> g_hold{false};          // the pump stops pushing (a stalled source)
std::atomic<int> g_restarts{0};           // the pump restarts from a keyframe
std::atomic<bool> g_first_frame_seen{false};
double g_delay_push = 0;                  // seconds before the first packet
std::string g_icon_arg;
thread_local bool g_in_burst_thread = false;
std::vector<std::thread> g_bursts;
int g_open_width = 0;
int g_open_height = 0;
int64_t g_surface = 0;
std::vector<int64_t> g_extra_surfaces;  // --surfaces N: fed the same stream
std::wstring g_title = L"wsn_play";
POINT g_cursor_home = {};

double Ms() {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - g_start).count();
}

void Print(const char* format, ...) {
  char line[2048];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  std::lock_guard<std::mutex> lock(g_print_mutex);
  std::printf("[%9.1f] %s\n", Ms(), line);
  std::fflush(stdout);
  if (g_log != nullptr) {
    std::fprintf(g_log, "[%9.1f] %s\n", Ms(), line);
    std::fflush(g_log);
  }
}

std::string Narrow(const std::wstring& text) {
  int bytes = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string out(static_cast<size_t>(bytes), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), out.data(), bytes, nullptr, nullptr);
  return out;
}

std::wstring Wide(const std::string& text) {
  int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), out.data(), length);
  return out;
}

const char* InputKind(int32_t kind) {
  switch (kind) {
    case 1: return "POINTER_DOWN";
    case 2: return "POINTER_MOVE";
    case 3: return "POINTER_UP";
    case 4: return "SCROLL";
    case 5: return "KEY_DOWN";
    case 6: return "KEY_UP";
    case 7: return "TEXT";
    case 8: return "POINTER_CANCEL";
    default: return "?";
  }
}

const char* WindowKind(int32_t kind) {
  switch (kind) {
    case 1: return "CLOSE_REQUESTED";
    case 2: return "FOCUS";
    case 3: return "VISIBILITY";
    case 4: return "RESIZED";
    case 5: return "FIRST_FRAME";
    case 6: return "NEED_KEYFRAME";
    case 7: return "DECODE_ERROR";
    case 8: return "ACTION";
    default: return "?";
  }
}

void OnInput(int64_t surface, int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx, double dy,
             int32_t phase, char* text) {
  g_input_events++;
  // Hover moves are frequent; print them compactly.
  Print("input s=%lld %s code=%d mods=0x%x x=%.4f y=%.4f dx=%.3f dy=%.3f phase=%d text=%s%s%s",
        static_cast<long long>(surface), InputKind(kind), code, modifiers, x, y, dx, dy, phase, text ? "\"" : "",
        text ? text : "(null)", text ? "\"" : "");
  if (text != nullptr) g_api.free_(text);
}

void OnWindow(int64_t surface, int32_t kind, double a, double b, double c, double d) {
  Print("window s=%lld %s a=%.2f b=%.2f c=%.2f d=%.2f", static_cast<long long>(surface), WindowKind(kind), a, b, c, d);
  if (kind == 5 && g_first_frame_ms < 0) g_first_frame_ms = Ms();
  if (kind == 5) g_first_frame_seen = true;  // the main loop sets LIVE, as Dart does
  if (kind == 6) g_keyframe_requests++;
}

template <typename T>
bool Resolve(HMODULE module, const char* name, T* out) {
  *out = reinterpret_cast<T>(GetProcAddress(module, name));
  if (*out == nullptr) {
    Print("missing export %s", name);
    return false;
  }
  return true;
}

// ---------------------------------------------------------------- Annex-B

struct AccessUnit {
  std::vector<uint8_t> config;  // SPS/PPS seen before this unit
  std::vector<uint8_t> data;
  bool key = false;
};

std::vector<AccessUnit> SplitAccessUnits(const std::vector<uint8_t>& stream) {
  struct Nal {
    size_t start;  // including start code
    size_t payload;
    size_t end;
    int type;
  };
  std::vector<Nal> nals;
  size_t i = 0;
  const size_t n = stream.size();
  std::vector<std::pair<size_t, size_t>> starts;
  while (i + 3 <= n) {
    if (stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1) {
      starts.push_back({i, i + 3});
      i += 3;
    } else if (i + 4 <= n && stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 0 && stream[i + 3] == 1) {
      starts.push_back({i, i + 4});
      i += 4;
    } else {
      i++;
    }
  }
  for (size_t k = 0; k < starts.size(); k++) {
    size_t end = k + 1 < starts.size() ? starts[k + 1].first : n;
    if (starts[k].second < end) nals.push_back({starts[k].first, starts[k].second, end, stream[starts[k].second] & 0x1F});
  }
  std::vector<AccessUnit> units;
  AccessUnit current;
  std::vector<uint8_t> config;
  bool has_vcl = false;
  auto flush = [&] {
    if (has_vcl) {
      units.push_back(std::move(current));
    }
    current = AccessUnit();
    has_vcl = false;
  };
  for (const Nal& nal : nals) {
    const bool vcl = nal.type == 1 || nal.type == 5;
    const bool first_slice = vcl && nal.payload + 1 < nal.end && (stream[nal.payload + 1] & 0x80) != 0;
    if (nal.type == 9 || nal.type == 7 || (vcl && first_slice && has_vcl)) {
      flush();
    }
    if (nal.type == 7) config.clear();
    if (nal.type == 7 || nal.type == 8) {
      config.insert(config.end(), stream.begin() + nal.start, stream.begin() + nal.end);
      continue;
    }
    if (nal.type == 9) continue;
    if (vcl) {
      has_vcl = true;
      if (nal.type == 5) {
        current.key = true;
        current.config = config;
      }
    }
    current.data.insert(current.data.end(), stream.begin() + nal.start, stream.begin() + nal.end);
  }
  flush();
  return units;
}

void PushTo(int64_t surface, const std::vector<uint8_t>& bytes, int64_t pts_us, int32_t flags) {
  uint8_t* buffer = g_api.buffer_alloc(static_cast<int32_t>(bytes.size()));
  std::memcpy(buffer, bytes.data(), bytes.size());
  g_api.video_push(surface, buffer, static_cast<int32_t>(bytes.size()), pts_us, flags);
}

void Push(const std::vector<uint8_t>& bytes, int64_t pts_us, int32_t flags) {
  PushTo(g_surface, bytes, pts_us, flags);
  for (int64_t extra : g_extra_surfaces) PushTo(extra, bytes, pts_us, flags);
}

// ---------------------------------------------------------------- window helpers

// Records what the default output device plays (WASAPI loopback) for
// `seconds` into a 32-bit float WAV, to look for clicks.
void RecordLoopback(const std::wstring& path, double seconds) {
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX* format = nullptr;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator))) ||
      FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)) ||
      FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&client))) ||
      FAILED(client->GetMixFormat(&format)) ||
      FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 10000000, 0, format, nullptr)) ||
      FAILED(client->GetService(IID_PPV_ARGS(&capture))) || FAILED(client->Start())) {
    Print("loopback: not available");
    return;
  }
  Print("loopback: %lu Hz %u ch %u bits", format->nSamplesPerSec, format->nChannels, format->wBitsPerSample);
  std::vector<uint8_t> data;
  const double end = Ms() + seconds * 1000;
  while (Ms() < end) {
    Sleep(5);
    UINT32 packet = 0;
    while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
      BYTE* bytes = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (FAILED(capture->GetBuffer(&bytes, &frames, &flags, nullptr, nullptr))) break;
      size_t length = static_cast<size_t>(frames) * format->nBlockAlign;
      if (flags & AUDCLNT_BUFFERFLAGS_SILENT) data.insert(data.end(), length, 0);
      else data.insert(data.end(), bytes, bytes + length);
      capture->ReleaseBuffer(frames);
    }
  }
  client->Stop();
  FILE* file = _wfopen(path.c_str(), L"wb");
  if (file != nullptr) {
    // WAVE_FORMAT_IEEE_FLOAT header (assumes the usual float mix format).
    uint32_t size = static_cast<uint32_t>(data.size());
    uint16_t channels = format->nChannels;
    uint32_t rate = format->nSamplesPerSec;
    uint16_t bits = format->wBitsPerSample;
    uint16_t align = format->nBlockAlign;
    uint32_t byte_rate = rate * align;
    uint16_t tag = 3;
    uint32_t chunk = 36 + size;
    uint32_t fmt_size = 16;
    std::fwrite("RIFF", 1, 4, file); std::fwrite(&chunk, 4, 1, file); std::fwrite("WAVEfmt ", 1, 8, file);
    std::fwrite(&fmt_size, 4, 1, file); std::fwrite(&tag, 2, 1, file); std::fwrite(&channels, 2, 1, file);
    std::fwrite(&rate, 4, 1, file); std::fwrite(&byte_rate, 4, 1, file); std::fwrite(&align, 2, 1, file);
    std::fwrite(&bits, 2, 1, file); std::fwrite("data", 1, 4, file); std::fwrite(&size, 4, 1, file);
    std::fwrite(data.data(), 1, data.size(), file);
    std::fclose(file);
  }
  Print("loopback: %zu bytes recorded", data.size());
  CoTaskMemFree(format);
  capture->Release();
  client->Release();
  device->Release();
  enumerator->Release();
}

// ---------------------------------------------------------------- audio test source

int64_t QpcMicros() {
  static const double frequency = [] {
    LARGE_INTEGER value;
    QueryPerformanceFrequency(&value);
    return static_cast<double>(value.QuadPart);
  }();
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  return static_cast<int64_t>(static_cast<double>(now.QuadPart) / frequency * 1e6);
}

std::atomic<bool> g_audio{false};
std::atomic<int> g_audio_silence_ms{0};  // the source goes quiet (pts jump)
std::atomic<int> g_audio_stall_ms{0};    // the network holds packets, then a burst
std::atomic<int> g_audio_jitter_ms{0};   // random extra delay per packet
std::atomic<int> g_audio_skew_ppm{0};    // the sender's clock runs fast (+) or slow (-)
std::atomic<int> g_audio_lose_ms{0};     // packets lost on the way (time goes on)
std::atomic<bool> g_audio_restart_pts{false};  // the host restarted: pts start over
std::thread g_audio_thread;

// 20 ms PCM frames like the viewer's Opus decoder hands over: a 440 Hz tone
// with a 10 ms 2 kHz marker every second, delivered through a fake network
// (jitter, stalls, loss) in order.
void AudioLoop() {
  SetThreadDescription(GetCurrentThread(), L"fake-sender");
  const int rate = 48000;
  const int channels = 2;
  const int frames = rate / 50;
  struct Pending {
    int64_t deliver_us;
    int64_t pts;
    bool marker;
    std::vector<int16_t> pcm;
  };
  std::deque<Pending> pending;
  const int64_t t0 = QpcMicros();
  int64_t gen_us = t0;
  int64_t pts = 0;
  int64_t last_deliver_us = 0;
  int64_t stall_until_us = 0;
  int64_t lost_until_us = 0;
  int64_t count = 0;
  double phase = 0;
  unsigned seed = 12345;
  while (g_audio) {
    int silence = g_audio_silence_ms.exchange(0);
    if (silence > 0) {
      gen_us += silence * 1000LL;
      pts += silence * 1000LL;
      Print("audio: source quiet for %d ms", silence);
    }
    int lose = g_audio_lose_ms.exchange(0);
    if (lose > 0) {
      lost_until_us = QpcMicros() + lose * 1000LL;
      Print("audio: packets lost for %d ms", lose);
    }
    if (g_audio_restart_pts.exchange(false)) {
      pts = 0;
      Print("audio: host restarted, pts from 0");
    }
    int stall = g_audio_stall_ms.exchange(0);
    if (stall > 0) {
      stall_until_us = QpcMicros() + stall * 1000LL;
      Print("audio: network stall %d ms", stall);
    }
    int64_t next_deliver = pending.empty() ? INT64_MAX : pending.front().deliver_us;
    int64_t wake = std::min(gen_us, next_deliver);
    int64_t now = QpcMicros();
    if (wake > now) Sleep(static_cast<DWORD>(std::min<int64_t>((wake - now) / 1000, 5)));
    now = QpcMicros();
    if (now >= gen_us) {
      Pending packet;
      packet.pts = pts;
      packet.marker = count % 50 == 0;
      packet.pcm.resize(static_cast<size_t>(frames * channels));
      for (int f = 0; f < frames; f++) {
        bool beep = packet.marker && f < rate / 100;
        double frequency = beep ? 2000 : 440;
        int16_t v = static_cast<int16_t>(std::sin(phase) * (beep ? 16000 : 8000));
        phase += 2 * 3.14159265358979 * frequency / rate;
        if (phase > 2 * 3.14159265358979) phase -= 2 * 3.14159265358979;
        packet.pcm[2 * f] = v;
        packet.pcm[2 * f + 1] = v;
      }
      int jitter = g_audio_jitter_ms.load();
      seed = seed * 1103515245u + 12345u;
      int64_t extra = jitter > 0 ? static_cast<int64_t>((seed >> 8) % static_cast<unsigned>(jitter * 1000)) : 0;
      packet.deliver_us = std::max<int64_t>({gen_us + extra, last_deliver_us, stall_until_us});
      last_deliver_us = packet.deliver_us;
      if (gen_us >= lost_until_us) pending.push_back(std::move(packet));
      count++;
      pts += 20000;
      // A sender clock off by `ppm` makes 20 ms of audio in a little more or
      // less than 20 ms of our time.
      gen_us += static_cast<int64_t>(20000.0 / (1.0 + g_audio_skew_ppm.load() / 1e6));
    }
    while (!pending.empty() && pending.front().deliver_us <= now) {
      Pending& packet = pending.front();
      int64_t surface = g_surface;
      if (surface != 0) {
        int32_t bytes = static_cast<int32_t>(packet.pcm.size() * 2);
        uint8_t* buffer = g_api.buffer_alloc(bytes);
        std::memcpy(buffer, packet.pcm.data(), static_cast<size_t>(bytes));
        int64_t pushed = QpcMicros();
        g_api.audio_push(surface, buffer, bytes, packet.pts);
        if (packet.marker) {
          Print("{\"marker_pts\":%lld,\"pushed_us\":%lld}", static_cast<long long>(packet.pts),
                static_cast<long long>(pushed));
        }
      }
      pending.pop_front();
    }
  }
}

void AudioOn(bool on) {
  if (on && !g_audio) {
    g_api.audio_configure(g_surface, 1, 48000, 2);
    g_audio = true;
    g_audio_thread = std::thread(AudioLoop);
  } else if (!on && g_audio) {
    g_audio = false;
    if (g_audio_thread.joinable()) g_audio_thread.join();
  }
}

class ActivateDone
    : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                          Microsoft::WRL::FtmBase, IActivateAudioInterfaceCompletionHandler> {
 public:
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  ~ActivateDone() { CloseHandle(done); }
  STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation*) override {
    SetEvent(done);
    return S_OK;
  }
};

void WriteWav(const std::wstring& path, const std::vector<int16_t>& samples, int rate, int channels) {
  FILE* file = _wfopen(path.c_str(), L"wb");
  if (file == nullptr) return;
  uint32_t size = static_cast<uint32_t>(samples.size() * 2);
  uint16_t ch = static_cast<uint16_t>(channels);
  uint32_t sr = static_cast<uint32_t>(rate);
  uint16_t bits = 16;
  uint16_t align = static_cast<uint16_t>(channels * 2);
  uint32_t byte_rate = sr * align;
  uint16_t tag = 1;
  uint32_t chunk = 36 + size;
  uint32_t fmt_size = 16;
  std::fwrite("RIFF", 1, 4, file); std::fwrite(&chunk, 4, 1, file); std::fwrite("WAVEfmt ", 1, 8, file);
  std::fwrite(&fmt_size, 4, 1, file); std::fwrite(&tag, 2, 1, file); std::fwrite(&ch, 2, 1, file);
  std::fwrite(&sr, 4, 1, file); std::fwrite(&byte_rate, 4, 1, file); std::fwrite(&align, 2, 1, file);
  std::fwrite(&bits, 2, 1, file); std::fwrite("data", 1, 4, file); std::fwrite(&size, 4, 1, file);
  std::fwrite(samples.data(), 2, samples.size(), file);
  std::fclose(file);
}

// Records this process's own sound (process loopback: nothing else on the
// machine) as 48 kHz stereo s16, each packet placed by its QPC time, so the
// file's timeline matches the markers' push times.
void RecordProcess(const std::wstring& path, double seconds) {
  AUDIOCLIENT_ACTIVATION_PARAMS params = {};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
  params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT activate = {};
  activate.vt = VT_BLOB;
  activate.blob.cbSize = sizeof(params);
  activate.blob.pBlobData = reinterpret_cast<BYTE*>(&params);
  auto handler = Microsoft::WRL::Make<ActivateDone>();
  Microsoft::WRL::ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &activate,
                                           handler.Get(), &operation);
  if (FAILED(hr)) {
    Print("record: activation failed 0x%08lx", static_cast<unsigned long>(hr));
    return;
  }
  WaitForSingleObject(handler->done, 5000);
  HRESULT result = E_FAIL;
  Microsoft::WRL::ComPtr<IUnknown> unknown;
  Microsoft::WRL::ComPtr<IAudioClient> client;
  Microsoft::WRL::ComPtr<IAudioCaptureClient> capture;
  if (FAILED(operation->GetActivateResult(&result, &unknown)) || FAILED(result) || FAILED(unknown.As(&client))) {
    Print("record: activation result 0x%08lx", static_cast<unsigned long>(result));
    return;
  }
  const int rate = 48000;
  WAVEFORMATEX format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = 2;
  format.nSamplesPerSec = rate;
  format.wBitsPerSample = 16;
  format.nBlockAlign = 4;
  format.nAvgBytesPerSec = rate * 4;
  HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (FAILED(hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                     AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 200000, 0,
                                     &format, nullptr)) ||
      FAILED(hr = client->SetEventHandle(event)) || FAILED(hr = client->GetService(IID_PPV_ARGS(&capture))) ||
      FAILED(hr = client->Start())) {
    Print("record: setup failed 0x%08lx", static_cast<unsigned long>(hr));
    CloseHandle(event);
    return;
  }
  std::vector<int16_t> samples;
  int64_t start_us = -1;
  int discontinuities = 0;
  int silent_packets = 0;
  int realigned = 0;
  const int64_t end = QpcMicros() + static_cast<int64_t>(seconds * 1e6);
  while (QpcMicros() < end) {
    WaitForSingleObject(event, 100);
    UINT32 packet = 0;
    while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      UINT64 position = 0;
      UINT64 qpc = 0;
      if (FAILED(capture->GetBuffer(&data, &frames, &flags, &position, &qpc))) break;
      const int64_t at_us = static_cast<int64_t>(qpc / 10);
      if (start_us < 0) start_us = at_us;
      if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) discontinuities++;
      if (flags & AUDCLNT_BUFFERFLAGS_SILENT) silent_packets++;
      // Where this packet belongs on the timeline.
      const int64_t index = (at_us - start_us) * rate / 1000000;
      const int64_t written = static_cast<int64_t>(samples.size() / 2);
      if (index > written + rate / 500) {  // more than 2 ms missing: fill
        samples.resize(static_cast<size_t>(index) * 2, 0);
        realigned++;
      }
      const size_t count = static_cast<size_t>(frames) * 2;
      if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) || data == nullptr) {
        samples.insert(samples.end(), count, 0);
      } else {
        const int16_t* pcm = reinterpret_cast<const int16_t*>(data);
        samples.insert(samples.end(), pcm, pcm + count);
      }
      capture->ReleaseBuffer(frames);
    }
  }
  client->Stop();
  CloseHandle(event);
  WriteWav(path, samples, rate, 2);
  Print("record: start_us=%lld %.2f s, %d discontinuities, %d silent packets, %d gaps filled", static_cast<long long>(start_us),
        samples.size() / 2.0 / rate, discontinuities, silent_packets, realigned);
}

// The audio sessions of this process on the default output device, as the
// volume mixer lists them.
void PrintSessions() {
  using Microsoft::WRL::ComPtr;
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioSessionManager2> manager;
  ComPtr<IAudioSessionEnumerator> sessions;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator))) ||
      FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)) ||
      FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void**>(manager.GetAddressOf()))) ||
      FAILED(manager->GetSessionEnumerator(&sessions))) {
    Print("sessions: not available");
    return;
  }
  int count = 0;
  sessions->GetCount(&count);
  int mine = 0;
  for (int k = 0; k < count; k++) {
    ComPtr<IAudioSessionControl> control;
    ComPtr<IAudioSessionControl2> control2;
    if (FAILED(sessions->GetSession(k, &control)) || FAILED(control.As(&control2))) continue;
    DWORD pid = 0;
    control2->GetProcessId(&pid);
    if (pid != GetCurrentProcessId()) continue;
    mine++;
    LPWSTR name = nullptr;
    control2->GetDisplayName(&name);
    AudioSessionState state = AudioSessionStateInactive;
    control2->GetState(&state);
    GUID group = {};
    control2->GetGroupingParam(&group);
    Print("session: \"%s\" state=%s", name != nullptr ? Narrow(name).c_str() : "",
          state == AudioSessionStateActive ? "active" : (state == AudioSessionStateInactive ? "inactive" : "expired"));
    if (name != nullptr) CoTaskMemFree(name);
  }
  Print("sessions: %d of this process (%d on the device)", mine, count);
}

// CPU since the previous call: the whole process and the DLL's audio
// thread, from cycle counts (thread times tick in whole quanta).
void PrintCpu() {
  static int64_t last_wall = 0;
  static ULONG64 last_process = 0;
  static ULONG64 last_audio = 0;
  static ULONG64 last_sender = 0;
  static double hz = [] {
    DWORD mhz = 0;
    DWORD size = sizeof(mhz);
    RegGetValueW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", L"~MHz", RRF_RT_REG_DWORD,
                 nullptr, &mhz, &size);
    return mhz > 0 ? mhz * 1e6 : 3e9;
  }();
  ULONG64 process = 0;
  QueryProcessCycleTime(GetCurrentProcess(), &process);
  ULONG64 audio = 0;
  ULONG64 sender = 0;
  int threads = 0;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  THREADENTRY32 entry = {sizeof(entry)};
  for (BOOL more = Thread32First(snapshot, &entry); more; more = Thread32Next(snapshot, &entry)) {
    if (entry.th32OwnerProcessID != GetCurrentProcessId()) continue;
    HANDLE thread = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ThreadID);
    if (thread == nullptr) continue;
    PWSTR description = nullptr;
    if (SUCCEEDED(GetThreadDescription(thread, &description)) && description != nullptr) {
      ULONG64 cycles = 0;
      if (std::wcscmp(description, L"wsn-audio") == 0 && QueryThreadCycleTime(thread, &cycles)) {
        audio += cycles;
        threads++;
      } else if (std::wcscmp(description, L"fake-sender") == 0 && QueryThreadCycleTime(thread, &cycles)) {
        sender += cycles;
      }
      LocalFree(description);
    }
    CloseHandle(thread);
  }
  CloseHandle(snapshot);
  const int64_t wall = QpcMicros();
  if (last_wall != 0) {
    const double span = (wall - last_wall) / 1e6;
    Print("cpu: process %.2f%%, audio thread %.3f%% (%d), sender thread (pushes + tone) %.3f%% over %.1f s at %.0f MHz",
          (process - last_process) / hz / span * 100, (audio - last_audio) / hz / span * 100, threads,
          (sender - last_sender) / hz / span * 100, span, hz / 1e6);
  }
  last_wall = wall;
  last_process = process;
  last_audio = audio;
  last_sender = sender;
}

// Prints the stack of every other thread (dbghelp, symbols from the PDBs
// next to the binaries): for finding where something hangs.
void DumpStacks() {
  HANDLE process = GetCurrentProcess();
  static bool symbols = false;
  if (!symbols) {
    SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES);
    symbols = SymInitialize(process, nullptr, TRUE) != FALSE;
  }
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  THREADENTRY32 entry = {sizeof(entry)};
  const DWORD self = GetCurrentThreadId();
  for (BOOL ok = Thread32First(snapshot, &entry); ok; ok = Thread32Next(snapshot, &entry)) {
    if (entry.th32OwnerProcessID != GetCurrentProcessId() || entry.th32ThreadID == self) continue;
    HANDLE thread = OpenThread(THREAD_ALL_ACCESS, FALSE, entry.th32ThreadID);
    if (thread == nullptr) continue;
    SuspendThread(thread);
    CONTEXT context = {};
    context.ContextFlags = CONTEXT_FULL;
    if (GetThreadContext(thread, &context)) {
      std::string text;
      STACKFRAME64 frame = {};
      frame.AddrPC.Offset = context.Rip;
      frame.AddrPC.Mode = AddrModeFlat;
      frame.AddrFrame.Offset = context.Rbp;
      frame.AddrFrame.Mode = AddrModeFlat;
      frame.AddrStack.Offset = context.Rsp;
      frame.AddrStack.Mode = AddrModeFlat;
      for (int depth = 0; depth < 40; depth++) {
        if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, process, thread, &frame, &context, nullptr,
                         SymFunctionTableAccess64, SymGetModuleBase64, nullptr) ||
            frame.AddrPC.Offset == 0) {
          break;
        }
        char buffer[sizeof(SYMBOL_INFO) + 256] = {};
        auto* symbol = reinterpret_cast<SYMBOL_INFO*>(buffer);
        symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
        symbol->MaxNameLen = 255;
        DWORD64 displacement = 0;
        char line[400];
        if (SymFromAddr(process, frame.AddrPC.Offset, &displacement, symbol)) {
          IMAGEHLP_LINE64 source = {sizeof(source)};
          DWORD column = 0;
          if (SymGetLineFromAddr64(process, frame.AddrPC.Offset, &column, &source)) {
            const char* name = std::strrchr(source.FileName, '\\');
            std::snprintf(line, sizeof(line), "\n    %s (%s:%lu)", symbol->Name, name ? name + 1 : source.FileName,
                          source.LineNumber);
          } else {
            std::snprintf(line, sizeof(line), "\n    %s+0x%llx", symbol->Name,
                          static_cast<unsigned long long>(displacement));
          }
        } else {
          std::snprintf(line, sizeof(line), "\n    0x%llx", static_cast<unsigned long long>(frame.AddrPC.Offset));
        }
        text += line;
      }
      Print("thread %lu:%s", entry.th32ThreadID, text.c_str());
    }
    ResumeThread(thread);
    CloseHandle(thread);
  }
  CloseHandle(snapshot);
}

HWND FindSurfaceWindow() { return FindWindowW(L"WhisperWindowStreamSurface", g_title.c_str()); }

HRESULT DwmGetWindowAttribute_(HWND hwnd, RECT* rect) {
  using Fn = HRESULT(WINAPI*)(HWND, DWORD, PVOID, DWORD);
  static Fn fn = reinterpret_cast<Fn>(GetProcAddress(LoadLibraryW(L"dwmapi.dll"), "DwmGetWindowAttribute"));
  if (fn == nullptr) return E_NOTIMPL;
  return fn(hwnd, 9 /* DWMWA_EXTENDED_FRAME_BOUNDS */, rect, sizeof(RECT));
}

bool SavePng(const std::wstring& path, HBITMAP bitmap, int width, int height) {
  IWICImagingFactory* factory = nullptr;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
    return false;
  }
  IWICBitmap* wic = nullptr;
  IWICStream* stream = nullptr;
  IWICBitmapEncoder* encoder = nullptr;
  IWICBitmapFrameEncode* frame = nullptr;
  bool ok = SUCCEEDED(factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha, &wic)) &&
            SUCCEEDED(factory->CreateStream(&stream)) &&
            SUCCEEDED(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE)) &&
            SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) &&
            SUCCEEDED(encoder->Initialize(stream, WICBitmapEncoderNoCache)) &&
            SUCCEEDED(encoder->CreateNewFrame(&frame, nullptr)) && SUCCEEDED(frame->Initialize(nullptr)) &&
            SUCCEEDED(frame->SetSize(width, height)) && SUCCEEDED(frame->WriteSource(wic, nullptr)) &&
            SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit());
  if (frame) frame->Release();
  if (encoder) encoder->Release();
  if (stream) stream->Release();
  if (wic) wic->Release();
  factory->Release();
  return ok;
}

// What is on screen where the window is (DWM composition, so D3D content
// and overlapping windows included). `taskbar`: the taskbar instead.
void ScreenShot(const std::wstring& path, bool taskbar = false) {
  HWND hwnd = taskbar ? FindWindowW(L"Shell_TrayWnd", nullptr) : FindSurfaceWindow();
  if (hwnd == nullptr) {
    Print("shot: no window");
    return;
  }
  RECT rect;
  GetWindowRect(hwnd, &rect);
  // Drop the invisible resize borders.
  RECT frame;
  if (!taskbar && SUCCEEDED(DwmGetWindowAttribute_(hwnd, &frame))) rect = frame;
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  HDC screen = GetDC(nullptr);
  HDC memory = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
  HGDIOBJ old = SelectObject(memory, bitmap);
  BitBlt(memory, 0, 0, width, height, screen, rect.left, rect.top, SRCCOPY | CAPTUREBLT);
  SelectObject(memory, old);
  bool ok = SavePng(path, bitmap, width, height);
  DeleteObject(bitmap);
  DeleteDC(memory);
  ReleaseDC(nullptr, screen);
  Print("shot %s %dx%d at %ld,%ld: %s", Narrow(path).c_str(), width, height, rect.left, rect.top, ok ? "ok" : "FAILED");
}

void MoveCursorTo(HWND hwnd, double fx, double fy) {
  RECT client;
  GetClientRect(hwnd, &client);
  POINT point = {static_cast<LONG>(client.right * fx), static_cast<LONG>(client.bottom * fy)};
  ClientToScreen(hwnd, &point);
  SetCursorPos(point.x, point.y);
}

void SendKey(WORD vk, bool down, bool extended = false) {
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vk;
  input.ki.wScan = static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
  input.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP) | (extended ? KEYEVENTF_EXTENDEDKEY : 0);
  SendInput(1, &input, sizeof(INPUT));
}

void Tap(WORD vk, bool extended = false) {
  SendKey(vk, true, extended);
  Sleep(15);
  SendKey(vk, false, extended);
  Sleep(25);
}

void Chord(WORD modifier, WORD vk) {
  SendKey(modifier, true);
  Sleep(15);
  Tap(vk);
  SendKey(modifier, false);
  Sleep(25);
}

void TypeUnicode(const std::wstring& text) {
  for (wchar_t character : text) {
    INPUT inputs[2] = {};
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wScan = character;
    inputs[0].ki.dwFlags = KEYEVENTF_UNICODE;
    inputs[1] = inputs[0];
    inputs[1].ki.dwFlags |= KEYEVENTF_KEYUP;
    SendInput(2, inputs, sizeof(INPUT));
    Sleep(20);
  }
}

void MouseButton(DWORD down_flag, DWORD up_flag) {
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = down_flag;
  SendInput(1, &input, sizeof(INPUT));
  Sleep(40);
  input.mi.dwFlags = up_flag;
  SendInput(1, &input, sizeof(INPUT));
  Sleep(40);
}

void Foreground(HWND hwnd) {
  // A click on the title bar brings the window forward the way a user does
  // (SetForegroundWindow from another process may be refused).
  RECT rect;
  GetWindowRect(hwnd, &rect);
  SetCursorPos((rect.left + rect.right) / 2, rect.top + 12);
  MouseButton(MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
  Sleep(150);
}

void RunAction(const std::string& action, const std::wstring& out_dir) {
  Print("action %s", action.c_str());
  auto value = [&](const char* prefix) -> std::string {
    size_t length = std::strlen(prefix);
    return action.compare(0, length, prefix) == 0 ? action.substr(length) : std::string("\x01");
  };
  std::string v;
  HWND hwnd = FindSurfaceWindow();
  // Synthetic input goes wherever the system sends it: only while this
  // window is in front (and under the cursor for mouse input), never into
  // someone else's app.
  const bool keyboard = action == "keys" || action == "pinyin" || action == "space" || action == "esc" ||
                        action.compare(0, 5, "text=") == 0;
  const bool mouse = action == "hover" || action == "click" || action == "rclick" || action == "drag" ||
                     action == "wheel" || action.compare(0, 11, "dragresize=") == 0;
  if ((keyboard || mouse) && (hwnd == nullptr || GetForegroundWindow() != hwnd)) {
    Print("skipped %s: the surface window is not in front", action.c_str());
    return;
  }
  if (mouse) {
    RECT client;
    GetClientRect(hwnd, &client);
    POINT center = {client.right / 2, client.bottom / 2};
    ClientToScreen(hwnd, &center);
    if (GetAncestor(WindowFromPoint(center), GA_ROOT) != hwnd) {
      Print("skipped %s: the surface window is covered", action.c_str());
      return;
    }
  }
  if (action == "live") {
    g_api.surface_set_visual(g_surface, 0, "");
  } else if ((v = value("connecting=")) != "\x01") {
    g_api.surface_set_visual(g_surface, 1, v.c_str());
  } else if ((v = value("paused=")) != "\x01") {
    g_api.surface_set_visual(g_surface, 2, v.c_str());
  } else if ((v = value("reconnecting=")) != "\x01") {
    g_api.surface_set_visual(g_surface, 3, v.c_str());
  } else if ((v = value("error=")) != "\x01") {
    g_api.surface_set_visual(g_surface, 7, v.c_str());
  } else if ((v = value("title=")) != "\x01") {
    g_api.surface_set_title(g_surface, v.c_str());
    g_title = Wide(v);
  } else if ((v = value("icon=")) != "\x01") {
    std::ifstream file(Wide(v), std::ios::binary);
    std::vector<uint8_t> png((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    if (!png.empty()) g_api.surface_set_icon(g_surface, png.data(), static_cast<int32_t>(png.size()));
  } else if ((v = value("snapshot=")) != "\x01") {
    int max_edge = 0;
    size_t at = v.find('@');
    if (at != std::string::npos) {
      max_edge = std::atoi(v.c_str() + at + 1);
      v = v.substr(0, at);
    }
    std::string path = Narrow(out_dir) + "\\" + v + ".jpg";
    double started = Ms();
    int32_t result = g_api.surface_snapshot(g_surface, path.c_str(), max_edge);
    Print("snapshot %s max_edge=%d -> %d (%.1f ms)", path.c_str(), max_edge, result, Ms() - started);
  } else if ((v = value("taskbar=")) != "\x01") {
    ScreenShot(out_dir + L"\\" + Wide(v) + L".png", true);
  } else if ((v = value("shot=")) != "\x01") {
    ScreenShot(out_dir + L"\\" + Wide(v) + L".png");
  } else if ((v = value("resize=")) != "\x01" && hwnd != nullptr) {
    int width = 0;
    int height = 0;
    std::sscanf(v.c_str(), "%dx%d", &width, &height);
    RECT frame = {0, 0, width, height};
    AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, GetDpiForWindow(hwnd));
    SetWindowPos(hwnd, nullptr, 0, 0, frame.right - frame.left, frame.bottom - frame.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  } else if ((v = value("move=")) != "\x01" && hwnd != nullptr) {
    int x = 0;
    int y = 0;
    std::sscanf(v.c_str(), "%d,%d", &x, &y);
    SetWindowPos(hwnd, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  } else if (action == "focus") {
    g_api.surface_focus(g_surface);
  } else if (action == "foreground" && hwnd != nullptr) {
    Foreground(hwnd);
  } else if (action == "hover" && hwnd != nullptr) {
    // A sweep across the picture at ~500 Hz: the DLL should send ≤120/s.
    int before = g_input_events;
    double started = Ms();
    // Absolute SendInput moves, as a 500 Hz mouse would deliver them.
    RECT client;
    GetClientRect(hwnd, &client);
    POINT origin = {0, 0};
    ClientToScreen(hwnd, &origin);
    const int screen_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int screen_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int screen_w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int screen_h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    for (int step = 0; step <= 300; step++) {
      double px = origin.x + client.right * (0.2 + 0.6 * step / 300.0);
      double py = origin.y + client.bottom * 0.5;
      INPUT input = {};
      input.type = INPUT_MOUSE;
      input.mi.dx = static_cast<LONG>((px - screen_x) * 65535.0 / (screen_w - 1));
      input.mi.dy = static_cast<LONG>((py - screen_y) * 65535.0 / (screen_h - 1));
      input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
      SendInput(1, &input, sizeof(INPUT));
      Sleep(2);
    }
    double seconds = (Ms() - started) / 1000.0;
    Sleep(50);
    Print("hover: %d events in %.2f s (%.0f/s)", g_input_events - before, seconds,
          (g_input_events - before) / seconds);
  } else if (action == "click" && hwnd != nullptr) {
    MoveCursorTo(hwnd, 0.5, 0.25);
    Sleep(30);
    MouseButton(MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
  } else if (action == "rclick" && hwnd != nullptr) {
    MoveCursorTo(hwnd, 0.75, 0.75);
    Sleep(30);
    MouseButton(MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
  } else if (action == "drag" && hwnd != nullptr) {
    MoveCursorTo(hwnd, 0.3, 0.3);
    Sleep(30);
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    SendInput(1, &input, sizeof(INPUT));
    for (int step = 0; step <= 20; step++) {
      MoveCursorTo(hwnd, 0.3 + 0.4 * step / 20.0, 0.3 + 0.4 * step / 20.0);
      Sleep(10);
    }
    input.mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(1, &input, sizeof(INPUT));
  } else if ((v = value("dragresize=")) != "\x01" && hwnd != nullptr) {
    // The user dragging the bottom-right corner by (dx, dy) over ~1 s,
    // with a shot halfway.
    int dx = 0;
    int dy = 0;
    std::sscanf(v.c_str(), "%d,%d", &dx, &dy);
    RECT frame;
    GetWindowRect(hwnd, &frame);
    RECT visible = frame;
    DwmGetWindowAttribute_(hwnd, &visible);
    // In the resize border just outside the visible frame.
    POINT start = {visible.right + 3, visible.bottom + 3};
    SetCursorPos(start.x, start.y);
    Sleep(60);
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    SendInput(1, &input, sizeof(INPUT));
    Sleep(60);
    for (int step = 1; step <= 60; step++) {
      SetCursorPos(start.x + dx * step / 60, start.y + dy * step / 60);
      Sleep(16);
      if (step == 30) ScreenShot(out_dir + L"\\live_resize.png");
    }
    Sleep(300);  // rest: a RESIZED should come while still held
    input.mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(1, &input, sizeof(INPUT));
    Sleep(100);
    RECT client;
    GetClientRect(hwnd, &client);
    Print("dragresize: client now %ldx%ld (aspect %.4f)", client.right, client.bottom,
          client.bottom > 0 ? static_cast<double>(client.right) / client.bottom : 0.0);
  } else if (action == "wheel" && hwnd != nullptr) {
    MoveCursorTo(hwnd, 0.5, 0.5);
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_WHEEL;
    input.mi.mouseData = static_cast<DWORD>(-WHEEL_DELTA);
    SendInput(1, &input, sizeof(INPUT));
    Sleep(40);
    input.mi.mouseData = 30;  // a touchpad-sized step
    SendInput(1, &input, sizeof(INPUT));
    Sleep(40);
    input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
    input.mi.mouseData = WHEEL_DELTA;
    SendInput(1, &input, sizeof(INPUT));
  } else if (action == "keys") {
    // Letters, Shift, digits, punctuation, F-keys, arrows, Return,
    // Backspace, shortcuts (Ctrl → Command), Alt+key, Escape.
    Tap('H');
    Tap('I');
    SendKey(VK_SHIFT, true);
    Tap('A');
    Tap('1');
    SendKey(VK_SHIFT, false);
    Tap('7');
    Tap(VK_OEM_PERIOD);
    Tap(VK_OEM_2);
    Tap(VK_OEM_MINUS);
    Tap(VK_SPACE);
    Tap(VK_F5);
    Tap(VK_LEFT, true);
    Tap(VK_UP, true);
    Tap(VK_RETURN);
    Tap(VK_BACK);
    Tap(VK_DELETE, true);
    Tap(VK_HOME, true);
    Tap(VK_NUMPAD5);
    Chord(VK_CONTROL, 'A');
    Chord(VK_CONTROL, 'C');
    Chord(VK_MENU, 'F');
    Tap(VK_ESCAPE);
  } else if ((v = value("text=")) != "\x01") {
    TypeUnicode(Wide(v));
  } else if (action == "pinyin") {
    // With a Chinese input method on, this composes 你好 (committed by "space").
    for (WORD vk : {'N', 'I', 'H', 'A', 'O'}) Tap(vk);
  } else if (action == "space") {
    Tap(VK_SPACE);
  } else if (action == "esc") {
    Tap(VK_ESCAPE);
  } else if ((v = value("dpi=")) != "\x01" && hwnd != nullptr) {
    // What Windows sends when the window moves to a monitor with another
    // scale: the new DPI and a suggested window rect.
    UINT dpi = static_cast<UINT>(std::atoi(v.c_str()));
    UINT old_dpi = GetDpiForWindow(hwnd);
    RECT rect;
    GetWindowRect(hwnd, &rect);
    RECT client;
    GetClientRect(hwnd, &client);
    RECT frame = {0, 0, static_cast<LONG>(client.right * dpi / old_dpi), static_cast<LONG>(client.bottom * dpi / old_dpi)};
    AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
    RECT suggested = {rect.left, rect.top, rect.left + frame.right - frame.left, rect.top + frame.bottom - frame.top};
    SendMessageW(hwnd, WM_DPICHANGED, MAKEWPARAM(dpi, dpi), reinterpret_cast<LPARAM>(&suggested));
  } else if (action == "ime" && hwnd != nullptr) {
    // Without switching the user's input method: report which layouts
    // exist (the real IME test needs one active).
    HKL layouts[16];
    int count = GetKeyboardLayoutList(16, layouts);
    for (int k = 0; k < count; k++) {
      Print("layout %p%s", static_cast<void*>(layouts[k]), ImmIsIME(layouts[k]) ? " (IME)" : "");
    }
  } else if ((v = value("loopback=")) != "\x01") {
    size_t at = v.find('@');
    double seconds = at == std::string::npos ? 3.0 : std::atof(v.c_str() + at + 1);
    RecordLoopback(out_dir + L"\\" + Wide(v.substr(0, at)) + L".wav", seconds);
  } else if (action == "postclick" && hwnd != nullptr) {
    // A click delivered to this window only (no SendInput), for when
    // another window keeps the foreground.
    RECT client;
    GetClientRect(hwnd, &client);
    const LPARAM at = MAKELPARAM(client.right / 2, client.bottom / 2);
    PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, at);
    Sleep(40);
    PostMessageW(hwnd, WM_LBUTTONUP, 0, at);
  } else if (action == "minimize" && hwnd != nullptr) {
    ShowWindow(hwnd, SW_MINIMIZE);
  } else if (action == "corrupt") {
    // A "keyframe" of garbage: the decoder should fail or recover, not hang.
    std::vector<uint8_t> junk(4096);
    junk[0] = 0; junk[1] = 0; junk[2] = 0; junk[3] = 1; junk[4] = 0x65;
    for (size_t k = 5; k < junk.size(); k++) junk[k] = static_cast<uint8_t>(std::rand());
    PushTo(g_surface, junk, 0, 2);
  } else if (action == "hold") {
    g_hold = true;
  } else if (action == "release") {
    g_restarts++;
    g_hold = false;
  } else if (action == "reopen") {
    // Close the window and open the same one again (same title), the
    // source silent for a moment, as a viewer reopening a window.
    g_hold = true;
    g_api.surface_destroy(g_surface);
    Sleep(300);
    const double created = Ms();
    g_surface = g_api.surface_create(Narrow(g_title).c_str(), g_open_width, g_open_height, 1);
    g_api.surface_set_visual(g_surface, 1, "正在连接…");
    if (!g_icon_arg.empty()) RunAction("icon=" + g_icon_arg, out_dir);
    Print("reopened as surface %lld in %.1f ms", static_cast<long long>(g_surface), Ms() - created);
  } else if ((v = value("burst=")) != "\x01" && !g_in_burst_thread) {
    // On its own thread: the main loop keeps acting like Dart meanwhile.
    std::wstring dir = out_dir;
    std::string spec = action;
    g_bursts.emplace_back([dir, spec] {
      g_in_burst_thread = true;
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      RunAction(spec, dir);
      CoUninitialize();
    });
  } else if ((v = value("burst=")) != "\x01") {
    // `count` captures of the window `interval` ms apart, kept in memory
    // and written afterwards so the timing stays exact.
    int count = 10;
    int interval = 50;
    std::string name = v;
    size_t at = v.find('@');
    if (at != std::string::npos) {
      name = v.substr(0, at);
      std::sscanf(v.c_str() + at + 1, "%d@%d", &count, &interval);
    }
    struct Shot {
      double ms;
      HBITMAP bitmap;
      int width;
      int height;
    };
    std::vector<Shot> shots;
    const double started = Ms();
    for (int k = 0; k < count; k++) {
      const double due = started + k * interval;
      while (Ms() < due) Sleep(1);
      HWND window = FindSurfaceWindow();
      if (window == nullptr) continue;
      RECT rect;
      if (FAILED(DwmGetWindowAttribute_(window, &rect))) GetWindowRect(window, &rect);
      const int width = rect.right - rect.left;
      const int height = rect.bottom - rect.top;
      HDC screen = GetDC(nullptr);
      HDC memory = CreateCompatibleDC(screen);
      HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
      HGDIOBJ old = SelectObject(memory, bitmap);
      BitBlt(memory, 0, 0, width, height, screen, rect.left, rect.top, SRCCOPY | CAPTUREBLT);
      SelectObject(memory, old);
      DeleteDC(memory);
      ReleaseDC(nullptr, screen);
      shots.push_back({Ms(), bitmap, width, height});
    }
    for (size_t k = 0; k < shots.size(); k++) {
      wchar_t file[64];
      swprintf(file, 64, L"\\%ls_%02zu_%05.0f.png", Wide(name).c_str(), k, shots[k].ms);
      SavePng(out_dir + file, shots[k].bitmap, shots[k].width, shots[k].height);
      DeleteObject(shots[k].bitmap);
    }
    Print("burst %s: %zu shots from %.1f to %.1f ms", name.c_str(), shots.size(),
          shots.empty() ? 0.0 : shots.front().ms, shots.empty() ? 0.0 : shots.back().ms);
  } else if ((v = value("audio=")) != "\x01") {
    AudioOn(v == "on");
  } else if (action == "audioconfigure") {
    g_api.audio_configure(g_surface, 1, 48000, 2);
    Print("audio configured again");
  } else if ((v = value("audiojitter=")) != "\x01") {
    g_audio_jitter_ms = std::atoi(v.c_str());
  } else if ((v = value("audiostall=")) != "\x01") {
    g_audio_stall_ms = std::atoi(v.c_str());
  } else if ((v = value("audiosilence=")) != "\x01") {
    g_audio_silence_ms = std::atoi(v.c_str());
  } else if ((v = value("audiolose=")) != "\x01") {
    g_audio_lose_ms = std::atoi(v.c_str());
  } else if ((v = value("audioskew=")) != "\x01") {
    g_audio_skew_ppm = std::atoi(v.c_str());
  } else if (action == "audiorestartpts") {
    g_audio_restart_pts = true;
  } else if ((v = value("record=")) != "\x01") {
    size_t at = v.find('@');
    double seconds = at == std::string::npos ? 5.0 : std::atof(v.c_str() + at + 1);
    std::wstring path = out_dir + L"\\" + Wide(v.substr(0, at)) + L".wav";
    g_bursts.emplace_back([path, seconds] {
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      RecordProcess(path, seconds);
      CoUninitialize();
    });
  } else if (action == "sessions") {
    PrintSessions();
  } else if (action == "cpu") {
    PrintCpu();
  } else if (action == "destroy") {
    const int64_t surface = g_surface;
    g_surface = 0;
    const double started = Ms();
    g_api.surface_destroy(surface);
    Print("destroy returned in %.2f ms", Ms() - started);
  } else if (action == "stacks") {
    DumpStacks();
  } else if (action == "close" && hwnd != nullptr) {
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
  } else {
    Print("unknown or unusable action: %s", action.c_str());
  }
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  timeBeginPeriod(1);
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  SetConsoleOutputCP(CP_UTF8);
  g_start = std::chrono::steady_clock::now();
  GetCursorPos(&g_cursor_home);
  std::wstring dll_path;
  std::wstring stream_path;
  std::wstring out_dir = L".";
  std::wstring icon_path;
  double fps = 60;
  double seconds = 10;
  bool loop = false;
  bool hud = false;
  bool audio = false;
  bool no_video = false;
  int surfaces = 1;
  double watch_seconds = 0;
  bool title_given = false;
  std::string watch_burst = "watch@60@40";
  int& open_width = g_open_width;
  int& open_height = g_open_height;
  std::vector<std::pair<double, std::string>> script;
  for (int i = 1; i < argc; i++) {
    std::wstring arg = argv[i];
    auto next = [&]() -> std::wstring { return i + 1 < argc ? argv[++i] : L""; };
    if (arg == L"--dll") dll_path = next();
    else if (arg == L"--stream") stream_path = next();
    else if (arg == L"--out") out_dir = next();
    else if (arg == L"--fps") fps = _wtof(next().c_str());
    else if (arg == L"--seconds") seconds = _wtof(next().c_str());
    else if (arg == L"--loop") loop = true;
    else if (arg == L"--hud") hud = true;
    else if (arg == L"--audio") audio = true;
    else if (arg == L"--no-video") no_video = true;
    else if (arg == L"--surfaces") surfaces = std::max(1, _wtoi(next().c_str()));
    else if (arg == L"--delay-push") g_delay_push = _wtof(next().c_str());
    else if (arg == L"--watch") watch_seconds = _wtof(next().c_str());
    else if (arg == L"--burst") watch_burst = "watch@" + Narrow(next());
    else if (arg == L"--size") swscanf(next().c_str(), L"%dx%d", &open_width, &open_height);
    else if (arg == L"--title") {
      g_title = next();
      title_given = true;
    }
    else if (arg == L"--icon") icon_path = next();
    else if (arg == L"--script") {
      // UTF-8 lines "<seconds>:<action>" (keeps non-ASCII text out of cmd).
      std::ifstream lines(next());
      std::string line;
      while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.size() >= 3 && static_cast<unsigned char>(line[0]) == 0xEF) line = line.substr(3);  // BOM
        size_t colon = line.find(':');
        if (line.empty() || line[0] == '#' || colon == std::string::npos) continue;
        script.push_back({std::atof(line.c_str()), line.substr(colon + 1)});
      }
    } else if (arg == L"--at") {
      std::string spec = Narrow(next());
      size_t colon = spec.find(':');
      if (colon != std::string::npos) script.push_back({std::atof(spec.c_str()), spec.substr(colon + 1)});
    }
  }
  CreateDirectoryW(out_dir.c_str(), nullptr);
  g_log = _wfopen((out_dir + L"\\wsn_play.log").c_str(), L"w");
  if (watch_seconds > 0) {
    // Watch mode: no DLL; wait for a streamed window of the real app to
    // appear and record it (`--burst count@interval`).
    const double deadline = Ms() + watch_seconds * 1000;
    HWND found = nullptr;
    // With --title, only a window whose title starts with it.
    const std::wstring wanted = title_given ? g_title : std::wstring();
    auto find = [&wanted]() -> HWND {
      HWND window = nullptr;
      while ((window = FindWindowExW(nullptr, window, L"WhisperWindowStreamSurface", nullptr)) != nullptr) {
        wchar_t text[256] = {};
        GetWindowTextW(window, text, 256);
        if (wanted.empty() || std::wstring(text).rfind(wanted, 0) == 0) return window;
      }
      return nullptr;
    };
    while (Ms() < deadline && (found = find()) == nullptr) Sleep(2);
    if (found == nullptr) {
      Print("watch: no streamed window appeared");
      return 5;
    }
    wchar_t title[256] = {};
    GetWindowTextW(found, title, 256);
    g_title = title;
    Print("watch: window \"%s\" appeared", Narrow(g_title).c_str());
    RunAction("burst=" + watch_burst, out_dir);
    for (std::thread& burst : g_bursts) burst.join();
    if (g_log != nullptr) std::fclose(g_log);
    return 0;
  }
  HMODULE module = LoadLibraryW(dll_path.c_str());
  if (module == nullptr) {
    Print("LoadLibrary failed: %lu", GetLastError());
    return 2;
  }
  bool ok = Resolve(module, "wsn_api_version", &g_api.api_version) && Resolve(module, "wsn_reset_all", &g_api.reset_all) &&
            Resolve(module, "wsn_set_input_callback", &g_api.set_input_callback) &&
            Resolve(module, "wsn_set_window_callback", &g_api.set_window_callback) &&
            Resolve(module, "wsn_free", &g_api.free_) && Resolve(module, "wsn_surface_create", &g_api.surface_create) &&
            Resolve(module, "wsn_surface_set_title", &g_api.surface_set_title) &&
            Resolve(module, "wsn_surface_set_visual", &g_api.surface_set_visual) &&
            Resolve(module, "wsn_surface_set_hud", &g_api.surface_set_hud) &&
            Resolve(module, "wsn_surface_set_icon", &g_api.surface_set_icon) &&
            Resolve(module, "wsn_surface_focus", &g_api.surface_focus) &&
            Resolve(module, "wsn_surface_destroy", &g_api.surface_destroy) &&
            Resolve(module, "wsn_surface_stats", &g_api.surface_stats) &&
            Resolve(module, "wsn_surface_snapshot", &g_api.surface_snapshot) &&
            Resolve(module, "wsn_buffer_alloc", &g_api.buffer_alloc) &&
            Resolve(module, "wsn_video_push", &g_api.video_push) &&
            Resolve(module, "wsn_audio_configure", &g_api.audio_configure) &&
            Resolve(module, "wsn_audio_push", &g_api.audio_push);
  if (!ok) return 3;
  Print("api version %d", g_api.api_version());
  std::ifstream file(stream_path, std::ios::binary);
  std::vector<uint8_t> stream((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
  std::vector<AccessUnit> units = SplitAccessUnits(stream);
  int keys = 0;
  for (const AccessUnit& unit : units) keys += unit.key ? 1 : 0;
  Print("stream %s: %zu bytes, %zu access units, %d keyframes", Narrow(stream_path).c_str(), stream.size(), units.size(),
        keys);
  if (units.empty()) return 4;
  g_api.set_input_callback(OnInput);
  g_api.set_window_callback(OnWindow);
  const double created_at = Ms();
  g_surface = g_api.surface_create(Narrow(g_title).c_str(), open_width, open_height, hud ? 1 : 0);
  Print("surface %lld created in %.1f ms", static_cast<long long>(g_surface), Ms() - created_at);
  for (int k = 1; k < surfaces; k++) {
    std::string title = Narrow(g_title) + " #" + std::to_string(k + 1);
    g_extra_surfaces.push_back(g_api.surface_create(title.c_str(), 0, 0, hud ? 1 : 0));
    g_api.surface_set_visual(g_extra_surfaces.back(), 0, "");
  }
  g_api.surface_set_visual(g_surface, 1, "正在连接…");
  g_icon_arg = Narrow(icon_path);
  if (!icon_path.empty()) RunAction("icon=" + Narrow(icon_path), out_dir);

  std::atomic<bool> stop{false};
  if (audio) AudioOn(true);

  // Video pump on its own thread, like the stream isolate.
  std::thread pump([&] {
    const auto begin = std::chrono::steady_clock::now();
    size_t index = 0;
    int64_t frame = 0;
    bool first = true;
    int served_requests = 0;
    int served_restarts = 0;
    std::this_thread::sleep_until(begin + std::chrono::milliseconds(static_cast<int64_t>(g_delay_push * 1000)));
    while (!stop && !no_video) {
      if (g_hold) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        frame = static_cast<int64_t>(
            std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count() * fps);
        continue;
      }
      if (g_restarts > served_restarts) {
        served_restarts = g_restarts;
        g_keyframe_requests++;
      }
      if (g_keyframe_requests > served_requests) {
        // As a source would: the next picture is a keyframe.
        served_requests = g_keyframe_requests;
        size_t key = index;
        while (!units[key].key) key = (key + 1) % units.size();
        Print("keyframe requested: jumping from unit %zu to %zu", index, key);
        index = key;
      }
      const AccessUnit& unit = units[index];
      auto due = begin + std::chrono::microseconds(static_cast<int64_t>(frame * 1e6 / fps));
      std::this_thread::sleep_until(due);
      const int64_t pts = static_cast<int64_t>(frame * 1e6 / fps);
      if (unit.key && !unit.config.empty()) Push(unit.config, pts, 1);
      Push(unit.data, pts, unit.key ? 2 : 0);
      if (first) {
        first = false;
        g_first_push_ms = Ms();
      }
      frame++;
      index++;
      if (index >= units.size()) {
        if (!loop) break;
        index = 0;
      }
    }
  });

  size_t next_action = 0;
  std::sort(script.begin(), script.end(), [](auto& a, auto& b) { return a.first < b.first; });
  const double run_start = Ms();
  double next_stats = run_start + 1000;
  while (Ms() - run_start < seconds * 1000) {
    if (g_first_frame_seen.exchange(false)) g_api.surface_set_visual(g_surface, 0, "");
    while (next_action < script.size() && Ms() - run_start >= script[next_action].first * 1000) {
      RunAction(script[next_action].second, out_dir);
      next_action++;
    }
    if (Ms() >= next_stats) {
      next_stats += 1000;
      double values[12] = {};
      int32_t count = g_api.surface_stats(g_surface, values, 12);
      static double last_presented = -1;
      static int stalls = 0;
      static bool dumped = false;
      if (g_first_frame_ms >= 0 && values[4] == last_presented && !g_hold) {
        if (++stalls >= 2 && !dumped) {
          dumped = true;
          Print("no new frames for 2 s: thread stacks follow");
          DumpStacks();
        }
      } else {
        stalls = 0;
      }
      last_presented = values[4];
      for (int64_t extra : g_extra_surfaces) {
        double more[12] = {};
        g_api.surface_stats(extra, more, 12);
        Print("stats s=%lld fps=%.1f dropped=%.0f decode=%.2fms presented=%.0f path=%.0f", static_cast<long long>(extra),
              more[0], more[1], more[2], more[4], more[10]);
      }
      Print("stats n=%d fps=%.1f dropped=%.0f decode=%.2fms queued=%.0f presented=%.0f audio[restarts=%.0f "
            "resyncs=%.0f lead=%.0fms target=%.0fms] present_latency=%.2fms path=%.0f skipped=%.0f",
            count, values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8],
            values[9], values[10], values[11]);
      if (hud) {
        char text[256];
        std::snprintf(text, sizeof(text), "%.0f fps  decode %.1f ms  present %.1f ms\nqueued %.0f  dropped %.0f  path %.0f",
                      values[0], values[2], values[9], values[3], values[1], values[10]);
        g_api.surface_set_hud(g_surface, text);
      }
    }
    Sleep(5);
  }
  for (std::thread& burst : g_bursts) burst.join();
  stop = true;
  SetCursorPos(g_cursor_home.x, g_cursor_home.y);
  pump.join();
  AudioOn(false);
  Print("first push at %.1f ms, first frame at %.1f ms (%.1f ms after the first push)", g_first_push_ms.load(),
        g_first_frame_ms.load(), g_first_frame_ms.load() - g_first_push_ms.load());
  const double destroy_at = Ms();
  if (g_surface != 0) g_api.surface_destroy(g_surface);
  for (int64_t extra : g_extra_surfaces) g_api.surface_destroy(extra);
  Print("destroyed in %.1f ms", Ms() - destroy_at);
  Sleep(200);
  g_api.reset_all();
  Print("done");
  if (g_log != nullptr) std::fclose(g_log);
  return 0;
}
