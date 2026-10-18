// C ABI (src/window_stream_native.h): capture exports — this PC as a window
// source. Thin shims over capture/*. Every result reaches Dart through the
// capture callback (PostCallback / EmitCapture), never inside an export.
// The per-capture exports only queue work for the capture's own thread and
// return at once (Dart calls them on its UI isolate).

#include "capture/capture_catalog.h"
#include "capture/capture_session.h"
#include "capture/wsn_journal.h"
#include "capture/wsn_wgc.h"
#include "capture/wsn_window.h"
#include "common/wsn_common.h"

#include <atomic>
#include <string>
#include <thread>

using namespace wsn;

namespace wsn {

void ResetAllCaptures() { ResetAllCapturesImpl(); }

}  // namespace wsn

namespace {

std::atomic<bool> g_support_checked{false};
std::atomic<int> g_supported{0};
std::atomic<bool> g_recovered{false};

int32_t Supported() {
  if (!g_support_checked.exchange(true)) {
    // WGC availability is cached; the first query spins up a short MTA thread.
    g_supported = QueryWgcSupport().supported && D3D::Shared() != nullptr ? 1 : 0;
  }
  return g_supported;
}

}  // namespace

WSN_EXPORT void wsn_set_capture_callback(wsn_capture_callback callback) {
  SetCaptureCallback(callback);
  if (callback != nullptr) WarmInstalledApps();
  if (callback != nullptr && !g_recovered.exchange(true)) {
    // The host is up: put back any window an earlier run left staged.
    std::thread([] {
      Journal journal;
      for (const auto& line : RecoverStaged(&journal)) Log("recover: %s", line.c_str());
    }).detach();
  }
}

WSN_EXPORT int32_t wsn_capture_supported(void) { return Supported(); }

WSN_EXPORT int32_t wsn_capture_input_permission(void) {
  // Windows needs no permission to inject into windows at our integrity level
  // or below; always available (per-target filtering is in the catalog).
  return 1;
}

WSN_EXPORT int64_t wsn_capture_request_catalog(void) {
  int64_t id = NextRequestId();
  std::thread([id] { RequestCatalog(id); }).detach();
  return id;
}

WSN_EXPORT int64_t wsn_capture_request_icon(const char* app_id, int32_t size) {
  int64_t id = NextRequestId();
  RequestIcon(id, app_id ? app_id : "", size);
  return id;
}

WSN_EXPORT int64_t wsn_capture_request_thumbnail(uint32_t window_id, int32_t max_edge) {
  int64_t id = NextRequestId();
  RequestThumbnail(id, window_id, max_edge);
  return id;
}

WSN_EXPORT int64_t wsn_capture_launch_app(const char* app_id) {
  int64_t id = NextRequestId();
  LaunchApp(id, app_id ? app_id : "");
  return id;
}

WSN_EXPORT int64_t wsn_capture_start(uint32_t window_id, int32_t pid, int32_t max_edge, int32_t fps,
                                     int32_t bit_rate) {
  int64_t id = NextRequestId();
  if (!Supported()) {
    PostCallback([id] { EmitCapture(id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_UNSUPPORTED); });
    return id;
  }
  auto session = std::make_shared<CaptureSession>(id, window_id, pid, max_edge, fps, bit_rate);
  RegisterCapture(session);
  session->Start();
  return id;
}

WSN_EXPORT void wsn_capture_stop(int64_t capture) {
  // Returns at once: the session's thread puts the window back first, then
  // shuts the capture down. Later events for this id are ignored by Dart.
  auto session = FindCapture(capture);
  RemoveCapture(capture);
  if (session) session->Stop();
}

WSN_EXPORT void wsn_capture_close_window(uint32_t window_id, int32_t pid) { CloseWindow(window_id, pid); }

WSN_EXPORT void wsn_capture_set_viewport(int64_t capture, double width, double height, double scale) {
  if (auto session = FindCapture(capture)) session->SetViewport(width, height, scale);
}

WSN_EXPORT void wsn_capture_set_inset(int64_t capture, double bottom) {
  if (auto session = FindCapture(capture)) session->SetBottomInset(bottom);
}

WSN_EXPORT void wsn_capture_set_screen(int64_t capture, int64_t key) {
  if (auto session = FindCapture(capture)) session->SetScreen(key);
}

WSN_EXPORT void wsn_capture_request_keyframe(int64_t capture) {
  if (auto session = FindCapture(capture)) session->RequestKeyframe();
}

WSN_EXPORT void wsn_capture_set_busy(int64_t capture, int32_t busy) {
  if (auto session = FindCapture(capture)) session->SetBusy(busy != 0);
}

WSN_EXPORT void wsn_capture_set_paused(int64_t capture, int32_t paused) {
  if (auto session = FindCapture(capture)) session->SetPaused(paused != 0);
}

WSN_EXPORT void wsn_capture_set_bit_rate(int64_t capture, int32_t bit_rate) {
  if (auto session = FindCapture(capture)) session->SetBitRate(bit_rate);
}

WSN_EXPORT void wsn_capture_set_audio(int64_t capture, int32_t mode) {
  if (auto session = FindCapture(capture)) session->SetAudio(mode);
}

WSN_EXPORT void wsn_capture_set_pixel_ratio(int64_t capture, double ratio) {
  // The host keeps its own density here for now.
}

WSN_EXPORT void wsn_capture_input(int64_t capture, int32_t kind, int32_t code, int32_t modifiers, double x,
                                  double y, double dx, double dy, int32_t phase, const char* text) {
  if (auto session = FindCapture(capture)) {
    session->Input(kind, code, modifiers, x, y, dx, dy, phase, text ? std::string(text) : std::string());
  }
}

// The app ends with exit(0) on Windows (ExitProcess) right after closing its
// streams, so a capture thread may not have put its window back yet. Here
// every other thread is already gone; put back whatever is still staged
// (without waiting on any app). The journal covers anything missed on the
// next start.
BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID reserved) {
  if (reason == DLL_PROCESS_DETACH && reserved != nullptr) RestoreStagedAtExit();
  return TRUE;
}
