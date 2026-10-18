#include "file_manager_plugin.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>
#include <glib/gstdio.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>

// The remote file manager's platform pieces on Linux.
//
// trash: GIO's trash, which picks the right trash for the file's
// filesystem (the home trash, or $topdir/.Trash-$uid on other mounts such
// as USB drives), so nothing is copied across filesystems.
//
// thumbnail: images are decoded here with GdkPixbuf (scaled while decoding,
// EXIF orientation applied); videos, and images GdkPixbuf cannot read, come
// from the freedesktop thumbnail cache that Files (Nautilus) and other apps
// fill, when an up-to-date entry is there. Thumbnailers are not run here:
// GNOME runs them inside a sandbox, and files reaching this channel may come
// from other devices.

namespace {

constexpr char kChannelName[] = "com.vireen.whisper/file_manager";
constexpr char kJpegQuality[] = "80";  // as the macOS runner
constexpr int kDefaultSize = 256;
constexpr int kMinSize = 16;
constexpr int kMaxSize = 2048;

struct Request {
  FlMethodCall* call = nullptr;
  bool trash = false;
  std::string path;
  int size = kDefaultSize;
  bool video = false;
  bool trashed = false;
  GBytes* jpeg = nullptr;
};

void FreeRequest(gpointer data) {
  auto* request = static_cast<Request*>(data);
  if (request->call != nullptr) {
    g_object_unref(request->call);
  }
  if (request->jpeg != nullptr) {
    g_bytes_unref(request->jpeg);
  }
  delete request;
}

bool Trash(const std::string& path) {
  if (path.empty() || !g_path_is_absolute(path.c_str())) {
    return false;
  }
  GFile* file = g_file_new_for_path(path.c_str());
  const gboolean trashed = g_file_trash(file, nullptr, nullptr);
  g_object_unref(file);
  return trashed == TRUE;
}

GdkPixbuf* LoadImage(const std::string& path, int size) {
  GdkPixbuf* pixbuf =
      gdk_pixbuf_new_from_file_at_scale(path.c_str(), size, size, TRUE, nullptr);
  if (pixbuf == nullptr) {
    return nullptr;
  }
  // Photos store their rotation in EXIF.
  GdkPixbuf* oriented = gdk_pixbuf_apply_embedded_orientation(pixbuf);
  g_object_unref(pixbuf);
  return oriented;
}

// The freedesktop thumbnail cache entry for `path`, if one is there and
// was made from the file as it is now (Thumb::MTime matches).
GdkPixbuf* CachedThumbnail(const std::string& path, int size) {
  GStatBuf info;
  if (g_stat(path.c_str(), &info) != 0) {
    return nullptr;
  }
  gchar* uri = g_filename_to_uri(path.c_str(), nullptr, nullptr);
  if (uri == nullptr) {
    return nullptr;
  }
  gchar* digest = g_compute_checksum_for_string(G_CHECKSUM_MD5, uri, -1);
  g_free(uri);
  const std::string name = std::string(digest) + ".png";
  g_free(digest);

  struct Flavor {
    const char* directory;
    int size;
  };
  static const Flavor kFlavors[] = {
      {"normal", 128}, {"large", 256}, {"x-large", 512}, {"xx-large", 1024}};
  // The smallest flavour at least as big as asked for first, then the
  // bigger ones, then the smaller ones from the biggest down.
  const Flavor* order[4];
  int count = 0;
  for (const Flavor& flavor : kFlavors) {
    if (flavor.size >= size) {
      order[count++] = &flavor;
    }
  }
  for (int index = 3; index >= 0; index--) {
    if (kFlavors[index].size < size) {
      order[count++] = &kFlavors[index];
    }
  }
  for (int index = 0; index < count; index++) {
    gchar* file = g_build_filename(g_get_user_cache_dir(), "thumbnails",
                                   order[index]->directory, name.c_str(),
                                   nullptr);
    GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(file, nullptr);
    g_free(file);
    if (pixbuf == nullptr) {
      continue;
    }
    const gchar* mtime = gdk_pixbuf_get_option(pixbuf, "tEXt::Thumb::MTime");
    if (mtime != nullptr &&
        g_ascii_strtoll(mtime, nullptr, 10) ==
            static_cast<gint64>(info.st_mtime)) {
      return pixbuf;
    }
    g_object_unref(pixbuf);
  }
  return nullptr;
}

// Fits `image` into size × size and drops transparency onto white, as JPEG
// has none (a transparent PNG would otherwise turn black).
GdkPixbuf* Fit(GdkPixbuf* image, int size) {
  const int width = gdk_pixbuf_get_width(image);
  const int height = gdk_pixbuf_get_height(image);
  const double scale =
      std::min(1.0, static_cast<double>(size) / std::max(width, height));
  const int fitted_width = std::max(1, static_cast<int>(width * scale + 0.5));
  const int fitted_height = std::max(1, static_cast<int>(height * scale + 0.5));
  if (gdk_pixbuf_get_has_alpha(image)) {
    // Onto an opaque RGB picture: JPEG encoders refuse RGBA.
    GdkPixbuf* flat = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, fitted_width,
                                     fitted_height);
    if (flat == nullptr) {
      return nullptr;
    }
    gdk_pixbuf_fill(flat, 0xffffffff);
    gdk_pixbuf_composite(image, flat, 0, 0, fitted_width, fitted_height, 0, 0,
                         static_cast<double>(fitted_width) / width,
                         static_cast<double>(fitted_height) / height,
                         GDK_INTERP_BILINEAR, 255);
    return flat;
  }
  if (fitted_width == width && fitted_height == height) {
    return GDK_PIXBUF(g_object_ref(image));
  }
  return gdk_pixbuf_scale_simple(image, fitted_width, fitted_height,
                                 GDK_INTERP_BILINEAR);
}

