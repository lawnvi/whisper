#include "system_power_plugin.h"

#include <gio/gio.h>
#ifdef HAVE_GIO_UNIX
#include <gio/gunixfdlist.h>
#endif

#include <unistd.h>

namespace {

constexpr char kSystemPowerChannel[] = "com.vireen.whisper/system_power";
constexpr char kLogindName[] = "org.freedesktop.login1";
constexpr char kLogindPath[] = "/org/freedesktop/login1";
constexpr char kLogindManager[] = "org.freedesktop.login1.Manager";
// Sleep goes ahead after this long even if Dart has not answered. logind
// itself waits at most InhibitDelayMaxSec, 5 seconds unless configured.
constexpr guint kSleepHoldMilliseconds = 2000;

FlMethodChannel* channel = nullptr;
GDBusConnection* system_bus = nullptr;
int inhibitor = -1;
gboolean inhibit_pending = FALSE;
guint hold_timeout = 0;

void ReleaseInhibitor() {
  if (hold_timeout != 0) {
    g_source_remove(hold_timeout);
    hold_timeout = 0;
  }
  if (inhibitor >= 0) {
    close(inhibitor);
    inhibitor = -1;
  }
}

#ifdef HAVE_GIO_UNIX
void OnInhibitReply(GObject* source, GAsyncResult* result, gpointer) {
  inhibit_pending = FALSE;
  GUnixFDList* descriptors = nullptr;
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_with_unix_fd_list_finish(
      G_DBUS_CONNECTION(source), &descriptors, result, &error);
  if (reply == nullptr || descriptors == nullptr) {
    g_clear_object(&descriptors);
    return;
  }
  gint32 index = -1;
  g_variant_get(reply, "(h)", &index);
  // g_unix_fd_list_get returns a duplicate; the list closes its own copy.
  const int descriptor = g_unix_fd_list_get(descriptors, index, nullptr);
  g_object_unref(descriptors);
  if (descriptor < 0) {
    return;
  }
  if (inhibitor >= 0) {
    close(descriptor);
    return;
  }
  inhibitor = descriptor;
}
#endif

// A delay lock only postpones sleep; logind lets it go on its own after
// InhibitDelayMaxSec. It is taken again after every wake.
void TakeInhibitor() {
#ifdef HAVE_GIO_UNIX
  if (system_bus == nullptr || inhibitor >= 0 || inhibit_pending) {
    return;
  }
  inhibit_pending = TRUE;
  g_dbus_connection_call_with_unix_fd_list(
      system_bus, kLogindName, kLogindPath, kLogindManager, "Inhibit",
      g_variant_new("(ssss)", "sleep", "Whisper",
                    "Disconnecting from nearby devices", "delay"),
      G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr,
      OnInhibitReply, nullptr);
#endif
}

gboolean OnHoldTimeout(gpointer) {
  hold_timeout = 0;
  ReleaseInhibitor();
  return G_SOURCE_REMOVE;
}

void OnWillSleepAnswered(GObject* source, GAsyncResult* result, gpointer) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(source), result, &error);
  ReleaseInhibitor();
}

void OnPrepareForSleep(GDBusConnection*, const gchar*, const gchar*,
                       const gchar*, const gchar*, GVariant* parameters,
                       gpointer) {
  if (channel == nullptr ||
      !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) {
    return;
  }
  gboolean starting = FALSE;
  g_variant_get(parameters, "(b)", &starting);
  if (starting) {
    if (hold_timeout == 0) {
      hold_timeout =
          g_timeout_add(kSleepHoldMilliseconds, OnHoldTimeout, nullptr);
    }
    fl_method_channel_invoke_method(channel, "willSleep", nullptr, nullptr,
                                    OnWillSleepAnswered, nullptr);
    return;
  }
  ReleaseInhibitor();
  TakeInhibitor();
  fl_method_channel_invoke_method(channel, "didWake", nullptr, nullptr,
                                  nullptr, nullptr);
}

void OnSystemBus(GObject*, GAsyncResult* result, gpointer) {
  g_autoptr(GError) error = nullptr;
  system_bus = g_bus_get_finish(result, &error);
  if (system_bus == nullptr) {
    return;
  }
  g_dbus_connection_signal_subscribe(
      system_bus, kLogindName, kLogindManager, "PrepareForSleep", kLogindPath,
      nullptr, G_DBUS_SIGNAL_FLAGS_NONE, OnPrepareForSleep, nullptr, nullptr);
  TakeInhibitor();
}

}  // namespace

void system_power_plugin_register(FlPluginRegistry* registry) {
  if (channel != nullptr) {
    return;
  }
  FlPluginRegistrar* registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "SystemPowerPlugin");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                                  kSystemPowerChannel, FL_METHOD_CODEC(codec));
  g_bus_get(G_BUS_TYPE_SYSTEM, nullptr, OnSystemBus, nullptr);
}
