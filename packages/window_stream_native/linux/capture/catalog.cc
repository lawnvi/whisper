#include "capture/catalog.h"

#include <gio/gdesktopappinfo.h>
#include <gio/gio.h>
#include <gtk/gtk.h>
#include <unistd.h>

#include <algorithm>
#include <set>
#include <vector>

#include "capture/capture_thread.h"
#include "capture/helper.h"
#include "common/callbacks.h"
#include "common/log.h"
#include "common/main_thread.h"
#include "window_stream_native.h"

namespace wsn::capture {

namespace {

void AppendJsonString(std::string* out, const std::string& value) {
  out->push_back('"');
  for (unsigned char c : value) {
    switch (c) {
      case '"': out->append("\\\""); break;
      case '\\': out->append("\\\\"); break;
      case '\n': out->append("\\n"); break;
      case '\r': out->append("\\r"); break;
      case '\t': out->append("\\t"); break;
      default:
        if (c < 0x20) {
          char escaped[8];
          g_snprintf(escaped, sizeof(escaped), "\\u%04x", c);
          out->append(escaped);
        } else {
          out->push_back(static_cast<char>(c));
        }
    }
  }
  out->push_back('"');
}

struct App {
  std::string id;
  std::string name;
};

// Apps a viewer can start: what the app grid shows. Read again when the
// installed set changes (GAppInfoMonitor) or after a minute.
class InstalledApps {
 public:
  const std::vector<App>& List() {
    int64_t now = g_get_monotonic_time();
    if (monitor_ == nullptr) {
      monitor_ = g_app_info_monitor_get();  // signals on this (the capture) thread
      g_signal_connect(monitor_, "changed", G_CALLBACK(+[](GAppInfoMonitor*, gpointer self) {
                         static_cast<InstalledApps*>(self)->read_at_ = 0;
                       }),
                       this);
    }
    if (read_at_ != 0 && now - read_at_ < 60 * G_USEC_PER_SEC) return apps_;
    read_at_ = now;
    apps_.clear();
    GList* all = g_app_info_get_all();
    std::set<std::string> seen;
    for (GList* item = all; item != nullptr; item = item->next) {
      auto* info = G_APP_INFO(item->data);
      const char* id = g_app_info_get_id(info);
      const char* name = g_app_info_get_name(info);
      if (id == nullptr || name == nullptr || !g_app_info_should_show(info)) continue;
      // Whisper itself is not something to stream.
      if (g_str_has_prefix(id, "whisper") || g_str_has_prefix(id, "com.vireen.whisper")) continue;
      if (!seen.insert(id).second) continue;
      apps_.push_back({id, name});
    }
    g_list_free_full(all, g_object_unref);
    std::sort(apps_.begin(), apps_.end(), [](const App& a, const App& b) { return a.name < b.name; });
    return apps_;
  }

