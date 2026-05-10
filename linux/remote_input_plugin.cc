#include "remote_input_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <glib/gstdio.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <poll.h>
#include <unistd.h>

#if HAVE_X11_REMOTE_INPUT
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
#endif

#if HAVE_XRANDR_REMOTE_INPUT
#include <X11/extensions/Xrandr.h>
#endif

#if HAVE_XI_REMOTE_INPUT
#include <X11/extensions/XInput2.h>
#endif

#if HAVE_LIBEI_REMOTE_INPUT
#include <libei.h>
#include <linux/input-event-codes.h>
#endif

namespace {

constexpr char kRemoteInputChannel[] = "com.vireen.whisper/remote_input";
constexpr int kEdgeThreshold = 6;
constexpr int kCaptureRecenterMargin = 96;
constexpr int kCaptureCursorInset = 2;
constexpr char kShowSourceCursorEnv[] = "WHISPER_REMOTE_INPUT_SHOW_SOURCE_CURSOR";
constexpr char kDisableRawMotionEnv[] = "WHISPER_REMOTE_INPUT_DISABLE_RAW_MOTION";
constexpr char kEnableRawMotionEnv[] = "WHISPER_REMOTE_INPUT_ENABLE_RAW_MOTION";

FlValue* Lookup(FlValue* map, const char* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(map, key);
}

std::string StringValue(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return "";
  }
  const gchar* text = fl_value_get_string(value);
  return text == nullptr ? "" : text;
}

int64_t IntValue(FlValue* map, const char* key, int64_t fallback = 0) {
  FlValue* value = Lookup(map, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return fallback;
  }
  return fl_value_get_int(value);
}

double DoubleValue(FlValue* map, const char* key, double fallback = 0) {
  FlValue* value = Lookup(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    return fl_value_get_float(value);
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(value));
  }
  return fallback;
}

std::vector<uint8_t> BytesValue(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (value == nullptr ||
      fl_value_get_type(value) != FL_VALUE_TYPE_UINT8_LIST) {
    return {};
  }
  const uint8_t* bytes = fl_value_get_uint8_list(value);
  const size_t length = fl_value_get_length(value);
  if (bytes == nullptr || length == 0) {
    return {};
  }
  return std::vector<uint8_t>(bytes, bytes + length);
}

void RespondSuccess(FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  fl_method_call_respond(method_call, response, nullptr);
}

void RespondSuccessValue(FlMethodCall* method_call, FlValue* value) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(method_call, response, nullptr);
}

void RespondError(FlMethodCall* method_call,
                  const char* code,
                  const std::string& message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message.c_str(), nullptr));
  fl_method_call_respond(method_call, response, nullptr);
}

int64_t NowMicros() {
  return static_cast<int64_t>(g_get_real_time());
}

std::string PayloadString(const std::vector<uint8_t>& payload) {
  return std::string(payload.begin(), payload.end());
}

template <typename T>
class Maybe {
 public:
  Maybe() = default;
  Maybe(const T& value) : has_value_(true), value_(value) {}
  Maybe(T&& value) : has_value_(true), value_(std::move(value)) {}

  bool has_value() const {
    return has_value_;
  }

  const T& value() const {
    return value_;
  }

  const T* operator->() const {
    return &value_;
  }

  T value_or(const T& fallback) const {
    return has_value_ ? value_ : fallback;
  }

 private:
  bool has_value_ = false;
  T value_{};
};

std::string JsonEscapedString(const std::string& value) {
  std::ostringstream json;
  const char* hex = "0123456789abcdef";
  for (const unsigned char ch : value) {
    switch (ch) {
      case '"':
        json << "\\\"";
        break;
      case '\\':
        json << "\\\\";
        break;
      case '\b':
        json << "\\b";
        break;
      case '\f':
        json << "\\f";
        break;
      case '\n':
        json << "\\n";
        break;
      case '\r':
        json << "\\r";
        break;
      case '\t':
        json << "\\t";
        break;
      default:
        if (ch < 0x20) {
          json << "\\u00" << hex[(ch >> 4) & 0x0f] << hex[ch & 0x0f];
        } else {
          json << static_cast<char>(ch);
        }
        break;
    }
  }
  return json.str();
}

Maybe<uint32_t> JsonHexCodePoint(const std::string& json,
                                         size_t offset) {
  if (offset + 4 > json.size()) {
    return {};
  }
  uint32_t value = 0;
  for (size_t i = offset; i < offset + 4; i++) {
    const char ch = json[i];
    value <<= 4;
    if (ch >= '0' && ch <= '9') {
      value += static_cast<uint32_t>(ch - '0');
    } else if (ch >= 'a' && ch <= 'f') {
      value += static_cast<uint32_t>(ch - 'a' + 10);
    } else if (ch >= 'A' && ch <= 'F') {
      value += static_cast<uint32_t>(ch - 'A' + 10);
    } else {
      return {};
    }
  }
  return value;
}

void AppendUtf8(std::string& output, uint32_t code_point) {
  if (code_point <= 0x7f) {
    output.push_back(static_cast<char>(code_point));
  } else if (code_point <= 0x7ff) {
    output.push_back(static_cast<char>(0xc0 | (code_point >> 6)));
    output.push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
  } else {
    output.push_back(static_cast<char>(0xe0 | (code_point >> 12)));
    output.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
  }
}

Maybe<std::string> JsonStringValue(const std::string& json,
                                           const std::string& key) {
  const auto key_pos = json.find("\"" + key + "\"");
  if (key_pos == std::string::npos) {
    return {};
  }
  const auto colon = json.find(':', key_pos);
  if (colon == std::string::npos) {
    return {};
  }
  const auto quote = json.find('"', colon + 1);
  if (quote == std::string::npos) {
    return {};
  }
  std::string result;
  for (size_t i = quote + 1; i < json.size(); i++) {
    const char ch = json[i];
    if (ch == '"') {
      return result;
    }
    if (ch != '\\') {
      result.push_back(ch);
      continue;
    }
    if (++i >= json.size()) {
      return {};
    }
    const char escaped = json[i];
    switch (escaped) {
      case '"':
      case '\\':
      case '/':
        result.push_back(escaped);
        break;
      case 'b':
        result.push_back('\b');
        break;
      case 'f':
        result.push_back('\f');
        break;
      case 'n':
        result.push_back('\n');
        break;
      case 'r':
        result.push_back('\r');
        break;
      case 't':
        result.push_back('\t');
        break;
      case 'u': {
        const auto code_point = JsonHexCodePoint(json, i + 1);
        if (!code_point.has_value()) {
          return {};
        }
        AppendUtf8(result, code_point.value());
        i += 4;
        break;
      }
      default:
        return {};
    }
  }
  return {};
}

double JsonNumber(const std::string& json,
                  const std::string& key,
                  double fallback = 0) {
  const auto key_pos = json.find("\"" + key + "\"");
  if (key_pos == std::string::npos) {
    return fallback;
  }
  const auto colon = json.find(':', key_pos);
  if (colon == std::string::npos) {
    return fallback;
  }
  const auto start = json.find_first_of("-0123456789", colon + 1);
  if (start == std::string::npos) {
    return fallback;
  }
  const auto end = json.find_first_not_of("0123456789.-", start);
  try {
    return std::stod(json.substr(start, end - start));
  } catch (...) {
    return fallback;
  }
}

bool JsonBool(const std::string& json, const std::string& key) {
  const auto key_pos = json.find("\"" + key + "\"");
  if (key_pos == std::string::npos) {
    return false;
  }
  const auto colon = json.find(':', key_pos);
  if (colon == std::string::npos) {
    return false;
  }
  const auto value = json.find_first_not_of(" \t\r\n", colon + 1);
  return value != std::string::npos && json.compare(value, 4, "true") == 0;
}

std::string JsonString(const std::string& json,
                       const std::string& key,
                       const std::string& fallback = "") {
  return JsonStringValue(json, key).value_or(fallback);
}

std::vector<uint8_t> JsonBytes(const std::string& json) {
  return std::vector<uint8_t>(json.begin(), json.end());
}

double ClampedUnit(double value) {
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}

int ClampInt(int value, int minimum, int maximum) {
  if (value < minimum) {
    return minimum;
  }
  if (value > maximum) {
    return maximum;
  }
  return value;
}

bool ShouldShowSourceCursor() {
  const char* value = std::getenv(kShowSourceCursorEnv);
  return value != nullptr && std::strcmp(value, "1") == 0;
}

bool ShouldDisableRawMotion() {
  const char* disable_value = std::getenv(kDisableRawMotionEnv);
  if (disable_value != nullptr && std::strcmp(disable_value, "1") == 0) {
    return true;
  }
  const char* enable_value = std::getenv(kEnableRawMotionEnv);
  return enable_value == nullptr || std::strcmp(enable_value, "1") != 0;
}

bool ShouldTraceRemoteInput() {
  const char* value = std::getenv("WHISPER_REMOTE_INPUT_TRACE");
  return value != nullptr && std::strcmp(value, "1") == 0;
}

void TraceRemoteInput(const std::string& message) {
  if (!ShouldTraceRemoteInput()) {
    return;
  }
  g_printerr("%s\n", message.c_str());
}

#if HAVE_X11_REMOTE_INPUT
bool IsLinuxDesktopLocked() {
  GError* error = nullptr;
  GDBusConnection* connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (connection == nullptr) {
    if (error != nullptr) {
      g_error_free(error);
    }
    return false;
  }
  GVariant* result = g_dbus_connection_call_sync(
      connection, "org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
      "org.gnome.ScreenSaver", "GetActive", nullptr, G_VARIANT_TYPE("(b)"),
      G_DBUS_CALL_FLAGS_NONE, 300, nullptr, &error);
  g_object_unref(connection);
  if (result == nullptr) {
    if (error != nullptr) {
      g_error_free(error);
    }
    return false;
  }
  gboolean active = FALSE;
  g_variant_get(result, "(b)", &active);
  g_variant_unref(result);
  return active == TRUE;
}
#endif

#if HAVE_LIBEI_REMOTE_INPUT && HAVE_X11_REMOTE_INPUT
constexpr char kPortalBusName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalObjectPath[] = "/org/freedesktop/portal/desktop";
constexpr char kPortalRemoteDesktopInterface[] =
    "org.freedesktop.portal.RemoteDesktop";
constexpr char kPortalInputCaptureInterface[] =
    "org.freedesktop.portal.InputCapture";
constexpr uint32_t kPortalKeyboardDevice = 1;
constexpr uint32_t kPortalPointerDevice = 2;

struct PortalResponse {
  uint32_t response = 2;
  GVariant* results = nullptr;
};

struct PortalResponseWaiter {
  GMainLoop* loop = nullptr;
  bool done = false;
  bool timed_out = false;
  PortalResponse response;
};

gboolean PortalResponseTimeout(gpointer user_data) {
  auto* waiter = static_cast<PortalResponseWaiter*>(user_data);
  waiter->timed_out = true;
  waiter->done = true;
  if (waiter->loop != nullptr) {
    g_main_loop_quit(waiter->loop);
  }
  return G_SOURCE_REMOVE;
}

void PortalResponseCallback(GDBusConnection*,
                            const gchar*,
                            const gchar*,
                            const gchar*,
                            const gchar*,
                            GVariant* parameters,
                            gpointer user_data) {
  auto* waiter = static_cast<PortalResponseWaiter*>(user_data);
  guint32 response = 2;
  GVariant* results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &response, &results);
  waiter->response.response = response;
  waiter->response.results = results;
  waiter->done = true;
  if (waiter->loop != nullptr) {
    g_main_loop_quit(waiter->loop);
  }
}

bool WaitPortalResponse(GDBusConnection* connection,
                        const std::string& request_path,
                        int timeout_ms,
                        PortalResponse* response,
                        std::string* error) {
  PortalResponseWaiter waiter;
  waiter.loop = g_main_loop_new(nullptr, FALSE);
  const guint signal_id = g_dbus_connection_signal_subscribe(
      connection, kPortalBusName, "org.freedesktop.portal.Request", "Response",
      request_path.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      PortalResponseCallback, &waiter, nullptr);
  const guint timeout_id =
      g_timeout_add(timeout_ms, PortalResponseTimeout, &waiter);
  g_main_loop_run(waiter.loop);
  if (timeout_id != 0 && !waiter.timed_out) {
    g_source_remove(timeout_id);
  }
  g_dbus_connection_signal_unsubscribe(connection, signal_id);
  g_main_loop_unref(waiter.loop);
  if (!waiter.done || waiter.response.results == nullptr) {
    *error = "Timed out waiting for Linux remote desktop permission";
    return false;
  }
  if (waiter.response.response != 0) {
    if (waiter.response.results != nullptr) {
      g_variant_unref(waiter.response.results);
    }
    *error = waiter.response.response == 1
                 ? "Linux remote desktop permission was cancelled"
                 : "Linux remote desktop permission was denied";
    return false;
  }
  *response = waiter.response;
  return true;
}

std::string PortalHandleToken(const char* prefix) {
  std::ostringstream token;
  token << prefix << "_" << NowMicros();
  return token.str();
}

std::string StringFromVariantDict(GVariant* dict, const char* key) {
  if (dict == nullptr) {
    return "";
  }
  GVariant* value = g_variant_lookup_value(dict, key, nullptr);
  if (value == nullptr) {
    return "";
  }
  const gchar* text = g_variant_get_string(value, nullptr);
  std::string result = text == nullptr ? "" : text;
  g_variant_unref(value);
  return result;
}

bool PortalPropertyUint32ForInterface(GDBusConnection* connection,
                                      const char* interface,
                                      const char* property,
                                      uint32_t* value) {
  GError* error = nullptr;
  GVariant* result = g_dbus_connection_call_sync(
      connection, kPortalBusName, kPortalObjectPath,
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", interface, property),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 500, nullptr, &error);
  if (result == nullptr) {
    if (error != nullptr) {
      g_error_free(error);
    }
    return false;
  }
  GVariant* variant = nullptr;
  g_variant_get(result, "(v)", &variant);
  if (variant == nullptr || !g_variant_is_of_type(variant, G_VARIANT_TYPE_UINT32)) {
    if (variant != nullptr) {
      g_variant_unref(variant);
    }
    g_variant_unref(result);
    return false;
  }
  *value = g_variant_get_uint32(variant);
  g_variant_unref(variant);
  g_variant_unref(result);
  return true;
}

bool PortalPropertyUint32(GDBusConnection* connection,
                          const char* property,
                          uint32_t* value) {
  return PortalPropertyUint32ForInterface(
      connection, kPortalRemoteDesktopInterface, property, value);
}

bool RemoteDesktopPortalAvailable() {
  GError* error = nullptr;
  GDBusConnection* connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (connection == nullptr) {
    if (error != nullptr) {
      g_error_free(error);
    }
    return false;
  }
  uint32_t version = 0;
  uint32_t devices = 0;
  const bool available =
      PortalPropertyUint32(connection, "version", &version) &&
      PortalPropertyUint32(connection, "AvailableDeviceTypes", &devices) &&
      version >= 2 &&
      (devices & (kPortalKeyboardDevice | kPortalPointerDevice)) ==
          (kPortalKeyboardDevice | kPortalPointerDevice);
  g_object_unref(connection);
  return available;
}

bool InputCapturePortalAvailable() {
  GError* error = nullptr;
  GDBusConnection* connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (connection == nullptr) {
    if (error != nullptr) {
      g_error_free(error);
    }
    return false;
  }
  uint32_t version = 0;
  uint32_t capabilities = 0;
  const bool available =
      PortalPropertyUint32ForInterface(connection, kPortalInputCaptureInterface,
                                       "version", &version) &&
      PortalPropertyUint32ForInterface(connection, kPortalInputCaptureInterface,
                                       "SupportedCapabilities",
                                       &capabilities) &&
      version >= 1 &&
      (capabilities & (kPortalKeyboardDevice | kPortalPointerDevice)) ==
          (kPortalKeyboardDevice | kPortalPointerDevice);
  g_object_unref(connection);
  return available;
}

uint32_t InputCapturePortalVersion() {
  GError* error = nullptr;
  GDBusConnection* connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (connection == nullptr) {
    if (error != nullptr) {
      g_error_free(error);
    }
    return 0;
  }
  uint32_t version = 0;
  PortalPropertyUint32ForInterface(connection, kPortalInputCaptureInterface,
                                   "version", &version);
  g_object_unref(connection);
  return version;
}

std::string PortalRestoreTokenPathForFile(const char* filename) {
  gchar* directory =
      g_build_filename(g_get_user_config_dir(), "whisper", nullptr);
  gchar* path = g_build_filename(directory, filename, nullptr);
  std::string result = path == nullptr ? "" : path;
  g_free(path);
  g_free(directory);
  return result;
}

std::string PortalRestoreTokenPath() {
  return PortalRestoreTokenPathForFile("remote-input-portal-token");
}

std::string InputCapturePortalRestoreTokenPath() {
  return PortalRestoreTokenPathForFile("input-capture-portal-token");
}

std::string LoadPortalRestoreTokenFromPath(const std::string& path) {
  if (path.empty()) {
    return "";
  }
  gchar* contents = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(path.c_str(), &contents, &length, nullptr) ||
      contents == nullptr) {
    return "";
  }
  gchar* stripped = g_strstrip(contents);
  std::string result = stripped == nullptr ? "" : stripped;
  g_free(contents);
  return result;
}

std::string LoadPortalRestoreToken() {
  return LoadPortalRestoreTokenFromPath(PortalRestoreTokenPath());
}

std::string LoadInputCapturePortalRestoreToken() {
  return LoadPortalRestoreTokenFromPath(InputCapturePortalRestoreTokenPath());
}

void SavePortalRestoreTokenToPath(const std::string& path,
                                  const std::string& token) {
  if (token.empty()) {
    return;
  }
  gchar* directory =
      g_build_filename(g_get_user_config_dir(), "whisper", nullptr);
  if (directory == nullptr) {
    return;
  }
  g_mkdir_with_parents(directory, 0700);
  if (!path.empty()) {
    g_file_set_contents(path.c_str(), token.c_str(),
                        static_cast<gssize>(token.size()), nullptr);
  }
  g_free(directory);
}

void SavePortalRestoreToken(const std::string& token) {
  SavePortalRestoreTokenToPath(PortalRestoreTokenPath(), token);
}

void SaveInputCapturePortalRestoreToken(const std::string& token) {
  SavePortalRestoreTokenToPath(InputCapturePortalRestoreTokenPath(), token);
}

bool PortalRequestForInterface(GDBusConnection* connection,
                               const char* interface,
                               const char* method,
                               GVariant* parameters,
                               int timeout_ms,
                               PortalResponse* response,
                               std::string* error) {
  GError* call_error = nullptr;
  GVariant* result = g_dbus_connection_call_sync(
      connection, kPortalBusName, kPortalObjectPath, interface, method,
      parameters, G_VARIANT_TYPE("(o)"),
      G_DBUS_CALL_FLAGS_NONE, timeout_ms, nullptr, &call_error);
  if (result == nullptr) {
    if (call_error != nullptr) {
      *error = call_error->message == nullptr ? "" : call_error->message;
      g_error_free(call_error);
    } else {
      *error = "Unable to call Linux remote desktop portal";
    }
    return false;
  }
  const gchar* request_path = nullptr;
  g_variant_get(result, "(&o)", &request_path);
  std::string path = request_path == nullptr ? "" : request_path;
  g_variant_unref(result);
  return WaitPortalResponse(connection, path, timeout_ms, response, error);
}

bool PortalRequest(GDBusConnection* connection,
                   const char* method,
                   GVariant* parameters,
                   int timeout_ms,
                   PortalResponse* response,
                   std::string* error) {
  return PortalRequestForInterface(connection, kPortalRemoteDesktopInterface,
                                   method, parameters, timeout_ms, response,
                                   error);
}

struct PortalSession {
  GDBusConnection* connection = nullptr;
  std::string session_handle;
  int eis_fd = -1;
};

struct PortalZone {
  uint32_t width = 0;
  uint32_t height = 0;
  int32_t x = 0;
  int32_t y = 0;
};

bool Uint32FromVariantDict(GVariant* dict, const char* key, uint32_t* value) {
  if (dict == nullptr) {
    return false;
  }
  GVariant* variant = g_variant_lookup_value(dict, key, G_VARIANT_TYPE_UINT32);
  if (variant == nullptr) {
    return false;
  }
  *value = g_variant_get_uint32(variant);
  g_variant_unref(variant);
  return true;
}

bool DoublePairFromVariantDict(GVariant* dict,
                               const char* key,
                               double* x,
                               double* y) {
  if (dict == nullptr) {
    return false;
  }
  GVariant* variant = g_variant_lookup_value(dict, key, G_VARIANT_TYPE("(dd)"));
  if (variant == nullptr) {
    return false;
  }
  g_variant_get(variant, "(dd)", x, y);
  g_variant_unref(variant);
  return true;
}

bool ConnectToEisForInterface(GDBusConnection* connection,
                              const char* interface,
                              const std::string& session_handle,
                              int* eis_fd,
                              std::string* error) {
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  GError* call_error = nullptr;
  GUnixFDList* fd_list = nullptr;
  GVariant* result = g_dbus_connection_call_with_unix_fd_list_sync(
      connection, kPortalBusName, kPortalObjectPath, interface, "ConnectToEIS",
      g_variant_new("(oa{sv})", session_handle.c_str(), &options),
      G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, &fd_list,
      nullptr, &call_error);
  if (result == nullptr) {
    if (call_error != nullptr) {
      *error = call_error->message == nullptr ? "" : call_error->message;
      g_error_free(call_error);
    } else {
      *error = "Unable to connect Linux remote desktop portal to EIS";
    }
    return false;
  }
  gint32 fd_index = -1;
  g_variant_get(result, "(h)", &fd_index);
  g_variant_unref(result);
  if (fd_list == nullptr || fd_index < 0) {
    if (fd_list != nullptr) {
      g_object_unref(fd_list);
    }
    *error = "Linux remote desktop portal did not return an EIS fd";
    return false;
  }
  GError* fd_error = nullptr;
  const int fd = g_unix_fd_list_get(fd_list, fd_index, &fd_error);
  g_object_unref(fd_list);
  if (fd < 0) {
    if (fd_error != nullptr) {
      *error = fd_error->message == nullptr ? "" : fd_error->message;
      g_error_free(fd_error);
    } else {
      *error = "Unable to read the Linux remote desktop EIS fd";
    }
    return false;
  }
  *eis_fd = fd;
  return true;
}

