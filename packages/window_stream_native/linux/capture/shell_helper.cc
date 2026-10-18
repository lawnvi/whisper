#include "capture/shell_helper.h"

#include <gio/gio.h>
#include <unistd.h>

#include <atomic>
#include <cstring>

#include "capture/bus.h"
#include "common/log.h"

namespace wsn::capture {

namespace {

constexpr const char* kBusName = "com.vireen.Whisper.Shell";
constexpr const char* kPath = "/com/vireen/Whisper/Shell";
constexpr const char* kIface = "com.vireen.Whisper.Shell1";
constexpr int64_t kRecheckUs = 2 * G_USEC_PER_SEC;

std::string ExecutableOf(uint32_t pid) {
  gchar* link = g_strdup_printf("/proc/%u/exe", pid);
  gchar* target = g_file_read_link(link, nullptr);
  g_free(link);
  std::string value = target != nullptr ? target : "";
  g_free(target);
  return value;
}

std::string ErrorName(const GError* error) {
  if (error == nullptr) return "";
  gchar* remote = g_dbus_error_get_remote_error(error);
  std::string name = remote != nullptr ? remote : "";
  g_free(remote);
  return name;
}

bool Lookup(GVariant* dict, const char* key, const char* type, void* out) {
  return g_variant_lookup(dict, key, type, out);
}

}  // namespace

const char* HelperStateName(HelperState state) {
  switch (state) {
    case HelperState::kReady: return "ready";
    case HelperState::kNoBus: return "no-bus";
    case HelperState::kMissing: return "missing";
    case HelperState::kUntrusted: return "untrusted";
    case HelperState::kOutdated: return "outdated";
    case HelperState::kDenied: return "denied";
  }
  return "?";
}

ShellHelper& ShellHelper::Get() {
  static ShellHelper* helper = new ShellHelper();
  return *helper;
}

HelperState ShellHelper::Check(bool force) {
  int64_t now = g_get_monotonic_time();
  if (!force && checked_at_ != 0 && now - checked_at_ < kRecheckUs) return state_;
  checked_at_ = now;
  HelperState previous = state_;
  if (Bus() == nullptr) {
    state_ = HelperState::kNoBus;
    return state_;
  }
  Watch();
  std::string owner = OwnerOf(kBusName);
  if (owner.empty()) {
    state_ = HelperState::kMissing;
  } else {
    // Only GNOME Shell may answer to this name: a stand-in could see what
    // is typed and move windows. The very connection that owns
    // org.gnome.Shell (a name only the shell holds) must own ours too.
    std::string shell = OwnerOf("org.gnome.Shell");
    uint32_t pid = PidOf(owner.c_str());
    std::string exe = pid != 0 ? ExecutableOf(pid) : "";
    const char* base = std::strrchr(exe.c_str(), '/');
    if (shell.empty() || owner != shell || base == nullptr || std::strcmp(base + 1, "gnome-shell") != 0) {
      WSN_LOG("capture: %s is owned by %s (pid %u, %s), not by GNOME Shell (%s)", kBusName, owner.c_str(), pid,
              exe.c_str(), shell.c_str());
      state_ = HelperState::kUntrusted;
    } else {
      GError* error = nullptr;
      GVariant* reply = CallSync(owner.c_str(), kPath, kIface, "GetInfo", nullptr, "(a{sv})", 1500, &error);
      if (reply == nullptr) {
        std::string name = ErrorName(error);
        state_ = name.find(".Denied") != std::string::npos ? HelperState::kDenied : HelperState::kMissing;
        WSN_LOG("capture: helper GetInfo failed: %s", error != nullptr ? error->message : "?");
      } else {
        GVariant* info = g_variant_get_child_value(reply, 0);
        guint32 version = 0;
        g_variant_lookup(info, "version", "u", &version);
        state_ = version == kHelperProtocol ? HelperState::kReady : HelperState::kOutdated;
        g_variant_unref(info);
        g_variant_unref(reply);
      }
      if (error != nullptr) g_error_free(error);
    }
  }
  owner_ = state_ == HelperState::kReady ? owner : "";
  if (state_ != previous) WSN_LOG("capture: GNOME Shell helper %s", HelperStateName(state_));
  return state_;
}

void ShellHelper::Watch() {
  if (watching_) return;
  watching_ = true;
  Subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
            [this](const char*, const char*, GVariant* params) {
              const gchar* name = nullptr;
              const gchar* old_owner = nullptr;
              const gchar* new_owner = nullptr;
              g_variant_get(params, "(&s&s&s)", &name, &old_owner, &new_owner);
              if (name == nullptr || std::strcmp(name, kBusName) != 0) return;
              bool had = !owner_.empty();
              checked_at_ = 0;
              owner_.clear();
              state_ = HelperState::kMissing;
              if (new_owner != nullptr && *new_owner != '\0') Check(true);
              if (had && handlers_.vanished) handlers_.vanished();
            },
            kBusName);
  // Signals come unicast from the owner; anything else claiming to be it
  // is ignored.
  Subscribe(nullptr, kIface, nullptr, kPath, [this](const char* sender, const char* member, GVariant* params) {
    if (owner_.empty() || sender == nullptr || owner_ != sender) return;
    if (std::strcmp(member, "WindowsChanged") == 0) {
      if (handlers_.windows_changed) handlers_.windows_changed();
    } else if (std::strcmp(member, "WindowGone") == 0 && g_variant_is_of_type(params, G_VARIANT_TYPE("(u)"))) {
      guint32 id = 0;
      g_variant_get(params, "(u)", &id);
      if (handlers_.window_gone) handlers_.window_gone(id);
    } else if (std::strcmp(member, "TextFocus") == 0 && g_variant_is_of_type(params, G_VARIANT_TYPE("(ub)"))) {
      guint32 id = 0;
      gboolean focused = FALSE;
      g_variant_get(params, "(ub)", &id, &focused);
      if (handlers_.text_focus) handlers_.text_focus(id, focused);
    }
  });
}

