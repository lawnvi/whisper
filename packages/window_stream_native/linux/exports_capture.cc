// C ABI, capture half: this desktop as a window source
// (window_stream_native.h), on GNOME or KDE Plasma on Wayland.
//
// Every entry point only queues work on the capture thread
// (capture/capture_thread.h), so callbacks never run inside an FFI call.
// Windows are listed, moved and driven through Whisper's GNOME Shell
// extension (capture/shell_helper.h) or a KWin script and KWin's own
// protocols (capture/kwin_helper.h); pictures come from Mutter's ScreenCast
// API or KWin's screencast protocol over PipeWire and are encoded with the
// system FFmpeg.
//
// Failure codes Dart sees (WSN_CAPTURE_FAILED flags):
//   7 DESKTOP    not GNOME or KDE Plasma on Wayland, or no screencast /
//                PipeWire (wsn_capture_supported() is 0 then); on KDE also
//                when KWin withholds its protocols from this executable
//   6 HELPER     the desktop's helper is not ready: on GNOME the Shell
//                extension is not installed, needs a new login, is outdated,
//                or does not trust this executable (a WSN_CAPTURE_NOTE
//                "helper: <state>" says which); on KDE the KWin script
//                does not answer
//   10 LOCKED    the session is locked
//   4 NOT_FOUND  the window (or app) is gone
//   5 ENCODER    no usable H.264 encoder in the system FFmpeg

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "capture/audio_tap.h"
#include "capture/capture_thread.h"
#include "capture/catalog.h"
#include "capture/encoder.h"
#include "capture/helper.h"
#include "capture/kwin_helper.h"
#include "capture/kwin_wayland.h"
#include "capture/pipewire_stream.h"
#include "capture/screencast.h"
#include "capture/session.h"
#include "common/callbacks.h"
#include "common/lifecycle.h"
#include "common/log.h"
#include "window_stream_native.h"

namespace {

using wsn::capture::Post;
using wsn::capture::Session;
using wsn::capture::WindowHelper;

// Once per process, on the capture thread: route the helper's signals.
void Init() {
  static bool done = false;
  if (done) return;
  done = true;
  WindowHelper::Handlers handlers;
  handlers.window_gone = [](uint32_t window) {
    Session::ForEach([window](Session* s) {
      if (s->window() == window) s->OnWindowGone();
    });
  };
  handlers.text_focus = [](uint32_t window, bool focused) {
    Session::ForEach([window, focused](Session* s) {
      if (s->window() == window) s->OnTextFocus(focused);
    });
  };
  handlers.vanished = [] { Session::ForEach([](Session* s) { s->OnHelperVanished(); }); };
  WindowHelper::Get().SetHandlers(std::move(handlers));
  // Sound routes an earlier run left moved (it died while streaming) go back.
  wsn::capture::RecoverAudioRoutes();
  // KWin takes a moment to see a new .desktop file: written now, it is
  // there by the first stream.
  if (wsn::capture::CurrentDesktop() == wsn::capture::Desktop::kKde && wsn_capture_supported() == 1) {
    std::string why;
    if (!wsn::capture::EnsureKWinPermission(&why)) WSN_LOG("capture: %s", why.c_str());
  }
}

template <typename Fn>
void WithSession(int64_t capture, Fn&& fn) {
  Post([capture, fn = std::forward<Fn>(fn)]() mutable {
    if (Session* session = Session::Find(capture)) fn(session);
  });
}

}  // namespace

namespace wsn {

void ResetCaptures() {
  SetCaptureCallback(nullptr);
  // Windows go home and monitors away before Dart starts over.
  capture::PostAndWait(
      [] {
        std::vector<int64_t> ids;
        Session::ForEach([&ids](Session* s) { ids.push_back(s->id()); });
        for (int64_t id : ids) Session::Remove(id);
      },
      3000);
}

}  // namespace wsn

void wsn_set_capture_callback(wsn_capture_callback callback) {
  wsn::SetCaptureCallback(callback);
  if (callback != nullptr) Post([] { Init(); });
}

int32_t wsn_capture_supported(void) {
  static int32_t supported = [] {
    using wsn::capture::Desktop;
    Desktop desktop = wsn::capture::CurrentDesktop();
    bool pipewire = wsn::capture::PipeWireStream::Available();
    bool ok = false;
    if (desktop == Desktop::kGnome) {
      ok = pipewire && wsn::capture::ScreenCastAvailable();
      WSN_LOG("capture: GNOME Wayland source %s", ok ? "available" : "unavailable");
    } else if (desktop == Desktop::kKde) {
      // Whether KWin lets this executable in shows at the first use.
      ok = pipewire && wsn::capture::kwin::Compiled();
      WSN_LOG("capture: KDE Plasma Wayland source %s", ok ? "available" : "unavailable");
    } else {
      WSN_LOG("capture: no window source here (neither GNOME nor KDE Plasma on Wayland)");
    }
    return ok ? 1 : 0;
  }();
  return supported;
}