bool ConnectToEis(GDBusConnection* connection,
                  const std::string& session_handle,
                  int* eis_fd,
                  std::string* error) {
  return ConnectToEisForInterface(connection, kPortalRemoteDesktopInterface,
                                  session_handle, eis_fd, error);
}

void ClosePortalSession(GDBusConnection* connection,
                        const std::string& session_handle) {
  if (connection == nullptr || session_handle.empty()) {
    return;
  }
  g_dbus_connection_call_sync(
      connection, kPortalBusName, session_handle.c_str(),
      "org.freedesktop.portal.Session", "Close", nullptr, nullptr,
      G_DBUS_CALL_FLAGS_NONE, 500, nullptr, nullptr);
}

bool StartRemoteDesktopPortalSession(PortalSession* session,
                                     std::string* error) {
  GError* bus_error = nullptr;
  GDBusConnection* connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &bus_error);
  if (connection == nullptr) {
    if (bus_error != nullptr) {
      *error = bus_error->message == nullptr ? "" : bus_error->message;
      g_error_free(bus_error);
    } else {
      *error = "Unable to connect to Linux session bus";
    }
    return false;
  }

  PortalResponse create_response;
  GVariantBuilder create_options;
  g_variant_builder_init(&create_options, G_VARIANT_TYPE_VARDICT);
  const std::string create_token = PortalHandleToken("whisper_create");
  const std::string session_token = PortalHandleToken("whisper_session");
  g_variant_builder_add(&create_options, "{sv}", "handle_token",
                        g_variant_new_string(create_token.c_str()));
  g_variant_builder_add(&create_options, "{sv}", "session_handle_token",
                        g_variant_new_string(session_token.c_str()));
  if (!PortalRequest(connection, "CreateSession",
                     g_variant_new("(a{sv})", &create_options), 3000,
                     &create_response, error)) {
    g_object_unref(connection);
    return false;
  }
  const std::string session_handle =
      StringFromVariantDict(create_response.results, "session_handle");
  g_variant_unref(create_response.results);
  if (session_handle.empty()) {
    *error = "Linux remote desktop portal did not return a session";
    g_object_unref(connection);
    return false;
  }

  PortalResponse select_response;
  GVariantBuilder select_options;
  g_variant_builder_init(&select_options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&select_options, "{sv}", "handle_token",
                        g_variant_new_string(
                            PortalHandleToken("whisper_select").c_str()));
  g_variant_builder_add(
      &select_options, "{sv}", "types",
      g_variant_new_uint32(kPortalKeyboardDevice | kPortalPointerDevice));
  g_variant_builder_add(&select_options, "{sv}", "persist_mode",
                        g_variant_new_uint32(2));
  const std::string restore_token = LoadPortalRestoreToken();
  if (!restore_token.empty()) {
    g_variant_builder_add(&select_options, "{sv}", "restore_token",
                          g_variant_new_string(restore_token.c_str()));
  }
  if (!PortalRequest(connection, "SelectDevices",
                     g_variant_new("(oa{sv})", session_handle.c_str(),
                                   &select_options),
                     30000, &select_response, error)) {
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }
  g_variant_unref(select_response.results);

  PortalResponse start_response;
  GVariantBuilder start_options;
  g_variant_builder_init(&start_options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&start_options, "{sv}", "handle_token",
                        g_variant_new_string(
                            PortalHandleToken("whisper_start").c_str()));
  if (!PortalRequest(connection, "Start",
                     g_variant_new("(osa{sv})", session_handle.c_str(), "",
                                   &start_options),
                     30000, &start_response, error)) {
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }
  const std::string next_restore_token =
      StringFromVariantDict(start_response.results, "restore_token");
  if (!next_restore_token.empty()) {
    SavePortalRestoreToken(next_restore_token);
  }
  g_variant_unref(start_response.results);

  int eis_fd = -1;
  if (!ConnectToEis(connection, session_handle, &eis_fd, error)) {
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }

  session->connection = connection;
  session->session_handle = session_handle;
  session->eis_fd = eis_fd;
  return true;
}

bool StartInputCapturePortalSessionV2(PortalSession* session,
                                      std::vector<PortalZone>* zones,
                                      uint32_t* zone_set,
                                      std::string* error) {
  GError* bus_error = nullptr;
  GDBusConnection* connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &bus_error);
  if (connection == nullptr) {
    if (bus_error != nullptr) {
      *error = bus_error->message == nullptr ? "" : bus_error->message;
      g_error_free(bus_error);
    } else {
      *error = "Unable to connect to Linux session bus";
    }
    return false;
  }

  GVariantBuilder create_options;
  g_variant_builder_init(&create_options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(
      &create_options, "{sv}", "session_handle_token",
      g_variant_new_string(PortalHandleToken("whisper_capture_session").c_str()));
  GError* create_error = nullptr;
  GVariant* create_result = g_dbus_connection_call_sync(
      connection, kPortalBusName, kPortalObjectPath,
      kPortalInputCaptureInterface, "CreateSession2",
      g_variant_new("(a{sv})", &create_options), G_VARIANT_TYPE("(a{sv})"),
      G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, &create_error);
  if (create_result == nullptr) {
    if (create_error != nullptr) {
      *error = create_error->message == nullptr ? "" : create_error->message;
      g_error_free(create_error);
    } else {
      *error = "Unable to create Linux input capture portal session";
    }
    g_object_unref(connection);
    return false;
  }
  GVariant* create_results = nullptr;
  g_variant_get(create_result, "(@a{sv})", &create_results);
  g_variant_unref(create_result);
  const std::string session_handle =
      StringFromVariantDict(create_results, "session_handle");
  if (create_results != nullptr) {
    g_variant_unref(create_results);
  }
  if (session_handle.empty()) {
    *error = "Linux input capture portal did not return a session";
    g_object_unref(connection);
    return false;
  }

  PortalResponse start_response;
  GVariantBuilder start_options;
  g_variant_builder_init(&start_options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(
      &start_options, "{sv}", "handle_token",
      g_variant_new_string(PortalHandleToken("whisper_capture_start").c_str()));
  g_variant_builder_add(
      &start_options, "{sv}", "capabilities",
      g_variant_new_uint32(kPortalKeyboardDevice | kPortalPointerDevice));
  g_variant_builder_add(&start_options, "{sv}", "persist_mode",
                        g_variant_new_uint32(2));
  const std::string restore_token = LoadInputCapturePortalRestoreToken();
  if (!restore_token.empty()) {
    g_variant_builder_add(&start_options, "{sv}", "restore_token",
                          g_variant_new_string(restore_token.c_str()));
  }
  if (!PortalRequestForInterface(
          connection, kPortalInputCaptureInterface, "Start",
          g_variant_new("(osa{sv})", session_handle.c_str(), "",
                        &start_options),
          30000, &start_response, error)) {
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }
  uint32_t capabilities = 0;
  const bool has_capabilities =
      Uint32FromVariantDict(start_response.results, "capabilities",
                            &capabilities);
  const std::string next_restore_token =
      StringFromVariantDict(start_response.results, "restore_token");
  if (!next_restore_token.empty()) {
    SaveInputCapturePortalRestoreToken(next_restore_token);
  }
  g_variant_unref(start_response.results);
  if (has_capabilities &&
      (capabilities & (kPortalKeyboardDevice | kPortalPointerDevice)) !=
          (kPortalKeyboardDevice | kPortalPointerDevice)) {
    *error = "Linux input capture portal did not grant keyboard and pointer";
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }

  int eis_fd = -1;
  if (!ConnectToEisForInterface(connection, kPortalInputCaptureInterface,
                                session_handle, &eis_fd, error)) {
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }

  PortalResponse zones_response;
  GVariantBuilder zones_options;
  g_variant_builder_init(&zones_options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(
      &zones_options, "{sv}", "handle_token",
      g_variant_new_string(PortalHandleToken("whisper_capture_zones").c_str()));
  if (!PortalRequestForInterface(
          connection, kPortalInputCaptureInterface, "GetZones",
          g_variant_new("(oa{sv})", session_handle.c_str(), &zones_options),
          3000, &zones_response, error)) {
    close(eis_fd);
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }
  GVariant* zones_value =
      g_variant_lookup_value(zones_response.results, "zones",
                             G_VARIANT_TYPE("a(uuii)"));
  if (zones_value != nullptr) {
    GVariantIter iter;
    g_variant_iter_init(&iter, zones_value);
    guint32 width = 0;
    guint32 height = 0;
    gint32 x = 0;
    gint32 y = 0;
    while (g_variant_iter_loop(&iter, "(uuii)", &width, &height, &x, &y)) {
      if (width > 0 && height > 0) {
        zones->push_back(PortalZone{width, height, x, y});
      }
    }
    g_variant_unref(zones_value);
  }
  Uint32FromVariantDict(zones_response.results, "zone_set", zone_set);
  g_variant_unref(zones_response.results);
  if (zones->empty()) {
    close(eis_fd);
    *error = "Linux input capture portal did not return input zones";
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }

  session->connection = connection;
  session->session_handle = session_handle;
  session->eis_fd = eis_fd;
  return true;
}

bool StartInputCapturePortalSessionV1(PortalSession* session,
                                      std::vector<PortalZone>* zones,
                                      uint32_t* zone_set,
                                      std::string* error) {
  GError* bus_error = nullptr;
  GDBusConnection* connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &bus_error);
  if (connection == nullptr) {
    if (bus_error != nullptr) {
      *error = bus_error->message == nullptr ? "" : bus_error->message;
      g_error_free(bus_error);
    } else {
      *error = "Unable to connect to Linux session bus";
    }
    return false;
  }

  PortalResponse create_response;
  GVariantBuilder create_options;
  g_variant_builder_init(&create_options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(
      &create_options, "{sv}", "handle_token",
      g_variant_new_string(PortalHandleToken("whisper_capture_create").c_str()));
  g_variant_builder_add(
      &create_options, "{sv}", "session_handle_token",
      g_variant_new_string(PortalHandleToken("whisper_capture_session").c_str()));
  g_variant_builder_add(
      &create_options, "{sv}", "capabilities",
      g_variant_new_uint32(kPortalKeyboardDevice | kPortalPointerDevice));
  if (!PortalRequestForInterface(
          connection, kPortalInputCaptureInterface, "CreateSession",
          g_variant_new("(sa{sv})", "", &create_options), 30000,
          &create_response, error)) {
    g_object_unref(connection);
    return false;
  }
  const std::string session_handle =
      StringFromVariantDict(create_response.results, "session_handle");
  uint32_t capabilities = 0;
  const bool has_capabilities =
      Uint32FromVariantDict(create_response.results, "capabilities",
                            &capabilities);
  g_variant_unref(create_response.results);
  if (session_handle.empty()) {
    *error = "Linux input capture portal did not return a session";
    g_object_unref(connection);
    return false;
  }
  if (has_capabilities &&
      (capabilities & (kPortalKeyboardDevice | kPortalPointerDevice)) !=
      (kPortalKeyboardDevice | kPortalPointerDevice)) {
    *error = "Linux input capture portal did not grant keyboard and pointer";
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }

  int eis_fd = -1;
  if (!ConnectToEisForInterface(connection, kPortalInputCaptureInterface,
                                session_handle, &eis_fd, error)) {
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }

  PortalResponse zones_response;
  GVariantBuilder zones_options;
  g_variant_builder_init(&zones_options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(
      &zones_options, "{sv}", "handle_token",
      g_variant_new_string(PortalHandleToken("whisper_capture_zones").c_str()));
  if (!PortalRequestForInterface(
          connection, kPortalInputCaptureInterface, "GetZones",
          g_variant_new("(oa{sv})", session_handle.c_str(), &zones_options),
          3000, &zones_response, error)) {
    close(eis_fd);
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }
  GVariant* zones_value =
      g_variant_lookup_value(zones_response.results, "zones",
                             G_VARIANT_TYPE("a(uuii)"));
  if (zones_value != nullptr) {
    GVariantIter iter;
    g_variant_iter_init(&iter, zones_value);
    guint32 width = 0;
    guint32 height = 0;
    gint32 x = 0;
    gint32 y = 0;
    while (g_variant_iter_loop(&iter, "(uuii)", &width, &height, &x, &y)) {
      if (width > 0 && height > 0) {
        zones->push_back(PortalZone{width, height, x, y});
      }
    }
    g_variant_unref(zones_value);
  }
  Uint32FromVariantDict(zones_response.results, "zone_set", zone_set);
  g_variant_unref(zones_response.results);
  if (zones->empty()) {
    close(eis_fd);
    *error = "Linux input capture portal did not return input zones";
    ClosePortalSession(connection, session_handle);
    g_object_unref(connection);
    return false;
  }

  session->connection = connection;
  session->session_handle = session_handle;
  session->eis_fd = eis_fd;
  return true;
}

bool StartInputCapturePortalSession(PortalSession* session,
                                    std::vector<PortalZone>* zones,
                                    uint32_t* zone_set,
                                    std::string* error) {
  if (InputCapturePortalVersion() >= 2) {
    return StartInputCapturePortalSessionV2(session, zones, zone_set, error);
  }
  return StartInputCapturePortalSessionV1(session, zones, zone_set, error);
}
#endif

struct MainThreadEvent {
  FlMethodChannel* channel = nullptr;
  std::string method;
  std::string session_id;
  std::string event_type;
  std::string reason;
  std::string message;
  int64_t sequence = 0;
  int64_t activation_sequence = 0;
  double edge_unit = 0;
  bool source_edge_unit = false;
  std::string route_id;
  std::string source_display_id;
  std::string source_edge;
  double source_segment_start = 0;
  double source_segment_end = 0;
  int64_t timestamp_micros = 0;
  std::vector<uint8_t> payload;
};

gboolean InvokeMainThreadEvent(gpointer user_data) {
  auto* event = static_cast<MainThreadEvent*>(user_data);
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(
      args, "sessionId", fl_value_new_string(event->session_id.c_str()));
  if (event->method == "onInputEvent") {
    fl_value_set_string_take(args, "sequence",
                             fl_value_new_int(event->sequence));
    fl_value_set_string_take(
        args, "timestampMicros", fl_value_new_int(event->timestamp_micros));
    fl_value_set_string_take(args, "eventType",
                             fl_value_new_string(event->event_type.c_str()));
    fl_value_set_string_take(
        args, "payload",
        fl_value_new_uint8_list(event->payload.data(), event->payload.size()));
  } else if (event->method == "onRelease") {
    fl_value_set_string_take(args, "reason",
                             fl_value_new_string(event->reason.c_str()));
    fl_value_set_string_take(args, "sequence",
                             fl_value_new_int(event->sequence));
    fl_value_set_string_take(
        args, "activationSequence", fl_value_new_int(event->activation_sequence));
    fl_value_set_string_take(args, "edgeUnit",
                             fl_value_new_float(event->edge_unit));
    if (event->source_edge_unit) {
      fl_value_set_string_take(args, "sourceEdgeUnit",
                               fl_value_new_bool(TRUE));
    }
    if (!event->route_id.empty()) {
      fl_value_set_string_take(
          args, "routeId", fl_value_new_string(event->route_id.c_str()));
    }
    if (!event->source_display_id.empty()) {
      fl_value_set_string_take(
          args, "sourceDisplayId",
          fl_value_new_string(event->source_display_id.c_str()));
    }
    if (!event->source_edge.empty()) {
      fl_value_set_string_take(
          args, "sourceEdge", fl_value_new_string(event->source_edge.c_str()));
    }
    if (event->source_segment_end > event->source_segment_start) {
      fl_value_set_string_take(args, "sourceSegmentStart",
                               fl_value_new_float(event->source_segment_start));
      fl_value_set_string_take(args, "sourceSegmentEnd",
                               fl_value_new_float(event->source_segment_end));
    }
  } else {
    fl_value_set_string_take(args, "message",
                             fl_value_new_string(event->message.c_str()));
  }
  fl_method_channel_invoke_method(event->channel, event->method.c_str(), args,
                                  nullptr, nullptr, nullptr);
  g_object_unref(event->channel);
  delete event;
  return G_SOURCE_REMOVE;
}

#if HAVE_X11_REMOTE_INPUT
struct ScreenBounds {
  int left = 0;
  int top = 0;
  int width = 1;
  int height = 1;

  int right() const {
    return left + width - 1;
  }

  int bottom() const {
    return top + height - 1;
  }
};

struct EdgeSegment {
  double start = 0;
  double end = 0;
};

struct DoublePoint {
  double x = 0;
  double y = 0;
};

struct CaptureRoute {
  std::string route_id;
  std::string source_display_id;
  std::string source_edge;
  EdgeSegment source_segment;
};

struct InjectionRoute {
  std::string route_id;
  std::string source_display_id;
  std::string source_edge;
  std::string sink_display_id;
  std::string sink_edge;
  EdgeSegment sink_segment;
  EdgeSegment source_segment;
};

struct InjectionReleaseRoute {
  std::string route_id;
  std::string source_display_id;
  std::string source_edge;
  EdgeSegment source_segment;
  double edge_unit = 0;
};

struct CaptureCrossing {
  CaptureRoute route;
  double edge_unit = 0;
  bool strict_segment_hit = false;
  double normal_motion = 0;
  double travel_to_intersection = 0;
};

struct InputCaptureBarrier {
  uint32_t id = 0;
  CaptureRoute route;
  int x1 = 0;
  int y1 = 0;
  int x2 = 0;
  int y2 = 0;
};

struct InjectionReleaseCrossing {
  InjectionRoute route;
  double edge_unit = 0;
  bool strict_segment_hit = false;
  double normal_motion = 0;
  double travel_to_intersection = 0;
};

struct DisplayInfo {
  std::string id;
  std::string name;
  ScreenBounds bounds;
  bool primary = false;
  double scale = 1.0;
};

enum class InjectionBackend {
  kNone,
  kX11,
  kPortal,
};

enum class CaptureBackend {
  kNone,
  kX11,
  kPortal,
};

bool HasSegment(const EdgeSegment& segment) {
  return segment.end > segment.start;
}

std::string SegmentTrace(const EdgeSegment& segment) {
  if (!HasSegment(segment)) {
    return "-";
  }
  std::ostringstream trace;
  trace << segment.start << ".." << segment.end;
  return trace.str();
}

std::vector<CaptureRoute> CaptureRoutesValue(FlValue* map, const char* key) {
  FlValue* values = Lookup(map, key);
  if (values == nullptr || fl_value_get_type(values) != FL_VALUE_TYPE_LIST) {
    return {};
  }
  std::vector<CaptureRoute> routes;
  const size_t length = fl_value_get_length(values);
  for (size_t i = 0; i < length; i++) {
    FlValue* item = fl_value_get_list_value(values, i);
    if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_MAP) {
      continue;
    }
    CaptureRoute route;
    route.route_id = StringValue(item, "routeId");
    route.source_display_id = StringValue(item, "displayId");
    route.source_edge = StringValue(item, "edge");
    route.source_segment = EdgeSegment{
        DoubleValue(item, "start"),
        DoubleValue(item, "end"),
    };
    if (!route.source_edge.empty() &&
        route.source_segment.end > route.source_segment.start) {
      routes.push_back(std::move(route));
    }
  }
  return routes;
}

std::vector<InjectionRoute> InjectionRoutesValue(FlValue* map,
                                                 const char* key) {
  FlValue* values = Lookup(map, key);
  if (values == nullptr || fl_value_get_type(values) != FL_VALUE_TYPE_LIST) {
    return {};
  }
  std::vector<InjectionRoute> routes;
  const size_t length = fl_value_get_length(values);
  for (size_t i = 0; i < length; i++) {
    FlValue* item = fl_value_get_list_value(values, i);
    if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_MAP) {
      continue;
    }
    InjectionRoute route;
    route.route_id = StringValue(item, "routeId");
    route.source_display_id = StringValue(item, "sourceDisplayId");
    route.source_edge = StringValue(item, "sourceEdge");
    route.sink_display_id = StringValue(item, "sinkDisplayId");
    route.sink_edge = StringValue(item, "sinkEdge");
    route.source_segment = EdgeSegment{
        DoubleValue(item, "sourceSegmentStart"),
        DoubleValue(item, "sourceSegmentEnd"),
    };
    route.sink_segment = EdgeSegment{
        DoubleValue(item, "sinkSegmentStart"),
        DoubleValue(item, "sinkSegmentEnd"),
    };
    if (!route.source_edge.empty() && !route.sink_display_id.empty() &&
        !route.sink_edge.empty() &&
        route.source_segment.end > route.source_segment.start &&
        route.sink_segment.end > route.sink_segment.start) {
      routes.push_back(std::move(route));
    }
  }
  return routes;
}

ScreenBounds BoundsFor(Display* display) {
  if (display == nullptr) {
    return ScreenBounds{};
  }
  const int screen = DefaultScreen(display);
  ScreenBounds bounds;
  bounds.width = std::max(1, DisplayWidth(display, screen));
  bounds.height = std::max(1, DisplayHeight(display, screen));
  return bounds;
}

std::vector<DisplayInfo> DisplayInfos(Display* display) {
  std::vector<DisplayInfo> infos;
  if (display == nullptr) {
    return infos;
  }
#if HAVE_XRANDR_REMOTE_INPUT
  Window root = DefaultRootWindow(display);
  int monitor_count = 0;
  XRRMonitorInfo* monitors = XRRGetMonitors(display, root, True,
                                            &monitor_count);
  if (monitors != nullptr) {
    for (int i = 0; i < monitor_count; i++) {
      if (monitors[i].width <= 0 || monitors[i].height <= 0) {
        continue;
      }
      char* name = XGetAtomName(display, monitors[i].name);
      DisplayInfo info;
      info.id = name == nullptr ? std::to_string(i) : name;
      info.name = info.id;
      info.bounds.left = monitors[i].x;
      info.bounds.top = monitors[i].y;
      info.bounds.width = std::max(1, monitors[i].width);
      info.bounds.height = std::max(1, monitors[i].height);
      info.primary = monitors[i].primary != 0;
      infos.push_back(info);
      if (name != nullptr) {
        XFree(name);
      }
    }
    XRRFreeMonitors(monitors);
  }
#endif
  if (infos.empty()) {
    DisplayInfo fallback;
    fallback.id = "primary";
    fallback.name = "Primary";
    fallback.bounds = BoundsFor(display);
    fallback.primary = true;
    infos.push_back(fallback);
  }
  return infos;
}

ScreenBounds BoundsForDisplay(Display* display, const std::string& display_id) {
  if (!display_id.empty()) {
    for (const auto& info : DisplayInfos(display)) {
      if (info.id == display_id) {
        return info.bounds;
      }
    }
  }
  return BoundsFor(display);
}

double Normalized(int value, int start, int length) {
  if (length <= 1) {
    return 0;
  }
  return ClampedUnit(static_cast<double>(value - start) /
                     static_cast<double>(length - 1));
}

double AxisValue(int x, int y, const std::string& edge) {
  if (edge == "left" || edge == "right") {
    return static_cast<double>(y);
  }
  return static_cast<double>(x);
}

double AxisCoordinate(DoublePoint point, const std::string& edge) {
  if (edge == "left" || edge == "right") {
    return point.y;
  }
  return point.x;
}

double EdgeLine(const ScreenBounds& bounds, const std::string& edge) {
  if (edge == "left") {
    return static_cast<double>(bounds.left);
  }
  if (edge == "top") {
    return static_cast<double>(bounds.top);
  }
  if (edge == "bottom") {
    return static_cast<double>(bounds.bottom());
  }
  return static_cast<double>(bounds.right());
}

Maybe<double> IntersectionParameter(const std::string& edge,
                                            double line,
                                            DoublePoint previous_point,
                                            double delta_x,
                                            double delta_y) {
  if (edge == "left" || edge == "right") {
    if (delta_x == 0) {
      return {};
    }
    return (line - previous_point.x) / delta_x;
  }
  if (delta_y == 0) {
    return {};
  }
  return (line - previous_point.y) / delta_y;
}

double EdgeNormalMotion(const std::string& edge,
                        double delta_x,
                        double delta_y) {
  if (edge == "left") {
    return -delta_x;
  }
  if (edge == "top") {
    return -delta_y;
  }
  if (edge == "bottom") {
    return delta_y;
  }
  return delta_x;
}

bool PointInSegment(int x,
                    int y,
                    const std::string& edge,
                    const EdgeSegment& segment,
                    double tolerance = 0) {
  if (!HasSegment(segment)) {
    return true;
  }
  const double value = AxisValue(x, y, edge);
  return value >= segment.start - tolerance && value <= segment.end + tolerance;
}

double EdgeUnitForPoint(int x,
                        int y,
                        const std::string& edge,
                        const EdgeSegment& segment) {
  if (!HasSegment(segment)) {
    return 0;
  }
  return ClampedUnit((AxisValue(x, y, edge) - segment.start) /
                     (segment.end - segment.start));
}

int SegmentCoordinate(double edge_unit, const EdgeSegment& segment) {
  return static_cast<int>(std::lround(
      segment.start + (segment.end - segment.start) * ClampedUnit(edge_unit)));
}

std::string MouseMovePayload(Display* display,
                             int x,
                             int y,
                             int delta_x,
                             int delta_y,
                             bool active_start,
                             const std::string& edge,
                             const std::string& route_id,
                             int buttons,
                             const ScreenBounds& bounds,
                             const EdgeSegment& segment,
                             double edge_unit_override = -1) {
  (void)display;
  std::ostringstream json;
  json << "{\"x\":" << x << ",\"y\":" << y
       << ",\"deltaX\":" << delta_x << ",\"deltaY\":" << delta_y
       << ",\"activeStart\":" << (active_start ? "true" : "false")
       << ",\"edge\":\"" << JsonEscapedString(edge) << "\""
       << ",\"buttons\":" << buttons
       << ",\"unitX\":" << Normalized(x, bounds.left, bounds.width)
       << ",\"unitY\":" << Normalized(y, bounds.top, bounds.height);
  if (!route_id.empty()) {
    json << ",\"routeId\":\"" << JsonEscapedString(route_id) << "\"";
  }
  if (HasSegment(segment)) {
    json << ",\"edgeUnit\":"
         << (edge_unit_override >= 0
                 ? ClampedUnit(edge_unit_override)
                 : EdgeUnitForPoint(x, y, edge, segment));
  }
  json << "}";
  return json.str();
}

std::string MouseButtonPayload(int x, int y, int button, bool down) {
  std::ostringstream json;
  json << "{\"button\":" << button << ",\"down\":"
       << (down ? "true" : "false") << ",\"x\":" << x
       << ",\"y\":" << y << "}";
  return json.str();
}

std::string MouseWheelPayload(int delta_x, int delta_y) {
  std::ostringstream json;
  json << "{\"deltaX\":" << delta_x << ",\"deltaY\":" << delta_y << "}";
  return json.str();
}

std::string LinuxKeyPayload(int linux_keycode, bool down) {
  std::ostringstream json;
  json << "{\"sourcePlatform\":\"linux\""
       << ",\"keyCode\":" << linux_keycode
       << ",\"linuxKeyCode\":" << linux_keycode
       << ",\"down\":" << (down ? "true" : "false") << "}";
  return json.str();
}

std::string KeyPayload(unsigned int x_keycode, bool down) {
  return LinuxKeyPayload(static_cast<int>(x_keycode) - 8, down);
}
#endif

class RemoteInputPlugin {
 public:
  explicit RemoteInputPlugin(FlMethodChannel* channel)
      : channel_(FL_METHOD_CHANNEL(g_object_ref(channel))) {}

  ~RemoteInputPlugin() {
    StopCapture("");
    StopInjection("");
    g_object_unref(channel_);
  }

  void HandleMethodCall(FlMethodCall* method_call) {
    const gchar* method = fl_method_call_get_name(method_call);
    FlValue* args = fl_method_call_get_args(method_call);

    if (std::strcmp(method, "startCapture") == 0) {
      const std::string session_id = StringValue(args, "sessionId");
      if (session_id.empty()) {
        RespondError(method_call, "bad-arguments",
                     "startCapture requires sessionId");
        return;
      }
      const std::string edge = StringValue(args, "edge").empty()
                                   ? "right"
                                   : StringValue(args, "edge");
      const std::string release_hotkey =
          StringValue(args, "releaseHotkey").empty()
              ? "ctrl+alt+esc"
              : StringValue(args, "releaseHotkey");
      const std::string display_id = StringValue(args, "displayId");
      const EdgeSegment segment = {
          DoubleValue(args, "segmentStart"),
          DoubleValue(args, "segmentEnd"),
      };
      const std::vector<CaptureRoute> routes =
          CaptureRoutesValue(args, "segments");
      std::string error;
      if (!StartCapture(session_id, edge, display_id, segment, routes,
                        release_hotkey, &error)) {
        RespondError(method_call, "remote-input-capture-unavailable", error);
        return;
      }
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "stopCapture") == 0) {
      StopCapture(StringValue(args, "sessionId"));
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "pauseCapture") == 0) {
      PauseCapture(
          StringValue(args, "sessionId"),
          IntValue(args, "releaseSequence"),
          IntValue(args, "releaseActivationSequence"),
          DoubleValue(args, "releaseEdgeUnit"),
          StringValue(args, "displayId"),
          StringValue(args, "edge"),
          EdgeSegment{
              DoubleValue(args, "segmentStart"),
              DoubleValue(args, "segmentEnd"),
          },
          StringValue(args, "routeId"));
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "startInjection") == 0) {
      const std::string session_id = StringValue(args, "sessionId");
      if (session_id.empty()) {
        RespondError(method_call, "bad-arguments",
                     "startInjection requires sessionId");
        return;
      }
      std::string error;
      if (!StartInjection(
              session_id,
              StringValue(args, "displayId"),
              StringValue(args, "edge"),
              EdgeSegment{
                  DoubleValue(args, "segmentStart"),
                  DoubleValue(args, "segmentEnd"),
              },
              InjectionRoutesValue(args, "mappings"),
              &error)) {
        RespondError(method_call, "remote-input-injection-unavailable", error);
        return;
      }
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "injectEvent") == 0) {
      const std::string session_id = StringValue(args, "sessionId");
      const std::string event_type = StringValue(args, "eventType");
      const std::vector<uint8_t> payload = BytesValue(args, "payload");
      if (session_id.empty() || event_type.empty() || payload.empty()) {
        RespondError(method_call, "bad-arguments",
                     "injectEvent requires sessionId, eventType, and payload");
        return;
      }
      InjectEvent(session_id, event_type, payload);
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "stopInjection") == 0) {
      StopInjection(StringValue(args, "sessionId"));
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "getDisplayTopology") == 0) {
      g_autoptr(FlValue) topology = DisplayTopologyValue();
      RespondSuccessValue(method_call, topology);
      return;
    }

    fl_method_call_respond_not_implemented(method_call, nullptr);
  }

 private:
  bool StartCapture(const std::string& session_id,
                    const std::string& edge,
                    const std::string& display_id,
                    EdgeSegment segment,
                    std::vector<CaptureRoute> routes,
                    const std::string& release_hotkey,
                    std::string* error) {
#if HAVE_X11_REMOTE_INPUT
    StopCapture("");
    bool portal_attempted = false;
    if (TryStartPortalCapture(session_id, edge, display_id, segment, routes,
                              release_hotkey, &portal_attempted, error)) {
      return true;
    }
    if (portal_attempted) {
      return false;
    }
    return StartX11Capture(session_id, edge, display_id, segment,
                           std::move(routes), release_hotkey, error);
#else
    (void)session_id;
    (void)edge;
    (void)display_id;
    (void)segment;
    (void)routes;
    (void)release_hotkey;
    *error = "X11 remote input support is not available in this Linux build";
    return false;
#endif
  }

  bool StartX11Capture(const std::string& session_id,
                       const std::string& edge,
                       const std::string& display_id,
                       EdgeSegment segment,
                       std::vector<CaptureRoute> routes,
                       const std::string& release_hotkey,
                       std::string* error) {
#if HAVE_X11_REMOTE_INPUT
    capture_running_.store(true);
    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      capture_backend_ = CaptureBackend::kX11;
      capture_session_id_ = session_id;
      capture_edge_ = edge;
      capture_display_id_ = display_id;
      capture_segment_ = segment;
      capture_route_id_.clear();
      capture_routes_ = routes;
      capture_pause_release_display_id_.clear();
      capture_pause_release_edge_.clear();
      capture_pause_release_route_id_.clear();
      capture_pause_release_segment_ = EdgeSegment{};
    }
    capture_thread_ = std::thread([this, session_id, edge, display_id,
                                    segment, routes, release_hotkey] {
      CaptureLoop(session_id, edge, display_id, segment, routes,
                  release_hotkey);
    });
    return true;
