#include "capture/kwin_helper.h"

#include <fcntl.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gdesktopappinfo.h>
#include <gio/gunixfdlist.h>
#include <glib/gstdio.h>
#include <poll.h>
#include <stdlib.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <thread>

#include "capture/bus.h"
#include "capture/capture_thread.h"
#include "capture/kwin_script.h"
#include "capture/kwin_wayland.h"
#include "common/log.h"
#include "window_stream_native.h"

namespace wsn::capture {

namespace {

constexpr const char* kPath = "/com/vireen/Whisper/KWin";
constexpr const char* kScriptName = "whisper-window-stream";
constexpr int64_t kRecheckUs = 2 * G_USEC_PER_SEC;
// A command the script has not answered by then fails, and the script is
// loaded again at the next check.
constexpr int64_t kCommandTimeoutUs = 3 * G_USEC_PER_SEC;
// KWin gives up on a call after 25 s; the script's waiting Poll is answered
// before that.
constexpr int64_t kKeepAliveUs = 15 * G_USEC_PER_SEC;
// How long a just-written .desktop file may take to reach KWin.
constexpr int64_t kFreshPermissionUs = 4 * G_USEC_PER_SEC;
// Waited before reading where a moved window settled (the app answers
// KWin's configure first).
constexpr guint kSettleMs = 200;

constexpr const char* kIntrospection =
    "<node><interface name='com.vireen.Whisper.KWin1'>"
    "<method name='Poll'><arg type='a{sv}' name='reply' direction='in'/>"
    "<arg type='a{sv}' name='command' direction='out'/></method>"
    "<method name='Event'><arg type='a{sv}' name='event' direction='in'/></method>"
    "</interface></node>";

// Linux button codes.
constexpr uint32_t kButtonLeft = 0x110;
constexpr uint32_t kButtonRight = 0x111;
constexpr uint32_t kButtonMiddle = 0x112;
// A wheel click, in wl_pointer axis units.
constexpr double kWheelStep = 15;

constexpr const char* kPermissionFile = "whisper-window-flow.desktop";
constexpr const char* kWaylandInterfaces = "zkde_screencast_unstable_v1,org_kde_kwin_fake_input";
constexpr const char* kDbusInterfaces = "org.kde.KWin.ScreenShot2";

// ---------------------------------------------------------------- a{sv}

GVariant* Value(GVariant* dict, const char* key) {
  if (dict == nullptr || !g_variant_is_of_type(dict, G_VARIANT_TYPE_VARDICT)) return nullptr;
  GVariant* value = g_variant_lookup_value(dict, key, nullptr);
  // Values QtDBus sends inside a variant come boxed once more.
  while (value != nullptr && g_variant_is_of_type(value, G_VARIANT_TYPE_VARIANT)) {
    GVariant* inner = g_variant_get_variant(value);
    g_variant_unref(value);
    value = inner;
  }
  return value;
}

double Number(GVariant* dict, const char* key, double fallback = 0) {
  GVariant* value = Value(dict, key);
  if (value == nullptr) return fallback;
  double result = fallback;
  const GVariantType* type = g_variant_get_type(value);
  if (g_variant_type_equal(type, G_VARIANT_TYPE_DOUBLE)) result = g_variant_get_double(value);
  else if (g_variant_type_equal(type, G_VARIANT_TYPE_INT32)) result = g_variant_get_int32(value);
  else if (g_variant_type_equal(type, G_VARIANT_TYPE_UINT32)) result = g_variant_get_uint32(value);
  else if (g_variant_type_equal(type, G_VARIANT_TYPE_INT64)) result = static_cast<double>(g_variant_get_int64(value));
  else if (g_variant_type_equal(type, G_VARIANT_TYPE_UINT64)) result = static_cast<double>(g_variant_get_uint64(value));
  else if (g_variant_type_equal(type, G_VARIANT_TYPE_INT16)) result = g_variant_get_int16(value);
  else if (g_variant_type_equal(type, G_VARIANT_TYPE_BYTE)) result = g_variant_get_byte(value);
  g_variant_unref(value);
  return result;
}

int Int(GVariant* dict, const char* key) { return static_cast<int>(std::lround(Number(dict, key))); }

bool Bool(GVariant* dict, const char* key) {
  GVariant* value = Value(dict, key);
  bool result = value != nullptr && g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN) && g_variant_get_boolean(value);
  if (value != nullptr) g_variant_unref(value);
  return result;
}

std::string String(GVariant* dict, const char* key) {
  GVariant* value = Value(dict, key);
  std::string result;
  if (value != nullptr && g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) result = g_variant_get_string(value, nullptr);
  if (value != nullptr) g_variant_unref(value);
  return result;
}

// The dictionaries in an array value (QtDBus: av of a{sv}).
std::vector<GVariant*> Dicts(GVariant* dict, const char* key) {
  std::vector<GVariant*> items;
  GVariant* value = Value(dict, key);
  if (value == nullptr) return items;
  if (g_variant_is_container(value)) {
    gsize count = g_variant_n_children(value);
    for (gsize i = 0; i < count; i++) {
      GVariant* item = g_variant_get_child_value(value, i);
      while (item != nullptr && g_variant_is_of_type(item, G_VARIANT_TYPE_VARIANT)) {
        GVariant* inner = g_variant_get_variant(item);
        g_variant_unref(item);
        item = inner;
      }
      if (item != nullptr && g_variant_is_of_type(item, G_VARIANT_TYPE_VARDICT)) {
        items.push_back(item);
      } else if (item != nullptr) {
        g_variant_unref(item);
      }
    }
  }
  g_variant_unref(value);
  return items;
}

struct Arg {
  const char* key;
  GVariant* value;
};

// A command: {op, seq, args...} (floating).
GVariant* Cmd(const char* op, uint32_t seq, std::initializer_list<Arg> args) {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&builder, "{sv}", "op", g_variant_new_string(op));
  g_variant_builder_add(&builder, "{sv}", "seq", g_variant_new_int32(static_cast<int32_t>(seq)));
  for (const Arg& arg : args) g_variant_builder_add(&builder, "{sv}", arg.key, arg.value);
  return g_variant_builder_end(&builder);
}

