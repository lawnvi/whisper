#include "capture/bus.h"

#include "capture/capture_thread.h"
#include "common/log.h"

namespace wsn::capture {

namespace {

GDBusConnection* g_bus = nullptr;
bool g_failed = false;

struct PendingCall {
  Reply reply;
};

void OnCallDone(GObject* source, GAsyncResult* result, gpointer data) {
  auto* pending = static_cast<PendingCall*>(data);
  GError* error = nullptr;
  GVariant* value = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (pending->reply) pending->reply(value, error);
  if (value != nullptr) g_variant_unref(value);
  if (error != nullptr) g_error_free(error);
  delete pending;
}

void OnSignal(GDBusConnection*, const gchar* sender, const gchar*, const gchar*, const gchar* member,
              GVariant* params, gpointer data) {
  (*static_cast<SignalHandler*>(data))(sender, member, params);
}

void DeleteHandler(gpointer data) { delete static_cast<SignalHandler*>(data); }

}  // namespace

GDBusConnection* Bus() {
  if (g_bus != nullptr || g_failed) return g_bus;
  GError* error = nullptr;
  gchar* address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (address != nullptr) {
    g_bus = g_dbus_connection_new_for_address_sync(
        address,
        static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                                          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, &error);
    g_free(address);
  }
  if (g_bus == nullptr) {
    WSN_LOG("capture: no session bus (%s)", error != nullptr ? error->message : "?");
    g_failed = true;
  } else {
    g_dbus_connection_set_exit_on_close(g_bus, FALSE);
  }
  if (error != nullptr) g_error_free(error);
  return g_bus;
}

std::string BusName() {
  GDBusConnection* bus = Bus();
  const char* name = bus != nullptr ? g_dbus_connection_get_unique_name(bus) : nullptr;
  return name != nullptr ? name : "";
}

void Call(const char* destination, const char* path, const char* interface, const char* method, GVariant* params,
          const char* reply_type, int timeout_ms, Reply reply) {
  GDBusConnection* bus = Bus();
  if (bus == nullptr) {
    if (params != nullptr) g_variant_unref(g_variant_ref_sink(params));
    if (reply) {
      GError* error = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_NOT_CONNECTED, "no session bus");
      reply(nullptr, error);
      g_error_free(error);
    }
    return;
  }
  g_dbus_connection_call(bus, destination, path, interface, method, params,
                         reply_type != nullptr ? G_VARIANT_TYPE(reply_type) : nullptr, G_DBUS_CALL_FLAGS_NONE,
                         timeout_ms, nullptr, OnCallDone, new PendingCall{std::move(reply)});
}

GVariant* CallSync(const char* destination, const char* path, const char* interface, const char* method,
                   GVariant* params, const char* reply_type, int timeout_ms, GError** error) {
  GDBusConnection* bus = Bus();
  if (bus == nullptr) {
    if (params != nullptr) g_variant_unref(g_variant_ref_sink(params));
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_CONNECTED, "no session bus");
    return nullptr;
  }
  return g_dbus_connection_call_sync(bus, destination, path, interface, method, params,
                                     reply_type != nullptr ? G_VARIANT_TYPE(reply_type) : nullptr,
                                     G_DBUS_CALL_FLAGS_NONE, timeout_ms, nullptr, error);
}

guint Subscribe(const char* sender, const char* interface, const char* member, const char* path,
                SignalHandler handler, const char* arg0) {
  GDBusConnection* bus = Bus();
  if (bus == nullptr) return 0;
  return g_dbus_connection_signal_subscribe(bus, sender, interface, member, path, arg0, G_DBUS_SIGNAL_FLAGS_NONE,
                                            OnSignal, new SignalHandler(std::move(handler)), DeleteHandler);
}

void Unsubscribe(guint id) {
  if (id != 0 && g_bus != nullptr) g_dbus_connection_signal_unsubscribe(g_bus, id);
}

uint32_t PidOf(const char* name) {
  GVariant* reply = CallSync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                             "GetConnectionUnixProcessID", g_variant_new("(s)", name), "(u)", 1000, nullptr);
  if (reply == nullptr) return 0;
  guint32 pid = 0;
  g_variant_get(reply, "(u)", &pid);
  g_variant_unref(reply);
  return pid;
}

std::string OwnerOf(const char* name) {
  GVariant* reply = CallSync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                             "GetNameOwner", g_variant_new("(s)", name), "(s)", 1000, nullptr);
  if (reply == nullptr) return "";
  const gchar* owner = nullptr;
  g_variant_get(reply, "(&s)", &owner);
  std::string value = owner != nullptr ? owner : "";
  g_variant_unref(reply);
  return value;
}

}  // namespace wsn::capture