#else
    (void)session_id;
    (void)edge;
    (void)display_id;
    (void)segment;
    (void)routes;
    (void)release_hotkey;
    *error = "X11 remote input support is not available in this Linux build";
    return false;
#endif
  }

  void StopCapture(const std::string& session_id) {
#if HAVE_X11_REMOTE_INPUT
    std::thread portal_thread_to_join;
#if HAVE_LIBEI_REMOTE_INPUT
    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      if (!session_id.empty() && session_id != capture_session_id_) {
        return;
      }
      if (capture_backend_ == CaptureBackend::kPortal) {
        input_capture_running_.store(false);
        if (input_capture_thread_.joinable()) {
          portal_thread_to_join = std::move(input_capture_thread_);
        }
      }
    }
    if (portal_thread_to_join.joinable()) {
      portal_thread_to_join.join();
    }
#endif
    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      if (!session_id.empty() && session_id != capture_session_id_) {
        return;
      }
      capture_running_.store(false);
    }
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }
    std::lock_guard<std::mutex> lock(capture_mutex_);
#if HAVE_LIBEI_REMOTE_INPUT
    ClearInputCapturePortalLocked();
#endif
    capture_backend_ = CaptureBackend::kNone;
    capture_session_id_.clear();
    capture_route_id_.clear();
    capture_display_id_.clear();
    capture_segment_ = EdgeSegment{};
    capture_routes_.clear();
    capture_pause_release_display_id_.clear();
    capture_pause_release_edge_.clear();
    capture_pause_release_route_id_.clear();
    capture_pause_release_segment_ = EdgeSegment{};
#else
    (void)session_id;
#endif
  }

  void PauseCapture(const std::string& session_id,
                    int64_t release_sequence,
                    int64_t release_activation_sequence,
                    double release_edge_unit,
                    const std::string& release_display_id,
                    const std::string& release_edge,
                    EdgeSegment release_segment,
                    const std::string& release_route_id) {
#if HAVE_X11_REMOTE_INPUT
    std::lock_guard<std::mutex> lock(capture_mutex_);
    if (session_id != capture_session_id_) {
      return;
    }
#if HAVE_LIBEI_REMOTE_INPUT
    if (capture_backend_ == CaptureBackend::kPortal) {
      ReleaseInputCapturePortalLocked(release_edge_unit, release_display_id,
                                      release_edge, release_segment,
                                      release_route_id);
      return;
    }
#endif
    capture_pause_requested_ = true;
    capture_pause_release_sequence_ = release_sequence;
    capture_pause_release_activation_sequence_ = release_activation_sequence;
    capture_pause_release_edge_unit_ = release_edge_unit;
    capture_pause_release_display_id_ = release_display_id;
    capture_pause_release_edge_ = release_edge;
    capture_pause_release_segment_ = release_segment;
    capture_pause_release_route_id_ = release_route_id;
#else
    (void)session_id;
    (void)release_sequence;
    (void)release_activation_sequence;
    (void)release_edge_unit;
    (void)release_display_id;
    (void)release_edge;
    (void)release_segment;
    (void)release_route_id;
#endif
  }

  bool TryStartPortalCapture(const std::string& session_id,
                             const std::string& edge,
                             const std::string& display_id,
                             EdgeSegment segment,
                             std::vector<CaptureRoute> routes,
                             const std::string& release_hotkey,
                             bool* attempted,
                             std::string* error) {
#if HAVE_LIBEI_REMOTE_INPUT
    (void)release_hotkey;
    *attempted = false;
    if (!InputCapturePortalAvailable()) {
      return false;
    }
    *attempted = true;
    return StartPortalCapture(session_id, edge, display_id, segment,
                              std::move(routes), error);
#else
    (void)session_id;
    (void)edge;
    (void)display_id;
    (void)segment;
    (void)routes;
    (void)release_hotkey;
    (void)error;
    *attempted = false;
    return false;
#endif
  }