GVariant* I(int value) { return g_variant_new_int32(value); }

// ---------------------------------------------------------------- bus object

void OnMethodCall(GDBusConnection*, const gchar* sender, const gchar*, const gchar*, const gchar* method,
                  GVariant* params, GDBusMethodInvocation* invocation, gpointer) {
  // Only KWin (the script runs inside it) may drive this.
  static std::string kwin;
  if (sender == nullptr || kwin != sender) kwin = OwnerOf("org.kde.KWin");
  if (sender == nullptr || kwin.empty() || kwin != sender) {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.AccessDenied",
                                               "only KWin may call this");
    return;
  }
  GVariant* dict = g_variant_get_child_value(params, 0);
  if (std::strcmp(method, "Poll") == 0) {
    KWinHelper::Get().OnPoll(dict, invocation);
  } else {
    KWinHelper::Get().OnEvent(dict);
    g_dbus_method_invocation_return_value(invocation, nullptr);
  }
  g_variant_unref(dict);
}

const GDBusInterfaceVTable kVTable = {OnMethodCall, nullptr, nullptr, {nullptr}};

// ---------------------------------------------------------------- permission

std::string Canonical(const std::string& path) {
  char* resolved = realpath(path.c_str(), nullptr);
  std::string value = resolved != nullptr ? resolved : "";
  free(resolved);
  return value;
}

std::string OwnExecutable() {
  gchar* target = g_file_read_link("/proc/self/exe", nullptr);
  std::string value = target != nullptr ? Canonical(target) : "";
  g_free(target);
  return value;
}

// The executable a desktop entry's Exec line starts, resolved like KWin
// does (QFileInfo::canonicalFilePath of the first word).
std::string ExecOf(GKeyFile* file) {
  gchar* exec = g_key_file_get_string(file, G_KEY_FILE_DESKTOP_GROUP, G_KEY_FILE_DESKTOP_KEY_EXEC, nullptr);
  if (exec == nullptr) return "";
  gchar** argv = nullptr;
  std::string program;
  if (g_shell_parse_argv(exec, nullptr, &argv, nullptr) && argv != nullptr && argv[0] != nullptr) {
    program = Canonical(argv[0]);
  }
  g_strfreev(argv);
  g_free(exec);
  return program;
}

bool Lists(const std::string& value, const char* wanted) {
  gchar** wanted_items = g_strsplit(wanted, ",", -1);
  bool all = true;
  for (gchar** item = wanted_items; *item != nullptr && all; item++) {
    bool found = false;
    gchar** have = g_strsplit_set(value.c_str(), ",;", -1);
    for (gchar** h = have; *h != nullptr && !found; h++) found = std::strcmp(g_strstrip(*h), *item) == 0;
    g_strfreev(have);
    all = found;
  }
  g_strfreev(wanted_items);
  return all;
}

