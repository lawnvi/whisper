// The capture side's own connection to the session bus (capture thread).
//
// Private on purpose: Mutter ties every ScreenCast session (and so every
// virtual monitor) to the connection that created it, and the GNOME Shell
// helper puts windows back when its caller's connection goes away. Keeping
// this connection to ourselves means closing it undoes everything at once,
// and nothing else in the app (RemoteDesktop for keyboard and mouse sharing,
// say) shares its fate.

#ifndef WSN_CAPTURE_BUS_H_
#define WSN_CAPTURE_BUS_H_

#include <gio/gio.h>

#include <cstdint>
#include <functional>
#include <string>

namespace wsn::capture {

// The connection (created on first use); null when the session bus is not
// reachable. Capture thread only.
GDBusConnection* Bus();

// Our unique name on Bus() ("" when not connected).
std::string BusName();

// `result` is null on error; `error` is null on success. Both are owned by
// the caller of the callback (do not unref).
using Reply = std::function<void(GVariant* result, const GError* error)>;

// Asynchronous method call on Bus(); `reply` (may be empty) runs on the
// capture thread. Calls are sent in the order they are made.
void Call(const char* destination, const char* path, const char* interface, const char* method, GVariant* params,
          const char* reply_type, int timeout_ms, Reply reply);

// Short synchronous call (capture thread). Returns a new reference or null.
GVariant* CallSync(const char* destination, const char* path, const char* interface, const char* method,
                   GVariant* params, const char* reply_type, int timeout_ms, GError** error);

using SignalHandler = std::function<void(const char* sender, const char* member, GVariant* params)>;

// Subscribes on Bus(); the handler runs on the capture thread. 0 on failure.
guint Subscribe(const char* sender, const char* interface, const char* member, const char* path,
                SignalHandler handler, const char* arg0 = nullptr);
void Unsubscribe(guint id);

// The pid behind a bus name (unique or well-known), or 0.
uint32_t PidOf(const char* name);

// The well-known name's current owner ("" when none).
std::string OwnerOf(const char* name);

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_BUS_H_
