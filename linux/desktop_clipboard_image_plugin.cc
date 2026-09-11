#include "desktop_clipboard_image_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gtk/gtk.h>

#include <cstdint>
#include <cstring>

namespace {

constexpr char kDesktopClipboardImageChannel[] =
    "com.vireen.whisper/desktop_clipboard_image";

constexpr guint kUriListTarget = 0;
constexpr guint kGnomeCopiedFilesTarget = 1;
constexpr guint kImageTarget = 2;

struct ClipboardPayload {
  gchar** uris;
  GdkPixbuf* image;
};

FlMethodChannel* g_clipboard_watcher_channel = nullptr;

GtkTargetEntry kFileClipboardTargets[] = {
    {const_cast<gchar*>("text/uri-list"), 0, kUriListTarget},
    {const_cast<gchar*>("x-special/gnome-copied-files"), 0,
     kGnomeCopiedFilesTarget},
};

void ProvideFileUris(GtkClipboard*,
                     GtkSelectionData* selection_data,
                     guint target,
                     gpointer user_data) {
  auto* payload = static_cast<ClipboardPayload*>(user_data);
  if (target == kImageTarget) {
    gtk_selection_data_set_pixbuf(selection_data, payload->image);
    return;
  }
  auto** uris = payload->uris;
  if (target == kUriListTarget) {
    gtk_selection_data_set_uris(selection_data, uris);
    return;
  }

  GString* copied_files = g_string_new("copy\n");
  for (gchar** uri = uris; *uri != nullptr; uri++) {
    g_string_append(copied_files, *uri);
    if (*(uri + 1) != nullptr) {
      g_string_append_c(copied_files, '\n');
    }
  }
  gtk_selection_data_set(
      selection_data, gtk_selection_data_get_target(selection_data), 8,
      reinterpret_cast<const guchar*>(copied_files->str),
      static_cast<gint>(copied_files->len));
  g_string_free(copied_files, TRUE);
}

void ClearFileUris(GtkClipboard*, gpointer user_data) {
  auto* payload = static_cast<ClipboardPayload*>(user_data);
  g_strfreev(payload->uris);
  g_clear_object(&payload->image);
  delete payload;
}

bool WriteClipboardPayload(GtkClipboard* clipboard, ClipboardPayload* payload) {
  GtkTargetList* targets = gtk_target_list_new(
      kFileClipboardTargets, G_N_ELEMENTS(kFileClipboardTargets));
  if (payload->image != nullptr) {
    // Keep the source URI alongside the image, as on macOS/Windows. It lets
    // the watcher recognize received images instead of publishing them back.
    gtk_target_list_add_image_targets(targets, kImageTarget, TRUE);
  }
  gint count = 0;
  GtkTargetEntry* entries = gtk_target_table_new_from_list(targets, &count);
  gtk_target_list_unref(targets);
  const bool written = gtk_clipboard_set_with_data(
      clipboard, entries, count, ProvideFileUris, ClearFileUris, payload);
  if (written) {
    gtk_clipboard_set_can_store(clipboard, entries, count);
    gtk_clipboard_store(clipboard);
  } else {
    ClearFileUris(clipboard, payload);
  }
  gtk_target_table_free(entries, count);
  return written;
}

void NotifyClipboardChanged(GtkClipboard*, GdkEvent*, gpointer) {
  if (g_clipboard_watcher_channel == nullptr) {
    return;
  }
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_method_channel_invoke_method(g_clipboard_watcher_channel,
                                  "onClipboardChanged", args, nullptr,
                                  nullptr, nullptr);
}

FlValue* ReadImagePng() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (clipboard == nullptr) {
    return nullptr;
  }
  g_autoptr(GdkPixbuf) pixbuf = gtk_clipboard_wait_for_image(clipboard);
  if (pixbuf == nullptr) {
    return nullptr;
  }

  gchar* buffer = nullptr;
  gsize size = 0;
  g_autoptr(GError) error = nullptr;
  if (!gdk_pixbuf_save_to_buffer(
          pixbuf, &buffer, &size, "png", &error, nullptr)) {
    g_clear_pointer(&buffer, g_free);
    return nullptr;
  }
  FlValue* value = fl_value_new_uint8_list(
      reinterpret_cast<const uint8_t*>(buffer), size);
  g_clear_pointer(&buffer, g_free);
  return value;
}