std::string KeyString(GKeyFile* file, const char* key) {
  gchar* value = g_key_file_get_string(file, G_KEY_FILE_DESKTOP_GROUP, key, nullptr);
  std::string result = value != nullptr ? value : "";
  g_free(value);
  return result;
}

// Exec quoting (Desktop Entry spec): only when needed, and the backslashes
// once more for the string value.
std::string QuoteExec(const std::string& path) {
  if (path.find_first_of(" \t\n\"'\\><~|&;$*?#()`") == std::string::npos) return path;
  std::string quoted = "\"";
  for (char c : path) {
    if (c == '"' || c == '`' || c == '$' || c == '\\') quoted += "\\\\";
    quoted += c;
  }
  return quoted + "\"";
}

}  // namespace

bool EnsureKWinPermission(std::string* why, int64_t* written_at) {
  static std::string granted_for;
  static int64_t wrote_at = 0;
  if (written_at != nullptr) *written_at = wrote_at;
  std::string exe = OwnExecutable();
  if (exe.empty()) {
    if (why != nullptr) *why = "cannot read /proc/self/exe";
    return false;
  }
  if (granted_for == exe) return true;
  std::vector<std::string> dirs = {std::string(g_get_user_data_dir()) + "/applications"};
  for (const gchar* const* dir = g_get_system_data_dirs(); *dir != nullptr; dir++) {
    dirs.push_back(std::string(*dir) + "/applications");
  }
  std::string own_path = dirs.front() + "/" + kPermissionFile;
  bool granted = false;
  std::string bare;  // a matching entry that does not grant them
  for (const std::string& dir : dirs) {
    GDir* listing = g_dir_open(dir.c_str(), 0, nullptr);
    if (listing == nullptr) continue;
    const gchar* name;
    while ((name = g_dir_read_name(listing)) != nullptr) {
      if (!g_str_has_suffix(name, ".desktop")) continue;
      std::string path = dir + "/" + name;
      GKeyFile* file = g_key_file_new();
      if (g_key_file_load_from_file(file, path.c_str(), G_KEY_FILE_NONE, nullptr) && ExecOf(file) == exe) {
        if (Lists(KeyString(file, "X-KDE-Wayland-Interfaces"), kWaylandInterfaces)) {
          granted = true;
        } else if (path != own_path) {
          bare = path;
        }
      }
      g_key_file_free(file);
    }
    g_dir_close(listing);
  }
  if (!granted) {
    std::string content = std::string("[Desktop Entry]\n") +
                          "Type=Application\n"
                          "Name=Whisper\n"
                          "Comment=Lets devices you trust show and use this computer's windows (Whisper window "
                          "flow)\n"
                          "Exec=" + QuoteExec(exe) + "\n" +
                          "Icon=whisper\n"
                          "NoDisplay=true\n"
                          "X-KDE-Wayland-Interfaces=" + kWaylandInterfaces + "\n" +
                          "X-KDE-DBUS-Restricted-Interfaces=" + kDbusInterfaces + "\n";
    g_mkdir_with_parents(dirs.front().c_str(), 0700);
    GError* error = nullptr;
    if (!g_file_set_contents(own_path.c_str(), content.c_str(), -1, &error)) {
      if (why != nullptr) *why = std::string("cannot write ") + own_path + ": " + (error ? error->message : "?");
      if (error != nullptr) g_error_free(error);
      return false;
    }
    WSN_LOG("capture: wrote %s for KWin", own_path.c_str());
    wrote_at = g_get_monotonic_time();
    if (written_at != nullptr) *written_at = wrote_at;
  }
  // KWin uses the first entry it finds for the executable.
  if (!bare.empty()) WSN_LOG("capture: %s names this executable without KWin's protocols", bare.c_str());
  granted_for = exe;
  return true;
}

KWinHelper& KWinHelper::Get() {
  static KWinHelper* helper = new KWinHelper();
  return *helper;
}

bool KWinHelper::Register() {
  if (object_id_ != 0) return true;
  GDBusConnection* bus = Bus();
  if (bus == nullptr) return false;
  GError* error = nullptr;
  GDBusNodeInfo* node = g_dbus_node_info_new_for_xml(kIntrospection, &error);
  if (node != nullptr) {
    object_id_ = g_dbus_connection_register_object(bus, kPath, node->interfaces[0], &kVTable, nullptr, nullptr, &error);
    g_dbus_node_info_unref(node);
  }
  if (object_id_ == 0) {
    WSN_LOG("capture: cannot export %s: %s", kPath, error != nullptr ? error->message : "?");
  }
  if (error != nullptr) g_error_free(error);
  return object_id_ != 0;
}