void ShellHelper::Call(const char* method, GVariant* params, const char* reply_type,
                       std::function<void(GVariant* reply, const std::string& error)> done, int timeout_ms) {
  if (state_ != HelperState::kReady || owner_.empty()) {
    if (params != nullptr) g_variant_unref(g_variant_ref_sink(params));
    if (done) done(nullptr, std::string("helper ") + HelperStateName(state_));
    return;
  }
  std::string name = method;
  capture::Call(owner_.c_str(), kPath, kIface, method, params, reply_type, timeout_ms,
                [this, name, done = std::move(done)](GVariant* reply, const GError* error) {
                  std::string message;
                  if (error != nullptr) {
                    message = error->message;
                    std::string remote = ErrorName(error);
                    if (remote.find(".Denied") != std::string::npos ||
                        remote == "org.freedesktop.DBus.Error.ServiceUnknown") {
                      Check(true);
                    }
                    // Input refused on the lock screen is expected; the rest is worth a line.
                    if (remote.find(".Locked") == std::string::npos) {
                      WSN_LOG("capture: helper %s failed: %s", name.c_str(), error->message);
                    }
                  }
                  if (done) done(reply, message);
                });
}

void ShellHelper::ListWindows(std::function<void(bool ok, std::vector<HelperWindow> windows, bool locked)> done) {
  Call("ListWindows", nullptr, "(aa{sv}a{sv})", [done = std::move(done)](GVariant* reply, const std::string& error) {
    std::vector<HelperWindow> windows;
    bool locked = false;
    if (reply == nullptr) {
      // The helper names no windows while the session is locked.
      bool refused_locked = error.find("Locked") != std::string::npos;
      done(refused_locked, windows, refused_locked);
      return;
    }
    GVariant* list = g_variant_get_child_value(reply, 0);
    GVariant* info = g_variant_get_child_value(reply, 1);
    gboolean is_locked = FALSE;
    if (g_variant_lookup(info, "locked", "b", &is_locked)) locked = is_locked;
    GVariantIter iter;
    g_variant_iter_init(&iter, list);
    GVariant* dict = nullptr;
    while ((dict = g_variant_iter_next_value(&iter)) != nullptr) {
      HelperWindow w;
      const gchar* text = nullptr;
      gboolean flag = FALSE;
      guint64 window_id = 0;
      Lookup(dict, "id", "u", &w.id);
      if (Lookup(dict, "windowId", "t", &window_id)) w.window_id = window_id;
      if (Lookup(dict, "title", "&s", &text)) w.title = text;
      if (Lookup(dict, "appId", "&s", &text)) w.app_id = text;
      if (Lookup(dict, "appName", "&s", &text)) w.app_name = text;
      Lookup(dict, "pid", "i", &w.pid);
      Lookup(dict, "x", "i", &w.frame.x);
      Lookup(dict, "y", "i", &w.frame.y);
      Lookup(dict, "width", "i", &w.frame.width);
      Lookup(dict, "height", "i", &w.frame.height);
      Lookup(dict, "monitor", "i", &w.monitor);
      if (Lookup(dict, "minimized", "b", &flag)) w.minimized = flag;
      if (Lookup(dict, "focused", "b", &flag)) w.focused = flag;
      if (Lookup(dict, "maximized", "b", &flag)) w.maximized = flag;
      if (Lookup(dict, "fullscreen", "b", &flag)) w.fullscreen = flag;
      if (Lookup(dict, "onCurrentWorkspace", "b", &flag)) w.on_current_workspace = flag;
      if (Lookup(dict, "staged", "b", &flag)) w.staged = flag;
      Lookup(dict, "type", "i", &w.type);
      Lookup(dict, "transientFor", "u", &w.transient_for);
      windows.push_back(std::move(w));
      g_variant_unref(dict);
    }
    g_variant_unref(list);
    g_variant_unref(info);
    done(true, std::move(windows), locked);
  });
}

