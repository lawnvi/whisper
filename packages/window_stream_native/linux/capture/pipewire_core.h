// The process-wide PipeWire connection (libpipewire opened at run time):
// one pw_thread_loop and one core, shared by the screencast streams and the
// audio taps. Build-time headers only (WSN_HAVE_PIPEWIRE_HEADERS).

#ifndef WSN_CAPTURE_PIPEWIRE_CORE_H_
#define WSN_CAPTURE_PIPEWIRE_CORE_H_

#ifdef WSN_HAVE_PIPEWIRE_HEADERS

#include <pipewire/pipewire.h>

#include <atomic>
#include <cstdint>

namespace wsn::capture::pwcore {

// libpipewire-0.3 entry points (resolved with dlsym; the headers' inline
// helpers such as pw_core_create_object or pw_registry_bind need nothing
// more). Names differ from the real ones so nothing links by accident.
struct Api {
  void (*init)(int*, char***) = nullptr;
  pw_thread_loop* (*thread_loop_new)(const char*, const spa_dict*) = nullptr;
  int (*thread_loop_start)(pw_thread_loop*) = nullptr;
  void (*thread_loop_lock)(pw_thread_loop*) = nullptr;
  void (*thread_loop_unlock)(pw_thread_loop*) = nullptr;
  pw_loop* (*thread_loop_get_loop)(pw_thread_loop*) = nullptr;
  pw_context* (*context_new)(pw_loop*, pw_properties*, size_t) = nullptr;
  pw_core* (*context_connect)(pw_context*, pw_properties*, size_t) = nullptr;
  int (*core_disconnect)(pw_core*) = nullptr;
  pw_properties* (*properties_new)(const char*, ...) = nullptr;
  void (*proxy_destroy)(pw_proxy*) = nullptr;
  pw_stream* (*stream_new)(pw_core*, const char*, pw_properties*) = nullptr;
  void (*stream_destroy)(pw_stream*) = nullptr;
  void (*stream_add_listener)(pw_stream*, spa_hook*, const pw_stream_events*, void*) = nullptr;
  int (*stream_connect)(pw_stream*, spa_direction, uint32_t, pw_stream_flags, const spa_pod**, uint32_t) = nullptr;
  int (*stream_disconnect)(pw_stream*) = nullptr;
  pw_buffer* (*stream_dequeue_buffer)(pw_stream*) = nullptr;
  int (*stream_queue_buffer)(pw_stream*, pw_buffer*) = nullptr;
  int (*stream_update_params)(pw_stream*, const spa_pod**, uint32_t) = nullptr;
  bool ok = false;
};

const Api& Pw();

// The core with the loop locked (reconnecting first when the daemon went
// away), or null (unlocked) when PipeWire is not reachable.
pw_core* LockCore();
void Lock();
void Unlock();

// Bumped at every new connection: objects made on an older one are gone.
uint64_t Generation();
bool CoreDead();

}  // namespace wsn::capture::pwcore

#endif  // WSN_HAVE_PIPEWIRE_HEADERS

#endif  // WSN_CAPTURE_PIPEWIRE_CORE_H_