int32_t wsn_capture_input_permission(void) {
  if (wsn_capture_supported() == 0) return 0;
  static std::atomic<int> state{-1};
  // The answer may be a few seconds old; the check itself runs on the
  // capture thread (it asks the bus), waited for at most a moment (else the
  // last answer stands).
  wsn::capture::PostAndWait(
      [] {
        Init();
        state = static_cast<int>(WindowHelper::Get().Check());
      },
      600);
  return state.load() == static_cast<int>(wsn::capture::HelperState::kReady) ? 1 : 0;
}

int64_t wsn_capture_request_catalog(void) {
  int64_t id = wsn::NewRequestId();
  Post([id] {
    Init();
    if (wsn_capture_supported() == 0) {
      wsn::EmitCapture(id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_DESKTOP);
      return;
    }
    wsn::capture::RequestCatalog(id);
  });
  return id;
}

int64_t wsn_capture_request_icon(const char* app_id, int32_t size) {
  int64_t id = wsn::NewRequestId();
  wsn::capture::RequestIcon(id, app_id != nullptr ? app_id : "", size);
  return id;
}

int64_t wsn_capture_request_thumbnail(uint32_t window_id, int32_t max_edge) {
  int64_t id = wsn::NewRequestId();
  Post([id, window_id, max_edge] {
    Init();
    wsn::capture::RequestThumbnail(id, window_id, max_edge);
  });
  return id;
}

int64_t wsn_capture_launch_app(const char* app_id) {
  int64_t id = wsn::NewRequestId();
  wsn::capture::LaunchApp(id, app_id != nullptr ? app_id : "");
  return id;
}

int64_t wsn_capture_start(uint32_t window_id, int32_t pid, int32_t max_edge, int32_t fps, int32_t bit_rate) {
  int64_t id = wsn::NewRequestId();
  Post([id, window_id, pid, max_edge, fps, bit_rate] {
    Init();
    if (wsn_capture_supported() == 0) {
      wsn::EmitCapture(id, WSN_CAPTURE_FAILED, nullptr, 0, 0, WSN_CAPTURE_ERROR_DESKTOP);
      return;
    }
    auto session = std::make_unique<Session>(id, window_id, pid, max_edge, fps, bit_rate);
    Session* raw = session.get();
    Session::Add(std::move(session));
    raw->Start();
  });
  return id;
}

void wsn_capture_stop(int64_t capture) {
  Post([capture] { Session::Remove(capture); });
}

void wsn_capture_close_window(uint32_t window_id, int32_t) {
  Post([window_id] { wsn::capture::CloseWindow(window_id); });
}

void wsn_capture_set_screen(int64_t capture, int64_t key) {
  WithSession(capture, [key](Session* s) { s->SetScreen(key); });
}

void wsn_capture_set_viewport(int64_t capture, double width, double height, double scale) {
  WithSession(capture, [width, height, scale](Session* s) { s->SetViewport(width, height, scale); });
}

void wsn_capture_set_inset(int64_t capture, double bottom) {
  WithSession(capture, [bottom](Session* s) { s->SetInset(bottom); });
}

void wsn_capture_request_keyframe(int64_t capture) {
  WithSession(capture, [](Session* s) { s->RequestKeyframe(); });
}

void wsn_capture_set_busy(int64_t capture, int32_t busy) {
  WithSession(capture, [busy](Session* s) { s->SetBusy(busy != 0); });
}

void wsn_capture_set_paused(int64_t capture, int32_t paused) {
  WithSession(capture, [paused](Session* s) { s->SetPaused(paused != 0); });
}

void wsn_capture_set_bit_rate(int64_t capture, int32_t bit_rate) {
  WithSession(capture, [bit_rate](Session* s) { s->SetBitRate(bit_rate); });
}

void wsn_capture_set_audio(int64_t capture, int32_t mode) {
  WithSession(capture, [mode](Session* s) { s->SetAudio(mode); });
}

void wsn_capture_set_pixel_ratio(int64_t capture, double ratio) {
  // The host keeps its own density here for now.
}

void wsn_capture_input(int64_t capture, int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx,
                       double dy, int32_t phase, const char* text) {
  std::string value = text != nullptr ? text : "";
  WithSession(capture, [=](Session* s) { s->Input(kind, code, modifiers, x, y, dx, dy, phase, value); });
}
