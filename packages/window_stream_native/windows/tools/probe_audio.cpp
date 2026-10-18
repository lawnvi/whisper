// Standalone check of WASAPI process loopback, to isolate it from the DLL.
//   wsn_probe audiocheck --pid <pid>   (or --match <window title>)
#include "probe.h"
#include "core/wsn_window.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <wrl/client.h>
#include <wrl/implements.h>
#include <combaseapi.h>

namespace probe {
namespace {
using Microsoft::WRL::ComPtr;
// Hand-rolled completion handler (no WRL), to rule out WRL as the cause.
class Handler : public IActivateAudioInterfaceCompletionHandler {
 public:
  HANDLE done = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  LONG ref = 1;
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
  STDMETHOD_(ULONG, AddRef)() override { return InterlockedIncrement(&ref); }
  STDMETHOD_(ULONG, Release)() override {
    LONG r = InterlockedDecrement(&ref);
    if (r == 0) delete this;
    return r;
  }
  STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation*) override { SetEvent(done); return S_OK; }
};
}  // namespace

int RunAudioCheck(const Args& args) {
  DWORD pid = static_cast<DWORD>(args.Int(L"--pid", 0));
  if (pid == 0) {
    std::wstring match = args.Get(L"--match");
    for (HWND w : TopLevelWindows()) {
      if (IsWindowVisible(w) && wsn::WindowTitle(w).find(match) != std::wstring::npos) { pid = wsn::WindowPid(w); break; }
    }
  }
  Log("target pid %lu", pid);
  CO_MTA_USAGE_COOKIE mta = nullptr;
  Log("CoIncrementMTAUsage 0x%08lx", CoIncrementMTAUsage(&mta));

  AUDIOCLIENT_ACTIVATION_PARAMS p{};
  p.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  p.ProcessLoopbackParams.TargetProcessId = pid;
  p.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT pv{};
  pv.vt = VT_BLOB;
  pv.blob.cbSize = sizeof(p);
  pv.blob.pBlobData = reinterpret_cast<BYTE*>(&p);
  Log("device path len %zu", wcslen(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK));
  ComPtr<Handler> handler;
  handler.Attach(new Handler());
  ComPtr<IActivateAudioInterfaceAsyncOperation> op;
  HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &pv,
                                           handler.Get(), &op);
  Log("ActivateAudioInterfaceAsync hr 0x%08lx", hr);
  if (SUCCEEDED(hr)) {
    WaitForSingleObject(handler->done, 3000);
    HRESULT ar = E_FAIL;
    ComPtr<IUnknown> unk;
    HRESULT gr = op->GetActivateResult(&ar, &unk);
    Log("GetActivateResult 0x%08lx activate 0x%08lx", gr, ar);
    if (SUCCEEDED(ar) && unk) {
      ComPtr<IAudioClient> client;
      unk.As(&client);
      WAVEFORMATEX wf{WAVE_FORMAT_PCM, 2, 48000, 48000 * 4, 4, 16, 0};
      HRESULT ih = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 20 * 10000, 0,
                                      &wf, nullptr);
      Log("Initialize 0x%08lx", ih);
      if (SUCCEEDED(ih)) {
        HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        client->SetEventHandle(ev);
        ComPtr<IAudioCaptureClient> cap;
        client->GetService(IID_PPV_ARGS(&cap));
        client->Start();
        int chunks = 0;
        long long frames = 0;
        double sum = 0;
        for (int i = 0; i < 40; ++i) {
          if (WaitForSingleObject(ev, 200) != WAIT_OBJECT_0) continue;
          UINT32 ps = 0;
          while (SUCCEEDED(cap->GetNextPacketSize(&ps)) && ps > 0) {
            BYTE* d = nullptr; UINT32 fr = 0; DWORD fl = 0; UINT64 dp = 0, q = 0;
            if (FAILED(cap->GetBuffer(&d, &fr, &fl, &dp, &q))) break;
            chunks++; frames += fr;
            if (!(fl & AUDCLNT_BUFFERFLAGS_SILENT) && d) {
              const int16_t* s = reinterpret_cast<const int16_t*>(d);
              long long a = 0; int n = fr * 2;
              for (int k = 0; k < n; ++k) a += std::abs((int)s[k]);
              if (n) sum += (double)a / n;
            }
            cap->ReleaseBuffer(fr);
          }
        }
        client->Stop();
        Log("captured %d chunks, %lld frames (%.1f s), mean |sample| %.0f", chunks, frames, frames / 48000.0,
            chunks ? sum / chunks : 0);
      }
    }
  }
  if (mta) CoDecrementMTAUsage(mta);
  return 0;
}
}  // namespace probe