 private:
  GAppInfoMonitor* monitor_ = nullptr;
  int64_t read_at_ = 0;
  std::vector<App> apps_;
};

InstalledApps& Apps() {
  static auto* apps = new InstalledApps();
  return *apps;
}

void FailRequest(int64_t id, int32_t error) { EmitCapture(id, WSN_CAPTURE_FAILED, nullptr, 0, 0, error); }

}  // namespace

void RequestCatalog(int64_t id) {
  WindowHelper& helper = WindowHelper::Get();
  HelperState state = helper.Check();
  if (state != HelperState::kReady) {
    // A note under id 0 (the host's log): the request id expects one answer.
    EmitCaptureNote(0, std::string("catalog: window helper ") + HelperStateName(state));
    FailRequest(id, HelperFailure(state));
    return;
  }
  helper.ListWindows([id](bool ok, std::vector<HelperWindow> windows, bool locked) {
    if (!ok) {
      FailRequest(id, WSN_CAPTURE_ERROR_HELPER);
      return;
    }
    int own = static_cast<int>(getpid());
    std::set<std::string> running;
    std::string json = "{\"windows\":[";
    bool first = true;
    for (const HelperWindow& w : windows) {
      if (!w.app_id.empty()) running.insert(w.app_id);
      // Whole windows of other apps: no dialogs or tool windows on their
      // own, nothing tiny, nothing of Whisper's.
      if (w.pid == own || w.type != 0 || w.transient_for != 0) continue;
      if (w.frame.width <= 100 || w.frame.height <= 100) continue;
      if (!first) json += ",";
      first = false;
      json += "{\"id\":" + std::to_string(w.id) + ",\"title\":";
      AppendJsonString(&json, w.title);
      json += ",\"appName\":";
      AppendJsonString(&json, w.app_name);
      json += ",\"bundleId\":";
      AppendJsonString(&json, w.app_id);
      json += ",\"pid\":" + std::to_string(w.pid);
      json += ",\"width\":" + std::to_string(w.frame.width);
      json += ",\"height\":" + std::to_string(w.frame.height);
      json += std::string(",\"onScreen\":") + (!w.minimized && w.on_current_workspace && !w.staged ? "true" : "false");
      json += std::string(",\"active\":") + (w.focused ? "true" : "false");
      json += "}";
    }
    json += "],\"apps\":[";
    first = true;
    for (const App& app : Apps().List()) {
      if (!first) json += ",";
      first = false;
      json += "{\"bundleId\":";
      AppendJsonString(&json, app.id);
      json += ",\"name\":";
      AppendJsonString(&json, app.name);
      json += std::string(",\"running\":") + (running.count(app.id) != 0 ? "true" : "false");
      json += "}";
    }
    json += std::string("],\"locked\":") + (locked ? "true" : "false") + "}";
    EmitCapture(id, WSN_CAPTURE_CATALOG, reinterpret_cast<const uint8_t*>(json.data()),
                static_cast<int32_t>(json.size()));
  });
}

void RequestThumbnail(int64_t id, uint32_t window, int max_edge) {
  WindowHelper& helper = WindowHelper::Get();
  HelperState state = helper.Check();
  if (state != HelperState::kReady) {
    FailRequest(id, HelperFailure(state));
    return;
  }
  int edge = max_edge > 0 ? std::min(max_edge, 2048) : 1024;
  // Only a window the catalog would offer: no dialogs on their own, nothing
  // of Whisper's, nothing while locked.
  helper.ListWindows([id, window, edge](bool ok, std::vector<HelperWindow> windows, bool locked) {
    int own = static_cast<int>(getpid());
    auto found = std::find_if(windows.begin(), windows.end(), [&](const HelperWindow& w) {
      return w.id == window && w.pid != own && w.type == 0 && w.transient_for == 0;
    });
    if (!ok || locked || found == windows.end()) {
      FailRequest(id, locked ? WSN_CAPTURE_ERROR_LOCKED : WSN_CAPTURE_ERROR_NOT_FOUND);
      return;
    }
    WindowHelper::Get().Thumbnail(window, edge, [id](bool shot, std::vector<uint8_t> jpeg) {
      if (!shot) {
        FailRequest(id, WSN_CAPTURE_ERROR_NOT_FOUND);
        return;
      }
      EmitCapture(id, WSN_CAPTURE_THUMBNAIL, jpeg.data(), static_cast<int32_t>(jpeg.size()));
    });
  });
}

void CloseWindow(uint32_t window) {
  WindowHelper& helper = WindowHelper::Get();
  if (helper.Check() == HelperState::kReady) helper.Close(window);
}

void RequestIcon(int64_t id, const std::string& app_id, int size) {
  // The icon theme belongs to the GTK thread.
  OnMain([id, app_id, size] {
    GDesktopAppInfo* info = app_id.empty() ? nullptr : g_desktop_app_info_new(app_id.c_str());
    GIcon* icon = info != nullptr ? g_app_info_get_icon(G_APP_INFO(info)) : nullptr;
    int pixels = std::clamp(size, 16, 512);
    GdkPixbuf* pixbuf = nullptr;
    if (icon != nullptr) {
      GtkIconInfo* found = gtk_icon_theme_lookup_by_gicon(gtk_icon_theme_get_default(), icon, pixels,
                                                          GTK_ICON_LOOKUP_FORCE_SIZE);
      if (found != nullptr) {
        pixbuf = gtk_icon_info_load_icon(found, nullptr);
        g_object_unref(found);
      }
    }
    gchar* png = nullptr;
    gsize length = 0;
    bool saved = pixbuf != nullptr && gdk_pixbuf_save_to_buffer(pixbuf, &png, &length, "png", nullptr, nullptr);
    if (saved) {
      EmitCapture(id, WSN_CAPTURE_ICON, reinterpret_cast<const uint8_t*>(png), static_cast<int32_t>(length));
    } else {
      FailRequest(id, WSN_CAPTURE_ERROR_NOT_FOUND);
    }
    g_free(png);
    if (pixbuf != nullptr) g_object_unref(pixbuf);
    if (info != nullptr) g_object_unref(info);
  });
}

void LaunchApp(int64_t id, const std::string& app_id) {
  OnMain([id, app_id] {
    GDesktopAppInfo* info = app_id.empty() ? nullptr : g_desktop_app_info_new(app_id.c_str());
    if (info == nullptr) {
      FailRequest(id, WSN_CAPTURE_ERROR_NOT_FOUND);
      return;
    }
    GdkDisplay* display = gdk_display_get_default();
    GdkAppLaunchContext* context = display != nullptr ? gdk_display_get_app_launch_context(display) : nullptr;
    GError* error = nullptr;
    gboolean launched = g_app_info_launch(G_APP_INFO(info), nullptr, G_APP_LAUNCH_CONTEXT(context), &error);
    if (launched) {
      EmitCapture(id, WSN_CAPTURE_LAUNCHED);
    } else {
      WSN_LOG("capture: launching %s failed: %s", app_id.c_str(), error != nullptr ? error->message : "?");
      FailRequest(id, WSN_CAPTURE_ERROR_UNKNOWN);
    }
    if (error != nullptr) g_error_free(error);
    if (context != nullptr) g_object_unref(context);
    g_object_unref(info);
  });
}

}  // namespace wsn::capture