GBytes* Thumbnail(const std::string& path, int size, bool video) {
  if (path.empty() || !g_path_is_absolute(path.c_str()) ||
      !g_file_test(path.c_str(), G_FILE_TEST_IS_REGULAR)) {
    return nullptr;
  }
  GdkPixbuf* image = video ? nullptr : LoadImage(path, size);
  if (image == nullptr) {
    image = CachedThumbnail(path, size);
  }
  if (image == nullptr) {
    return nullptr;
  }
  GdkPixbuf* fitted = Fit(image, size);
  g_object_unref(image);
  if (fitted == nullptr) {
    return nullptr;
  }
  gchar* buffer = nullptr;
  gsize length = 0;
  const gboolean saved =
      gdk_pixbuf_save_to_buffer(fitted, &buffer, &length, "jpeg", nullptr,
                                "quality", kJpegQuality, nullptr);
  g_object_unref(fitted);
  if (!saved || buffer == nullptr) {
    g_free(buffer);
    return nullptr;
  }
  return g_bytes_new_take(buffer, length);
}

void RunRequest(GTask* task, gpointer, gpointer data, GCancellable*) {
  auto* request = static_cast<Request*>(data);
  if (request->trash) {
    request->trashed = Trash(request->path);
  } else {
    request->jpeg = Thumbnail(request->path, request->size, request->video);
  }
  g_task_return_boolean(task, TRUE);
}

// Back on the main thread.
void FinishRequest(GObject*, GAsyncResult* result, gpointer) {
  auto* request =
      static_cast<Request*>(g_task_get_task_data(G_TASK(result)));
  g_autoptr(FlValue) value = nullptr;
  if (request->trash) {
    value = fl_value_new_bool(request->trashed);
  } else if (request->jpeg != nullptr) {
    gsize length = 0;
    const auto* bytes =
        static_cast<const uint8_t*>(g_bytes_get_data(request->jpeg, &length));
    value = fl_value_new_uint8_list(bytes, length);
  } else {
    value = fl_value_new_null();
  }
  fl_method_call_respond_success(request->call, value, nullptr);
}

std::string StringArgument(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return "";
  }
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : "";
}

int64_t IntArgument(FlValue* args, const char* key, int64_t fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return fallback;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr) {
    return fallback;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return fl_value_get_int(value);
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    return static_cast<int64_t>(fl_value_get_float(value));
  }
  return fallback;
}

bool BoolArgument(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

void HandleMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  const bool trash = std::strcmp(method, "trash") == 0;
  if (!trash && std::strcmp(method, "thumbnail") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  auto* request = new Request();
  request->call = FL_METHOD_CALL(g_object_ref(call));
  request->trash = trash;
  request->path = StringArgument(args, "path");
  request->size = static_cast<int>(std::max<int64_t>(
      kMinSize, std::min<int64_t>(kMaxSize, IntArgument(args, "size", kDefaultSize))));
  request->video = BoolArgument(args, "video");
  GTask* task = g_task_new(nullptr, nullptr, FinishRequest, nullptr);
  g_task_set_task_data(task, request, FreeRequest);
  g_task_run_in_thread(task, RunRequest);
  g_object_unref(task);
}

}  // namespace

void file_manager_plugin_register(FlPluginRegistry* registry) {
  FlPluginRegistrar* registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FileManagerPlugin");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kChannelName,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, HandleMethodCall, nullptr,
                                            nullptr);
  // The registrar's messenger keeps the handler; the channel lives as long
  // as the engine (the other runner channels do the same).
}