void ShellHelper::Stage(uint32_t id, const Rect& rect,
                        std::function<void(bool ok, Rect frame, const std::string& error)> done) {
  Call("Stage", g_variant_new("(uiiii)", id, rect.x, rect.y, rect.width, rect.height), "(iiiii)",
       [done = std::move(done)](GVariant* reply, const std::string& error) {
         Rect frame;
         if (reply == nullptr) {
           done(false, frame, error);
           return;
         }
         gint32 monitor = 0;
         g_variant_get(reply, "(iiiii)", &frame.x, &frame.y, &frame.width, &frame.height, &monitor);
         done(true, frame, "");
       },
       8000);
}

void ShellHelper::Unstage(uint32_t id, Done done) {
  Call("Unstage", g_variant_new("(u)", id), "(b)", [done = std::move(done)](GVariant* reply, const std::string& error) {
    if (done) done(reply != nullptr, error);
  });
}

void ShellHelper::Activate(uint32_t id) { Call("Activate", g_variant_new("(u)", id), "(b)", {}); }

void ShellHelper::Unminimize(uint32_t id) { Call("Unminimize", g_variant_new("(u)", id), nullptr, {}); }

void ShellHelper::Close(uint32_t id) { Call("Close", g_variant_new("(u)", id), nullptr, {}); }

void ShellHelper::EvictStrangers(const Rect& rect, uint32_t keep) {
  Call("EvictStrangers", g_variant_new("(iiiiu)", rect.x, rect.y, rect.width, rect.height, keep), "(u)", {});
}

void ShellHelper::SetFence(const Rect& rect, bool on) {
  Call("SetFence", g_variant_new("(iiiib)", rect.x, rect.y, rect.width, rect.height, on), nullptr, {});
}

void ShellHelper::Pointer(uint32_t kind, uint32_t button, double x, double y) {
  Call("Pointer", g_variant_new("(uudd)", kind, button, x, y), nullptr, {});
}

void ShellHelper::Scroll(double x, double y, double dx, double dy, uint32_t source, bool finish) {
  Call("Scroll", g_variant_new("(ddddub)", x, y, dx, dy, source, finish), nullptr, {});
}

void ShellHelper::Key(uint32_t evdev, bool down) { Call("Key", g_variant_new("(ub)", evdev, down), nullptr, {}); }

void ShellHelper::Keyval(uint32_t keysym, bool down) {
  Call("Keyval", g_variant_new("(ub)", keysym, down), nullptr, {});
}

void ShellHelper::Text(const std::string& text) {
  Call("Text", g_variant_new("(s)", text.c_str()), "(s)", {});
}

void ShellHelper::WarpHome() { Call("WarpHome", nullptr, nullptr, {}); }

void ShellHelper::ReleaseInput() { Call("ReleaseInput", nullptr, nullptr, {}); }

void ShellHelper::Thumbnail(uint32_t id, int max_edge, std::function<void(bool ok, std::vector<uint8_t> jpeg)> done) {
  Call("Thumbnail", g_variant_new("(ui)", id, max_edge), "(ay)",
       [done = std::move(done)](GVariant* reply, const std::string&) {
         std::vector<uint8_t> jpeg;
         if (reply == nullptr) {
           done(false, jpeg);
           return;
         }
         GVariant* bytes = g_variant_get_child_value(reply, 0);
         gsize size = 0;
         const auto* data = static_cast<const uint8_t*>(g_variant_get_fixed_array(bytes, &size, 1));
         jpeg.assign(data, data + size);
         g_variant_unref(bytes);
         done(!jpeg.empty(), std::move(jpeg));
       });
}

}  // namespace wsn::capture