bool KWinHelper::LoadScript(std::string* why) {
  std::string script = kKWinScript;
  auto replace = [&script](const std::string& from, const std::string& to) {
    for (size_t at = script.find(from); at != std::string::npos; at = script.find(from, at + to.size())) {
      script.replace(at, from.size(), to);
    }
  };
  replace("%SERVICE%", BusName());
  replace("%VERSION%", std::to_string(kKWinScriptVersion));
  const char* runtime = g_get_user_runtime_dir();
  std::string file = std::string(runtime != nullptr ? runtime : g_get_tmp_dir()) + "/whisper-window-stream-kwin.js";
  GError* error = nullptr;
  if (!g_file_set_contents(file.c_str(), script.c_str(), -1, &error)) {
    if (why != nullptr) *why = std::string("cannot write the KWin script: ") + (error ? error->message : "?");
    if (error != nullptr) g_error_free(error);
    return false;
  }
  g_chmod(file.c_str(), 0600);
  // An earlier run's script (same name) goes first.
  GVariant* reply = CallSync("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript",
                             g_variant_new("(s)", kScriptName), "(b)", 2000, nullptr);
  if (reply != nullptr) g_variant_unref(reply);
  reply = CallSync("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "loadScript",
                   g_variant_new("(ss)", file.c_str(), kScriptName), "(i)", 2000, &error);
  gint32 id = -1;
  if (reply != nullptr) {
    g_variant_get(reply, "(i)", &id);
    g_variant_unref(reply);
  }
  if (id < 0) {
    if (why != nullptr) *why = std::string("KWin did not load the script: ") + (error ? error->message : "refused");
    if (error != nullptr) g_error_free(error);
    return false;
  }
  std::string object = "/Scripting/Script" + std::to_string(id);
  reply = CallSync("org.kde.KWin", object.c_str(), "org.kde.kwin.Script", "run", nullptr, nullptr, 2000, &error);
  if (reply == nullptr) {
    if (why != nullptr) *why = std::string("KWin did not run the script: ") + (error ? error->message : "?");
    if (error != nullptr) g_error_free(error);
    return false;
  }
  g_variant_unref(reply);
  FailAll("script reloaded");
  if (held_ != nullptr) {
    // The old script's call; it is gone.
    g_dbus_method_invocation_return_value(held_, g_variant_new("(@a{sv})", Cmd("nop", 0, {})));
    held_ = nullptr;
  }
  script_name_ = kScriptName;
  script_running_ = false;
  script_loaded_at_ = g_get_monotonic_time();
  active_ = 0;
  WSN_LOG("capture: KWin script loaded (%s)", object.c_str());
  return true;
}

// KWin reads new .desktop files when it next looks (at most every 1.5 s
// or so): right after ours was written, a refusal is asked again.
bool KWinHelper::Connect(int64_t written_at, std::string* why) {
  while (!kwin::Connect(why)) {
    if (written_at == 0 || g_get_monotonic_time() - written_at > kFreshPermissionUs) return false;
    g_usleep(250 * 1000);
  }
  why->clear();
  return true;
}

HelperState KWinHelper::Check(bool force) {
  int64_t now = g_get_monotonic_time();
  if (!force && checked_at_ != 0 && now - checked_at_ < kRecheckUs) return state_;
  checked_at_ = now;
  HelperState previous = state_;
  std::string why;
  int64_t written_at = 0;
  if (Bus() == nullptr) {
    state_ = HelperState::kNoBus;
  } else if (!EnsureKWinPermission(&why, &written_at) || !Connect(written_at, &why)) {
    state_ = HelperState::kDenied;
  } else if (!Register()) {
    state_ = HelperState::kMissing;
  } else {
    // Loaded again when it never answered (KWin restarted scripting, say).
    bool load = script_name_.empty() || (!script_running_ && now - script_loaded_at_ > kCommandTimeoutUs);
    state_ = !load || LoadScript(&why) ? HelperState::kReady : HelperState::kMissing;
  }
  if (state_ != previous || (state_ != HelperState::kReady && !why.empty())) {
    WSN_LOG("capture: KWin helper %s%s%s", HelperStateName(state_), why.empty() ? "" : ": ", why.c_str());
  }
  if (expire_timer_ == 0 && state_ == HelperState::kReady) Expire();
  return state_;
}

// ---------------------------------------------------------------- commands