#if HAVE_LIBEI_REMOTE_INPUT
  bool StartPortalCapture(const std::string& session_id,
                          const std::string& edge,
                          const std::string& display_id,
                          EdgeSegment segment,
                          std::vector<CaptureRoute> routes,
                          std::string* error) {
    PortalSession session;
    std::vector<PortalZone> zones;
    uint32_t zone_set = 0;
    if (!StartInputCapturePortalSession(&session, &zones, &zone_set, error)) {
      return false;
    }
    Display* x_display = XOpenDisplay(nullptr);
    std::vector<InputCaptureBarrier> barriers =
        BuildInputCaptureBarriers(x_display, zones, display_id, edge, segment,
                                  routes);
    if (barriers.empty()) {
      *error = "Linux input capture portal did not expose a usable edge";
      if (session.eis_fd >= 0) {
        close(session.eis_fd);
      }
      if (x_display != nullptr) {
        XCloseDisplay(x_display);
      }
      ClosePortalSession(session.connection, session.session_handle);
      g_object_unref(session.connection);
      return false;
    }
    if (!SetInputCapturePointerBarriers(session.connection,
                                        session.session_handle, barriers,
                                        zone_set, error)) {
      if (session.eis_fd >= 0) {
        close(session.eis_fd);
      }
      if (x_display != nullptr) {
        XCloseDisplay(x_display);
      }
      ClosePortalSession(session.connection, session.session_handle);
      g_object_unref(session.connection);
      return false;
    }

    struct ei* portal_ei = ei_new_receiver(nullptr);
    if (portal_ei == nullptr) {
      *error = "Unable to create Linux input capture client";
      if (session.eis_fd >= 0) {
        close(session.eis_fd);
      }
      if (x_display != nullptr) {
        XCloseDisplay(x_display);
      }
      ClosePortalSession(session.connection, session.session_handle);
      g_object_unref(session.connection);
      return false;
    }
    ei_configure_name(portal_ei, "Whisper");
    const int setup_result = ei_setup_backend_fd(portal_ei, session.eis_fd);
    session.eis_fd = -1;
    if (setup_result < 0) {
      *error = "Unable to connect Linux input capture client";
      ei_unref(portal_ei);
      if (x_display != nullptr) {
        XCloseDisplay(x_display);
      }
      ClosePortalSession(session.connection, session.session_handle);
      g_object_unref(session.connection);
      return false;
    }

    const guint activated_signal_id = g_dbus_connection_signal_subscribe(
        session.connection, kPortalBusName, kPortalInputCaptureInterface,
        "Activated", kPortalObjectPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        InputCaptureActivatedCallback, this, nullptr);
    const guint deactivated_signal_id = g_dbus_connection_signal_subscribe(
        session.connection, kPortalBusName, kPortalInputCaptureInterface,
        "Deactivated", kPortalObjectPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        InputCaptureDeactivatedCallback, this, nullptr);
    const guint disabled_signal_id = g_dbus_connection_signal_subscribe(
        session.connection, kPortalBusName, kPortalInputCaptureInterface,
        "Disabled", kPortalObjectPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        InputCaptureDisabledCallback, this, nullptr);
    const guint zones_changed_signal_id = g_dbus_connection_signal_subscribe(
        session.connection, kPortalBusName, kPortalInputCaptureInterface,
        "ZonesChanged", kPortalObjectPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        InputCaptureZonesChangedCallback, this, nullptr);

    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      capture_backend_ = CaptureBackend::kPortal;
      capture_session_id_ = session_id;
      capture_edge_ = edge;
      capture_display_id_ = display_id;
      capture_segment_ = segment;
      capture_route_id_.clear();
      capture_routes_ = routes;
      capture_pause_release_display_id_.clear();
      capture_pause_release_edge_.clear();
      capture_pause_release_route_id_.clear();
      capture_pause_release_segment_ = EdgeSegment{};
      input_capture_connection_ = session.connection;
      input_capture_session_handle_ = session.session_handle;
      input_capture_ei_ = portal_ei;
      input_capture_x_display_ = x_display;
      input_capture_barriers_ = barriers;
      input_capture_zone_set_ = zone_set;
      input_capture_activated_signal_id_ = activated_signal_id;
      input_capture_deactivated_signal_id_ = deactivated_signal_id;
      input_capture_disabled_signal_id_ = disabled_signal_id;
      input_capture_zones_changed_signal_id_ = zones_changed_signal_id;
      ResetInputCaptureStateLocked();
      capture_running_.store(true);
      input_capture_running_.store(true);
    }
    input_capture_thread_ = std::thread([this, session_id] {
      InputCaptureEventLoop(session_id);
    });
    if (!EnableInputCapturePortal(session.connection, session.session_handle,
                                  error)) {
      StopCapture(session_id);
      return false;
    }
    TraceRemoteInput("linux remote input portal capture started session=" +
                     session_id + " barriers=" +
                     std::to_string(barriers.size()));
    EmitDiagnosticForSession(session_id,
                             "linux remote input portal capture started");
    return true;
  }

  bool EnableInputCapturePortal(GDBusConnection* connection,
                                const std::string& session_handle,
                                std::string* error) {
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    GError* call_error = nullptr;
    GVariant* result = g_dbus_connection_call_sync(
        connection, kPortalBusName, kPortalObjectPath,
        kPortalInputCaptureInterface, "Enable",
        g_variant_new("(oa{sv})", session_handle.c_str(), &options), nullptr,
        G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, &call_error);
    if (result == nullptr) {
      if (call_error != nullptr) {
        *error = call_error->message == nullptr ? "" : call_error->message;
        g_error_free(call_error);
      } else {
        *error = "Unable to enable Linux input capture portal";
      }
      return false;
    }
    g_variant_unref(result);
    return true;
  }

  void ResetInputCaptureStateLocked() {
    input_capture_active_ = false;
    input_capture_pending_active_start_ = false;
    input_capture_activation_id_ = 0;
    input_capture_sequence_ = 0;
    input_capture_activation_sequence_ = 0;
    input_capture_buttons_ = 0;
    input_capture_x_ = 0;
    input_capture_y_ = 0;
    input_capture_activation_edge_unit_ = -1;
    input_capture_active_route_id_.clear();
    input_capture_active_display_id_ = capture_display_id_;
    input_capture_active_edge_ = capture_edge_;
    input_capture_active_segment_ = capture_segment_;
    input_capture_active_bounds_ =
        BoundsForDisplay(input_capture_x_display_, input_capture_active_display_id_);
  }

  bool PortalZonesTouchOnEdge(const PortalZone& zone,
                              const PortalZone& other,
                              const std::string& edge) const {
    if (edge == "left" || edge == "right") {
      const int zone_top = zone.y;
      const int zone_bottom = zone.y + static_cast<int>(zone.height);
      const int other_top = other.y;
      const int other_bottom = other.y + static_cast<int>(other.height);
      const bool overlaps =
          std::max(zone_top, other_top) < std::min(zone_bottom, other_bottom);
      if (!overlaps) {
        return false;
      }
      if (edge == "left") {
        return other.x + static_cast<int>(other.width) == zone.x;
      }
      return zone.x + static_cast<int>(zone.width) == other.x;
    }
    const int zone_left = zone.x;
    const int zone_right = zone.x + static_cast<int>(zone.width);
    const int other_left = other.x;
    const int other_right = other.x + static_cast<int>(other.width);
    const bool overlaps =
        std::max(zone_left, other_left) < std::min(zone_right, other_right);
    if (!overlaps) {
      return false;
    }
    if (edge == "top") {
      return other.y + static_cast<int>(other.height) == zone.y;
    }
    return zone.y + static_cast<int>(zone.height) == other.y;
  }

  bool PortalZoneHasOutsideEdge(const PortalZone& zone,
                                const std::vector<PortalZone>& zones,
                                const std::string& edge) const {
    for (const auto& other : zones) {
      if (&other == &zone) {
        continue;
      }
      if (PortalZonesTouchOnEdge(zone, other, edge)) {
        return false;
      }
    }
    return true;
  }

  std::vector<InputCaptureBarrier> BuildInputCaptureBarriers(
      Display* display,
      const std::vector<PortalZone>& zones,
      const std::string& display_id,
      const std::string& edge,
      const EdgeSegment& segment,
      const std::vector<CaptureRoute>& configured_routes) const {
    std::vector<InputCaptureBarrier> barriers;
    uint32_t next_id = 1;
    const std::vector<CaptureRoute> routes =
        CaptureRoutesForMatching(configured_routes, display_id, edge, segment);
    for (const auto& route : routes) {
      for (const auto& zone : zones) {
        if (!PortalZoneHasOutsideEdge(zone, zones, route.source_edge)) {
          continue;
        }
        const bool vertical =
            route.source_edge == "left" || route.source_edge == "right";
        const int zone_start = vertical ? zone.y : zone.x;
        const int zone_end = vertical
                                 ? zone.y + static_cast<int>(zone.height) - 1
                                 : zone.x + static_cast<int>(zone.width) - 1;
        int start = zone_start;
        int end = zone_end;
        if (HasSegment(route.source_segment)) {
          start = std::max(start, static_cast<int>(std::floor(
                                      route.source_segment.start)));
          end = std::min(end,
                         static_cast<int>(std::ceil(route.source_segment.end)) -
                             1);
        }
        if (start > end) {
          continue;
        }
        InputCaptureBarrier barrier;
        barrier.id = next_id++;
        barrier.route = route;
        barrier.route.source_segment =
            EdgeSegment{static_cast<double>(start), static_cast<double>(end)};
        if (route.source_edge == "left") {
          barrier.x1 = zone.x;
          barrier.y1 = start;
          barrier.x2 = zone.x;
          barrier.y2 = end;
        } else if (route.source_edge == "top") {
          barrier.x1 = start;
          barrier.y1 = zone.y;
          barrier.x2 = end;
          barrier.y2 = zone.y;
        } else if (route.source_edge == "bottom") {
          barrier.x1 = start;
          barrier.y1 = zone.y + static_cast<int>(zone.height);
          barrier.x2 = end;
          barrier.y2 = zone.y + static_cast<int>(zone.height);
        } else {
          barrier.x1 = zone.x + static_cast<int>(zone.width);
          barrier.y1 = start;
          barrier.x2 = zone.x + static_cast<int>(zone.width);
          barrier.y2 = end;
        }
        barriers.push_back(barrier);
      }
    }
    (void)display;
    return barriers;
  }

  bool SetInputCapturePointerBarriers(
      GDBusConnection* connection,
      const std::string& session_handle,
      const std::vector<InputCaptureBarrier>& barriers,
      uint32_t zone_set,
      std::string* error) {
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(
        &options, "{sv}", "handle_token",
        g_variant_new_string(
            PortalHandleToken("whisper_capture_barriers").c_str()));
    GVariantBuilder barrier_values;
    g_variant_builder_init(&barrier_values, G_VARIANT_TYPE("aa{sv}"));
    for (const auto& barrier : barriers) {
      GVariantBuilder item;
      g_variant_builder_init(&item, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&item, "{sv}", "barrier_id",
                            g_variant_new_uint32(barrier.id));
      g_variant_builder_add(
          &item, "{sv}", "position",
          g_variant_new("(iiii)", barrier.x1, barrier.y1, barrier.x2,
                        barrier.y2));
      g_variant_builder_add_value(&barrier_values, g_variant_builder_end(&item));
    }
    PortalResponse response;
    if (!PortalRequestForInterface(
            connection, kPortalInputCaptureInterface, "SetPointerBarriers",
            g_variant_new("(oa{sv}aa{sv}u)", session_handle.c_str(), &options,
                          &barrier_values, zone_set),
            3000, &response, error)) {
      return false;
    }
    GVariant* failed =
        g_variant_lookup_value(response.results, "failed_barriers",
                               G_VARIANT_TYPE("au"));
    const bool all_failed =
        failed != nullptr &&
        g_variant_n_children(failed) >= static_cast<gsize>(barriers.size());
    if (failed != nullptr) {
      g_variant_unref(failed);
    }
    g_variant_unref(response.results);
    if (all_failed) {
      *error = "Linux input capture portal rejected pointer barriers";
      return false;
    }
    return true;
  }

  const InputCaptureBarrier* InputCaptureBarrierByIdLocked(
      uint32_t barrier_id) const {
    for (const auto& barrier : input_capture_barriers_) {
      if (barrier.id == barrier_id) {
        return &barrier;
      }
    }
    return nullptr;
  }

  void HandleInputCaptureActivated(GVariant* parameters) {
    const gchar* session_handle = nullptr;
    GVariant* options = nullptr;
    g_variant_get(parameters, "(&o@a{sv})", &session_handle, &options);
    std::lock_guard<std::mutex> lock(capture_mutex_);
    if (input_capture_session_handle_ !=
        (session_handle == nullptr ? "" : session_handle)) {
      if (options != nullptr) {
        g_variant_unref(options);
      }
      return;
    }
    uint32_t barrier_id = 0;
    Uint32FromVariantDict(options, "barrier_id", &barrier_id);
    uint32_t activation_id = 0;
    Uint32FromVariantDict(options, "activation_id", &activation_id);
    const InputCaptureBarrier* barrier =
        InputCaptureBarrierByIdLocked(barrier_id);
    if (barrier != nullptr) {
      input_capture_active_route_id_ = barrier->route.route_id;
      input_capture_active_display_id_ = barrier->route.source_display_id;
      input_capture_active_edge_ = barrier->route.source_edge;
      input_capture_active_segment_ = barrier->route.source_segment;
      input_capture_active_bounds_ =
          BoundsForDisplay(input_capture_x_display_,
                           input_capture_active_display_id_);
    } else {
      input_capture_active_route_id_.clear();
      input_capture_active_display_id_ = capture_display_id_;
      input_capture_active_edge_ = capture_edge_;
      input_capture_active_segment_ = capture_segment_;
      input_capture_active_bounds_ =
          BoundsForDisplay(input_capture_x_display_,
                           input_capture_active_display_id_);
    }
    double cursor_x = 0;
    double cursor_y = 0;
    if (!DoublePairFromVariantDict(options, "cursor_position", &cursor_x,
                                   &cursor_y) &&
        barrier != nullptr) {
      cursor_x = (barrier->x1 + barrier->x2) / 2.0;
      cursor_y = (barrier->y1 + barrier->y2) / 2.0;
    }
    input_capture_x_ = static_cast<int>(std::lround(cursor_x));
    input_capture_y_ = static_cast<int>(std::lround(cursor_y));
    input_capture_active_ = true;
    input_capture_pending_active_start_ = true;
    input_capture_activation_id_ = activation_id;
    input_capture_activation_sequence_ = input_capture_sequence_ + 1;
    input_capture_activation_edge_unit_ =
        EdgeUnitForPoint(input_capture_x_, input_capture_y_,
                         input_capture_active_edge_,
                         input_capture_active_segment_);
    capture_route_id_ = input_capture_active_route_id_;
    std::ostringstream trace;
    trace << "linux remote input portal capture active edge="
          << input_capture_active_edge_ << " barrier=" << barrier_id
          << " activation=" << activation_id << " cursor=" << input_capture_x_
          << "," << input_capture_y_;
    TraceRemoteInput(trace.str());
    EmitDiagnosticForSession(capture_session_id_,
                             "linux remote input portal capture active edge=" +
                                 input_capture_active_edge_);
    if (options != nullptr) {
      g_variant_unref(options);
    }
  }

  void HandleInputCaptureDeactivated(GVariant* parameters) {
    const gchar* session_handle = nullptr;
    GVariant* options = nullptr;
    g_variant_get(parameters, "(&o@a{sv})", &session_handle, &options);
    std::lock_guard<std::mutex> lock(capture_mutex_);
    if (input_capture_session_handle_ ==
        (session_handle == nullptr ? "" : session_handle)) {
      input_capture_active_ = false;
      input_capture_pending_active_start_ = false;
      input_capture_buttons_ = 0;
      TraceRemoteInput("linux remote input portal capture deactivated");
    }
    if (options != nullptr) {
      g_variant_unref(options);
    }
  }

  void HandleInputCaptureDisabled(GVariant* parameters) {
    const gchar* session_handle = nullptr;
    GVariant* options = nullptr;
    g_variant_get(parameters, "(&o@a{sv})", &session_handle, &options);
    std::lock_guard<std::mutex> lock(capture_mutex_);
    if (input_capture_session_handle_ ==
        (session_handle == nullptr ? "" : session_handle)) {
      input_capture_active_ = false;
      input_capture_pending_active_start_ = false;
      input_capture_buttons_ = 0;
      TraceRemoteInput("linux remote input portal capture disabled");
    }
    if (options != nullptr) {
      g_variant_unref(options);
    }
  }

  void HandleInputCaptureZonesChanged(GVariant* parameters) {
    const gchar* session_handle = nullptr;
    GVariant* options = nullptr;
    g_variant_get(parameters, "(&o@a{sv})", &session_handle, &options);
    std::lock_guard<std::mutex> lock(capture_mutex_);
    if (input_capture_session_handle_ ==
        (session_handle == nullptr ? "" : session_handle)) {
      EmitDiagnosticForSession(capture_session_id_,
                               "linux remote input portal zones changed");
    }
    if (options != nullptr) {
      g_variant_unref(options);
    }
  }

  static void InputCaptureActivatedCallback(GDBusConnection*,
                                            const gchar*,
                                            const gchar*,
                                            const gchar*,
                                            const gchar*,
                                            GVariant* parameters,
                                            gpointer user_data) {
    static_cast<RemoteInputPlugin*>(user_data)->HandleInputCaptureActivated(
        parameters);
  }

  static void InputCaptureDeactivatedCallback(GDBusConnection*,
                                              const gchar*,
                                              const gchar*,
                                              const gchar*,
                                              const gchar*,
                                              GVariant* parameters,
                                              gpointer user_data) {
    static_cast<RemoteInputPlugin*>(user_data)->HandleInputCaptureDeactivated(
        parameters);
  }

  static void InputCaptureDisabledCallback(GDBusConnection*,
                                           const gchar*,
                                           const gchar*,
                                           const gchar*,
                                           const gchar*,
                                           GVariant* parameters,
                                           gpointer user_data) {
    static_cast<RemoteInputPlugin*>(user_data)->HandleInputCaptureDisabled(
        parameters);
  }

  static void InputCaptureZonesChangedCallback(GDBusConnection*,
                                               const gchar*,
                                               const gchar*,
                                               const gchar*,
                                               const gchar*,
                                               GVariant* parameters,
                                               gpointer user_data) {
    static_cast<RemoteInputPlugin*>(user_data)->HandleInputCaptureZonesChanged(
        parameters);
  }

  void InputCaptureEventLoop(const std::string& session_id) {
    while (input_capture_running_.load()) {
      int fd = -1;
      {
        std::lock_guard<std::mutex> lock(capture_mutex_);
        if (input_capture_ei_ == nullptr || capture_session_id_ != session_id) {
          return;
        }
        fd = ei_get_fd(input_capture_ei_);
      }
      if (fd < 0) {
        return;
      }
      pollfd pfd = {};
      pfd.fd = fd;
      pfd.events = POLLIN;
      const int poll_result = poll(&pfd, 1, 100);
      if (poll_result <= 0) {
        continue;
      }
      std::string error;
      {
        std::lock_guard<std::mutex> lock(capture_mutex_);
        if (input_capture_ei_ == nullptr || capture_session_id_ != session_id) {
          return;
        }
        DispatchInputCaptureEiLocked(&error);
      }
      if (!error.empty()) {
        EmitErrorForSession(session_id, error);
        input_capture_running_.store(false);
        return;
      }
    }
  }

  void DispatchInputCaptureEiLocked(std::string* error) {
    error->clear();
    if (input_capture_ei_ == nullptr) {
      return;
    }
    ei_dispatch(input_capture_ei_);
    struct ei_event* event = nullptr;
    while ((event = ei_get_event(input_capture_ei_)) != nullptr) {
      HandleInputCaptureEiEventLocked(event, error);
      ei_event_unref(event);
      if (!error->empty()) {
        return;
      }
    }
  }

  void HandleInputCaptureEiEventLocked(struct ei_event* event,
                                       std::string* error) {
    switch (ei_event_get_type(event)) {
      case EI_EVENT_CONNECT:
        return;
      case EI_EVENT_DISCONNECT:
        *error = "Linux input capture client disconnected";
        return;
      case EI_EVENT_SEAT_ADDED: {
        struct ei_seat* seat = ei_event_get_seat(event);
        if (seat != nullptr) {
          ei_seat_bind_capabilities(seat, EI_DEVICE_CAP_POINTER,
                                    EI_DEVICE_CAP_BUTTON, EI_DEVICE_CAP_SCROLL,
                                    EI_DEVICE_CAP_KEYBOARD, NULL);
        }
        return;
      }
      case EI_EVENT_DEVICE_START_EMULATING:
        input_capture_active_ = true;
        if (input_capture_activation_sequence_ == 0) {
          input_capture_pending_active_start_ = true;
          input_capture_activation_sequence_ = input_capture_sequence_ + 1;
        }
        return;
      case EI_EVENT_DEVICE_STOP_EMULATING:
        input_capture_active_ = false;
        input_capture_pending_active_start_ = false;
        input_capture_buttons_ = 0;
        return;
      case EI_EVENT_POINTER_MOTION:
        EmitInputCaptureMouseMoveLocked(
            static_cast<int>(std::lround(ei_event_pointer_get_dx(event))),
            static_cast<int>(std::lround(ei_event_pointer_get_dy(event))));
        return;
      case EI_EVENT_POINTER_MOTION_ABSOLUTE:
        EmitInputCaptureAbsoluteMoveLocked(
            static_cast<int>(std::lround(
                ei_event_pointer_get_absolute_x(event))),
            static_cast<int>(std::lround(
                ei_event_pointer_get_absolute_y(event))));
        return;
      case EI_EVENT_BUTTON_BUTTON:
        EmitInputCaptureButtonLocked(
            ProtocolButtonForEvdevButton(ei_event_button_get_button(event)),
            ei_event_button_get_is_press(event));
        return;
      case EI_EVENT_SCROLL_DISCRETE:
        EmitInputEvent(capture_session_id_, "mouseWheel",
                       ++input_capture_sequence_,
                       JsonBytes(MouseWheelPayload(
                           ei_event_scroll_get_discrete_dx(event),
                           ei_event_scroll_get_discrete_dy(event))));
        return;
      case EI_EVENT_SCROLL_DELTA:
        EmitInputEvent(capture_session_id_, "mouseWheel",
                       ++input_capture_sequence_,
                       JsonBytes(MouseWheelPayload(
                           static_cast<int>(std::lround(
                               ei_event_scroll_get_dx(event))),
                           static_cast<int>(std::lround(
                               ei_event_scroll_get_dy(event))))));
        return;
      case EI_EVENT_KEYBOARD_KEY:
        EmitInputEvent(capture_session_id_, "key", ++input_capture_sequence_,
                       JsonBytes(LinuxKeyPayload(
                           static_cast<int>(ei_event_keyboard_get_key(event)),
                           ei_event_keyboard_get_key_is_press(event))));
        return;
      default:
        return;
    }
  }

  void EmitInputCaptureMouseMoveLocked(int delta_x, int delta_y) {
    if (!input_capture_active_ && !input_capture_pending_active_start_) {
      return;
    }
    const bool active_start = input_capture_pending_active_start_;
    input_capture_pending_active_start_ = false;
    const int payload_x =
        active_start ? input_capture_x_ : input_capture_x_ + delta_x;
    const int payload_y =
        active_start ? input_capture_y_ : input_capture_y_ + delta_y;
    input_capture_x_ += delta_x;
    input_capture_y_ += delta_y;
    if (delta_x == 0 && delta_y == 0 && !active_start) {
      return;
    }
    EmitInputEvent(
        capture_session_id_, "mouseMove", ++input_capture_sequence_,
        JsonBytes(MouseMovePayload(
            input_capture_x_display_, payload_x, payload_y, delta_x, delta_y,
            active_start, input_capture_active_edge_,
            input_capture_active_route_id_, input_capture_buttons_,
            input_capture_active_bounds_, input_capture_active_segment_,
            active_start ? input_capture_activation_edge_unit_ : -1)));
    if (active_start) {
      input_capture_activation_edge_unit_ = -1;
    }
  }

  void EmitInputCaptureAbsoluteMoveLocked(int x, int y) {
    const int delta_x = x - input_capture_x_;
    const int delta_y = y - input_capture_y_;
    EmitInputCaptureMouseMoveLocked(delta_x, delta_y);
  }

  int ProtocolButtonForEvdevButton(uint32_t button) const {
    if (button == BTN_RIGHT) {
      return 1;
    }
    if (button == BTN_MIDDLE) {
      return 2;
    }
    if (button == BTN_LEFT) {
      return 0;
    }
    return -1;
  }

  void EmitInputCaptureButtonLocked(int button, bool down) {
    if (button < 0) {
      return;
    }
    const int bit = MouseButtonBit(button);
    if (down) {
      input_capture_buttons_ |= bit;
    } else {
      input_capture_buttons_ &= ~bit;
    }
    EmitInputEvent(capture_session_id_, "mouseButton",
                   ++input_capture_sequence_,
                   JsonBytes(MouseButtonPayload(input_capture_x_,
                                                input_capture_y_, button,
                                                down)));
  }

  DoublePoint ReleaseCursorPositionForInputCapture(
      double release_edge_unit,
      const std::string& release_display_id,
      const std::string& release_edge,
      const EdgeSegment& release_segment) const {
    const std::string display_id =
        release_display_id.empty() ? input_capture_active_display_id_
                                   : release_display_id;
    const std::string edge =
        release_edge.empty() ? input_capture_active_edge_ : release_edge;
    const EdgeSegment segment =
        HasSegment(release_segment) ? release_segment
                                    : input_capture_active_segment_;
    const ScreenBounds bounds =
        BoundsForDisplay(input_capture_x_display_, display_id);
    int x = ClampInt(input_capture_x_, bounds.left + kCaptureCursorInset,
                     bounds.right() - kCaptureCursorInset);
    int y = ClampInt(input_capture_y_, bounds.top + kCaptureCursorInset,
                     bounds.bottom() - kCaptureCursorInset);
    if (HasSegment(segment)) {
      const int coordinate = SegmentCoordinate(release_edge_unit, segment);
      if (edge == "left" || edge == "right") {
        y = ClampInt(coordinate, bounds.top + kCaptureCursorInset,
                     bounds.bottom() - kCaptureCursorInset);
      } else {
        x = ClampInt(coordinate, bounds.left + kCaptureCursorInset,
                     bounds.right() - kCaptureCursorInset);
      }
    }
    if (edge == "left") {
      x = bounds.left + kCaptureCursorInset;
    } else if (edge == "top") {
      y = bounds.top + kCaptureCursorInset;
    } else if (edge == "bottom") {
      y = bounds.bottom() - kCaptureCursorInset;
    } else {
      x = bounds.right() - kCaptureCursorInset;
    }
    return DoublePoint{static_cast<double>(x), static_cast<double>(y)};
  }

  void ReleaseInputCapturePortalLocked(double release_edge_unit,
                                       const std::string& release_display_id,
                                       const std::string& release_edge,
                                       const EdgeSegment& release_segment,
                                       const std::string& release_route_id) {
    if (input_capture_connection_ == nullptr ||
        input_capture_session_handle_.empty()) {
      return;
    }
    const DoublePoint cursor = ReleaseCursorPositionForInputCapture(
        release_edge_unit, release_display_id, release_edge, release_segment);
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    if (input_capture_activation_id_ != 0) {
      g_variant_builder_add(&options, "{sv}", "activation_id",
                            g_variant_new_uint32(input_capture_activation_id_));
    }
    g_variant_builder_add(&options, "{sv}", "cursor_position",
                          g_variant_new("(dd)", cursor.x, cursor.y));
    GError* call_error = nullptr;
    GVariant* result = g_dbus_connection_call_sync(
        input_capture_connection_, kPortalBusName, kPortalObjectPath,
        kPortalInputCaptureInterface, "Release",
        g_variant_new("(oa{sv})", input_capture_session_handle_.c_str(),
                      &options),
        nullptr, G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &call_error);
    if (result != nullptr) {
      g_variant_unref(result);
    } else if (call_error != nullptr) {
      TraceRemoteInput(std::string("linux remote input portal release failed: ") +
                       (call_error->message == nullptr ? ""
                                                       : call_error->message));
      g_error_free(call_error);
    }
    input_capture_active_ = false;
    input_capture_pending_active_start_ = false;
    input_capture_activation_id_ = 0;
    input_capture_buttons_ = 0;
    input_capture_x_ = static_cast<int>(std::lround(cursor.x));
    input_capture_y_ = static_cast<int>(std::lround(cursor.y));
    input_capture_active_route_id_ = release_route_id;
  }

  void ClearInputCapturePortalLocked() {
    if (input_capture_connection_ != nullptr) {
      if (input_capture_activated_signal_id_ != 0) {
        g_dbus_connection_signal_unsubscribe(
            input_capture_connection_, input_capture_activated_signal_id_);
      }
      if (input_capture_deactivated_signal_id_ != 0) {
        g_dbus_connection_signal_unsubscribe(
            input_capture_connection_, input_capture_deactivated_signal_id_);
      }
      if (input_capture_disabled_signal_id_ != 0) {
        g_dbus_connection_signal_unsubscribe(
            input_capture_connection_, input_capture_disabled_signal_id_);
      }
      if (input_capture_zones_changed_signal_id_ != 0) {
        g_dbus_connection_signal_unsubscribe(
            input_capture_connection_, input_capture_zones_changed_signal_id_);
      }
    }
    input_capture_activated_signal_id_ = 0;
    input_capture_deactivated_signal_id_ = 0;
    input_capture_disabled_signal_id_ = 0;
    input_capture_zones_changed_signal_id_ = 0;
    if (input_capture_ei_ != nullptr) {
      ei_disconnect(input_capture_ei_);
      input_capture_ei_ = ei_unref(input_capture_ei_);
    }
    if (input_capture_connection_ != nullptr) {
      ClosePortalSession(input_capture_connection_, input_capture_session_handle_);
      g_object_unref(input_capture_connection_);
      input_capture_connection_ = nullptr;
    }
    input_capture_session_handle_.clear();
    if (input_capture_x_display_ != nullptr) {
      XCloseDisplay(input_capture_x_display_);
      input_capture_x_display_ = nullptr;
    }
    input_capture_barriers_.clear();
    input_capture_zone_set_ = 0;
    ResetInputCaptureStateLocked();
  }