FlValue* ReadFilePaths() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (clipboard == nullptr) {
    return fl_value_new_list();
  }
  gchar** uris = gtk_clipboard_wait_for_uris(clipboard);
  FlValue* paths = fl_value_new_list();
  if (uris == nullptr) {
    return paths;
  }
  for (gchar** uri = uris; *uri != nullptr; uri++) {
    g_autoptr(GError) error = nullptr;
    gchar* filename = g_filename_from_uri(*uri, nullptr, &error);
    if (filename == nullptr) {
      continue;
    }
    fl_value_append_take(paths, fl_value_new_string(filename));
    g_free(filename);
  }
  g_strfreev(uris);
  return paths;
}

bool WriteFilePaths(FlValue* arguments) {
  if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue* paths = fl_value_lookup_string(arguments, "paths");
  if (paths == nullptr || fl_value_get_type(paths) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(paths) == 0) {
    return false;
  }
  g_autoptr(GPtrArray) uris = g_ptr_array_new_with_free_func(g_free);
  for (size_t index = 0; index < fl_value_get_length(paths); index++) {
    FlValue* value = fl_value_get_list_value(paths, index);
    if (fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
      return false;
    }
    const gchar* path = fl_value_get_string(value);
    if (!g_file_test(path, G_FILE_TEST_EXISTS)) {
      return false;
    }
    g_autoptr(GError) error = nullptr;
    gchar* uri = g_filename_to_uri(path, nullptr, &error);
    if (uri == nullptr) {
      return false;
    }
    g_ptr_array_add(uris, uri);
  }
  g_ptr_array_add(uris, nullptr);
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (clipboard == nullptr) {
    return false;
  }
  FlValue* as_image_value = fl_value_lookup_string(arguments, "asImage");
  const bool as_image = as_image_value != nullptr &&
                        fl_value_get_type(as_image_value) == FL_VALUE_TYPE_BOOL &&
                        fl_value_get_bool(as_image_value);
  g_autoptr(GdkPixbuf) pixbuf = nullptr;
  if (as_image && fl_value_get_length(paths) == 1) {
    FlValue* path_value = fl_value_get_list_value(paths, 0);
    g_autoptr(GError) error = nullptr;
    pixbuf =
        gdk_pixbuf_new_from_file(fl_value_get_string(path_value), &error);
    if (pixbuf == nullptr) {
      return false;
    }
  }
  return WriteClipboardPayload(
      clipboard,
      new ClipboardPayload{
          reinterpret_cast<gchar**>(
              g_ptr_array_free(g_steal_pointer(&uris), FALSE)),
          g_steal_pointer(&pixbuf)});
}

void MethodCallCallback(FlMethodChannel*,
                        FlMethodCall* method_call,
                        gpointer) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (std::strcmp(method, "readFilePaths") == 0) {
    g_autoptr(FlValue) paths = ReadFilePaths();
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(paths));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  if (std::strcmp(method, "writeFilePaths") == 0) {
    const bool written = WriteFilePaths(fl_method_call_get_args(method_call));
    g_autoptr(FlValue) value = fl_value_new_bool(written);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  if (std::strcmp(method, "readImagePng") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  g_autoptr(FlValue) image = ReadImagePng();
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(image));
  fl_method_call_respond(method_call, response, nullptr);
}

}  // namespace

void desktop_clipboard_image_plugin_register(FlPluginRegistry* registry) {
  FlPluginRegistrar* registrar = fl_plugin_registry_get_registrar_for_plugin(
      registry, "DesktopClipboardImagePlugin");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      kDesktopClipboardImageChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, MethodCallCallback,
                                            nullptr, nullptr);
  // clipboard_watcher 0.3 listens to PRIMARY on Linux. Screenshots and image
  // clipboard writes use CLIPBOARD, so mirror its event onto the same Dart
  // channel to keep remote clipboard sync responsive.
  g_clipboard_watcher_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "clipboard_watcher",
      FL_METHOD_CODEC(codec));
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_signal_connect(clipboard, "owner-change", G_CALLBACK(NotifyClipboardChanged),
                   nullptr);
  g_object_unref(channel);
}