void KWinHelper::Send(GVariant* body, Result done) {
  Command command;
  command.body = g_variant_ref_sink(body);
  command.seq = static_cast<uint32_t>(Number(command.body, "seq"));
  command.done = std::move(done);
  if (state_ != HelperState::kReady) {
    g_variant_unref(command.body);
    if (command.done) command.done(nullptr, std::string("KWin helper ") + HelperStateName(state_));
    return;
  }
  queue_.push_back(std::move(command));
  Pump();
}

void KWinHelper::Pump() {
  if (held_ == nullptr || inflight_.seq != 0 || queue_.empty()) return;
  inflight_ = std::move(queue_.front());
  queue_.pop_front();
  inflight_.sent_at = g_get_monotonic_time();
  GDBusMethodInvocation* invocation = held_;
  held_ = nullptr;
  g_dbus_method_invocation_return_value(invocation, g_variant_new("(@a{sv})", inflight_.body));
  g_variant_unref(inflight_.body);
  inflight_.body = nullptr;
}

void KWinHelper::OnPoll(GVariant* reply, GDBusMethodInvocation* invocation) {
  if (!script_running_) WSN_LOG("capture: KWin script running");
  script_running_ = true;
  uint32_t re = static_cast<uint32_t>(Number(reply, "re"));
  if (inflight_.seq != 0 && re == inflight_.seq) {
    Command done = std::move(inflight_);
    inflight_ = Command();
    std::string error = String(reply, "error");
    if (!error.empty()) WSN_TRACE("capture: KWin script: %s", error.c_str());
    if (done.done) done.done(error.empty() ? reply : nullptr, error);
  }
  if (held_ != nullptr) {
    g_dbus_method_invocation_return_value(held_, g_variant_new("(@a{sv})", Cmd("nop", 0, {})));
  }
  held_ = invocation;
  held_at_ = g_get_monotonic_time();
  Pump();
}

void KWinHelper::OnEvent(GVariant* event) {
  std::string type = String(event, "type");
  uint32_t id = static_cast<uint32_t>(Number(event, "id"));
  if (type == "active") {
    active_ = id;
  } else if (type == "gone") {
    uuids_.erase(id);
    if (active_ == id) active_ = 0;
    if (handlers_.window_gone) handlers_.window_gone(id);
  }
}

void KWinHelper::FailAll(const std::string& why) {
  std::vector<Command> failed;
  if (inflight_.seq != 0) failed.push_back(std::move(inflight_));
  inflight_ = Command();
  for (auto& command : queue_) failed.push_back(std::move(command));
  queue_.clear();
  for (auto& command : failed) {
    if (command.body != nullptr) g_variant_unref(command.body);
    if (command.done) command.done(nullptr, why);
  }
}

void KWinHelper::Expire() {
  expire_timer_ = PostAfter(1000, [this] {
    expire_timer_ = 0;
    int64_t now = g_get_monotonic_time();
    bool stuck = inflight_.seq != 0 && now - inflight_.sent_at > kCommandTimeoutUs;
    bool silent = !script_running_ && !queue_.empty() && now - script_loaded_at_ > kCommandTimeoutUs;
    if (stuck || silent) {
      WSN_LOG("capture: KWin script does not answer");
      script_running_ = false;
      FailAll("the KWin script does not answer");
      if (handlers_.vanished) handlers_.vanished();
      checked_at_ = 0;  // load it again at the next check
    } else if (held_ != nullptr && now - held_at_ > kKeepAliveUs) {
      Send(Cmd("nop", next_seq_++, {}), {});
    }
    Expire();
  });
}

// ---------------------------------------------------------------- windows

bool KWinHelper::AppInfo(const std::string& app_id, std::string* name) {
  if (app_id.empty()) return false;
  auto found = app_names_.find(app_id);
  if (found != app_names_.end()) {
    *name = found->second;
    return true;
  }
  // KWin reports the Wayland app id whether or not an installed .desktop
  // file has it; only one that does counts (looked up again next time).
  GDesktopAppInfo* info = g_desktop_app_info_new(app_id.c_str());
  if (info == nullptr) return false;
  const char* app_name = g_app_info_get_name(G_APP_INFO(info));
  *name = app_name != nullptr && *app_name != '\0' ? app_name : app_id;
  g_object_unref(info);
  app_names_[app_id] = *name;
  return true;
}

