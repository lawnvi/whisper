// The GLib main loop (the GTK thread) as a work queue.
//
// Every GTK call in this library runs on the default GLib main context.
// The C ABI may be called from any thread (and from inside Dart), so entry
// points only queue work here; callbacks into Dart therefore never run
// inside an FFI call made by Dart.

#ifndef WSN_COMMON_MAIN_THREAD_H_
#define WSN_COMMON_MAIN_THREAD_H_

#include <glib.h>

#include <functional>

namespace wsn {

// Runs `task` on the main loop soon (default priority, ahead of idle work
// and redraws, so input-related work is not starved by a busy stream).
void OnMain(std::function<void()> task);

// Runs `task` on the main loop after `delay_ms`. Returns the GLib source id;
// cancel it with g_source_remove on the main thread.
guint OnMainAfter(guint delay_ms, std::function<void()> task);

// True on the thread that owns the default main context.
bool OnMainThread();

}  // namespace wsn

#endif  // WSN_COMMON_MAIN_THREAD_H_
