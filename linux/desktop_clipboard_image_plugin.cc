#include "desktop_clipboard_image_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gtk/gtk.h>

#include <cstdint>
#include <cstring>

namespace {

constexpr char kDesktopClipboardImageChannel[] =
    "com.vireen.whisper/desktop_clipboard_image";

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
  g_object_unref(channel);
}