void KWinHelper::ListWindows(std::function<void(bool ok, std::vector<HelperWindow> windows, bool locked)> done) {
  if (Check() != HelperState::kReady) {
    done(false, {}, false);
    return;
  }
  // Nothing is listed while the screen is locked (as on GNOME).
  capture::Call("org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver", "GetActive", nullptr,
                "(b)", 1000, [this, done](GVariant* result, const GError*) {
                  gboolean locked = FALSE;
                  if (result != nullptr) g_variant_get(result, "(b)", &locked);
                  if (locked) {
                    done(true, {}, true);
                    return;
                  }
                  Send(Cmd("list", next_seq_++, {}), [this, done](GVariant* reply, const std::string&) {
                    if (reply == nullptr) {
                      done(false, {}, false);
                      return;
                    }
                    std::vector<HelperWindow> windows;
                    uuids_.clear();
                    for (GVariant* item : Dicts(reply, "windows")) {
                      HelperWindow w;
                      w.id = static_cast<uint32_t>(Number(item, "id"));
                      w.uuid = String(item, "uuid");
                      w.title = String(item, "title");
                      std::string desktop = String(item, "desktopFile");
                      if (!desktop.empty() && !g_str_has_suffix(desktop.c_str(), ".desktop")) desktop += ".desktop";
                      // Like GNOME's: the .desktop id of a known app, else "".
                      w.app_name = String(item, "resourceClass");
                      if (AppInfo(desktop, &w.app_name)) w.app_id = desktop;
                      w.pid = Int(item, "pid");
                      w.frame = Rect{Int(item, "x"), Int(item, "y"), Int(item, "width"), Int(item, "height")};
                      w.minimized = Bool(item, "minimized");
                      w.focused = Bool(item, "focused");
                      w.maximized = Bool(item, "maximized");
                      w.fullscreen = Bool(item, "fullscreen");
                      w.on_current_workspace = Bool(item, "onCurrentDesktop");
                      w.staged = Bool(item, "staged");
                      w.type = Int(item, "type");
                      w.transient_for = static_cast<uint32_t>(Number(item, "transientFor"));
                      if (w.focused) active_ = w.id;
                      uuids_[w.id] = w.uuid;
                      windows.push_back(std::move(w));
                      g_variant_unref(item);
                    }
                    done(true, std::move(windows), false);
                  });
                });
}

void KWinHelper::Stage(uint32_t id, const Rect& rect,
                       std::function<void(bool ok, Rect frame, const std::string& error)> done) {
  Send(Cmd("stage", next_seq_++,
               {{"id", I(static_cast<int>(id))}, {"x", I(rect.x)}, {"y", I(rect.y)}, {"width", I(rect.width)},
                {"height", I(rect.height)}}),
       [this, id, done](GVariant* reply, const std::string& error) {
         if (reply == nullptr) {
           done(false, Rect(), error);
           return;
         }
         // Where it settled, once the app took the new size.
         PostAfter(kSettleMs, [this, id, done] {
           Send(Cmd("get", next_seq_++, {{"id", I(static_cast<int>(id))}}),
                [done](GVariant* window, const std::string& error) {
                  if (window == nullptr) {
                    done(false, Rect(), error);
                    return;
                  }
                  done(true, Rect{Int(window, "x"), Int(window, "y"), Int(window, "width"), Int(window, "height")}, "");
                });
         });
       });
}

void KWinHelper::Unstage(uint32_t id, Done done) {
  Send(Cmd("unstage", next_seq_++, {{"id", I(static_cast<int>(id))}}),
       [done](GVariant* reply, const std::string& error) {
         if (done) done(reply != nullptr && Bool(reply, "restored"), error);
       });
}

void KWinHelper::Activate(uint32_t id) {
  if (active_ == id) return;
  // Keys must reach the window, not the one active before it.
  waits_++;
  Send(Cmd("activate", next_seq_++, {{"id", I(static_cast<int>(id))}}),
       [this, id](GVariant* reply, const std::string&) {
         if (reply != nullptr && Bool(reply, "active")) active_ = id;
         waits_--;
         Flush();
       });
}

void KWinHelper::Unminimize(uint32_t id) { Send(Cmd("unminimize", next_seq_++, {{"id", I(static_cast<int>(id))}}), {}); }

void KWinHelper::Close(uint32_t id) { Send(Cmd("close", next_seq_++, {{"id", I(static_cast<int>(id))}}), {}); }

void KWinHelper::EvictStrangers(const Rect& rect, uint32_t keep) {
  Send(Cmd("evict", next_seq_++,
               {{"x", I(rect.x)}, {"y", I(rect.y)}, {"width", I(rect.width)}, {"height", I(rect.height)},
                {"keep", I(static_cast<int>(keep))}}),
       {});
}

