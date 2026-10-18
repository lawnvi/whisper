#include "capture/pipewire_core.h"

#ifdef WSN_HAVE_PIPEWIRE_HEADERS

#include <cerrno>

#include <mutex>

#include "common/dl.h"
#include "common/log.h"

namespace wsn::capture::pwcore {

namespace {

// The one thread loop and core every stream and the audio taps share;
// created on first use and kept for the process (cheap when idle).
struct Shared {
  pw_thread_loop* loop = nullptr;
  pw_context* context = nullptr;
  pw_core* core = nullptr;
  spa_hook core_listener = {};
  // The daemon went away (restarted, upgraded): the next user reconnects.
  std::atomic<bool> core_dead{false};
  uint64_t generation = 0;
};

std::mutex g_shared_mutex;
Shared g_shared;

}  // namespace

const Api& Pw() {
  static Api api = [] {
    Api a;
    void* handle = OpenFirst({"libpipewire-0.3.so.0", "libpipewire-0.3.so"});
    if (handle == nullptr) return a;
    bool ok = true;
    Sym(handle, "pw_init", &a.init, &ok);
    Sym(handle, "pw_thread_loop_new", &a.thread_loop_new, &ok);
    Sym(handle, "pw_thread_loop_start", &a.thread_loop_start, &ok);
    Sym(handle, "pw_thread_loop_lock", &a.thread_loop_lock, &ok);
    Sym(handle, "pw_thread_loop_unlock", &a.thread_loop_unlock, &ok);
    Sym(handle, "pw_thread_loop_get_loop", &a.thread_loop_get_loop, &ok);
    Sym(handle, "pw_context_new", &a.context_new, &ok);
    Sym(handle, "pw_context_connect", &a.context_connect, &ok);
    Sym(handle, "pw_core_disconnect", &a.core_disconnect, &ok);
    Sym(handle, "pw_properties_new", &a.properties_new, &ok);
    Sym(handle, "pw_proxy_destroy", &a.proxy_destroy, &ok);
    Sym(handle, "pw_stream_new", &a.stream_new, &ok);
    Sym(handle, "pw_stream_destroy", &a.stream_destroy, &ok);
    Sym(handle, "pw_stream_add_listener", &a.stream_add_listener, &ok);
    Sym(handle, "pw_stream_connect", &a.stream_connect, &ok);
    Sym(handle, "pw_stream_disconnect", &a.stream_disconnect, &ok);
    Sym(handle, "pw_stream_dequeue_buffer", &a.stream_dequeue_buffer, &ok);
    Sym(handle, "pw_stream_queue_buffer", &a.stream_queue_buffer, &ok);
    Sym(handle, "pw_stream_update_params", &a.stream_update_params, &ok);
    a.ok = ok;
    if (ok) a.init(nullptr, nullptr);
    return a;
  }();
  return api;
}

pw_core* LockCore() {
  const Api& pw = Pw();
  if (!pw.ok) return nullptr;
  std::lock_guard<std::mutex> guard(g_shared_mutex);
  if (g_shared.loop == nullptr) {
    g_shared.loop = pw.thread_loop_new("wsn-pipewire", nullptr);
    if (g_shared.loop == nullptr || pw.thread_loop_start(g_shared.loop) < 0) {
      WSN_LOG("capture: PipeWire thread loop failed");
      g_shared.loop = nullptr;
      return nullptr;
    }
  }
  pw.thread_loop_lock(g_shared.loop);
  if (g_shared.context == nullptr) {
    g_shared.context = pw.context_new(pw.thread_loop_get_loop(g_shared.loop), nullptr, 0);
  }
  if (g_shared.core != nullptr && g_shared.core_dead.load()) {
    WSN_LOG("capture: PipeWire went away; reconnecting");
    spa_hook_remove(&g_shared.core_listener);
    pw.core_disconnect(g_shared.core);
    g_shared.core = nullptr;
    g_shared.core_dead = false;
  }
  if (g_shared.context != nullptr && g_shared.core == nullptr) {
    g_shared.core = pw.context_connect(g_shared.context, nullptr, 0);
    if (g_shared.core == nullptr) {
      WSN_LOG("capture: cannot connect to PipeWire");
    } else {
      g_shared.generation++;
      static const pw_core_events events = [] {
        pw_core_events e = {};
        e.version = PW_VERSION_CORE_EVENTS;
        e.error = [](void*, uint32_t id, int, int res, const char* message) {
          if (id == PW_ID_CORE && res == -EPIPE) {
            WSN_LOG("capture: PipeWire connection lost (%s)", message != nullptr ? message : "");
            g_shared.core_dead = true;
          }
        };
        return e;
      }();
      g_shared.core_listener = {};
      // An inline call through the proxy's method table: nothing to link.
      pw_core_add_listener(g_shared.core, &g_shared.core_listener, &events, nullptr);
    }
  }
  if (g_shared.core == nullptr) {
    pw.thread_loop_unlock(g_shared.loop);
    return nullptr;
  }
  return g_shared.core;
}

void Lock() { Pw().thread_loop_lock(g_shared.loop); }
void Unlock() { Pw().thread_loop_unlock(g_shared.loop); }

uint64_t Generation() { return g_shared.generation; }

bool CoreDead() { return g_shared.core_dead.load(); }

}  // namespace wsn::capture::pwcore

#endif  // WSN_HAVE_PIPEWIRE_HEADERS
