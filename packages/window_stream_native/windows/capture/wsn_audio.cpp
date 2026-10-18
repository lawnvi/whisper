#include "wsn_audio.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <tlhelp32.h>
#include <objbase.h>
#include <wrl/client.h>
#include <combaseapi.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace wsn {

using Microsoft::WRL::ComPtr;

namespace {

constexpr int kRate = 48000;
constexpr int kChannels = 2;

bool BuildAtLeast(DWORD build) {
  // RtlGetVersion: the real build even when the exe is not manifested.
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) return false;
  auto fn = reinterpret_cast<RtlGetVersionFn>(GetProcAddress(ntdll, "RtlGetVersion"));
  if (fn == nullptr) return false;
  RTL_OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  if (fn(&info) != 0) return false;
  return info.dwMajorVersion > 10 || (info.dwMajorVersion == 10 && info.dwBuildNumber >= build);
}

// ActivateAudioInterfaceAsync completion: signals an event. Hand-rolled (not
// WRL): the API marshals the handler to an MTA worker and queries it for
// IAgileObject, which a WRL RuntimeClass without a module does not expose,
// making the activation fail with E_ILLEGAL_METHOD_CALL.
class ActivateHandler : public IActivateAudioInterfaceCompletionHandler, public IAgileObject {
 public:
  HANDLE done = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  ~ActivateHandler() {
    if (done != nullptr) CloseHandle(done);
  }
  STDMETHOD(QueryInterface)(REFIID riid, void** ppv) override {
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IActivateAudioInterfaceCompletionHandler) ||
        riid == __uuidof(IAgileObject)) {
      *ppv = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHOD_(ULONG, AddRef)() override { return InterlockedIncrement(&ref_); }
  STDMETHOD_(ULONG, Release)() override {
    LONG r = InterlockedDecrement(&ref_);
    if (r == 0) delete this;
    return r;
  }
  STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation*) override {
    if (done != nullptr) SetEvent(done);
    return S_OK;
  }

 private:
  LONG ref_ = 1;
};

// The pid plus all its descendants (a snapshot; sessions opened later are
// matched on the next mute).
std::vector<DWORD> ProcessTree(DWORD root) {
  std::vector<DWORD> result{root};
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return result;
  std::vector<std::pair<DWORD, DWORD>> edges;  // (pid, parent)
  PROCESSENTRY32W e{};
  e.dwSize = sizeof(e);
  if (Process32FirstW(snap, &e)) {
    do {
      edges.push_back({e.th32ProcessID, e.th32ParentProcessID});
    } while (Process32NextW(snap, &e));
  }
  CloseHandle(snap);
  for (size_t i = 0; i < result.size(); ++i) {
    for (const auto& [pid, parent] : edges) {
      if (parent == result[i] && pid != 0 &&
          std::find(result.begin(), result.end(), pid) == result.end()) {
        result.push_back(pid);
      }
    }
  }
  return result;
}

WAVEFORMATEX StereoS16() {
  WAVEFORMATEX wf{};
  wf.wFormatTag = WAVE_FORMAT_PCM;
  wf.nChannels = kChannels;
  wf.nSamplesPerSec = kRate;
  wf.wBitsPerSample = 16;
  wf.nBlockAlign = wf.nChannels * wf.wBitsPerSample / 8;
  wf.nAvgBytesPerSec = wf.nSamplesPerSec * wf.nBlockAlign;
  return wf;
}

}  // namespace

bool AudioCapture::Supported() { return BuildAtLeast(19041); }

AudioCapture::AudioCapture(DWORD pid, std::function<void(const int16_t*, int, int64_t)> on_pcm,
                           std::function<void(const std::string&)> on_note)
    : pid_(pid), on_pcm_(std::move(on_pcm)), on_note_(std::move(on_note)) {}

AudioCapture::~AudioCapture() { Stop(); }

bool AudioCapture::Start(int mode) {
  if (running_.exchange(true)) {
    SetMode(mode);
    return true;
  }
  if (!Supported()) {
    running_ = false;
    if (on_note_) on_note_("audio: process loopback needs Windows 10 build 19041+");
    return false;
  }
  mode_ = mode;
  ready_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  thread_ = std::thread([this] { Run(); });
  // Wait briefly for the capture to come up (or fail), so the caller's note
  // order is sensible.
  if (ready_event_ != nullptr) WaitForSingleObject(ready_event_, 1500);
  return running_.load();
}

