#include "desktop_quick_send_plugin.h"

#include <cerrno>
#include <cstring>

#include <fcntl.h>
#include <unistd.h>

#include <glib/gstdio.h>

namespace {

constexpr char kDesktopQuickSendChannel[] =
    "com.vireen.whisper/desktop_quick_send";
constexpr guint kMaximumPendingCount = 32;
constexpr char kStateGroup[] = "queue";

struct PendingEntry {
  gchar* id;
  gchar** arguments;
};

FlMethodChannel* channel = nullptr;
GQueue* pending_entries = nullptr;
gchar* rejection_id = nullptr;
gchar* rejection_reason = nullptr;
gint64 rejection_limit = 0;
gboolean state_loaded = FALSE;

gboolean RequestsBareClipboardCapture(char** arguments);
gboolean SetPendingRejection(const gchar* reason, gint64 limit);

void DestroyPendingEntry(PendingEntry* entry) {
  if (entry == nullptr) {
    return;
  }
  g_free(entry->id);
  g_strfreev(entry->arguments);
  g_free(entry);
}

gchar* StatePath() {
  g_autofree gchar* directory =
      g_build_filename(g_get_user_data_dir(), "whisper", nullptr);
  if (g_mkdir_with_parents(directory, 0700) != 0) {
    return nullptr;
  }
  return g_build_filename(directory, "desktop_quick_send_queue.ini", nullptr);
}

gboolean WriteStateAtomically(const gchar* path, const gchar* data,
                              gsize data_length) {
  g_autofree gchar* temporary = g_strdup_printf("%s.tmp", path);
  const int descriptor =
      g_open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (descriptor < 0) {
    return FALSE;
  }
  gsize offset = 0;
  while (offset < data_length) {
    const ssize_t written =
        write(descriptor, data + offset, data_length - offset);
    if (written < 0 && errno == EINTR) {
      continue;
    }
    if (written <= 0) {
      close(descriptor);
      g_unlink(temporary);
      return FALSE;
    }
    offset += static_cast<gsize>(written);
  }
  gboolean saved = fsync(descriptor) == 0;
  if (close(descriptor) != 0) {
    saved = FALSE;
  }
  if (saved && g_rename(temporary, path) != 0) {
    saved = FALSE;
  }
  if (!saved) {
    g_unlink(temporary);
    return FALSE;
  }
  g_autofree gchar* directory = g_path_get_dirname(path);
  const int directory_descriptor = open(directory, O_RDONLY | O_DIRECTORY);
  if (directory_descriptor >= 0) {
    fsync(directory_descriptor);
    close(directory_descriptor);
  }
  return TRUE;
}

gboolean PersistState() {
  g_autofree gchar* path = StatePath();
  if (path == nullptr) {
    return FALSE;
  }
  g_autoptr(GKeyFile) key_file = g_key_file_new();
  const guint count = pending_entries == nullptr
                          ? 0
                          : g_queue_get_length(pending_entries);
  g_auto(GStrv) order = g_new0(gchar*, count + 1);
  guint index = 0;
  if (pending_entries != nullptr) {
    for (GList* link = pending_entries->head; link != nullptr;
         link = link->next) {
      auto* entry = static_cast<PendingEntry*>(link->data);
      order[index++] = g_strdup(entry->id);
      g_autofree gchar* group = g_strdup_printf("event:%s", entry->id);
      g_key_file_set_string_list(
          key_file, group, "arguments",
          const_cast<const gchar* const*>(entry->arguments),
          g_strv_length(entry->arguments));
    }
  }
  g_key_file_set_string_list(
      key_file, kStateGroup, "order",
      const_cast<const gchar* const*>(order), count);
  if (rejection_id != nullptr) {
    g_key_file_set_string(key_file, kStateGroup, "rejection_id",
                          rejection_id);
    g_key_file_set_string(
        key_file, kStateGroup, "rejection_reason",
        rejection_reason == nullptr ? "draftLimitExceeded" : rejection_reason);
    g_key_file_set_int64(key_file, kStateGroup, "rejection_limit",
                         rejection_limit);
  }
  gsize data_length = 0;
  g_autofree gchar* data = g_key_file_to_data(key_file, &data_length, nullptr);
  return WriteStateAtomically(path, data, data_length);
}

void EnsureStateLoaded() {
  if (state_loaded) {
    return;
  }
  state_loaded = TRUE;
  pending_entries = g_queue_new();
  g_autofree gchar* path = StatePath();
  if (path == nullptr) {
    return;
  }
  g_autoptr(GKeyFile) key_file = g_key_file_new();
  if (!g_key_file_load_from_file(key_file, path, G_KEY_FILE_NONE, nullptr)) {
    return;
  }
  gsize order_length = 0;
  g_auto(GStrv) order =
      g_key_file_get_string_list(key_file, kStateGroup, "order",
                                 &order_length, nullptr);
  gboolean discarded_legacy_bare_capture = FALSE;
  for (gsize index = 0;
       order != nullptr && index < order_length &&
       g_queue_get_length(pending_entries) < kMaximumPendingCount;
       ++index) {
    g_autofree gchar* group = g_strdup_printf("event:%s", order[index]);
    gsize argument_count = 0;
    gchar** arguments = g_key_file_get_string_list(
        key_file, group, "arguments", &argument_count, nullptr);
    if (arguments == nullptr || argument_count == 0) {
      g_strfreev(arguments);
      continue;
    }
    if (RequestsBareClipboardCapture(arguments)) {
      discarded_legacy_bare_capture = TRUE;
      g_strfreev(arguments);
      continue;
    }
    auto* entry = g_new0(PendingEntry, 1);
    entry->id = g_strdup(order[index]);
    entry->arguments = arguments;
    g_queue_push_tail(pending_entries, entry);
  }
  rejection_id =
      g_key_file_get_string(key_file, kStateGroup, "rejection_id", nullptr);
  if (rejection_id != nullptr) {
    rejection_reason = g_key_file_get_string(
        key_file, kStateGroup, "rejection_reason", nullptr);
    if (rejection_reason == nullptr) {
      rejection_reason = g_strdup("draftLimitExceeded");
      rejection_limit = kMaximumPendingCount;
    } else {
      rejection_limit =
          g_key_file_get_int64(key_file, kStateGroup, "rejection_limit", nullptr);
    }
  }
  if (discarded_legacy_bare_capture) {
    SetPendingRejection("clipboardSnapshotUnavailable", 0);
  }
}

gboolean HasQuickSendCommand(char** arguments) {
  if (arguments == nullptr) {
    return FALSE;
  }
  for (char** argument = arguments; *argument != nullptr; ++argument) {
    if (std::strcmp(*argument, "--quick-send") == 0 ||
        std::strcmp(*argument, "--quick-send-text") == 0 ||
        std::strcmp(*argument, "--quick-send-file") == 0) {
      return TRUE;
    }
  }
  return FALSE;
}

gboolean RequestsBareClipboardCapture(char** arguments) {
  if (arguments == nullptr) {
    return FALSE;
  }
  gboolean requested = FALSE;
  gboolean has_content = FALSE;
  for (char** argument = arguments; *argument != nullptr; ++argument) {
    if ((std::strcmp(*argument, "--quick-send-text") == 0 ||
         std::strcmp(*argument, "--quick-send-file") == 0) &&
        *(argument + 1) != nullptr) {
      has_content = TRUE;
      ++argument;
      continue;
    }
    if (std::strcmp(*argument, "--quick-send") == 0) {
      requested = TRUE;
      has_content = has_content || *(argument + 1) != nullptr;
      break;
    }
  }
  return requested && !has_content;
}

FlValue* ArgumentsValue(char** arguments) {
  FlValue* values = fl_value_new_list();
  if (arguments == nullptr) {
    return values;
  }
  for (char** argument = arguments; *argument != nullptr; ++argument) {
    fl_value_append_take(values, fl_value_new_string(*argument));
  }
  return values;
}

FlValue* EntryValue(PendingEntry* entry) {
  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(value, "id", fl_value_new_string(entry->id));
  fl_value_set_string_take(value, "arguments",
                           ArgumentsValue(entry->arguments));
  return value;
}

FlValue* RejectionValue() {
  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(value, "id", fl_value_new_string(rejection_id));
  FlValue* rejection = fl_value_new_map();
  fl_value_set_string_take(rejection, "reason",
                           fl_value_new_string(
                               rejection_reason == nullptr
                                   ? "draftLimitExceeded"
                                   : rejection_reason));
  fl_value_set_string_take(rejection, "limit",
                           fl_value_new_int(rejection_limit));
  fl_value_set_string_take(value, "rejection", rejection);
  return value;
}

void WakeDart() {
  if (channel != nullptr) {
    fl_method_channel_invoke_method(channel, "quickSendReceived", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

gboolean SetPendingRejection(const gchar* reason, gint64 limit) {
  g_autofree gchar* uuid = g_uuid_string_random();
  gchar* previous_id = rejection_id;
  gchar* previous_reason = rejection_reason;
  const gint64 previous_limit = rejection_limit;
  rejection_id = g_strdup_printf("linux-rejection-%s", uuid);
  rejection_reason = g_strdup(reason);
  rejection_limit = limit;
  if (PersistState()) {
    g_free(previous_id);
    g_free(previous_reason);
    return TRUE;
  }
  g_free(rejection_id);
  g_free(rejection_reason);
  rejection_id = previous_id;
  rejection_reason = previous_reason;
  rejection_limit = previous_limit;
  return FALSE;
}

gboolean Acknowledge(const gchar* id) {
  EnsureStateLoaded();
  if (id == nullptr || *id == '\0') {
    return FALSE;
  }
  if (g_strcmp0(id, rejection_id) == 0) {
    gchar* previous_id = rejection_id;
    gchar* previous_reason = rejection_reason;
    const gint64 previous_limit = rejection_limit;
    rejection_id = nullptr;
    rejection_reason = nullptr;
    rejection_limit = 0;
    if (PersistState()) {
      g_free(previous_id);
      g_free(previous_reason);
      return TRUE;
    }
    rejection_id = previous_id;
    rejection_reason = previous_reason;
    rejection_limit = previous_limit;
    return FALSE;
  }
  for (GList* link = pending_entries->head; link != nullptr;
       link = link->next) {
    auto* entry = static_cast<PendingEntry*>(link->data);
    if (g_strcmp0(entry->id, id) != 0) {
      continue;
    }
    const gint position = g_queue_link_index(pending_entries, link);
    g_queue_unlink(pending_entries, link);
    if (PersistState()) {
      DestroyPendingEntry(entry);
      g_list_free_1(link);
      return TRUE;
    }
    g_queue_push_nth_link(pending_entries, position, link);
    return FALSE;
  }
  return TRUE;
}

void MethodCallCallback(FlMethodChannel*, FlMethodCall* method_call,
                        gpointer) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (std::strcmp(method, "consumePendingQuickSends") == 0) {
    EnsureStateLoaded();
    g_autoptr(FlValue) pending = fl_value_new_list();
    for (GList* link = pending_entries->head; link != nullptr;
         link = link->next) {
      fl_value_append_take(
          pending, EntryValue(static_cast<PendingEntry*>(link->data)));
    }
    if (rejection_id != nullptr) {
      fl_value_append_take(pending, RejectionValue());
    }
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(pending));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  if (std::strcmp(method, "acknowledgeQuickSend") == 0) {
    FlValue* arguments = fl_method_call_get_args(method_call);
    const gboolean acknowledged =
        arguments != nullptr && fl_value_get_type(arguments) == FL_VALUE_TYPE_STRING
            ? Acknowledge(fl_value_get_string(arguments))
            : FALSE;
    g_autoptr(FlValue) value = fl_value_new_bool(acknowledged);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

}  // namespace

void desktop_quick_send_plugin_register(FlPluginRegistry* registry) {
  EnsureStateLoaded();
  FlPluginRegistrar* registrar = fl_plugin_registry_get_registrar_for_plugin(
      registry, "DesktopQuickSendPlugin");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                                  kDesktopQuickSendChannel,
                                  FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, MethodCallCallback,
                                            nullptr, nullptr);
  WakeDart();
}

DesktopQuickSendEnqueueOutcome desktop_quick_send_plugin_emit_arguments(
    char** arguments) {
  if (!HasQuickSendCommand(arguments)) {
    return DESKTOP_QUICK_SEND_IGNORED;
  }
  EnsureStateLoaded();
  if (RequestsBareClipboardCapture(arguments)) {
    SetPendingRejection("clipboardSnapshotUnavailable", 0);
    WakeDart();
    return DESKTOP_QUICK_SEND_REJECTED;
  }
  if (g_queue_get_length(pending_entries) >= kMaximumPendingCount) {
    SetPendingRejection("draftLimitExceeded", kMaximumPendingCount);
    WakeDart();
    return DESKTOP_QUICK_SEND_REJECTED;
  }
  auto* entry = g_new0(PendingEntry, 1);
  g_autofree gchar* uuid = g_uuid_string_random();
  entry->id = g_strdup_printf("linux-%s", uuid);
  entry->arguments = g_strdupv(arguments);
  g_queue_push_tail(pending_entries, entry);
  if (!PersistState()) {
    g_queue_pop_tail(pending_entries);
    DestroyPendingEntry(entry);
    return DESKTOP_QUICK_SEND_REJECTED;
  }
  WakeDart();
  return DESKTOP_QUICK_SEND_ACCEPTED;
}
