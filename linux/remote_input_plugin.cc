#include "remote_input_plugin.h"

#include <flutter_linux/flutter_linux.h>

#include <algorithm>
#include <atomic>
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

bool HasSegment(const EdgeSegment& segment) {
  return segment.end > segment.start;
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
  const int screen = DefaultScreen(display);
  ScreenBounds bounds;
  bounds.width = std::max(1, DisplayWidth(display, screen));
  bounds.height = std::max(1, DisplayHeight(display, screen));
  return bounds;
}

std::vector<DisplayInfo> DisplayInfos(Display* display) {
  std::vector<DisplayInfo> infos;
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

std::string KeyPayload(unsigned int x_keycode, bool down) {
  const int linux_keycode = static_cast<int>(x_keycode) - 8;
  std::ostringstream json;
  json << "{\"sourcePlatform\":\"linux\""
       << ",\"keyCode\":" << linux_keycode
       << ",\"linuxKeyCode\":" << linux_keycode
       << ",\"down\":" << (down ? "true" : "false") << "}";
  return json.str();
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
    capture_running_.store(true);
    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
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

  bool StartInjection(const std::string& session_id,
                      const std::string& display_id,
                      const std::string& edge,
                      EdgeSegment segment,
                      std::vector<InjectionRoute> routes,
                      std::string* error) {
#if HAVE_X11_REMOTE_INPUT
    StopInjection("");
    Display* display = XOpenDisplay(nullptr);
    if (display == nullptr) {
      *error = "Unable to open X11 display for remote input injection";
      return false;
    }
    std::lock_guard<std::mutex> lock(injection_mutex_);
    injection_display_ = display;
    injection_session_id_ = session_id;
    injection_display_id_ = display_id;
    injection_edge_ = edge;
    injection_segment_ = segment;
    injection_route_id_.clear();
    injection_routes_ = routes;
    injected_cursor_entered_interior_ = false;
    injected_buttons_ = 0;
    injected_keys_.clear();
    EmitDiagnosticForSession(session_id, "linux remote input injection started");
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

  void StopInjection(const std::string& session_id) {
#if HAVE_X11_REMOTE_INPUT
    std::lock_guard<std::mutex> lock(injection_mutex_);
    if (!session_id.empty() && session_id != injection_session_id_) {
      return;
    }
    ReleaseInjectedButtonsLocked();
    ReleaseInjectedKeysLocked();
    ReleaseCommonModifierKeysLocked();
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
#else
    (void)session_id;
#endif
  }

  void InjectEvent(const std::string& session_id,
                   const std::string& event_type,
                   const std::vector<uint8_t>& payload) {
#if HAVE_X11_REMOTE_INPUT
    std::lock_guard<std::mutex> lock(injection_mutex_);
    if (session_id != injection_session_id_ || injection_display_ == nullptr) {
      return;
    }
    const std::string json = PayloadString(payload);
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
  }

  void InjectMouseMoveLocked(const std::string& json) {
    const int delta_x =
        static_cast<int>(std::lround(JsonNumber(json, "deltaX")));
    const int delta_y =
        static_cast<int>(std::lround(JsonNumber(json, "deltaY")));
    int current_x = 0;
    int current_y = 0;
    unsigned int mask = 0;
    QueryPointer(injection_display_, DefaultRootWindow(injection_display_),
                 &current_x, &current_y, &mask);
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
      EmitReleaseForSession(session_id, "edge", 0, 0, edge_unit);
      return;
    }
    int final_x = current_x;
    int final_y = current_y;
    if (active_start) {
      SetCursorPosForEntryLocked(json);
      injected_cursor_entered_interior_ = false;
      QueryPointer(injection_display_, DefaultRootWindow(injection_display_),
                   &current_x, &current_y, &mask);
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
      final_x += delta_x;
      final_y += delta_y;
    }
    UpdateInjectedCursorInteriorState(json, final_x, final_y);
    XFlush(injection_display_);
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
        BoundsForDisplay(injection_display_, route.sink_display_id);
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
    if (HasSegment(injection_segment_) && !injection_edge_.empty()) {
      const ScreenBounds bounds =
          BoundsForDisplay(injection_display_, injection_display_id_);
      if (!PointInSegment(x, y, injection_edge_, injection_segment_,
                          kEdgeThreshold)) {
        return false;
      }
      if (injection_edge_ == "left") {
        return x <= bounds.left + kEdgeThreshold && delta_x < 0;
      }
      if (injection_edge_ == "right") {
        return x >= bounds.right() - kEdgeThreshold && delta_x > 0;
      }
      if (injection_edge_ == "top") {
        return y <= bounds.top + kEdgeThreshold && delta_y < 0;
      }
      if (injection_edge_ == "bottom") {
        return y >= bounds.bottom() - kEdgeThreshold && delta_y > 0;
      }
    }
    const ScreenBounds bounds = BoundsFor(injection_display_);
    const std::string edge = JsonString(json, "edge", "right");
    if (edge == "left") {
      return x >= bounds.right() - kEdgeThreshold && delta_x > 0;
    }
    if (edge == "top") {
      return y >= bounds.bottom() - kEdgeThreshold && delta_y > 0;
    }
    if (edge == "bottom") {
      return y <= bounds.top + kEdgeThreshold && delta_y < 0;
    }
    return x <= bounds.left + kEdgeThreshold && delta_x < 0;
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
            ? BoundsForDisplay(injection_display_, injection_display_id_)
            : BoundsFor(injection_display_);
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
    XTestFakeButtonEvent(injection_display_, XButtonForProtocolButton(button),
                         down ? True : False, CurrentTime);
  }

  void SendMouseWheelLocked(int delta_x, int delta_y) {
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
    if (injected_buttons_ == 0 || injection_display_ == nullptr) {
      return;
    }
    SyncInjectedButtonsLocked(0);
    XFlush(injection_display_);
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
    if (injected_keys_.empty() || injection_display_ == nullptr) {
      return;
    }
    const auto keys = injected_keys_;
    injected_keys_.clear();
    for (auto it = keys.rbegin(); it != keys.rend(); ++it) {
      SendKeyboardKeyLocked(*it, false);
    }
    XFlush(injection_display_);
  }

  void ReleaseCommonModifierKeysLocked() {
    if (injection_display_ == nullptr) {
      return;
    }
    constexpr int linux_modifiers[] = {29, 97, 42, 54, 56, 100, 125, 126};
    for (const int linux_key : linux_modifiers) {
      SendKeyboardKeyLocked(linux_key + 8, false);
    }
    XFlush(injection_display_);
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
  Display* injection_display_ = nullptr;
  std::string injection_session_id_;
  std::string injection_display_id_;
  std::string injection_edge_;
  std::string injection_route_id_;
  EdgeSegment injection_segment_;
  std::vector<InjectionRoute> injection_routes_;
  bool injected_cursor_entered_interior_ = false;
  int injected_buttons_ = 0;
  std::vector<int> injected_keys_;
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