#endif

  bool StartInjection(const std::string& session_id,
                      const std::string& display_id,
                      const std::string& edge,
                      EdgeSegment segment,
                      std::vector<InjectionRoute> routes,
                      std::string* error) {
#if HAVE_X11_REMOTE_INPUT
    StopInjection("");
    if (IsLinuxDesktopLocked()) {
      *error = "Unlock the Linux desktop before sharing keyboard and mouse";
      TraceRemoteInput(
          "linux remote input injection blocked because desktop is locked");
      return false;
    }
    bool portal_attempted = false;
    if (TryStartPortalInjection(session_id, display_id, edge, segment, routes,
                                &portal_attempted, error)) {
      return true;
    }
    if (portal_attempted) {
      return false;
    }
    return StartX11Injection(session_id, display_id, edge, segment,
                             std::move(routes), error);
#else
    (void)session_id;
    (void)display_id;
    (void)edge;
    (void)segment;
    (void)routes;
    *error = "X11 remote input support is not available in this Linux build";
    return false;
#endif
  }

  bool StartX11Injection(const std::string& session_id,
                         const std::string& display_id,
                         const std::string& edge,
                         EdgeSegment segment,
                         std::vector<InjectionRoute> routes,
                         std::string* error) {
#if HAVE_X11_REMOTE_INPUT
    Display* display = XOpenDisplay(nullptr);
    if (display == nullptr) {
      *error = "Unable to open X11 display for remote input injection";
      return false;
    }
    std::lock_guard<std::mutex> lock(injection_mutex_);
    injection_backend_ = InjectionBackend::kX11;
    injection_display_ = display;
    injection_session_id_ = session_id;
    injection_display_id_ = display_id;
    injection_edge_ = edge;
    injection_segment_ = segment;
    injection_route_id_.clear();
    injection_routes_ = routes;
    injected_cursor_entered_interior_ = false;
    has_injected_cursor_position_ = false;
    injected_cursor_x_ = 0;
    injected_cursor_y_ = 0;
    injected_buttons_ = 0;
    injected_keys_.clear();
    std::ostringstream trace;
    trace << "linux remote input injection started session=" << session_id
          << " edge=" << (edge.empty() ? "-" : edge)
          << " display=" << (display_id.empty() ? "-" : display_id)
          << " segment=" << SegmentTrace(segment)
          << " routes=" << routes.size();
    TraceRemoteInput(trace.str());
    EmitDiagnosticForSession(session_id,
                             "linux remote input x11 injection started");
    return true;
#else
    (void)session_id;
    (void)display_id;
    (void)edge;
    (void)segment;
    (void)routes;
    *error = "X11 remote input support is not available in this Linux build";
    return false;
#endif
  }

  bool TryStartPortalInjection(const std::string& session_id,
                               const std::string& display_id,
                               const std::string& edge,
                               EdgeSegment segment,
                               std::vector<InjectionRoute> routes,
                               bool* attempted,
                               std::string* error) {
#if HAVE_LIBEI_REMOTE_INPUT
    *attempted = false;
    if (!RemoteDesktopPortalAvailable()) {
      return false;
    }
    *attempted = true;
    return StartPortalInjection(session_id, display_id, edge, segment,
                                std::move(routes), error);
#else
    (void)session_id;
    (void)display_id;
    (void)edge;
    (void)segment;
    (void)routes;
    (void)error;
    *attempted = false;
    return false;
#endif
  }

#if HAVE_LIBEI_REMOTE_INPUT
  bool StartPortalInjection(const std::string& session_id,
                            const std::string& display_id,
                            const std::string& edge,
                            EdgeSegment segment,
                            std::vector<InjectionRoute> routes,
                            std::string* error) {
    PortalSession session;
    if (!StartRemoteDesktopPortalSession(&session, error)) {
      return false;
    }
    struct ei* portal_ei = ei_new_sender(nullptr);
    if (portal_ei == nullptr) {
      *error = "Unable to create Linux remote desktop input client";
      if (session.eis_fd >= 0) {
        close(session.eis_fd);
      }
      ClosePortalSession(session.connection, session.session_handle);
      g_object_unref(session.connection);
      return false;
    }
    ei_configure_name(portal_ei, "Whisper");
    const int setup_result = ei_setup_backend_fd(portal_ei, session.eis_fd);
    session.eis_fd = -1;
    if (setup_result < 0) {
      *error = "Unable to connect Linux remote desktop input client";
      ei_unref(portal_ei);
      ClosePortalSession(session.connection, session.session_handle);
      g_object_unref(session.connection);
      return false;
    }
    Display* x_display = XOpenDisplay(nullptr);
    std::lock_guard<std::mutex> lock(injection_mutex_);
    injection_backend_ = InjectionBackend::kPortal;
    injection_session_id_ = session_id;
    injection_display_id_ = display_id;
    injection_edge_ = edge;
    injection_segment_ = segment;
    injection_route_id_.clear();
    injection_routes_ = routes;
    injected_cursor_entered_interior_ = false;
    has_injected_cursor_position_ = false;
    injected_cursor_x_ = 0;
    injected_cursor_y_ = 0;
    injected_buttons_ = 0;
    injected_keys_.clear();
    portal_connection_ = session.connection;
    portal_session_handle_ = session.session_handle;
    portal_ei_ = portal_ei;
    portal_x_display_ = x_display;
    portal_running_.store(true);
    ResetPortalDeviceStateLocked();
    if (!WaitForPortalDevicesLocked(error)) {
      portal_running_.store(false);
      ReleaseInjectedButtonsLocked();
      ReleaseInjectedKeysLocked();
      ReleaseCommonModifierKeysLocked();
      ClearPortalInjectionLocked();
      injection_backend_ = InjectionBackend::kNone;
      injection_session_id_.clear();
      return false;
    }
    portal_thread_ = std::thread([this, session_id] {
      PortalEventLoop(session_id);
    });
    TraceRemoteInput("linux remote input portal injection started session=" +
                     session_id);
    EmitDiagnosticForSession(session_id,
                             "linux remote input portal injection started");
    return true;
  }

  void ResetPortalDeviceStateLocked() {
    portal_pointer_ready_ = false;
    portal_absolute_pointer_ready_ = false;
    portal_button_ready_ = false;
    portal_scroll_ready_ = false;
    portal_keyboard_ready_ = false;
    portal_emulation_sequence_ = 0;
  }

  bool WaitForPortalDevicesLocked(std::string* error) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!PortalDevicesReadyLocked()) {
      const int fd = portal_ei_ == nullptr ? -1 : ei_get_fd(portal_ei_);
      if (fd < 0) {
        *error = "Linux remote desktop input client has no event fd";
        return false;
      }
      const auto now = std::chrono::steady_clock::now();
      if (now >= deadline) {
        *error = "Timed out waiting for Linux remote desktop input devices";
        return false;
      }
      const int remaining_ms = static_cast<int>(
          std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now)
              .count());
      pollfd pfd = {};
      pfd.fd = fd;
      pfd.events = POLLIN;
      const int poll_result = poll(&pfd, 1, std::min(100, remaining_ms));
      if (poll_result < 0) {
        if (errno == EINTR) {
          continue;
        }
        *error = "Unable to poll Linux remote desktop input client";
        return false;
      }
      if (poll_result == 0) {
        continue;
      }
      DispatchPortalEiLocked(error);
      if (!error->empty()) {
        return false;
      }
    }
    return true;
  }

  bool PortalDevicesReadyLocked() const {
    return portal_pointer_device_ != nullptr && portal_keyboard_device_ != nullptr &&
           portal_button_device_ != nullptr && portal_pointer_ready_ &&
           portal_keyboard_ready_ && portal_button_ready_;
  }

  void PortalEventLoop(const std::string& session_id) {
    while (portal_running_.load()) {
      int fd = -1;
      {
        std::lock_guard<std::mutex> lock(injection_mutex_);
        if (portal_ei_ == nullptr || injection_session_id_ != session_id) {
          return;
        }
        fd = ei_get_fd(portal_ei_);
      }
      if (fd < 0) {
        return;
      }
      pollfd pfd = {};
      pfd.fd = fd;
      pfd.events = POLLIN;
      const int poll_result = poll(&pfd, 1, 100);
      if (poll_result <= 0) {
        continue;
      }
      std::string error;
      {
        std::lock_guard<std::mutex> lock(injection_mutex_);
        if (portal_ei_ == nullptr || injection_session_id_ != session_id) {
          return;
        }
        DispatchPortalEiLocked(&error);
      }
      if (!error.empty()) {
        EmitErrorForSession(session_id, error);
        portal_running_.store(false);
        return;
      }
    }
  }

  void DispatchPortalEiLocked(std::string* error) {
    error->clear();
    if (portal_ei_ == nullptr) {
      return;
    }
    ei_dispatch(portal_ei_);
    struct ei_event* event = nullptr;
    while ((event = ei_get_event(portal_ei_)) != nullptr) {
      HandlePortalEiEventLocked(event, error);
      ei_event_unref(event);
      if (!error->empty()) {
        return;
      }
    }
  }

  void HandlePortalEiEventLocked(struct ei_event* event, std::string* error) {
    switch (ei_event_get_type(event)) {
      case EI_EVENT_CONNECT:
        return;
      case EI_EVENT_DISCONNECT:
        *error = "Linux remote desktop input client disconnected";
        return;
      case EI_EVENT_SEAT_ADDED: {
        struct ei_seat* seat = ei_event_get_seat(event);
        if (seat != nullptr) {
          ei_seat_bind_capabilities(seat, EI_DEVICE_CAP_POINTER,
                                    EI_DEVICE_CAP_POINTER_ABSOLUTE,
                                    EI_DEVICE_CAP_BUTTON,
                                    EI_DEVICE_CAP_SCROLL,
                                    EI_DEVICE_CAP_KEYBOARD, NULL);
        }
        return;
      }
      case EI_EVENT_DEVICE_ADDED:
        StorePortalDeviceLocked(ei_event_get_device(event));
        return;
      case EI_EVENT_DEVICE_REMOVED:
        RemovePortalDeviceLocked(ei_event_get_device(event));
        return;
      case EI_EVENT_DEVICE_PAUSED:
        MarkPortalDeviceReadyLocked(ei_event_get_device(event), false);
        return;
      case EI_EVENT_DEVICE_RESUMED: {
        struct ei_device* device = ei_event_get_device(event);
        StorePortalDeviceLocked(device);
        if (device != nullptr) {
          ei_device_start_emulating(device, ++portal_emulation_sequence_);
          MarkPortalDeviceReadyLocked(device, true);
        }
        return;
      }
      default:
        return;
    }
  }

  void StorePortalDeviceLocked(struct ei_device* device) {
    if (device == nullptr) {
      return;
    }
    if (portal_pointer_device_ == nullptr &&
        ei_device_has_capability(device, EI_DEVICE_CAP_POINTER)) {
      portal_pointer_device_ = ei_device_ref(device);
    }
    if (portal_absolute_pointer_device_ == nullptr &&
        ei_device_has_capability(device, EI_DEVICE_CAP_POINTER_ABSOLUTE)) {
      portal_absolute_pointer_device_ = ei_device_ref(device);
    }
    if (portal_button_device_ == nullptr &&
        ei_device_has_capability(device, EI_DEVICE_CAP_BUTTON)) {
      portal_button_device_ = ei_device_ref(device);
    }
    if (portal_scroll_device_ == nullptr &&
        ei_device_has_capability(device, EI_DEVICE_CAP_SCROLL)) {
      portal_scroll_device_ = ei_device_ref(device);
    }
    if (portal_keyboard_device_ == nullptr &&
        ei_device_has_capability(device, EI_DEVICE_CAP_KEYBOARD)) {
      portal_keyboard_device_ = ei_device_ref(device);
    }
  }

  void RemovePortalDeviceLocked(struct ei_device* device) {
    if (device == nullptr) {
      return;
    }
    if (device == portal_pointer_device_) {
      portal_pointer_device_ = ei_device_unref(portal_pointer_device_);
      portal_pointer_ready_ = false;
    }
    if (device == portal_absolute_pointer_device_) {
      portal_absolute_pointer_device_ =
          ei_device_unref(portal_absolute_pointer_device_);
      portal_absolute_pointer_ready_ = false;
    }
    if (device == portal_button_device_) {
      portal_button_device_ = ei_device_unref(portal_button_device_);
      portal_button_ready_ = false;
    }
    if (device == portal_scroll_device_) {
      portal_scroll_device_ = ei_device_unref(portal_scroll_device_);
      portal_scroll_ready_ = false;
    }
    if (device == portal_keyboard_device_) {
      portal_keyboard_device_ = ei_device_unref(portal_keyboard_device_);
      portal_keyboard_ready_ = false;
    }
  }

  void MarkPortalDeviceReadyLocked(struct ei_device* device, bool ready) {
    if (device == nullptr) {
      return;
    }
    if (device == portal_pointer_device_) {
      portal_pointer_ready_ = ready;
    }
    if (device == portal_absolute_pointer_device_) {
      portal_absolute_pointer_ready_ = ready;
    }
    if (device == portal_button_device_) {
      portal_button_ready_ = ready;
    }
    if (device == portal_scroll_device_) {
      portal_scroll_ready_ = ready;
    }
    if (device == portal_keyboard_device_) {
      portal_keyboard_ready_ = ready;
    }
  }

  void AddUniquePortalDevice(std::vector<ei_device*>* devices,
                             ei_device* device) const {
    if (device == nullptr) {
      return;
    }
    if (std::find(devices->begin(), devices->end(), device) ==
        devices->end()) {
      devices->push_back(device);
    }
  }

  std::vector<ei_device*> UniquePortalDevicesLocked() const {
    std::vector<ei_device*> devices;
    AddUniquePortalDevice(&devices, portal_pointer_device_);
    AddUniquePortalDevice(&devices, portal_absolute_pointer_device_);
    AddUniquePortalDevice(&devices, portal_button_device_);
    AddUniquePortalDevice(&devices, portal_scroll_device_);
    AddUniquePortalDevice(&devices, portal_keyboard_device_);
    return devices;
  }

  std::vector<ei_device*> UniquePortalReadyDevicesLocked() const {
    std::vector<ei_device*> devices;
    if (portal_pointer_ready_) {
      AddUniquePortalDevice(&devices, portal_pointer_device_);
    }
    if (portal_absolute_pointer_ready_) {
      AddUniquePortalDevice(&devices, portal_absolute_pointer_device_);
    }
    if (portal_button_ready_) {
      AddUniquePortalDevice(&devices, portal_button_device_);
    }
    if (portal_scroll_ready_) {
      AddUniquePortalDevice(&devices, portal_scroll_device_);
    }
    if (portal_keyboard_ready_) {
      AddUniquePortalDevice(&devices, portal_keyboard_device_);
    }
    return devices;
  }

  void ClearPortalInjectionLocked() {
    if (portal_ei_ != nullptr) {
      for (auto* device : UniquePortalReadyDevicesLocked()) {
        ei_device_stop_emulating(device);
      }
    }
    if (portal_pointer_device_ != nullptr) {
      portal_pointer_device_ = ei_device_unref(portal_pointer_device_);
    }
    if (portal_absolute_pointer_device_ != nullptr) {
      portal_absolute_pointer_device_ =
          ei_device_unref(portal_absolute_pointer_device_);
    }
    if (portal_button_device_ != nullptr) {
      portal_button_device_ = ei_device_unref(portal_button_device_);
    }
    if (portal_scroll_device_ != nullptr) {
      portal_scroll_device_ = ei_device_unref(portal_scroll_device_);
    }
    if (portal_keyboard_device_ != nullptr) {
      portal_keyboard_device_ = ei_device_unref(portal_keyboard_device_);
    }
    ResetPortalDeviceStateLocked();
    if (portal_ei_ != nullptr) {
      ei_disconnect(portal_ei_);
      portal_ei_ = ei_unref(portal_ei_);
    }
    if (portal_connection_ != nullptr) {
      ClosePortalSession(portal_connection_, portal_session_handle_);
      g_object_unref(portal_connection_);
      portal_connection_ = nullptr;
    }
    portal_session_handle_.clear();
    if (portal_x_display_ != nullptr) {
      XCloseDisplay(portal_x_display_);
      portal_x_display_ = nullptr;
    }
  }
#endif

  void StopInjection(const std::string& session_id) {
#if HAVE_X11_REMOTE_INPUT
    std::thread portal_thread_to_join;
#if HAVE_LIBEI_REMOTE_INPUT
    {
      std::lock_guard<std::mutex> lock(injection_mutex_);
      if (!session_id.empty() && session_id != injection_session_id_) {
        return;
      }
      if (injection_backend_ == InjectionBackend::kPortal) {
        portal_running_.store(false);
        if (portal_thread_.joinable()) {
          portal_thread_to_join = std::move(portal_thread_);
        }
      }
    }
    if (portal_thread_to_join.joinable()) {
      portal_thread_to_join.join();
    }
#endif
    std::lock_guard<std::mutex> lock(injection_mutex_);
    if (!session_id.empty() && session_id != injection_session_id_) {
      return;
    }
    ReleaseInjectedButtonsLocked();
    ReleaseInjectedKeysLocked();
    ReleaseCommonModifierKeysLocked();
#if HAVE_LIBEI_REMOTE_INPUT
    ClearPortalInjectionLocked();
#endif
    if (injection_display_ != nullptr) {
      XCloseDisplay(injection_display_);
      injection_display_ = nullptr;
    }
    injection_session_id_.clear();
    injection_display_id_.clear();
    injection_edge_.clear();
    injection_route_id_.clear();
    injection_segment_ = EdgeSegment{};
    injection_routes_.clear();
    injected_cursor_entered_interior_ = false;
    has_injected_cursor_position_ = false;
    injected_cursor_x_ = 0;
    injected_cursor_y_ = 0;
    injection_backend_ = InjectionBackend::kNone;
#else
    (void)session_id;
#endif
  }

  void InjectEvent(const std::string& session_id,
                   const std::string& event_type,
                   const std::vector<uint8_t>& payload) {
#if HAVE_X11_REMOTE_INPUT
    std::lock_guard<std::mutex> lock(injection_mutex_);
    if (session_id != injection_session_id_ ||
        injection_backend_ == InjectionBackend::kNone) {
      return;
    }
    const std::string json = PayloadString(payload);
#if HAVE_LIBEI_REMOTE_INPUT
    if (injection_backend_ == InjectionBackend::kPortal) {
      InjectPortalEventLocked(event_type, json);
      return;
    }
#endif
    if (injection_display_ == nullptr) {
      return;
    }
    if (event_type == "mouseMove") {
      InjectMouseMoveLocked(json);
      return;
    }
    if (event_type == "mouseButton") {
      const int button =
          static_cast<int>(std::lround(JsonNumber(json, "button")));
      const bool down = JsonBool(json, "down");
      SendMouseButtonLocked(button, down);
      SetInjectedButton(button, down);
      XFlush(injection_display_);
      return;
    }
    if (event_type == "mouseWheel") {
      const int delta_x =
          static_cast<int>(std::lround(JsonNumber(json, "deltaX")));
      const int delta_y =
          static_cast<int>(std::lround(JsonNumber(json, "deltaY")));
      SendMouseWheelLocked(delta_x, delta_y);
      XFlush(injection_display_);
      return;
    }
    if (event_type == "key") {
      const int linux_key = static_cast<int>(std::lround(
          JsonNumber(json, "linuxKeyCode", JsonNumber(json, "keyCode"))));
      const bool down = JsonBool(json, "down");
      SendKeyboardKeyLocked(linux_key + 8, down);
      SetInjectedKey(linux_key + 8, down);
      XFlush(injection_display_);
    }
#else
    (void)session_id;
    (void)event_type;
    (void)payload;
#endif
  }

