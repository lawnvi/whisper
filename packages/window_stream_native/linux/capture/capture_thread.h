// The capture side's own thread: a GLib main loop on a private context.
//
// Everything the capture side decides (sessions, virtual monitors, the GNOME
// Shell helper, D-Bus traffic) happens here, one task at a time, so none of
// it needs locks and none of it waits on the GTK thread. The C ABI only
// posts work to it.

#ifndef WSN_CAPTURE_CAPTURE_THREAD_H_
#define WSN_CAPTURE_CAPTURE_THREAD_H_

#include <gio/gio.h>

#include <functional>

namespace wsn::capture {

// Runs `task` on the capture thread (started on first use), in order.
void Post(std::function<void()> task);

// Runs `task` on the capture thread after `delay_ms`. Returns a timer id for
// CancelTimer (capture thread only); 0 never names a timer.
guint PostAfter(guint delay_ms, std::function<void()> task);

// Capture thread only. Cancelling an id that already ran is harmless.
void CancelTimer(guint id);

// Runs `task` on the capture thread and waits for it (up to `timeout_ms`).
// Returns false on timeout; never call from the capture thread itself.
bool PostAndWait(std::function<void()> task, int timeout_ms);

bool OnCaptureThread();

// The capture thread's main context (thread-default there).
GMainContext* Context();

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_CAPTURE_THREAD_H_