void AudioCapture::Stop() {
  if (!running_.exchange(false)) return;
  if (thread_.joinable() && std::this_thread::get_id() != thread_.get_id()) thread_.join();
  ApplyLocalMute(false);
  if (ready_event_ != nullptr) {
    CloseHandle(ready_event_);
    ready_event_ = nullptr;
  }
}

void AudioCapture::SetMode(int mode) {
  int old = mode_.exchange(mode);
  if (old == mode) return;
  if (mode != 2) {
    ApplyLocalMute(false);   // back to audible here
  } else {
    mute_checked_ = false;   // the Run-loop probe mutes and re-checks
  }
}

void AudioCapture::Run() {
  // ActivateAudioInterfaceAsync needs a stable MTA; CoInitializeEx alone can
  // return E_ILLEGAL_METHOD_CALL if the MTA is not otherwise held.
  CO_MTA_USAGE_COOKIE mta = nullptr;
  HRESULT com = CoIncrementMTAUsage(&mta);  // implicit MTA; no CoInitializeEx (it makes this API fail)
  bool opened = false;
  do {
    AUDIOCLIENT_ACTIVATION_PARAMS params{};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = pid_;
    params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT activate{};
    activate.vt = VT_BLOB;
    activate.blob.cbSize = sizeof(params);
    activate.blob.pBlobData = reinterpret_cast<BYTE*>(&params);

    ComPtr<ActivateHandler> handler;
    handler.Attach(new ActivateHandler());
    ComPtr<IActivateAudioInterfaceAsyncOperation> op;
    HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
                                             &activate, handler.Get(), &op);
    if (FAILED(hr)) {
      if (on_note_) on_note_("audio: ActivateAudioInterfaceAsync " + HrText(hr));
      break;
    }
    WaitForSingleObject(handler->done, 3000);
    HRESULT activate_hr = E_FAIL;
    ComPtr<IUnknown> unknown;
    if (op == nullptr || FAILED(op->GetActivateResult(&activate_hr, &unknown)) || FAILED(activate_hr) || !unknown) {
      if (on_note_) on_note_("audio: process loopback activation failed " + HrText(activate_hr));
      break;
    }
    ComPtr<IAudioClient> client;
    if (FAILED(unknown.As(&client))) break;

    WAVEFORMATEX wf = StereoS16();
    REFERENCE_TIME buffer = 20 * 10000;  // 20 ms
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                            AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, buffer, 0, &wf, nullptr);
    if (FAILED(hr)) {
      if (on_note_) on_note_("audio: Initialize " + HrText(hr));
      break;
    }
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (FAILED(client->SetEventHandle(event))) {
      CloseHandle(event);
      break;
    }
    ComPtr<IAudioCaptureClient> capture;
    if (FAILED(client->GetService(IID_PPV_ARGS(&capture))) || FAILED(client->Start())) {
      CloseHandle(event);
      break;
    }
    opened = true;
    if (on_note_) on_note_(Format("audio: capturing process tree pid %lu at 48000 Hz stereo", pid_));
    if (ready_event_ != nullptr) SetEvent(ready_event_);

    std::vector<int16_t> silence;  // zero-fill for gaps we must not reorder around
    // Mode-2 probe: muting is applied once sound is confirmed, then the
    // level after muting decides whether the loopback survived it.
    double loud_before_mute_at = 0;   // last time real sound was seen before muting
    double mute_started_at = 0;
    while (running_.load()) {
      DWORD woke = WaitForSingleObject(event, 200);
      if (!running_.load()) break;
      if (woke != WAIT_OBJECT_0) continue;
      UINT32 packet = 0;
      while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0 && running_.load()) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        UINT64 device_pos = 0, qpc = 0;
        if (FAILED(capture->GetBuffer(&data, &frames, &flags, &device_pos, &qpc))) break;
        int64_t pts_us = static_cast<int64_t>(qpc) / 10;  // QPC 100 ns -> us, video's base
        const int16_t* pcm = reinterpret_cast<const int16_t*>(data);
        bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr;
        double level = 0;
        if (!silent) {
          int64_t sum = 0;
          size_t n = static_cast<size_t>(frames) * kChannels;
          for (size_t i = 0; i < n; ++i) sum += std::abs(static_cast<int>(pcm[i]));
          level = n > 0 ? static_cast<double>(sum) / n : 0;
          if (level > 60) loud_before_mute_at = NowMs();  // ~ -55 dBFS
        }
        if (frames > 0 && on_pcm_) {
          if (silent) {
            silence.assign(static_cast<size_t>(frames) * kChannels, 0);
            on_pcm_(silence.data(), static_cast<int>(frames), pts_us);
          } else {
            on_pcm_(pcm, static_cast<int>(frames), pts_us);
          }
        }
        capture->ReleaseBuffer(frames);
      }
      // Mode-2 probe: start muting once real sound has been seen; then, if
      // after muting the loopback stays silent for ~700 ms although sound was
      // flowing just before, muting killed the capture — revert and keep it
      // local.
      if (mode_.load() == 2 && !mute_checked_.load() && !mute_kills_capture_.load()) {
        double now = NowMs();
        if (!muted_.load()) {
          if (loud_before_mute_at > 0) {
            ApplyLocalMute(true);
            mute_started_at = now;
          }
        } else if (mute_started_at > 0 && now - mute_started_at > 700) {
          bool still_loud = loud_before_mute_at > mute_started_at + 100;
          mute_checked_ = true;
          if (!still_loud) {
            mute_kills_capture_ = true;
            ApplyLocalMute(false);
            if (on_note_) {
              on_note_("audio: muting the app silenced the capture too; leaving sound local (mode 2 == mode 1 here)");
            }
          } else if (on_note_) {
            on_note_("audio: capture survives local muting; playing only on the viewer");
          }
        }
      }
    }
    client->Stop();
    CloseHandle(event);
  } while (false);

  ApplyLocalMute(false);
  if (!opened && ready_event_ != nullptr) SetEvent(ready_event_);
  running_ = false;
  if (mta != nullptr) CoDecrementMTAUsage(mta);
  (void)com;
}