#if HAVE_X11_REMOTE_INPUT && HAVE_LIBEI_REMOTE_INPUT
  void InjectPortalEventLocked(const std::string& event_type,
                               const std::string& json) {
    if (event_type == "mouseMove") {
      InjectPortalMouseMoveLocked(json);
      return;
    }
    if (event_type == "mouseButton") {
      const int button =
          static_cast<int>(std::lround(JsonNumber(json, "button")));
      const bool down = JsonBool(json, "down");
      SendPortalMouseButtonLocked(button, down);
      SetInjectedButton(button, down);
      return;
    }
    if (event_type == "mouseWheel") {
      const int delta_x =
          static_cast<int>(std::lround(JsonNumber(json, "deltaX")));
      const int delta_y =
          static_cast<int>(std::lround(JsonNumber(json, "deltaY")));
      SendPortalMouseWheelLocked(delta_x, delta_y);
      return;
    }
    if (event_type == "key") {
      const int linux_key = static_cast<int>(std::lround(
          JsonNumber(json, "linuxKeyCode", JsonNumber(json, "keyCode"))));
      const bool down = JsonBool(json, "down");
      SendPortalKeyboardKeyLocked(linux_key, down);
      SetInjectedKey(linux_key, down);
    }
  }

  void InjectPortalMouseMoveLocked(const std::string& json) {
    const int delta_x =
        static_cast<int>(std::lround(JsonNumber(json, "deltaX")));
    const int delta_y =
        static_cast<int>(std::lround(JsonNumber(json, "deltaY")));
    int current_x = 0;
    int current_y = 0;
    unsigned int mask = 0;
    InjectedCursorPositionLocked(&current_x, &current_y, &mask);
    const bool active_start = JsonBool(json, "activeStart");
    Maybe<InjectionReleaseRoute> routed_release;
    if (!active_start && injected_cursor_entered_interior_) {
      routed_release =
          ReverseInjectionSourceEdgeUnit(current_x, current_y, delta_x,
                                         delta_y);
    }
    if (routed_release.has_value()) {
      const std::string session_id = injection_session_id_;
      const auto release_route = routed_release.value();
      ReleaseInjectedButtonsLocked();
      ReleaseInjectedKeysLocked();
      ReleaseCommonModifierKeysLocked();
      injected_cursor_entered_interior_ = false;
      has_injected_cursor_position_ = false;
      EmitReleaseForSession(
          session_id, "edge", 0, 0, release_route.edge_unit, true,
          release_route.route_id, release_route.source_display_id,
          release_route.source_edge, release_route.source_segment.start,
          release_route.source_segment.end);
      return;
    }
    if (!active_start && injected_cursor_entered_interior_ &&
        IsInjectionReverseRelease(json, current_x, current_y, delta_x,
                                  delta_y)) {
      const std::string session_id = injection_session_id_;
      const double edge_unit = InjectionEdgeUnit(current_x, current_y);
      ReleaseInjectedButtonsLocked();
      ReleaseInjectedKeysLocked();
      ReleaseCommonModifierKeysLocked();
      injected_cursor_entered_interior_ = false;
      has_injected_cursor_position_ = false;
      EmitReleaseForSession(session_id, "edge", 0, 0, edge_unit);
      return;
    }
    int final_x = current_x;
    int final_y = current_y;
    if (active_start) {
      SetPortalCursorPosForEntryLocked(json);
      injected_cursor_entered_interior_ = false;
      InjectedCursorPositionLocked(&current_x, &current_y, &mask);
      final_x = current_x;
      final_y = current_y;
    }
    const int buttons =
        static_cast<int>(std::lround(JsonNumber(json, "buttons", -1)));
    if (buttons >= 0) {
      SyncInjectedButtonsLocked(buttons);
    }
    if (delta_x != 0 || delta_y != 0) {
      SendPortalPointerMotionLocked(delta_x, delta_y);
      if (has_injected_cursor_position_) {
        final_x = injected_cursor_x_ + delta_x;
        final_y = injected_cursor_y_ + delta_y;
      } else {
        final_x += delta_x;
        final_y += delta_y;
      }
      RememberInjectedCursorPositionLocked(final_x, final_y);
    }
    UpdateInjectedCursorInteriorState(json, final_x, final_y);
  }

  void SetPortalCursorPosForEntryLocked(const std::string& json) {
    UpdateInjectionRouteFromPayload(json);
    if (portal_absolute_pointer_device_ == nullptr ||
        !portal_absolute_pointer_ready_) {
      return;
    }
    const double edge_unit = JsonNumber(json, "edgeUnit", -1);
    int x = 0;
    int y = 0;
    if (edge_unit >= 0 && HasSegment(injection_segment_) &&
        !injection_edge_.empty()) {
      const ScreenBounds bounds =
          BoundsForDisplay(InjectionBoundsDisplayLocked(),
                           injection_display_id_);
      const int coordinate = SegmentCoordinate(edge_unit, injection_segment_);
      x = bounds.left + kCaptureCursorInset;
      y = ClampInt(coordinate, bounds.top + kCaptureCursorInset,
                   bounds.bottom() - kCaptureCursorInset);
      if (injection_edge_ == "right") {
        x = bounds.right() - kCaptureCursorInset;
      } else if (injection_edge_ == "top") {
        x = ClampInt(coordinate, bounds.left + kCaptureCursorInset,
                     bounds.right() - kCaptureCursorInset);
        y = bounds.top + kCaptureCursorInset;
      } else if (injection_edge_ == "bottom") {
        x = ClampInt(coordinate, bounds.left + kCaptureCursorInset,
                     bounds.right() - kCaptureCursorInset);
        y = bounds.bottom() - kCaptureCursorInset;
      }
    } else {
      const ScreenBounds bounds = BoundsFor(InjectionBoundsDisplayLocked());
      const int unit_width = bounds.width > 1 ? bounds.width - 1 : 1;
      const int unit_height = bounds.height > 1 ? bounds.height - 1 : 1;
      const double unit_x = ClampedUnit(JsonNumber(json, "unitX"));
      const double unit_y = ClampedUnit(JsonNumber(json, "unitY"));
      const std::string edge = JsonString(json, "edge", "right");
      x = bounds.left + kCaptureCursorInset;
      y = ClampInt(
          bounds.top + static_cast<int>(std::lround(unit_y * unit_height)),
          bounds.top, bounds.bottom());
      if (edge == "left") {
        x = bounds.right() - kCaptureCursorInset;
      } else if (edge == "top") {
        x = ClampInt(
            bounds.left + static_cast<int>(std::lround(unit_x * unit_width)),
            bounds.left, bounds.right());
        y = bounds.bottom() - kCaptureCursorInset;
      } else if (edge == "bottom") {
        x = ClampInt(
            bounds.left + static_cast<int>(std::lround(unit_x * unit_width)),
            bounds.left, bounds.right());
        y = bounds.top + kCaptureCursorInset;
      }
    }
    ei_device_pointer_motion_absolute(portal_absolute_pointer_device_, x, y);
    PortalDeviceFrameLocked(portal_absolute_pointer_device_);
    RememberInjectedCursorPositionLocked(x, y);
  }

  void PortalDeviceFrameLocked(struct ei_device* device) {
    if (portal_ei_ == nullptr || device == nullptr) {
      return;
    }
    ei_device_frame(device, ei_now(portal_ei_));
  }

  void SendPortalPointerMotionLocked(int delta_x, int delta_y) {
    if (portal_pointer_device_ == nullptr || !portal_pointer_ready_) {
      return;
    }
    ei_device_pointer_motion(portal_pointer_device_, delta_x, delta_y);
    PortalDeviceFrameLocked(portal_pointer_device_);
  }

  int EvdevButtonForProtocolButton(int button) const {
    if (button == 1) {
      return BTN_RIGHT;
    }
    if (button == 2) {
      return BTN_MIDDLE;
    }
    return BTN_LEFT;
  }

  void SendPortalMouseButtonLocked(int button, bool down) {
    if (portal_button_device_ == nullptr || !portal_button_ready_) {
      return;
    }
    ei_device_button_button(portal_button_device_,
                            EvdevButtonForProtocolButton(button), down);
    PortalDeviceFrameLocked(portal_button_device_);
  }

  void SendPortalMouseWheelLocked(int delta_x, int delta_y) {
    if (portal_scroll_device_ == nullptr || !portal_scroll_ready_) {
      return;
    }
    if (delta_x == 0 && delta_y == 0) {
      return;
    }
    ei_device_scroll_discrete(portal_scroll_device_, delta_x, delta_y);
    PortalDeviceFrameLocked(portal_scroll_device_);
  }

  void SendPortalKeyboardKeyLocked(int linux_key, bool down) {
    if (linux_key <= 0 || portal_keyboard_device_ == nullptr ||
        !portal_keyboard_ready_) {
      return;
    }
    ei_device_keyboard_key(portal_keyboard_device_,
                           static_cast<uint32_t>(linux_key), down);
    PortalDeviceFrameLocked(portal_keyboard_device_);
  }
#endif