void KWinHelper::Thumbnail(uint32_t id, int max_edge, std::function<void(bool ok, std::vector<uint8_t> jpeg)> done) {
  auto found = uuids_.find(id);
  GDBusConnection* bus = Bus();
  int fds[2] = {-1, -1};
  if (found == uuids_.end() || bus == nullptr || pipe2(fds, O_CLOEXEC) != 0) {
    done(false, {});
    return;
  }
  GUnixFDList* list = g_unix_fd_list_new();
  gint index = g_unix_fd_list_append(list, fds[1], nullptr);
  close(fds[1]);  // the list holds its own copy until the call is sent
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "include-decoration", g_variant_new_boolean(TRUE));
  g_variant_builder_add(&options, "{sv}", "include-shadow", g_variant_new_boolean(FALSE));
  g_variant_builder_add(&options, "{sv}", "native-resolution", g_variant_new_boolean(FALSE));
  struct Pending {
    int fd;
    int edge;
    std::function<void(bool, std::vector<uint8_t>)> done;
  };
  auto* pending = new Pending{fds[0], max_edge, std::move(done)};
  g_dbus_connection_call_with_unix_fd_list(
      bus, "org.kde.KWin.ScreenShot2", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", "CaptureWindow",
      g_variant_new("(sa{sv}h)", found->second.c_str(), &options, index), G_VARIANT_TYPE("(a{sv})"),
      G_DBUS_CALL_FLAGS_NONE, 4000, list, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer data) {
        std::unique_ptr<Pending> pending(static_cast<Pending*>(data));
        GError* error = nullptr;
        GVariant* reply =
            g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(source), nullptr, result, &error);
        if (reply == nullptr) {
          WSN_LOG("capture: KWin window screenshot failed: %s", error != nullptr ? error->message : "?");
          if (error != nullptr) g_error_free(error);
          close(pending->fd);
          pending->done(false, {});
          return;
        }
        GVariant* meta = g_variant_get_child_value(reply, 0);
        int width = Int(meta, "width");
        int height = Int(meta, "height");
        int stride = Int(meta, "stride");
        int format = Int(meta, "format");
        g_variant_unref(meta);
        g_variant_unref(reply);
        // QImage formats 4 (RGB32), 5 (ARGB32), 6 (ARGB32 premultiplied):
        // B, G, R, A in memory.
        if (width <= 0 || height <= 0 || stride < width * 4 || format < 4 || format > 6) {
          close(pending->fd);
          pending->done(false, {});
          return;
        }
        // KWin writes the pixels after answering; read them off the thread.
        std::thread([pending = pending.release(), width, height, stride] {
          std::vector<uint8_t> pixels(static_cast<size_t>(stride) * height);
          size_t got = 0;
          while (got < pixels.size()) {
            pollfd p = {pending->fd, POLLIN, 0};
            if (poll(&p, 1, 3000) <= 0) break;
            ssize_t n = read(pending->fd, pixels.data() + got, pixels.size() - got);
            if (n <= 0) break;
            got += static_cast<size_t>(n);
          }
          close(pending->fd);
          bool complete = got == pixels.size();
          Post([pending, pixels = std::move(pixels), complete, width, height, stride]() mutable {
            std::unique_ptr<Pending> owned(pending);
            if (!complete) {
              owned->done(false, {});
              return;
            }
            GdkPixbuf* rgb = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, width, height);
            int out_stride = gdk_pixbuf_get_rowstride(rgb);
            guchar* out = gdk_pixbuf_get_pixels(rgb);
            for (int y = 0; y < height; y++) {
              const uint8_t* src = pixels.data() + static_cast<size_t>(y) * stride;
              guchar* dst = out + static_cast<size_t>(y) * out_stride;
              for (int x = 0; x < width; x++) {
                dst[x * 3] = src[x * 4 + 2];
                dst[x * 3 + 1] = src[x * 4 + 1];
                dst[x * 3 + 2] = src[x * 4];
              }
            }
            int edge = owned->edge > 0 ? owned->edge : 1024;
            double fit = std::min(1.0, static_cast<double>(edge) / std::max(width, height));
            GdkPixbuf* scaled = fit < 1 ? gdk_pixbuf_scale_simple(rgb, std::max(1, static_cast<int>(width * fit)),
                                                                  std::max(1, static_cast<int>(height * fit)),
                                                                  GDK_INTERP_BILINEAR)
                                        : static_cast<GdkPixbuf*>(g_object_ref(rgb));
            gchar* jpeg = nullptr;
            gsize length = 0;
            bool saved = scaled != nullptr &&
                         gdk_pixbuf_save_to_buffer(scaled, &jpeg, &length, "jpeg", nullptr, "quality", "80", nullptr);
            std::vector<uint8_t> bytes;
            if (saved) bytes.assign(reinterpret_cast<uint8_t*>(jpeg), reinterpret_cast<uint8_t*>(jpeg) + length);
            g_free(jpeg);
            if (scaled != nullptr) g_object_unref(scaled);
            g_object_unref(rgb);
            owned->done(saved, std::move(bytes));
          });
        }).detach();
      },
      pending);
  g_object_unref(list);
}