// Mode 2: mute every render session of the app's process tree. The pre-mix
// process loopback is unaffected on Windows (the session mute is applied to
// the engine mix, not the per-process tap) (the mode-2 probe in Run checks this).
void AudioCapture::ApplyLocalMute(bool mute) {
  if (muted_.load() == mute) return;
  if (mute && mute_kills_capture_.load()) {
    if (on_note_) on_note_("audio: not muting locally (it would stop the capture); sound stays audible here");
    return;
  }
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) return;
  ComPtr<IMMDeviceCollection> devices;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices))) return;
  UINT count = 0;
  devices->GetCount(&count);
  // The app's whole process tree: a session's process is matched against it,
  // so a child that actually plays (a browser's audio service, a console's
  // shell) is muted too, the same tree the loopback captures.
  std::vector<DWORD> tree = ProcessTree(pid_);
  int muted = 0;
  for (UINT i = 0; i < count; ++i) {
    ComPtr<IMMDevice> device;
    if (FAILED(devices->Item(i, &device))) continue;
    ComPtr<IAudioSessionManager2> manager;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, &manager))) continue;
    ComPtr<IAudioSessionEnumerator> sessions;
    if (FAILED(manager->GetSessionEnumerator(&sessions))) continue;
    int n = 0;
    sessions->GetCount(&n);
    for (int s = 0; s < n; ++s) {
      ComPtr<IAudioSessionControl> control;
      if (FAILED(sessions->GetSession(s, &control))) continue;
      ComPtr<IAudioSessionControl2> control2;
      if (FAILED(control.As(&control2))) continue;
      DWORD session_pid = 0;
      if (FAILED(control2->GetProcessId(&session_pid)) || session_pid == 0) continue;
      bool ours = false;
      for (DWORD p : tree) {
        if (p == session_pid) ours = true;
      }
      if (!ours) continue;
      ComPtr<ISimpleAudioVolume> volume;
      if (FAILED(control2.As(&volume))) continue;
      if (SUCCEEDED(volume->SetMute(mute, nullptr))) muted++;
    }
  }
  muted_ = mute;
  if (on_note_ && muted > 0) {
    on_note_(mute ? Format("audio: muted %d local session(s)", muted) : "audio: unmuted local session(s)");
  }
}

}  // namespace wsn