#if HAVE_X11_REMOTE_INPUT
  void CaptureLoop(const std::string& session_id,
                   const std::string& edge,
                   const std::string& display_id,
                   EdgeSegment segment,
                   std::vector<CaptureRoute> routes,
                   const std::string& release_hotkey) {
    Display* display = XOpenDisplay(nullptr);
    if (display == nullptr) {
      EmitErrorForSession(session_id,
                          "Unable to open X11 display for remote input capture");
      capture_running_.store(false);
      return;
    }
    const Window root = DefaultRootWindow(display);
    std::string active_route_id;
    std::string active_display_id = display_id;
    std::string active_edge = edge;
    EdgeSegment active_segment = segment;
    ScreenBounds bounds = BoundsForDisplay(display, active_display_id);
    int center_x = bounds.left + bounds.width / 2;
    int center_y = bounds.top + bounds.height / 2;
    int xi_opcode = 0;
    const bool raw_motion_disabled = ShouldDisableRawMotion();
    const bool raw_motion_enabled =
        !raw_motion_disabled && EnableRawMotion(display, root, &xi_opcode);
    const bool show_source_cursor = ShouldShowSourceCursor();
    Cursor hidden_cursor =
        show_source_cursor ? None : CreateHiddenCursor(display, root);
    bool active = false;
    bool pointer_grabbed = false;
    bool keyboard_grabbed = false;
    bool pending_active_start = false;
    bool ignore_next_motion = false;
    uint64_t sequence = 0;
    uint64_t activation_sequence = 0;
    int capture_buttons = 0;
    int last_x = center_x;
    int last_y = center_y;
    int entry_x = center_x;
    int entry_y = center_y;
    double capture_activation_edge_unit = -1;
    bool has_last = false;
    double raw_remainder_x = 0;
    double raw_remainder_y = 0;
    int mouse_trace_count = 0;
    int key_trace_count = 0;

    EmitDiagnosticForSession(
        session_id, "linux remote input capture started edge=" + edge +
                        " sourceCursorHidden=" +
                        (show_source_cursor ? "0" : "1") +
                        " rawMotionDisabled=" +
                        (raw_motion_disabled ? "1" : "0"));
    TraceRemoteInput("linux remote input native capture started edge=" + edge +
                     " rawMotion=" + (raw_motion_enabled ? "1" : "0") +
                     " rawMotionDisabled=" +
                     (raw_motion_disabled ? "1" : "0") +
                     " sourceCursorHidden=" +
                     (show_source_cursor ? "0" : "1"));
    if (raw_motion_enabled) {
      EmitDiagnosticForSession(session_id,
                               "linux remote input raw motion enabled");
    }

    while (capture_running_.load()) {
      if (ConsumePauseRequest(session_id, activation_sequence, display, root,
                              &active_route_id, &active_display_id,
                              &active_edge, &active_segment, &bounds,
                              &center_x, &center_y, &active,
                              &pointer_grabbed, &keyboard_grabbed,
                              &pending_active_start, &capture_buttons,
                              &has_last)) {
        continue;
      }

      if (!active) {
        int x = 0;
        int y = 0;
        unsigned int mask = 0;
        if (QueryPointer(display, root, &x, &y, &mask)) {
          const int delta_x = has_last ? x - last_x : 0;
          const int delta_y = has_last ? y - last_y : 0;
          last_x = x;
          last_y = y;
          has_last = true;
          const DoublePoint previous_point{
              static_cast<double>(x - delta_x),
              static_cast<double>(y - delta_y),
          };
          const DoublePoint current_point{static_cast<double>(x),
                                          static_cast<double>(y)};
          const auto crossing =
              ResolveCaptureCrossing(display, previous_point, current_point,
                                      routes, display_id, edge, segment);
          if (crossing.has_value()) {
            const CaptureRoute route = crossing->route;
            active_route_id = route.route_id;
            active_display_id = route.source_display_id;
            active_edge = route.source_edge;
            active_segment = route.source_segment;
            capture_activation_edge_unit = crossing->edge_unit;
            bounds = BoundsForDisplay(display, active_display_id);
            center_x = bounds.left + bounds.width / 2;
            center_y = bounds.top + bounds.height / 2;
            std::string grab_error;
            if (!GrabCapture(display, root, hidden_cursor, &pointer_grabbed,
                             &keyboard_grabbed, &grab_error)) {
              EmitErrorForSession(session_id, grab_error);
              break;
            }
            active = true;
            pending_active_start = true;
            activation_sequence = sequence + 1;
            capture_buttons = ButtonsMask(mask);
            entry_x = x;
            entry_y = y;
            raw_remainder_x = 0;
            raw_remainder_y = 0;
            if (raw_motion_enabled) {
              last_x = x;
              last_y = y;
              ignore_next_motion = false;
            } else {
              WarpPointer(display, root, center_x, center_y);
              last_x = center_x;
              last_y = center_y;
              ignore_next_motion = true;
            }
            EmitDiagnosticForSession(
                session_id,
                "linux remote input capture active edge=" + active_edge);
            std::ostringstream trace;
            trace << "linux remote input native active edge=" << active_edge
                  << " x=" << x << " y=" << y
                  << " dx=" << delta_x << " dy=" << delta_y
                  << " rawMotion=" << (raw_motion_enabled ? 1 : 0);
            TraceRemoteInput(trace.str());
          }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(8));
        continue;
      }

      while (XPending(display) > 0 && capture_running_.load()) {
        XEvent event;
        XNextEvent(display, &event);
        if (raw_motion_enabled && event.type == GenericEvent &&
            event.xcookie.extension == xi_opcode) {
          if (XGetEventData(display, &event.xcookie)) {
            double raw_delta_x = 0;
            double raw_delta_y = 0;
            if (RawMotionDelta(event, xi_opcode, &raw_delta_x,
                               &raw_delta_y)) {
              raw_remainder_x += raw_delta_x;
              raw_remainder_y += raw_delta_y;
              const int delta_x = static_cast<int>(std::trunc(raw_remainder_x));
              const int delta_y = static_cast<int>(std::trunc(raw_remainder_y));
              raw_remainder_x -= delta_x;
              raw_remainder_y -= delta_y;
              const bool active_start = pending_active_start;
              pending_active_start = false;
              const int payload_x = active_start ? entry_x : last_x;
              const int payload_y = active_start ? entry_y : last_y;
              if (delta_x != 0 || delta_y != 0 || active_start) {
                if (mouse_trace_count < 60) {
                  std::ostringstream trace;
                  trace << "linux remote input native mouse raw seq="
                        << (sequence + 1)
                        << " dx=" << delta_x << " dy=" << delta_y
                        << " rawDx=" << raw_delta_x
                        << " rawDy=" << raw_delta_y
                        << " activeStart=" << (active_start ? 1 : 0)
                        << " edge=" << active_edge
                        << " payload=" << payload_x << "," << payload_y;
                  TraceRemoteInput(trace.str());
                  mouse_trace_count++;
                }
                EmitInputEvent(
                    session_id, "mouseMove", ++sequence,
                    JsonBytes(MouseMovePayload(display, payload_x, payload_y,
                                               delta_x, delta_y, active_start,
                                               active_edge, active_route_id,
                                               capture_buttons, bounds,
                                               active_segment,
                                               active_start
                                                   ? capture_activation_edge_unit
                                                   : -1)));
                if (active_start) {
                  capture_activation_edge_unit = -1;
                }
              }
            }
            XFreeEventData(display, &event.xcookie);
          }
          continue;
        }
        if (event.type == MotionNotify) {
          if (raw_motion_enabled) {
            continue;
          }
          const int x = event.xmotion.x_root;
          const int y = event.xmotion.y_root;
          int delta_x = x - last_x;
          int delta_y = y - last_y;
          last_x = x;
          last_y = y;
          if (ignore_next_motion) {
            ignore_next_motion = false;
            continue;
          }
          const bool active_start = pending_active_start;
          pending_active_start = false;
          const int payload_x = active_start ? entry_x : x;
          const int payload_y = active_start ? entry_y : y;
          if (delta_x != 0 || delta_y != 0 || active_start) {
            if (mouse_trace_count < 60) {
              std::ostringstream trace;
              trace << "linux remote input native mouse motion seq="
                    << (sequence + 1)
                    << " dx=" << delta_x << " dy=" << delta_y
                    << " activeStart=" << (active_start ? 1 : 0)
                    << " edge=" << active_edge
                    << " payload=" << payload_x << "," << payload_y;
              TraceRemoteInput(trace.str());
              mouse_trace_count++;
            }
            EmitInputEvent(
                session_id, "mouseMove", ++sequence,
                JsonBytes(MouseMovePayload(
                    display, payload_x, payload_y, delta_x, delta_y,
                    active_start, active_edge, active_route_id,
                    capture_buttons, bounds, active_segment,
                    active_start ? capture_activation_edge_unit : -1)));
            if (active_start) {
              capture_activation_edge_unit = -1;
            }
          }
          if (ShouldRecenter(bounds, x, y)) {
            WarpPointer(display, root, center_x, center_y);
            last_x = center_x;
            last_y = center_y;
            ignore_next_motion = true;
          }
        } else if (event.type == ButtonPress || event.type == ButtonRelease) {
          HandleCaptureButton(display, session_id, event, &sequence,
                              &capture_buttons);
        } else if (event.type == KeyPress || event.type == KeyRelease) {
          if (event.type == KeyPress &&
              IsReleaseHotkey(display, event.xkey, release_hotkey)) {
            EmitReleaseForSession(session_id, "hotkey", sequence,
                                  activation_sequence, 0);
            capture_running_.store(false);
            break;
          }
          if (key_trace_count < 40) {
            std::ostringstream trace;
            trace << "linux remote input native key seq=" << (sequence + 1)
                  << " type="
                  << (event.type == KeyPress ? "press" : "release")
                  << " keycode=" << event.xkey.keycode;
            TraceRemoteInput(trace.str());
            key_trace_count++;
          }
          EmitInputEvent(
              session_id, "key", ++sequence,
              JsonBytes(KeyPayload(event.xkey.keycode, event.type == KeyPress)));
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }

    if (keyboard_grabbed) {
      XUngrabKeyboard(display, CurrentTime);
    }
    if (pointer_grabbed) {
      XUngrabPointer(display, CurrentTime);
    }
    if (hidden_cursor != None) {
      XFreeCursor(display, hidden_cursor);
    }
    XFlush(display);
    XCloseDisplay(display);
    capture_running_.store(false);
  }

  bool ConsumePauseRequest(const std::string& session_id,
                           uint64_t activation_sequence,
                           Display* display,
                           Window root,
                           std::string* active_route_id,
                           std::string* active_display_id,
                           std::string* active_edge,
                           EdgeSegment* active_segment,
                           ScreenBounds* bounds,
                           int* center_x,
                           int* center_y,
                           bool* active,
                           bool* pointer_grabbed,
                           bool* keyboard_grabbed,
                           bool* pending_active_start,
                           int* capture_buttons,
                           bool* has_last) {
    int64_t release_sequence = 0;
    int64_t release_activation_sequence = 0;
    double release_edge_unit = 0;
    std::string release_display_id;
    std::string release_edge;
    std::string release_route_id;
    EdgeSegment release_segment;
    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      if (!capture_pause_requested_) {
        return false;
      }
      capture_pause_requested_ = false;
      release_sequence = capture_pause_release_sequence_;
      release_activation_sequence = capture_pause_release_activation_sequence_;
      release_edge_unit = capture_pause_release_edge_unit_;
      release_display_id = capture_pause_release_display_id_;
      release_edge = capture_pause_release_edge_;
      release_segment = capture_pause_release_segment_;
      release_route_id = capture_pause_release_route_id_;
    }
    if (release_activation_sequence > 0 &&
        activation_sequence > static_cast<uint64_t>(release_activation_sequence)) {
      EmitDiagnosticForSession(
          session_id, "linux remote input ignored stale pause");
      return true;
    }
    if (*keyboard_grabbed) {
      XUngrabKeyboard(display, CurrentTime);
      *keyboard_grabbed = false;
    }
    if (*pointer_grabbed) {
      XUngrabPointer(display, CurrentTime);
      *pointer_grabbed = false;
    }
    if (!release_edge.empty()) {
      *active_edge = release_edge;
      *active_segment = release_segment;
    }
    if (!release_display_id.empty()) {
      *active_display_id = release_display_id;
    }
    *active_route_id = release_route_id;
    *bounds = BoundsForDisplay(display, *active_display_id);
    *center_x = bounds->left + bounds->width / 2;
    *center_y = bounds->top + bounds->height / 2;
    MoveCaptureCursorToLocalEdge(display, root, *active_display_id,
                                 *active_edge, *active_segment,
                                 release_edge_unit);
    *active = false;
    *pending_active_start = false;
    *capture_buttons = 0;
    *has_last = false;
    std::ostringstream diagnostic;
    diagnostic << "linux remote input capture paused edge=" << *active_edge
               << " releaseSequence=" << release_sequence
               << " releaseActivationSequence=" << release_activation_sequence;
    EmitDiagnosticForSession(session_id, diagnostic.str());
    return true;
  }

  bool QueryPointer(Display* display,
                    Window root,
                    int* x,
                    int* y,
                    unsigned int* mask) const {
    Window root_return = 0;
    Window child_return = 0;
    int root_x = 0;
    int root_y = 0;
    int win_x = 0;
    int win_y = 0;
    unsigned int pointer_mask = 0;
    const Bool ok = XQueryPointer(display, root, &root_return, &child_return,
                                  &root_x, &root_y, &win_x, &win_y,
                                  &pointer_mask);
    if (!ok) {
      return false;
    }
    *x = root_x;
    *y = root_y;
    *mask = pointer_mask;
    return true;
  }

  Cursor CreateHiddenCursor(Display* display, Window root) const {
    static const char empty_bitmap[] = {0};
    Pixmap bitmap =
        XCreateBitmapFromData(display, root, empty_bitmap, 1, 1);
    if (bitmap == None) {
      return None;
    }
    XColor black = {};
    Cursor hidden_cursor =
        XCreatePixmapCursor(display, bitmap, bitmap, &black, &black, 0, 0);
    XFreePixmap(display, bitmap);
    return hidden_cursor;
  }

  bool EnableRawMotion(Display* display, Window root, int* xi_opcode) const {
#if HAVE_XI_REMOTE_INPUT
    int event = 0;
    int error = 0;
    if (!XQueryExtension(display, "XInputExtension", xi_opcode, &event,
                         &error)) {
      return false;
    }
    int major = 2;
    int minor = 0;
    if (XIQueryVersion(display, &major, &minor) != Success) {
      return false;
    }
    unsigned char mask[XIMaskLen(XI_LASTEVENT)] = {};
    XISetMask(mask, XI_RawMotion);
    XIEventMask event_mask = {};
    event_mask.deviceid = XIAllMasterDevices;
    event_mask.mask_len = sizeof(mask);
    event_mask.mask = mask;
    if (XISelectEvents(display, root, &event_mask, 1) != Success) {
      return false;
    }
    XFlush(display);
    return true;
#else
    (void)display;
    (void)root;
    (void)xi_opcode;
    return false;
#endif
  }

  bool RawMotionDelta(const XEvent& event,
                      int xi_opcode,
                      double* delta_x,
                      double* delta_y) const {
#if HAVE_XI_REMOTE_INPUT
    if (event.type != GenericEvent || event.xcookie.extension != xi_opcode ||
        event.xcookie.evtype != XI_RawMotion ||
        event.xcookie.data == nullptr) {
      return false;
    }
    auto* raw = static_cast<XIRawEvent*>(event.xcookie.data);
    int value_index = 0;
    double x = 0;
    double y = 0;
    for (int axis = 0; axis < raw->valuators.mask_len * 8; axis++) {
      if (!XIMaskIsSet(raw->valuators.mask, axis)) {
        continue;
      }
      const double* values =
          raw->raw_values != nullptr ? raw->raw_values : raw->valuators.values;
      const double value = values == nullptr ? 0 : values[value_index];
      if (axis == 0) {
        x = value;
      } else if (axis == 1) {
        y = value;
      }
      value_index++;
    }
    *delta_x = x;
    *delta_y = y;
    return x != 0 || y != 0;
#else
    (void)event;
    (void)xi_opcode;
    (void)delta_x;
    (void)delta_y;
    return false;
#endif
  }

  bool GrabCapture(Display* display,
                   Window root,
                   Cursor hidden_cursor,
                   bool* pointer_grabbed,
                   bool* keyboard_grabbed,
                   std::string* error) const {
    const int pointer_result = XGrabPointer(
        display, root, False,
        PointerMotionMask | ButtonPressMask | ButtonReleaseMask |
            ButtonMotionMask,
        GrabModeAsync, GrabModeAsync, None, hidden_cursor, CurrentTime);
    if (pointer_result != GrabSuccess) {
      *error = "XGrabPointer failed: " + std::to_string(pointer_result);
      return false;
    }
    *pointer_grabbed = true;
    const int keyboard_result =
        XGrabKeyboard(display, root, False, GrabModeAsync, GrabModeAsync,
                      CurrentTime);
    if (keyboard_result != GrabSuccess) {
      XUngrabPointer(display, CurrentTime);
      *pointer_grabbed = false;
      *error = "XGrabKeyboard failed: " + std::to_string(keyboard_result);
      return false;
    }
    *keyboard_grabbed = true;
    return true;
  }

  std::vector<CaptureRoute> CaptureRoutesForMatching(
      const std::vector<CaptureRoute>& routes,
      const std::string& display_id,
      const std::string& edge,
      const EdgeSegment& segment) const {
    if (!routes.empty()) {
      return routes;
    }
    return std::vector<CaptureRoute>{CaptureRoute{
        "",
        display_id,
        edge,
        segment,
    }};
  }

  Maybe<CaptureCrossing> ResolveCaptureCrossing(
      Display* display,
      DoublePoint previous_point,
      DoublePoint current_point,
      const std::vector<CaptureRoute>& configured_routes,
      const std::string& display_id,
      const std::string& edge,
      const EdgeSegment& segment) const {
    const std::vector<CaptureRoute> routes =
        CaptureRoutesForMatching(configured_routes, display_id, edge, segment);
    std::vector<CaptureCrossing> candidates;
    for (const auto& route : routes) {
      const auto crossing =
          CaptureCrossingForRoute(display, route, previous_point,
                                  current_point, routes);
      if (crossing.has_value()) {
        candidates.push_back(crossing.value());
      }
    }
    if (candidates.empty()) {
      return {};
    }
    std::sort(candidates.begin(), candidates.end(),
              [](const CaptureCrossing& lhs, const CaptureCrossing& rhs) {
                if (lhs.strict_segment_hit != rhs.strict_segment_hit) {
                  return lhs.strict_segment_hit;
                }
                if (std::abs(lhs.normal_motion) !=
                    std::abs(rhs.normal_motion)) {
                  return std::abs(lhs.normal_motion) >
                         std::abs(rhs.normal_motion);
                }
                if (lhs.travel_to_intersection !=
                    rhs.travel_to_intersection) {
                  return lhs.travel_to_intersection <
                         rhs.travel_to_intersection;
                }
                return lhs.route.route_id < rhs.route.route_id;
              });
    return candidates.front();
  }

  Maybe<CaptureCrossing> CaptureCrossingForRoute(
      Display* display,
      const CaptureRoute& route,
      DoublePoint previous_point,
      DoublePoint current_point,
      const std::vector<CaptureRoute>& routes) const {
    const ScreenBounds bounds =
        BoundsForDisplay(display, route.source_display_id);
    const double delta_x = current_point.x - previous_point.x;
    const double delta_y = current_point.y - previous_point.y;
    if (delta_x == 0 && delta_y == 0) {
      return {};
    }
    const double line = EdgeLine(bounds, route.source_edge);
    const auto t = IntersectionParameter(route.source_edge, line,
                                         previous_point, delta_x, delta_y);
    if (!t.has_value() || t.value() < 0 || t.value() > 1) {
      return {};
    }
    const double normal_motion =
        EdgeNormalMotion(route.source_edge, delta_x, delta_y);
    if (normal_motion <= 0) {
      return {};
    }
    const DoublePoint intersection{
        previous_point.x + delta_x * t.value(),
        previous_point.y + delta_y * t.value(),
    };
    const double coordinate = AxisCoordinate(intersection, route.source_edge);
    if (!SegmentContains(coordinate, route.source_segment,
                         route.source_display_id, route.source_edge, routes)) {
      return {};
    }
    const double length = route.source_segment.end - route.source_segment.start;
    if (length <= 0) {
      return {};
    }
    CaptureCrossing crossing;
    crossing.route = route;
    crossing.edge_unit =
        ClampedUnit((coordinate - route.source_segment.start) / length);
    crossing.strict_segment_hit = coordinate > route.source_segment.start &&
                                  coordinate < route.source_segment.end;
    crossing.normal_motion = normal_motion;
    crossing.travel_to_intersection =
        std::hypot(intersection.x - previous_point.x,
                   intersection.y - previous_point.y);
    return crossing;
  }

  bool SegmentContains(double coordinate,
                       const EdgeSegment& segment,
                       const std::string& display_id,
                       const std::string& edge,
                       const std::vector<CaptureRoute>& routes) const {
    if (!HasSegment(segment)) {
      return true;
    }
    if (coordinate < segment.start) {
      return false;
    }
    if (coordinate < segment.end) {
      return true;
    }
    if (coordinate != segment.end) {
      return false;
    }
    for (const auto& other : routes) {
      if (other.source_display_id == display_id &&
          other.source_edge == edge &&
          other.source_segment.start <= segment.end &&
          other.source_segment.end > segment.end) {
        return false;
      }
    }
    return true;
  }

  bool IsEdgeActivation(const ScreenBounds& bounds,
                        const std::string& edge,
                        const EdgeSegment& segment,
                        int x,
                        int y,
                        int delta_x,
                        int delta_y) const {
    if (!PointInSegment(x, y, edge, segment, kEdgeThreshold)) {
      return false;
    }
    if (edge == "left") {
      return x <= bounds.left + kEdgeThreshold && delta_x < 0;
    }
    if (edge == "top") {
      return y <= bounds.top + kEdgeThreshold && delta_y < 0;
    }
    if (edge == "bottom") {
      return y >= bounds.bottom() - kEdgeThreshold && delta_y > 0;
    }
    return x >= bounds.right() - kEdgeThreshold && delta_x > 0;
  }

  bool ShouldRecenter(const ScreenBounds& bounds, int x, int y) const {
    return x <= bounds.left + kCaptureRecenterMargin ||
           x >= bounds.right() - kCaptureRecenterMargin ||
           y <= bounds.top + kCaptureRecenterMargin ||
           y >= bounds.bottom() - kCaptureRecenterMargin;
  }

  void WarpPointer(Display* display, Window root, int x, int y) const {
    XWarpPointer(display, None, root, 0, 0, 0, 0, x, y);
    XFlush(display);
  }

  void MoveCaptureCursorToLocalEdge(Display* display,
                                    Window root,
                                    const std::string& display_id,
                                    const std::string& edge,
                                    const EdgeSegment& segment,
                                    double edge_unit = -1) const {
    const ScreenBounds bounds = BoundsForDisplay(display, display_id);
    int x = bounds.left + bounds.width / 2;
    int y = bounds.top + bounds.height / 2;
    unsigned int mask = 0;
    QueryPointer(display, root, &x, &y, &mask);
    x = ClampInt(x, bounds.left + kCaptureCursorInset,
                 bounds.right() - kCaptureCursorInset);
    y = ClampInt(y, bounds.top + kCaptureCursorInset,
                 bounds.bottom() - kCaptureCursorInset);
    if (HasSegment(segment)) {
      const double unit = edge_unit >= 0
                              ? ClampedUnit(edge_unit)
                              : EdgeUnitForPoint(x, y, edge, segment);
      const int coordinate = SegmentCoordinate(unit, segment);
      if (edge == "left" || edge == "right") {
        y = ClampInt(coordinate, bounds.top + kCaptureCursorInset,
                     bounds.bottom() - kCaptureCursorInset);
      } else {
        x = ClampInt(coordinate, bounds.left + kCaptureCursorInset,
                     bounds.right() - kCaptureCursorInset);
      }
    }
    if (edge == "left") {
      x = bounds.left + kCaptureCursorInset;
    } else if (edge == "top") {
      y = bounds.top + kCaptureCursorInset;
    } else if (edge == "bottom") {
      y = bounds.bottom() - kCaptureCursorInset;
    } else {
      x = bounds.right() - kCaptureCursorInset;
    }
    WarpPointer(display, root, x, y);
  }

  int ButtonsMask(unsigned int state) const {
    int buttons = 0;
    if ((state & Button1Mask) != 0) {
      buttons |= 1;
    }
    if ((state & Button3Mask) != 0) {
      buttons |= 2;
    }
    if ((state & Button2Mask) != 0) {
      buttons |= 4;
    }
    return buttons;
  }

  int MouseButtonBit(int button) const {
    if (button == 1) {
      return 2;
    }
    if (button == 2) {
      return 4;
    }
    return 1;
  }

  int XButtonForProtocolButton(int button) const {
    if (button == 1) {
      return Button3;
    }
    if (button == 2) {
      return Button2;
    }
    return Button1;
  }

  int ProtocolButtonForXButton(int button) const {
    if (button == Button3) {
      return 1;
    }
    if (button == Button2) {
      return 2;
    }
    return 0;
  }

  void HandleCaptureButton(Display* display,
                           const std::string& session_id,
                           const XEvent& event,
                           uint64_t* sequence,
                           int* capture_buttons) {
    const bool down = event.type == ButtonPress;
    const int button = event.xbutton.button;
    if (down && button == Button4) {
      EmitInputEvent(session_id, "mouseWheel", ++(*sequence),
                     JsonBytes(MouseWheelPayload(0, 120)));
      return;
    }
    if (down && button == Button5) {
      EmitInputEvent(session_id, "mouseWheel", ++(*sequence),
                     JsonBytes(MouseWheelPayload(0, -120)));
      return;
    }
    if (down && button == 6) {
      EmitInputEvent(session_id, "mouseWheel", ++(*sequence),
                     JsonBytes(MouseWheelPayload(-120, 0)));
      return;
    }
    if (down && button == 7) {
      EmitInputEvent(session_id, "mouseWheel", ++(*sequence),
                     JsonBytes(MouseWheelPayload(120, 0)));
      return;
    }
    if (button != Button1 && button != Button2 && button != Button3) {
      return;
    }
    const int protocol_button = ProtocolButtonForXButton(button);
    const int bit = MouseButtonBit(protocol_button);
    if (down) {
      *capture_buttons |= bit;
    } else {
      *capture_buttons &= ~bit;
    }
    EmitInputEvent(session_id, "mouseButton", ++(*sequence),
                   JsonBytes(MouseButtonPayload(event.xbutton.x_root,
                                                event.xbutton.y_root,
                                                protocol_button, down)));
    (void)display;
  }

  bool IsReleaseHotkey(Display* display,
                       const XKeyEvent& event,
                       const std::string& release_hotkey) const {
    if (release_hotkey != "ctrl+alt+esc") {
      return false;
    }
    KeySym keysym = XkbKeycodeToKeysym(display, event.keycode, 0, 0);
    return keysym == XK_Escape && (event.state & ControlMask) != 0 &&
           (event.state & Mod1Mask) != 0;
  }

  double InjectionEdgeUnit(int x, int y) const {
    if (injection_edge_.empty()) {
      return 0;
    }
    return EdgeUnitForPoint(x, y, injection_edge_, injection_segment_);
  }

  void UpdateInjectionRouteFromPayload(const std::string& json) {
    injection_display_id_ =
        JsonString(json, "sinkDisplayId", injection_display_id_);
    injection_edge_ = JsonString(json, "sinkEdge", injection_edge_);
    injection_route_id_ = JsonString(json, "routeId", injection_route_id_);
    const double segment_start =
        JsonNumber(json, "sinkSegmentStart", injection_segment_.start);
    const double segment_end =
        JsonNumber(json, "sinkSegmentEnd", injection_segment_.end);
    if (segment_end > segment_start) {
      injection_segment_ = EdgeSegment{segment_start, segment_end};
    }
  }

  void SetCursorPosForEntryLocked(const std::string& json) {
    UpdateInjectionRouteFromPayload(json);
    const double edge_unit = JsonNumber(json, "edgeUnit", -1);
    if (edge_unit >= 0 && HasSegment(injection_segment_) &&
        !injection_edge_.empty()) {
      const ScreenBounds bounds =
          BoundsForDisplay(injection_display_, injection_display_id_);
      const int coordinate = SegmentCoordinate(edge_unit, injection_segment_);
      int x = bounds.left + kCaptureCursorInset;
      int y = ClampInt(coordinate, bounds.top + kCaptureCursorInset,
                       bounds.bottom() - kCaptureCursorInset);
      if (injection_edge_ == "right") {
        x = bounds.right() - kCaptureCursorInset;
      } else if (injection_edge_ == "top") {
        x = ClampInt(coordinate, bounds.left + kCaptureCursorInset,
                     bounds.right() - kCaptureCursorInset);
        y = bounds.top + kCaptureCursorInset;
      } else if (injection_edge_ == "bottom") {
        x = ClampInt(coordinate, bounds.left + kCaptureCursorInset,
                     bounds.right() - kCaptureCursorInset);
        y = bounds.bottom() - kCaptureCursorInset;
      }
      XTestFakeMotionEvent(injection_display_, DefaultScreen(injection_display_),
                           x, y, CurrentTime);
      RememberInjectedCursorPositionLocked(x, y);
      return;
    }
    const ScreenBounds bounds = BoundsFor(injection_display_);
    const int unit_width = bounds.width > 1 ? bounds.width - 1 : 1;
    const int unit_height = bounds.height > 1 ? bounds.height - 1 : 1;
    const double unit_x = ClampedUnit(JsonNumber(json, "unitX"));
    const double unit_y = ClampedUnit(JsonNumber(json, "unitY"));
    const std::string edge = JsonString(json, "edge", "right");
    int x = bounds.left + kCaptureCursorInset;
    int y = ClampInt(
        bounds.top + static_cast<int>(std::lround(unit_y * unit_height)),
        bounds.top, bounds.bottom());
    if (edge == "left") {
      x = bounds.right() - kCaptureCursorInset;
    } else if (edge == "top") {
      x = ClampInt(
          bounds.left + static_cast<int>(std::lround(unit_x * unit_width)),
          bounds.left, bounds.right());
      y = bounds.bottom() - kCaptureCursorInset;
    } else if (edge == "bottom") {
      x = ClampInt(
          bounds.left + static_cast<int>(std::lround(unit_x * unit_width)),
          bounds.left, bounds.right());
      y = bounds.top + kCaptureCursorInset;
    }
    XTestFakeMotionEvent(injection_display_, DefaultScreen(injection_display_),
                         x, y, CurrentTime);
    RememberInjectedCursorPositionLocked(x, y);
  }

  void InjectMouseMoveLocked(const std::string& json) {
    const int delta_x =
        static_cast<int>(std::lround(JsonNumber(json, "deltaX")));
    const int delta_y =
        static_cast<int>(std::lround(JsonNumber(json, "deltaY")));
    int current_x = 0;
    int current_y = 0;
    unsigned int mask = 0;
    InjectedCursorPositionLocked(&current_x, &current_y, &mask);
    const bool active_start = JsonBool(json, "activeStart");
    if (ShouldTraceRemoteInput()) {
      std::ostringstream trace;
      trace << "linux remote input injection move session="
            << injection_session_id_
            << " activeStart=" << (active_start ? 1 : 0)
            << " dx=" << delta_x << " dy=" << delta_y
            << " current=" << current_x << "," << current_y
            << " edge=" << (injection_edge_.empty() ? "-" : injection_edge_)
            << " display="
            << (injection_display_id_.empty() ? "-" : injection_display_id_)
            << " segment=" << SegmentTrace(injection_segment_)
            << " interior="
            << (injected_cursor_entered_interior_ ? 1 : 0)
            << " routes=" << injection_routes_.size();
      TraceRemoteInput(trace.str());
    }
    Maybe<InjectionReleaseRoute> routed_release;
    if (!active_start && injected_cursor_entered_interior_) {
      routed_release =
          ReverseInjectionSourceEdgeUnit(current_x, current_y, delta_x,
                                         delta_y);
    }
    if (routed_release.has_value()) {
      const std::string session_id = injection_session_id_;
      const auto release_route = routed_release.value();
      if (ShouldTraceRemoteInput()) {
        std::ostringstream trace;
        trace << "linux remote input injection release routed session="
              << session_id << " requested=" << current_x << "," << current_y
              << "->" << (current_x + delta_x) << ","
              << (current_y + delta_y)
              << " edgeUnit=" << release_route.edge_unit
              << " route=" << release_route.route_id
              << " sourceDisplay=" << release_route.source_display_id
              << " sourceEdge=" << release_route.source_edge
              << " sourceSegment="
              << SegmentTrace(release_route.source_segment);
        TraceRemoteInput(trace.str());
      }
      ReleaseInjectedButtonsLocked();
      ReleaseInjectedKeysLocked();
      ReleaseCommonModifierKeysLocked();
      injected_cursor_entered_interior_ = false;
      has_injected_cursor_position_ = false;
      EmitReleaseForSession(
          session_id, "edge", 0, 0, release_route.edge_unit, true,
          release_route.route_id, release_route.source_display_id,
          release_route.source_edge, release_route.source_segment.start,
          release_route.source_segment.end);
      return;
    }
    if (!active_start && injected_cursor_entered_interior_ &&
        IsInjectionReverseRelease(json, current_x, current_y, delta_x,
                                  delta_y)) {
      const std::string session_id = injection_session_id_;
      const double edge_unit = InjectionEdgeUnit(current_x, current_y);
      if (ShouldTraceRemoteInput()) {
        std::ostringstream trace;
        trace << "linux remote input injection release legacy session="
              << session_id << " requested=" << current_x << "," << current_y
              << "->" << (current_x + delta_x) << ","
              << (current_y + delta_y)
              << " edgeUnit=" << edge_unit
              << " edge=" << (injection_edge_.empty() ? "-" : injection_edge_)
              << " segment=" << SegmentTrace(injection_segment_);
        TraceRemoteInput(trace.str());
      }
      ReleaseInjectedButtonsLocked();
      ReleaseInjectedKeysLocked();
      ReleaseCommonModifierKeysLocked();
      injected_cursor_entered_interior_ = false;
      has_injected_cursor_position_ = false;
      EmitReleaseForSession(session_id, "edge", 0, 0, edge_unit);
      return;
    }
    int final_x = current_x;
    int final_y = current_y;
    if (active_start) {
      SetCursorPosForEntryLocked(json);
      injected_cursor_entered_interior_ = false;
      InjectedCursorPositionLocked(&current_x, &current_y, &mask);
      final_x = current_x;
      final_y = current_y;
    }
    const int buttons =
        static_cast<int>(std::lround(JsonNumber(json, "buttons", -1)));
    if (buttons >= 0) {
      SyncInjectedButtonsLocked(buttons);
    }
    if (delta_x != 0 || delta_y != 0) {
      XTestFakeRelativeMotionEvent(injection_display_, delta_x, delta_y,
                                   CurrentTime);
      if (has_injected_cursor_position_) {
        final_x = injected_cursor_x_ + delta_x;
        final_y = injected_cursor_y_ + delta_y;
      } else {
        final_x += delta_x;
        final_y += delta_y;
      }
      RememberInjectedCursorPositionLocked(final_x, final_y);
    }
    UpdateInjectedCursorInteriorState(json, final_x, final_y);
    XFlush(injection_display_);
    if (ShouldTraceRemoteInput()) {
      int actual_x = final_x;
      int actual_y = final_y;
      QueryPointer(injection_display_, DefaultRootWindow(injection_display_),
                   &actual_x, &actual_y, &mask);
      std::ostringstream trace;
      trace << "linux remote input injection applied session="
            << injection_session_id_
            << " requested=" << final_x << "," << final_y
            << " actual=" << actual_x << "," << actual_y
            << " interior="
            << (injected_cursor_entered_interior_ ? 1 : 0);
      TraceRemoteInput(trace.str());
    }
  }

  Display* InjectionBoundsDisplayLocked() const {
#if HAVE_LIBEI_REMOTE_INPUT
    if (injection_backend_ == InjectionBackend::kPortal) {
      return portal_x_display_;
    }
#endif
    return injection_display_;
  }

  void RememberInjectedCursorPositionLocked(int x, int y) {
    const ScreenBounds bounds = BoundsFor(InjectionBoundsDisplayLocked());
    injected_cursor_x_ = ClampInt(x, bounds.left, bounds.right());
    injected_cursor_y_ = ClampInt(y, bounds.top, bounds.bottom());
    has_injected_cursor_position_ = true;
  }

  bool InjectedCursorPositionLocked(int* x, int* y, unsigned int* mask) {
    if (has_injected_cursor_position_) {
      *x = injected_cursor_x_;
      *y = injected_cursor_y_;
      return true;
    }
    // XQueryPointer can remain stale under XWayland after XTest injection.
    Display* display = InjectionBoundsDisplayLocked();
    if (display == nullptr) {
      return false;
    }
    return QueryPointer(display, DefaultRootWindow(display), x, y, mask);
  }

  Maybe<InjectionReleaseRoute> ReverseInjectionSourceEdgeUnit(
      int x,
      int y,
      int delta_x,
      int delta_y) const {
    if (injection_routes_.empty()) {
      return {};
    }
    const DoublePoint previous_point{static_cast<double>(x),
                                     static_cast<double>(y)};
    const DoublePoint current_point{static_cast<double>(x + delta_x),
                                    static_cast<double>(y + delta_y)};
    const auto crossing =
        ResolveInjectionReleaseCrossing(previous_point, current_point);
    if (!crossing.has_value()) {
      return {};
    }
    const auto route = crossing->route;
    return InjectionReleaseRoute{
        route.route_id,
        route.source_display_id,
        route.source_edge,
        route.source_segment,
        crossing->edge_unit,
    };
  }

  Maybe<InjectionReleaseCrossing> ResolveInjectionReleaseCrossing(
      DoublePoint previous_point,
      DoublePoint current_point) const {
    std::vector<InjectionReleaseCrossing> candidates;
    for (const auto& route : injection_routes_) {
      const auto crossing =
          InjectionReleaseCrossingForRoute(route, previous_point,
                                           current_point);
      if (crossing.has_value()) {
        candidates.push_back(crossing.value());
      }
    }
    if (candidates.empty()) {
      return {};
    }
    std::sort(candidates.begin(), candidates.end(),
              [this](const InjectionReleaseCrossing& lhs,
                     const InjectionReleaseCrossing& rhs) {
                if (lhs.strict_segment_hit != rhs.strict_segment_hit) {
                  return lhs.strict_segment_hit;
                }
                if (std::abs(lhs.normal_motion) !=
                    std::abs(rhs.normal_motion)) {
                  return std::abs(lhs.normal_motion) >
                         std::abs(rhs.normal_motion);
                }
                if (lhs.travel_to_intersection !=
                    rhs.travel_to_intersection) {
                  return lhs.travel_to_intersection <
                         rhs.travel_to_intersection;
                }
                if (!injection_route_id_.empty() &&
                    (lhs.route.route_id == injection_route_id_) !=
                        (rhs.route.route_id == injection_route_id_)) {
                  return lhs.route.route_id == injection_route_id_;
                }
                return lhs.route.route_id < rhs.route.route_id;
              });
    return candidates.front();
  }

  Maybe<InjectionReleaseCrossing> InjectionReleaseCrossingForRoute(
      const InjectionRoute& route,
      DoublePoint previous_point,
      DoublePoint current_point) const {
    const ScreenBounds bounds =
        BoundsForDisplay(InjectionBoundsDisplayLocked(), route.sink_display_id);
    const double delta_x = current_point.x - previous_point.x;
    const double delta_y = current_point.y - previous_point.y;
    if (delta_x == 0 && delta_y == 0) {
      return {};
    }
    const double line = EdgeLine(bounds, route.sink_edge);
    const auto t = IntersectionParameter(route.sink_edge, line,
                                         previous_point, delta_x, delta_y);
    if (!t.has_value() || t.value() < 0 || t.value() > 1) {
      return {};
    }
    const double normal_motion =
        EdgeNormalMotion(route.sink_edge, delta_x, delta_y);
    if (normal_motion <= 0) {
      return {};
    }
    const DoublePoint intersection{
        previous_point.x + delta_x * t.value(),
        previous_point.y + delta_y * t.value(),
    };
    const double coordinate = AxisCoordinate(intersection, route.sink_edge);
    if (!SegmentContains(coordinate, route.sink_segment,
                         route.sink_display_id, route.sink_edge,
                         injection_routes_)) {
      return {};
    }
    const double length = route.sink_segment.end - route.sink_segment.start;
    if (length <= 0) {
      return {};
    }
    InjectionReleaseCrossing crossing;
    crossing.route = route;
    crossing.edge_unit =
        ClampedUnit((coordinate - route.sink_segment.start) / length);
    crossing.strict_segment_hit = coordinate > route.sink_segment.start &&
                                  coordinate < route.sink_segment.end;
    crossing.normal_motion = normal_motion;
    crossing.travel_to_intersection =
        std::hypot(intersection.x - previous_point.x,
                   intersection.y - previous_point.y);
    return crossing;
  }

  bool SegmentContains(double coordinate,
                       const EdgeSegment& segment,
                       const std::string& display_id,
                       const std::string& edge,
                       const std::vector<InjectionRoute>& routes) const {
    if (!HasSegment(segment)) {
      return true;
    }
    if (coordinate < segment.start) {
      return false;
    }
    if (coordinate < segment.end) {
      return true;
    }
    if (coordinate != segment.end) {
      return false;
    }
    for (const auto& other : routes) {
      if (other.sink_display_id == display_id &&
          other.sink_edge == edge &&
          other.sink_segment.start <= segment.end &&
          other.sink_segment.end > segment.end) {
        return false;
      }
    }
    return true;
  }

  bool IsInjectionReverseRelease(const std::string& json,
                                 int x,
                                 int y,
                                 int delta_x,
                                 int delta_y) const {
    if (injection_session_id_.empty() || JsonBool(json, "activeStart")) {
      return false;
    }
    const int next_x = x + delta_x;
    const int next_y = y + delta_y;
    if (HasSegment(injection_segment_) && !injection_edge_.empty()) {
      const ScreenBounds bounds =
          BoundsForDisplay(InjectionBoundsDisplayLocked(),
                           injection_display_id_);
      if (!PointInSegment(x, y, injection_edge_, injection_segment_,
                          kEdgeThreshold)) {
        return false;
      }
      if (injection_edge_ == "left") {
        return x + delta_x <= bounds.left + kEdgeThreshold && delta_x < 0;
      }
      if (injection_edge_ == "right") {
        return next_x >= bounds.right() - kEdgeThreshold && delta_x > 0;
      }
      if (injection_edge_ == "top") {
        return next_y <= bounds.top + kEdgeThreshold && delta_y < 0;
      }
      if (injection_edge_ == "bottom") {
        return next_y >= bounds.bottom() - kEdgeThreshold && delta_y > 0;
      }
    }
    const ScreenBounds bounds = BoundsFor(InjectionBoundsDisplayLocked());
    const std::string edge = JsonString(json, "edge", "right");
    if (edge == "left") {
      return next_x >= bounds.right() - kEdgeThreshold && delta_x > 0;
    }
    if (edge == "top") {
      return next_y >= bounds.bottom() - kEdgeThreshold && delta_y > 0;
    }
    if (edge == "bottom") {
      return next_y <= bounds.top + kEdgeThreshold && delta_y < 0;
    }
    return next_x <= bounds.left + kEdgeThreshold && delta_x < 0;
  }

  void UpdateInjectedCursorInteriorState(const std::string& json,
                                         int x,
                                         int y) {
    if (JsonBool(json, "activeStart")) {
      injected_cursor_entered_interior_ = false;
      return;
    }
    if (injected_cursor_entered_interior_) {
      return;
    }
    const bool using_configured_edge =
        HasSegment(injection_segment_) && !injection_edge_.empty();
    const ScreenBounds bounds =
        using_configured_edge
            ? BoundsForDisplay(InjectionBoundsDisplayLocked(),
                               injection_display_id_)
            : BoundsFor(InjectionBoundsDisplayLocked());
    const std::string edge =
        using_configured_edge ? injection_edge_ : JsonString(json, "edge", "right");
    constexpr int distance = 32;
    bool interior = false;
    if (using_configured_edge) {
      if (edge == "left") {
        interior = x >= bounds.left + distance;
      } else if (edge == "right") {
        interior = x <= bounds.right() - distance;
      } else if (edge == "top") {
        interior = y >= bounds.top + distance;
      } else if (edge == "bottom") {
        interior = y <= bounds.bottom() - distance;
      }
    } else if (edge == "left") {
      interior = x <= bounds.right() - distance;
    } else if (edge == "top") {
      interior = y <= bounds.bottom() - distance;
    } else if (edge == "bottom") {
      interior = y >= bounds.top + distance;
    } else {
      interior = x >= bounds.left + distance;
    }
    if (interior) {
      injected_cursor_entered_interior_ = true;
    }
  }

  void SendMouseButtonLocked(int button, bool down) {
#if HAVE_LIBEI_REMOTE_INPUT
    if (injection_backend_ == InjectionBackend::kPortal) {
      SendPortalMouseButtonLocked(button, down);
      return;
    }
#endif
    XTestFakeButtonEvent(injection_display_, XButtonForProtocolButton(button),
                         down ? True : False, CurrentTime);
  }

  void SendMouseWheelLocked(int delta_x, int delta_y) {
#if HAVE_LIBEI_REMOTE_INPUT
    if (injection_backend_ == InjectionBackend::kPortal) {
      SendPortalMouseWheelLocked(delta_x, delta_y);
      return;
    }
#endif
    const int vertical_button = delta_y > 0 ? Button4 : Button5;
    const int horizontal_button = delta_x > 0 ? 7 : 6;
    const int vertical_clicks = std::min(8, std::abs(delta_y) / 120);
    const int horizontal_clicks = std::min(8, std::abs(delta_x) / 120);
    for (int i = 0; i < vertical_clicks; i++) {
      XTestFakeButtonEvent(injection_display_, vertical_button, True,
                           CurrentTime);
      XTestFakeButtonEvent(injection_display_, vertical_button, False,
                           CurrentTime);
    }
    for (int i = 0; i < horizontal_clicks; i++) {
      XTestFakeButtonEvent(injection_display_, horizontal_button, True,
                           CurrentTime);
      XTestFakeButtonEvent(injection_display_, horizontal_button, False,
                           CurrentTime);
    }
  }

  void SendKeyboardKeyLocked(int x_keycode, bool down) {
    if (x_keycode <= 0) {
      return;
    }
    XTestFakeKeyEvent(injection_display_, static_cast<unsigned int>(x_keycode),
                      down ? True : False, CurrentTime);
  }

  void SetInjectedButton(int button, bool down) {
    const int bit = MouseButtonBit(button);
    if (down) {
      injected_buttons_ |= bit;
    } else {
      injected_buttons_ &= ~bit;
    }
  }

  void SyncInjectedButtonsLocked(int desired_buttons) {
    SyncInjectedButtonLocked(0, desired_buttons);
    SyncInjectedButtonLocked(1, desired_buttons);
    SyncInjectedButtonLocked(2, desired_buttons);
  }

  void SyncInjectedButtonLocked(int button, int desired_buttons) {
    const int bit = MouseButtonBit(button);
    const bool should_be_down = (desired_buttons & bit) != 0;
    const bool is_down = (injected_buttons_ & bit) != 0;
    if (should_be_down == is_down) {
      return;
    }
    SendMouseButtonLocked(button, should_be_down);
    SetInjectedButton(button, should_be_down);
  }

  void ReleaseInjectedButtonsLocked() {
    if (injection_backend_ == InjectionBackend::kNone ||
        injected_buttons_ == 0 ||
        (injection_backend_ == InjectionBackend::kX11 &&
         injection_display_ == nullptr)) {
      return;
    }
    SyncInjectedButtonsLocked(0);
    if (injection_backend_ == InjectionBackend::kX11) {
      XFlush(injection_display_);
    }
  }

  void SetInjectedKey(int x_keycode, bool down) {
    if (x_keycode <= 0) {
      return;
    }
    const auto it =
        std::find(injected_keys_.begin(), injected_keys_.end(), x_keycode);
    if (down) {
      if (it == injected_keys_.end()) {
        injected_keys_.push_back(x_keycode);
      }
      return;
    }
    if (it != injected_keys_.end()) {
      injected_keys_.erase(it);
    }
  }

  void ReleaseInjectedKeysLocked() {
    if (injection_backend_ == InjectionBackend::kNone ||
        injected_keys_.empty() ||
        (injection_backend_ == InjectionBackend::kX11 &&
         injection_display_ == nullptr)) {
      return;
    }
    const auto keys = injected_keys_;
    injected_keys_.clear();
    for (auto it = keys.rbegin(); it != keys.rend(); ++it) {
#if HAVE_LIBEI_REMOTE_INPUT
      if (injection_backend_ == InjectionBackend::kPortal) {
        SendPortalKeyboardKeyLocked(*it, false);
        continue;
      }
#endif
      SendKeyboardKeyLocked(*it, false);
    }
    if (injection_backend_ == InjectionBackend::kX11) {
      XFlush(injection_display_);
    }
  }

  void ReleaseCommonModifierKeysLocked() {
    if (injection_backend_ == InjectionBackend::kNone ||
        (injection_backend_ == InjectionBackend::kX11 &&
         injection_display_ == nullptr)) {
      return;
    }
    constexpr int linux_modifiers[] = {29, 97, 42, 54, 56, 100, 125, 126};
    for (const int linux_key : linux_modifiers) {
#if HAVE_LIBEI_REMOTE_INPUT
      if (injection_backend_ == InjectionBackend::kPortal) {
        SendPortalKeyboardKeyLocked(linux_key, false);
        continue;
      }
#endif
      SendKeyboardKeyLocked(linux_key + 8, false);
    }
    if (injection_backend_ == InjectionBackend::kX11) {
      XFlush(injection_display_);
    }
  }
#endif

  FlValue* DisplayTopologyValue() const {
    FlValue* topology = fl_value_new_map();
    fl_value_set_string_take(topology, "platform",
                             fl_value_new_string("linux"));
    fl_value_set_string_take(topology, "updatedAt",
                             fl_value_new_int(NowMicros() / 1000));
    FlValue* displays = fl_value_new_list();
#if HAVE_X11_REMOTE_INPUT
    Display* display = XOpenDisplay(nullptr);
    if (display != nullptr) {
      for (const auto& info : DisplayInfos(display)) {
        FlValue* item = fl_value_new_map();
        fl_value_set_string_take(item, "displayId",
                                 fl_value_new_string(info.id.c_str()));
        fl_value_set_string_take(item, "name",
                                 fl_value_new_string(info.name.c_str()));
        fl_value_set_string_take(item, "x", fl_value_new_int(info.bounds.left));
        fl_value_set_string_take(item, "y", fl_value_new_int(info.bounds.top));
        fl_value_set_string_take(item, "width",
                                 fl_value_new_int(info.bounds.width));
        fl_value_set_string_take(item, "height",
                                 fl_value_new_int(info.bounds.height));
        fl_value_set_string_take(item, "scale",
                                 fl_value_new_float(info.scale));
        fl_value_set_string_take(item, "isPrimary",
                                 fl_value_new_bool(info.primary));
        fl_value_append_take(displays, item);
      }
      XCloseDisplay(display);
    }
#endif
    fl_value_set_string_take(topology, "displays", displays);
    return topology;
  }

  void EmitInputEvent(const std::string& session_id,
                      const std::string& event_type,
                      int64_t sequence,
                      std::vector<uint8_t> payload) {
    auto* event = new MainThreadEvent();
    event->channel = FL_METHOD_CHANNEL(g_object_ref(channel_));
    event->method = "onInputEvent";
    event->session_id = session_id;
    event->event_type = event_type;
    event->sequence = sequence;
    event->timestamp_micros = NowMicros();
    event->payload = std::move(payload);
    g_main_context_invoke(nullptr, InvokeMainThreadEvent, event);
  }

  void EmitReleaseForSession(const std::string& session_id,
                             const std::string& reason,
                             int64_t sequence,
                             int64_t activation_sequence,
                             double edge_unit = 0,
                             bool source_edge_unit = false,
                             const std::string& route_id = "",
                             const std::string& source_display_id = "",
                             const std::string& source_edge = "",
                             double source_segment_start = 0,
                             double source_segment_end = 0) {
    if (session_id.empty()) {
      return;
    }
    auto* event = new MainThreadEvent();
    event->channel = FL_METHOD_CHANNEL(g_object_ref(channel_));
    event->method = "onRelease";
    event->session_id = session_id;
    event->reason = reason;
    event->sequence = sequence;
    event->activation_sequence = activation_sequence;
    event->edge_unit = edge_unit;
    event->source_edge_unit = source_edge_unit;
    event->route_id = route_id;
    event->source_display_id = source_display_id;
    event->source_edge = source_edge;
    event->source_segment_start = source_segment_start;
    event->source_segment_end = source_segment_end;
    g_main_context_invoke(nullptr, InvokeMainThreadEvent, event);
  }

  void EmitErrorForSession(const std::string& session_id,
                           const std::string& message) {
    auto* event = new MainThreadEvent();
    event->channel = FL_METHOD_CHANNEL(g_object_ref(channel_));
    event->method = "onError";
    event->session_id = session_id;
    event->message = message;
    g_main_context_invoke(nullptr, InvokeMainThreadEvent, event);
  }

  void EmitDiagnosticForSession(const std::string& session_id,
                                const std::string& message) {
    if (session_id.empty()) {
      return;
    }
    auto* event = new MainThreadEvent();
    event->channel = FL_METHOD_CHANNEL(g_object_ref(channel_));
    event->method = "onDiagnostic";
    event->session_id = session_id;
    event->message = message;
    g_main_context_invoke(nullptr, InvokeMainThreadEvent, event);
  }

  FlMethodChannel* channel_ = nullptr;

#if HAVE_X11_REMOTE_INPUT
  std::mutex capture_mutex_;
  CaptureBackend capture_backend_ = CaptureBackend::kNone;
  std::string capture_session_id_;
  std::string capture_route_id_;
  std::string capture_edge_ = "right";
  std::string capture_display_id_;
  EdgeSegment capture_segment_;
  std::vector<CaptureRoute> capture_routes_;
  std::atomic<bool> capture_running_{false};
  std::thread capture_thread_;
  bool capture_pause_requested_ = false;
  int64_t capture_pause_release_sequence_ = 0;
  int64_t capture_pause_release_activation_sequence_ = 0;
  double capture_pause_release_edge_unit_ = 0;
  std::string capture_pause_release_display_id_;
  std::string capture_pause_release_edge_;
  std::string capture_pause_release_route_id_;
  EdgeSegment capture_pause_release_segment_;

  std::mutex injection_mutex_;
  InjectionBackend injection_backend_ = InjectionBackend::kNone;
  Display* injection_display_ = nullptr;
  std::string injection_session_id_;
  std::string injection_display_id_;
  std::string injection_edge_;
  std::string injection_route_id_;
  EdgeSegment injection_segment_;
  std::vector<InjectionRoute> injection_routes_;
  bool injected_cursor_entered_interior_ = false;
  bool has_injected_cursor_position_ = false;
  int injected_cursor_x_ = 0;
  int injected_cursor_y_ = 0;
  int injected_buttons_ = 0;
  std::vector<int> injected_keys_;
#if HAVE_LIBEI_REMOTE_INPUT
  GDBusConnection* input_capture_connection_ = nullptr;
  std::string input_capture_session_handle_;
  struct ei* input_capture_ei_ = nullptr;
  Display* input_capture_x_display_ = nullptr;
  std::thread input_capture_thread_;
  std::atomic<bool> input_capture_running_{false};
  guint input_capture_activated_signal_id_ = 0;
  guint input_capture_deactivated_signal_id_ = 0;
  guint input_capture_disabled_signal_id_ = 0;
  guint input_capture_zones_changed_signal_id_ = 0;
  std::vector<InputCaptureBarrier> input_capture_barriers_;
  uint32_t input_capture_zone_set_ = 0;
  bool input_capture_active_ = false;
  bool input_capture_pending_active_start_ = false;
  uint32_t input_capture_activation_id_ = 0;
  uint64_t input_capture_sequence_ = 0;
  uint64_t input_capture_activation_sequence_ = 0;
  int input_capture_buttons_ = 0;
  int input_capture_x_ = 0;
  int input_capture_y_ = 0;
  double input_capture_activation_edge_unit_ = -1;
  std::string input_capture_active_route_id_;
  std::string input_capture_active_display_id_;
  std::string input_capture_active_edge_;
  EdgeSegment input_capture_active_segment_;
  ScreenBounds input_capture_active_bounds_;

  GDBusConnection* portal_connection_ = nullptr;
  std::string portal_session_handle_;
  struct ei* portal_ei_ = nullptr;
  Display* portal_x_display_ = nullptr;
  std::thread portal_thread_;
  std::atomic<bool> portal_running_{false};
  struct ei_device* portal_pointer_device_ = nullptr;
  struct ei_device* portal_absolute_pointer_device_ = nullptr;
  struct ei_device* portal_button_device_ = nullptr;
  struct ei_device* portal_scroll_device_ = nullptr;
  struct ei_device* portal_keyboard_device_ = nullptr;
  bool portal_pointer_ready_ = false;
  bool portal_absolute_pointer_ready_ = false;
  bool portal_button_ready_ = false;
  bool portal_scroll_ready_ = false;
  bool portal_keyboard_ready_ = false;
  uint32_t portal_emulation_sequence_ = 0;
#endif
#endif
};

RemoteInputPlugin* g_plugin = nullptr;

void MethodCallCallback(FlMethodChannel*,
                        FlMethodCall* method_call,
                        gpointer user_data) {
  auto* plugin = static_cast<RemoteInputPlugin*>(user_data);
  plugin->HandleMethodCall(method_call);
}

}  // namespace

void remote_input_plugin_register(FlPluginRegistry* registry) {
#if HAVE_X11_REMOTE_INPUT
  XInitThreads();
#endif
  FlPluginRegistrar* registrar = fl_plugin_registry_get_registrar_for_plugin(
      registry, "RemoteInputPlugin");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kRemoteInputChannel,
      FL_METHOD_CODEC(codec));
  g_plugin = new RemoteInputPlugin(channel);
  fl_method_channel_set_method_call_handler(channel, MethodCallCallback,
                                            g_plugin, nullptr);
  g_object_unref(channel);
}