// ---------------------------------------------------------------- input

void KWinHelper::Input(std::function<void()> action, bool pointer) {
  if (pointer && !has_home_ && !reading_home_) {
    // Where the user's pointer is, to put it back afterwards (not when it
    // is already out on one of ours).
    reading_home_ = true;
    waits_++;
    Send(Cmd("cursor", next_seq_++, {}), [this](GVariant* reply, const std::string&) {
      if (reply != nullptr && !Bool(reply, "ours")) {
        home_x_ = Number(reply, "x");
        home_y_ = Number(reply, "y");
        has_home_ = true;
      }
      waits_--;
      Flush();
    });
  }
  if (waits_ > 0 || !input_.empty()) {
    input_.push_back(std::move(action));
    return;
  }
  action();
}

void KWinHelper::Flush() {
  while (waits_ == 0 && !input_.empty()) {
    auto action = std::move(input_.front());
    input_.pop_front();
    action();
  }
}

void KWinHelper::Pointer(uint32_t kind, uint32_t button, double x, double y) {
  Input(
      [this, kind, button, x, y] {
        kwin::PointerAbsolute(x, y);
        uint32_t code = button == 1 ? kButtonRight : button == 2 ? kButtonMiddle : kButtonLeft;
        if (kind == WSN_INPUT_POINTER_DOWN) {
          if (buttons_.insert(code).second) kwin::Button(code, true);
        } else if (kind == WSN_INPUT_POINTER_UP || kind == WSN_INPUT_POINTER_CANCEL) {
          for (uint32_t held : buttons_) kwin::Button(held, false);
          buttons_.clear();
        }
      },
      true);
}

void KWinHelper::Scroll(double x, double y, double dx, double dy, uint32_t source, bool finish) {
  Input(
      [x, y, dx, dy, source] {
        kwin::PointerAbsolute(x, y);
        // Wheel clicks; anything else is already in pixels.
        double step = source == 1 ? kWheelStep : 1;
        if (dy != 0) kwin::Axis(0, dy * step);
        if (dx != 0) kwin::Axis(1, dx * step);
      },
      true);
}

void KWinHelper::Key(uint32_t evdev, bool down) {
  Input(
      [this, evdev, down] {
        if (down) {
          keys_.insert(evdev);
        } else if (keys_.erase(evdev) == 0) {
          return;
        }
        kwin::Key(evdev, down);
      },
      false);
}

void KWinHelper::Keyval(uint32_t keysym, bool down) {
  Input(
      [this, keysym, down] {
        if (down) {
          keysyms_.insert(keysym);
        } else if (keysyms_.erase(keysym) == 0) {
          return;
        }
        kwin::Keysym(keysym, down);
      },
      false);
}

void KWinHelper::Text(const std::string& text) {
  if (!g_utf8_validate(text.c_str(), static_cast<gssize>(text.size()), nullptr)) return;
  Input(
      [text] {
        // KWin types any keysym, whatever the keyboard layout: Latin-1 as
        // itself, the rest as Unicode keysyms.
        for (const gchar* p = text.c_str(); *p != '\0'; p = g_utf8_next_char(p)) {
          gunichar c = g_utf8_get_char(p);
          if (c == '\r') continue;
          uint32_t keysym = c == '\n'   ? 0xff0d
                            : c == '\t' ? 0xff09
                            : (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0xff) ? c
                                                                                    : 0x01000000u | c;
          kwin::Keysym(keysym, true);
          kwin::Keysym(keysym, false);
        }
      },
      false);
}

void KWinHelper::WarpHome() {
  Input(
      [this] {
        if (has_home_ && buttons_.empty()) kwin::PointerAbsolute(home_x_, home_y_);
        has_home_ = false;
        reading_home_ = false;
      },
      false);
}

void KWinHelper::ReleaseInput() {
  Input(
      [this] {
        for (uint32_t held : buttons_) kwin::Button(held, false);
        for (uint32_t key : keys_) kwin::Key(key, false);
        for (uint32_t keysym : keysyms_) kwin::Keysym(keysym, false);
        buttons_.clear();
        keys_.clear();
        keysyms_.clear();
      },
      false);
}

}  // namespace wsn::capture
