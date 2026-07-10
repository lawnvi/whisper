#include "remote_input_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr char kRemoteInputChannel[] = "com.vireen.whisper/remote_input";
constexpr int kEdgeThreshold = 6;

enum class RemoteInputDiagnosticEvent {
  kCaptureActive,
  kCapturePaused,
  kCaptureStarted,
  kEventCaptured,
  kEventIgnored,
  kStalePauseIgnored,
};

const char* RemoteInputDiagnosticEventName(RemoteInputDiagnosticEvent event) {
  switch (event) {
    case RemoteInputDiagnosticEvent::kCaptureActive:
      return "capture_active";
    case RemoteInputDiagnosticEvent::kCapturePaused:
      return "capture_paused";
    case RemoteInputDiagnosticEvent::kCaptureStarted:
      return "capture_started";
    case RemoteInputDiagnosticEvent::kEventCaptured:
      return "event_captured";
    case RemoteInputDiagnosticEvent::kEventIgnored:
      return "event_ignored";
    case RemoteInputDiagnosticEvent::kStalePauseIgnored:
      return "stale_pause_ignored";
  }
  return "unknown";
}

bool ShouldTraceRemoteInput() {
  const char* value = std::getenv("WHISPER_REMOTE_INPUT_TRACE");
  return value != nullptr && std::strcmp(value, "1") == 0;
}

struct ScreenArea {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;

  int width() const { return std::max(1, right - left + 1); }
  int height() const { return std::max(1, bottom - top + 1); }
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

struct MonitorDisplay {
  std::string id;
  std::string name;
  ScreenArea area;
  bool primary = false;
  double scale = 1.0;
};

WORD MacVirtualKeyToWindows(int key_code);
int WindowsVirtualKeyToMac(USHORT virtual_key);

int64_t NowMicros() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

template <typename T>
const T* GetMapValue(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return nullptr;
  }
  return std::get_if<T>(&it->second);
}

int64_t GetMapInt64(const flutter::EncodableMap& map,
                    const char* key,
                    int64_t fallback = 0) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return *value;
  }
  return fallback;
}

double GetMapDouble(const flutter::EncodableMap& map,
                    const char* key,
                    double fallback = 0) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return fallback;
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  return fallback;
}

std::vector<EdgeSegment> GetMapSegments(const flutter::EncodableMap& map,
                                        const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return {};
  }
  const auto* values = std::get_if<flutter::EncodableList>(&it->second);
  if (values == nullptr) {
    return {};
  }
  std::vector<EdgeSegment> segments;
  for (const auto& value : *values) {
    const auto* item = std::get_if<flutter::EncodableMap>(&value);
    if (item == nullptr) {
      continue;
    }
    EdgeSegment segment{
        GetMapDouble(*item, "start"),
        GetMapDouble(*item, "end"),
    };
    if (segment.end > segment.start) {
      segments.push_back(segment);
    }
  }
  return segments;
}

std::vector<CaptureRoute> GetMapCaptureRoutes(
    const flutter::EncodableMap& map,
    const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return {};
  }
  const auto* values = std::get_if<flutter::EncodableList>(&it->second);
  if (values == nullptr) {
    return {};
  }
  std::vector<CaptureRoute> routes;
  for (const auto& value : *values) {
    const auto* item = std::get_if<flutter::EncodableMap>(&value);
    if (item == nullptr) {
      continue;
    }
    const auto* display_id = GetMapValue<std::string>(*item, "displayId");
    const auto* edge = GetMapValue<std::string>(*item, "edge");
    const auto* route_id = GetMapValue<std::string>(*item, "routeId");
    CaptureRoute route;
    route.route_id = route_id == nullptr ? "" : *route_id;
    route.source_display_id = display_id == nullptr ? "" : *display_id;
    route.source_edge = edge == nullptr ? "" : *edge;
    route.source_segment = EdgeSegment{
        GetMapDouble(*item, "start"),
        GetMapDouble(*item, "end"),
    };
    if (!route.source_edge.empty() &&
        route.source_segment.end > route.source_segment.start) {
      routes.push_back(std::move(route));
    }
  }
  return routes;
}

std::vector<InjectionRoute> GetMapInjectionRoutes(
    const flutter::EncodableMap& map,
    const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return {};
  }
  const auto* values = std::get_if<flutter::EncodableList>(&it->second);
  if (values == nullptr) {
    return {};
  }
  std::vector<InjectionRoute> routes;
  for (const auto& value : *values) {
    const auto* item = std::get_if<flutter::EncodableMap>(&value);
    if (item == nullptr) {
      continue;
    }
    const auto* sink_display_id =
        GetMapValue<std::string>(*item, "sinkDisplayId");
    const auto* sink_edge = GetMapValue<std::string>(*item, "sinkEdge");
    const auto* source_display_id =
        GetMapValue<std::string>(*item, "sourceDisplayId");
    const auto* source_edge = GetMapValue<std::string>(*item, "sourceEdge");
    const auto* route_id = GetMapValue<std::string>(*item, "routeId");
    InjectionRoute route;
    route.route_id = route_id == nullptr ? "" : *route_id;
    route.source_display_id =
        source_display_id == nullptr ? "" : *source_display_id;
    route.source_edge = source_edge == nullptr ? "" : *source_edge;
    route.sink_display_id = sink_display_id == nullptr ? "" : *sink_display_id;
    route.sink_edge = sink_edge == nullptr ? "" : *sink_edge;
    route.sink_segment = EdgeSegment{
        GetMapDouble(*item, "sinkSegmentStart"),
        GetMapDouble(*item, "sinkSegmentEnd"),
    };
    route.source_segment = EdgeSegment{
        GetMapDouble(*item, "sourceSegmentStart"),
        GetMapDouble(*item, "sourceSegmentEnd"),
    };
    if (!route.source_edge.empty() &&
        !route.sink_display_id.empty() && !route.sink_edge.empty() &&
        route.sink_segment.end > route.sink_segment.start &&
        route.source_segment.end > route.source_segment.start) {
      routes.push_back(std::move(route));
    }
  }
  return routes;
}

std::string PayloadString(const std::vector<uint8_t>& payload) {
  return std::string(payload.begin(), payload.end());
}

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

std::optional<uint32_t> JsonHexCodePoint(const std::string& json,
                                         size_t offset) {
  if (offset + 4 > json.size()) {
    return std::nullopt;
  }
  uint32_t value = 0;
  for (size_t i = offset; i < offset + 4; ++i) {
    const char ch = json[i];
    value <<= 4;
    if (ch >= '0' && ch <= '9') {
      value += static_cast<uint32_t>(ch - '0');
    } else if (ch >= 'a' && ch <= 'f') {
      value += static_cast<uint32_t>(ch - 'a' + 10);
    } else if (ch >= 'A' && ch <= 'F') {
      value += static_cast<uint32_t>(ch - 'A' + 10);
    } else {
      return std::nullopt;
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

std::optional<std::string> JsonStringValue(const std::string& json,
                                           const std::string& key) {
  const auto key_pos = json.find("\"" + key + "\"");
  if (key_pos == std::string::npos) {
    return std::nullopt;
  }
  const auto colon = json.find(':', key_pos);
  if (colon == std::string::npos) {
    return std::nullopt;
  }
  const auto quote = json.find('"', colon + 1);
  if (quote == std::string::npos) {
    return std::nullopt;
  }
  std::string result;
  for (size_t i = quote + 1; i < json.size(); ++i) {
    const char ch = json[i];
    if (ch == '"') {
      return result;
    }
    if (ch != '\\') {
      result.push_back(ch);
      continue;
    }
    if (++i >= json.size()) {
      return std::nullopt;
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
          return std::nullopt;
        }
        AppendUtf8(result, code_point.value());
        i += 4;
        break;
      }
      default:
        return std::nullopt;
    }
  }
  return std::nullopt;
}

std::optional<double> JsonNumber(const std::string& json,
                                 const std::string& key) {
  const auto key_pos = json.find("\"" + key + "\"");
  if (key_pos == std::string::npos) {
    return std::nullopt;
  }
  const auto colon = json.find(':', key_pos);
  if (colon == std::string::npos) {
    return std::nullopt;
  }
  const auto start = json.find_first_of("-0123456789", colon + 1);
  if (start == std::string::npos) {
    return std::nullopt;
  }
  const auto end = json.find_first_not_of("0123456789.-", start);
  try {
    return std::stod(json.substr(start, end - start));
  } catch (...) {
    return std::nullopt;
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

bool HasSegment(const EdgeSegment& segment) {
  return segment.end > segment.start;
}

ScreenArea VirtualScreenArea() {
  const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  return ScreenArea{left, top, left + width - 1, top + height - 1};
}

std::string Utf8FromWide(const wchar_t* value) {
  if (value == nullptr || value[0] == L'\0') {
    return "";
  }
  const int length = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                         nullptr, nullptr);
  if (length <= 1) {
    return "";
  }
  std::string result(static_cast<size_t>(length - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, &result[0], length, nullptr,
                      nullptr);
  return result;
}

BOOL CALLBACK EnumMonitorDisplayProc(HMONITOR monitor,
                                     HDC,
                                     LPRECT,
                                     LPARAM data) {
  auto* displays = reinterpret_cast<std::vector<MonitorDisplay>*>(data);
  MONITORINFOEXW info = {};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(monitor, &info) != TRUE) {
    return TRUE;
  }
  const std::string id = Utf8FromWide(info.szDevice);
  MonitorDisplay display;
  display.id = id.empty() ? std::to_string(displays->size()) : id;
  display.name = display.id;
  display.area = ScreenArea{
      info.rcMonitor.left,
      info.rcMonitor.top,
      info.rcMonitor.right - 1,
      info.rcMonitor.bottom - 1,
  };
  display.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
  displays->push_back(display);
  return TRUE;
}

std::vector<MonitorDisplay> MonitorDisplays() {
  std::vector<MonitorDisplay> displays;
  EnumDisplayMonitors(nullptr, nullptr, EnumMonitorDisplayProc,
                      reinterpret_cast<LPARAM>(&displays));
  if (displays.empty()) {
    MonitorDisplay fallback;
    fallback.id = "primary";
    fallback.name = "Primary";
    fallback.area = VirtualScreenArea();
    fallback.primary = true;
    displays.push_back(fallback);
  }
  return displays;
}

std::optional<MonitorDisplay> MonitorDisplayForId(const std::string& id) {
  if (id.empty()) {
    return std::nullopt;
  }
  for (const auto& display : MonitorDisplays()) {
    if (display.id == id) {
      return display;
    }
  }
  return std::nullopt;
}

double AxisValue(POINT point, const std::string& edge) {
  if (edge == "left" || edge == "right") {
    return static_cast<double>(point.y);
  }
  return static_cast<double>(point.x);
}

bool PointInSegment(POINT point,
                    const std::string& edge,
                    const EdgeSegment& segment,
                    double tolerance = 0) {
  if (!HasSegment(segment)) {
    return true;
  }
  const double value = AxisValue(point, edge);
  return value >= segment.start - tolerance && value <= segment.end + tolerance;
}

double EdgeUnitForPoint(POINT point,
                        const std::string& edge,
                        const EdgeSegment& segment) {
  if (!HasSegment(segment)) {
    return 0;
  }
  return ClampedUnit((AxisValue(point, edge) - segment.start) /
                     (segment.end - segment.start));
}

int SegmentCoordinate(double edge_unit, const EdgeSegment& segment) {
  return static_cast<int>(
      std::lround(segment.start + (segment.end - segment.start) *
                                      ClampedUnit(edge_unit)));
}

POINT EdgePoint(const ScreenArea& area,
                const std::string& edge,
                double edge_unit,
                const EdgeSegment& segment) {
  constexpr int inset = 2;
  const int coordinate = SegmentCoordinate(edge_unit, segment);
  if (edge == "left") {
    return POINT{area.left + inset,
                 ClampInt(coordinate, area.top + inset, area.bottom - inset)};
  }
  if (edge == "right") {
    return POINT{area.right - inset,
                 ClampInt(coordinate, area.top + inset, area.bottom - inset)};
  }
  if (edge == "top") {
    return POINT{ClampInt(coordinate, area.left + inset, area.right - inset),
                 area.top + inset};
  }
  if (edge == "bottom") {
    return POINT{ClampInt(coordinate, area.left + inset, area.right - inset),
                 area.bottom - inset};
  }
  return POINT{area.left + inset,
               ClampInt(coordinate, area.top + inset, area.bottom - inset)};
}

double Normalized(int value, int start, int length) {
  if (length <= 0) {
    return 0;
  }
  return ClampedUnit(static_cast<double>(value - start) /
                     static_cast<double>(length));
}

int CurrentMouseButtonsMask() {
  int buttons = 0;
  if ((GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
    buttons |= 1;
  }
  if ((GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0) {
    buttons |= 2;
  }
  if ((GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0) {
    buttons |= 4;
  }
  return buttons;
}

std::string MouseMovePayload(POINT point,
                             LONG delta_x,
                             LONG delta_y,
                             bool active_start,
                             const std::string& edge,
                             const std::string& route_id,
                             int buttons,
                             const ScreenArea& area,
                             const EdgeSegment& segment,
                             std::optional<double> edge_unit_override) {
  std::ostringstream json;
  json << "{\"x\":" << point.x << ",\"y\":" << point.y
       << ",\"deltaX\":" << delta_x << ",\"deltaY\":" << delta_y
       << ",\"activeStart\":" << (active_start ? "true" : "false")
       << ",\"edge\":\"" << JsonEscapedString(edge) << "\""
       << ",\"buttons\":" << buttons
       << ",\"unitX\":" << Normalized(point.x, area.left, area.width())
       << ",\"unitY\":" << Normalized(point.y, area.top, area.height());
  if (!route_id.empty()) {
    json << ",\"routeId\":\"" << JsonEscapedString(route_id) << "\"";
  }
  if (HasSegment(segment)) {
    json << ",\"edgeUnit\":"
         << (edge_unit_override.has_value()
                 ? ClampedUnit(edge_unit_override.value())
                 : EdgeUnitForPoint(point, edge, segment));
  }
  json << "}";
  return json.str();
}

std::string MouseButtonPayload(POINT point, int button, bool down) {
  std::ostringstream json;
  json << "{\"button\":" << button << ",\"down\":"
       << (down ? "true" : "false") << ",\"x\":" << point.x
       << ",\"y\":" << point.y << "}";
  return json.str();
}

std::string MouseWheelPayload(int delta_x, int delta_y) {
  std::ostringstream json;
  json << "{\"deltaX\":" << delta_x << ",\"deltaY\":" << delta_y << "}";
  return json.str();
}

std::string KeyPayload(USHORT virtual_key, bool down) {
  std::ostringstream json;
  json << "{\"sourcePlatform\":\"windows\""
       << ",\"keyCode\":" << virtual_key
       << ",\"windowsKeyCode\":" << virtual_key
       << ",\"macKeyCode\":"
       << WindowsVirtualKeyToMac(virtual_key)
       << ",\"down\":" << (down ? "true" : "false") << "}";
  return json.str();
}

WORD MacVirtualKeyToWindows(int key_code) {
  switch (key_code) {
    case 0: return 'A';
    case 1: return 'S';
    case 2: return 'D';
    case 3: return 'F';
    case 4: return 'H';
    case 5: return 'G';
    case 6: return 'Z';
    case 7: return 'X';
    case 8: return 'C';
    case 9: return 'V';
    case 11: return 'B';
    case 12: return 'Q';
    case 13: return 'W';
    case 14: return 'E';
    case 15: return 'R';
    case 16: return 'Y';
    case 17: return 'T';
    case 18: return '1';
    case 19: return '2';
    case 20: return '3';
    case 21: return '4';
    case 22: return '6';
    case 23: return '5';
    case 24: return VK_OEM_PLUS;
    case 25: return '9';
    case 26: return '7';
    case 27: return VK_OEM_MINUS;
    case 28: return '8';
    case 29: return '0';
    case 30: return VK_OEM_6;
    case 31: return 'O';
    case 32: return 'U';
    case 33: return VK_OEM_4;
    case 34: return 'I';
    case 35: return 'P';
    case 36: return VK_RETURN;
    case 37: return 'L';
    case 38: return 'J';
    case 39: return VK_OEM_7;
    case 40: return 'K';
    case 41: return VK_OEM_1;
    case 42: return VK_OEM_5;
    case 43: return VK_OEM_COMMA;
    case 44: return VK_OEM_2;
    case 45: return 'N';
    case 46: return 'M';
    case 47: return VK_OEM_PERIOD;
    case 48: return VK_TAB;
    case 49: return VK_SPACE;
    case 50: return VK_OEM_3;
    case 51: return VK_BACK;
    case 53: return VK_ESCAPE;
    case 57: return VK_CAPITAL;
    case 54: return VK_RWIN;
    case 55: return VK_LWIN;
    case 59: return VK_LCONTROL;
    case 62: return VK_RCONTROL;
    case 56:
    case 60:
      return VK_SHIFT;
    case 58:
    case 61:
      return VK_MENU;
    case 117: return VK_DELETE;
    case 123: return VK_LEFT;
    case 124: return VK_RIGHT;
    case 125: return VK_DOWN;
    case 126: return VK_UP;
    default: return static_cast<WORD>(key_code);
  }
}

int WindowsVirtualKeyToMac(USHORT virtual_key) {
  switch (virtual_key) {
    case 'A': return 0;
    case 'S': return 1;
    case 'D': return 2;
    case 'F': return 3;
    case 'H': return 4;
    case 'G': return 5;
    case 'Z': return 6;
    case 'X': return 7;
    case 'C': return 8;
    case 'V': return 9;
    case 'B': return 11;
    case 'Q': return 12;
    case 'W': return 13;
    case 'E': return 14;
    case 'R': return 15;
    case 'Y': return 16;
    case 'T': return 17;
    case '1': return 18;
    case '2': return 19;
    case '3': return 20;
    case '4': return 21;
    case '6': return 22;
    case '5': return 23;
    case VK_OEM_PLUS: return 24;
    case '9': return 25;
    case '7': return 26;
    case VK_OEM_MINUS: return 27;
    case '8': return 28;
    case '0': return 29;
    case VK_OEM_6: return 30;
    case 'O': return 31;
    case 'U': return 32;
    case VK_OEM_4: return 33;
    case 'I': return 34;
    case 'P': return 35;
    case VK_RETURN: return 36;
    case 'L': return 37;
    case 'J': return 38;
    case VK_OEM_7: return 39;
    case 'K': return 40;
    case VK_OEM_1: return 41;
    case VK_OEM_5: return 42;
    case VK_OEM_COMMA: return 43;
    case VK_OEM_2: return 44;
    case 'N': return 45;
    case 'M': return 46;
    case VK_OEM_PERIOD: return 47;
    case VK_TAB: return 48;
    case VK_SPACE: return 49;
    case VK_OEM_3: return 50;
    case VK_BACK: return 51;
    case VK_ESCAPE: return 53;
    case VK_CAPITAL: return 57;
    case VK_CONTROL:
    case VK_LCONTROL:
    case VK_RCONTROL: return 59;
    case VK_LWIN:
    case VK_RWIN: return 55;
    case VK_SHIFT:
    case VK_LSHIFT:
    case VK_RSHIFT:
      return 56;
    case VK_MENU:
    case VK_LMENU:
    case VK_RMENU:
      return 58;
    case VK_DELETE: return 117;
    case VK_LEFT: return 123;
    case VK_RIGHT: return 124;
    case VK_DOWN: return 125;
    case VK_UP: return 126;
    default: return static_cast<int>(virtual_key);
  }
}

class RemoteInputPlugin;
RemoteInputPlugin* g_plugin = nullptr;

class RemoteInputPlugin : public flutter::Plugin {
 public:
  RemoteInputPlugin(flutter::PluginRegistrarWindows* registrar, HWND window)
      : window_(window),
        channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), kRemoteInputChannel,
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          HandleMethodCall(call, std::move(result));
        });
  }

  ~RemoteInputPlugin() override {
    StopInjection();
    StopCapture();
  }

  bool HandleLowLevelMouse(WPARAM wparam, const MSLLHOOKSTRUCT* mouse) {
    if (capture_session_id_.empty() || mouse == nullptr) {
      return false;
    }
    const POINT point = mouse->pt;
    LONG delta_x = 0;
    LONG delta_y = 0;
    if (last_hook_mouse_point_.has_value()) {
      delta_x = point.x - last_hook_mouse_point_->x;
      delta_y = point.y - last_hook_mouse_point_->y;
    }
    last_hook_mouse_point_ = point;
    if (!capture_active_ && wparam != WM_MOUSEMOVE) {
      return false;
    }
    if (!capture_active_ && IsEdgeActivation(point, delta_x, delta_y)) {
      ActivateCapture("hook");
    }
    return capture_active_;
  }

  bool HandleLowLevelKeyboard(WPARAM wparam, const KBDLLHOOKSTRUCT* keyboard) {
    if (capture_session_id_.empty() || keyboard == nullptr) {
      return false;
    }
    const bool down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
    const bool up = wparam == WM_KEYUP || wparam == WM_SYSKEYUP;
    const auto virtual_key = static_cast<USHORT>(keyboard->vkCode);
    if (down && IsReleaseHotkey(virtual_key)) {
      EmitRelease("hotkey");
      StopCapture();
      return true;
    }
    if (!capture_active_) {
      POINT point = {};
      const bool has_cursor = GetCursorPos(&point) == TRUE;
      const bool at_edge = has_cursor && IsCursorAtCaptureEdge(point);
      EmitInactiveEventDiagnostic(down, up);
      if (!at_edge) {
        return false;
      }
      ActivateCapture("keyboard");
    }
    if (ShouldTraceRemoteInput() && event_diagnostic_count_ < 20 &&
        (down || up)) {
      EmitDiagnostic(RemoteInputDiagnosticEvent::kEventCaptured);
      ++event_diagnostic_count_;
    }
    if (down || up) {
      EmitInputEvent("key", JsonBytes(KeyPayload(virtual_key, down)));
    }
    return true;
  }

  bool HandleWindowMessage(HWND,
                           UINT message,
                           WPARAM,
                           LPARAM lparam) {
    if (message != WM_INPUT || capture_session_id_.empty()) {
      return false;
    }

    UINT size = 0;
    if (GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT, nullptr,
                        &size, sizeof(RAWINPUTHEADER)) != 0 ||
        size == 0) {
      return false;
    }
    std::vector<uint8_t> buffer(size);
    if (GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT,
                        buffer.data(), &size, sizeof(RAWINPUTHEADER)) != size) {
      return false;
    }
    const auto* raw = reinterpret_cast<const RAWINPUT*>(buffer.data());
    if (raw->header.dwType == RIM_TYPEMOUSE) {
      HandleRawMouse(raw->data.mouse);
    } else if (raw->header.dwType == RIM_TYPEKEYBOARD) {
      HandleRawKeyboard(raw->data.keyboard);
    }
    return false;
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();
    if (method == "startCapture") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto* session_id =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "sessionId");
      if (session_id == nullptr || session_id->empty()) {
        result->Error("bad-arguments", "startCapture requires sessionId");
        return;
      }
      const auto* edge =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "edge");
      const auto* release_hotkey = args == nullptr
                                       ? nullptr
                                       : GetMapValue<std::string>(
                                             *args, "releaseHotkey");
      const auto* display_id = args == nullptr
                                   ? nullptr
                                   : GetMapValue<std::string>(*args, "displayId");
      const EdgeSegment segment = {
          args == nullptr ? 0 : GetMapDouble(*args, "segmentStart"),
          args == nullptr ? 0 : GetMapDouble(*args, "segmentEnd"),
      };
      const auto segments =
          args == nullptr ? std::vector<EdgeSegment>{}
                          : GetMapSegments(*args, "segments");
      const auto routes =
          args == nullptr ? std::vector<CaptureRoute>{}
                          : GetMapCaptureRoutes(*args, "segments");
      const auto error = StartCapture(
          *session_id, edge == nullptr ? "right" : *edge,
          display_id == nullptr ? "" : *display_id, segment, segments, routes,
          release_hotkey == nullptr ? "ctrl+alt+esc" : *release_hotkey);
      if (error.has_value()) {
        result->Error("remote-input-capture-unavailable", error.value());
        return;
      }
      result->Success();
      return;
    }

    if (method == "stopCapture") {
      StopCapture();
      result->Success();
      return;
    }

    if (method == "pauseCapture") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto* session_id =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "sessionId");
      if (session_id == nullptr || session_id->empty()) {
        result->Error("bad-arguments", "pauseCapture requires sessionId");
        return;
      }
      const auto release_sequence =
          args == nullptr ? 0 : GetMapInt64(*args, "releaseSequence");
      const auto release_activation_sequence =
          args == nullptr ? 0 : GetMapInt64(*args, "releaseActivationSequence");
      const auto release_edge_unit =
          args == nullptr ? 0 : GetMapDouble(*args, "releaseEdgeUnit");
      const auto* display_id =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "displayId");
      const auto* edge =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "edge");
      const auto* route_id =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "routeId");
      const EdgeSegment segment{
          args == nullptr ? 0 : GetMapDouble(*args, "segmentStart"),
          args == nullptr ? 0 : GetMapDouble(*args, "segmentEnd"),
      };
      PauseCapture(*session_id, release_sequence, release_activation_sequence,
                   release_edge_unit,
                   display_id == nullptr ? "" : *display_id,
                   edge == nullptr ? "" : *edge,
                   route_id == nullptr ? "" : *route_id,
                   segment);
      result->Success();
      return;
    }

    if (method == "startInjection") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto* session_id =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "sessionId");
      if (session_id == nullptr || session_id->empty()) {
        result->Error("bad-arguments", "startInjection requires sessionId");
        return;
      }
      ReleaseInjectedButtons();
      ReleaseInjectedKeys();
      ReleaseCommonModifierKeys();
      injection_session_id_ = *session_id;
      injected_cursor_entered_interior_ = false;
      const auto* display_id = args == nullptr
                                   ? nullptr
                                   : GetMapValue<std::string>(*args, "displayId");
      const auto* edge =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "edge");
      injection_display_id_ = display_id == nullptr ? "" : *display_id;
      injection_edge_ = edge == nullptr ? "" : *edge;
      injection_route_id_.clear();
      injection_segment_ = EdgeSegment{
          args == nullptr ? 0 : GetMapDouble(*args, "segmentStart"),
          args == nullptr ? 0 : GetMapDouble(*args, "segmentEnd"),
      };
      injection_routes_ =
          args == nullptr ? std::vector<InjectionRoute>{}
                          : GetMapInjectionRoutes(*args, "mappings");
      result->Success();
      return;
    }

    if (method == "injectEvent") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto* session_id =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "sessionId");
      const auto* event_type =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "eventType");
      const auto* payload = args == nullptr
                                ? nullptr
                                : GetMapValue<std::vector<uint8_t>>(
                                      *args, "payload");
      if (session_id == nullptr || event_type == nullptr || payload == nullptr) {
        result->Error("bad-arguments",
                      "injectEvent requires sessionId, eventType, and payload");
        return;
      }
      InjectEvent(*session_id, *event_type, *payload);
      result->Success();
      return;
    }

    if (method == "stopInjection") {
      StopInjection();
      result->Success();
      return;
    }

    if (method == "getDisplayTopology") {
      result->Success(DisplayTopologyValue());
      return;
    }

    result->NotImplemented();
  }

  std::optional<std::string> StartCapture(std::string session_id,
                                          std::string edge,
                                          std::string display_id,
                                          EdgeSegment segment,
                                          std::vector<EdgeSegment> segments,
                                          std::vector<CaptureRoute> routes,
                                          std::string release_hotkey) {
    StopCapture();
    capture_session_id_ = std::move(session_id);
    capture_edge_ = std::move(edge);
    capture_route_id_.clear();
    capture_display_id_ = std::move(display_id);
    capture_segment_ = segment;
    capture_segments_ = std::move(segments);
    capture_routes_ = std::move(routes);
    release_hotkey_ = std::move(release_hotkey);
    capture_active_ = false;
    pending_active_start_ = false;
    capture_activation_sequence_ = 0;
    capture_buttons_ = 0;
    last_hook_mouse_point_.reset();
    capture_activation_edge_unit_.reset();
    event_diagnostic_count_ = 0;
    inactive_event_diagnostic_count_ = 0;
    sequence_ = 0;
    const bool raw_input_registered = RegisterRawInput(true);
    std::string hook_error;
    const bool hooks_installed = InstallHooks(&hook_error);
    std::ostringstream diagnostic;
    diagnostic << "windows remote input capture started rawInput="
               << (raw_input_registered ? 1 : 0)
               << " mouseHook=" << (mouse_hook_ != nullptr ? 1 : 0)
               << " keyboardHook=" << (keyboard_hook_ != nullptr ? 1 : 0);
    if (!hook_error.empty()) {
      diagnostic << " hookError=" << hook_error;
    }
    EmitDiagnostic(RemoteInputDiagnosticEvent::kCaptureStarted);
    if (!raw_input_registered || !hooks_installed) {
      const std::string error = diagnostic.str();
      StopCapture();
      return error;
    }
    return std::nullopt;
  }

  void StopCapture() {
    if (!capture_session_id_.empty()) {
      RegisterRawInput(false);
    }
    UninstallHooks();
    ReleaseCommonModifierKeys();
    capture_session_id_.clear();
    capture_display_id_.clear();
    capture_route_id_.clear();
    capture_segment_ = EdgeSegment{};
    capture_segments_.clear();
    capture_routes_.clear();
    capture_active_ = false;
    pending_active_start_ = false;
    capture_activation_sequence_ = 0;
    capture_buttons_ = 0;
    last_hook_mouse_point_.reset();
    capture_activation_edge_unit_.reset();
    inactive_event_diagnostic_count_ = 0;
  }

  void PauseCapture(const std::string& session_id,
                    int64_t release_sequence,
                    int64_t release_activation_sequence,
                    double release_edge_unit,
                    const std::string& release_display_id,
                    const std::string& release_edge,
                    const std::string& release_route_id,
                    EdgeSegment release_segment) {
    if (session_id == capture_session_id_) {
      if (release_activation_sequence > 0 &&
          capture_activation_sequence_ >
              static_cast<uint64_t>(release_activation_sequence)) {
        EmitDiagnostic(RemoteInputDiagnosticEvent::kStalePauseIgnored);
        return;
      }
      EmitDiagnostic(RemoteInputDiagnosticEvent::kCapturePaused);
      ReleaseCommonModifierKeys();
      if (!release_edge.empty()) {
        ApplyCaptureRoute(
            CaptureRoute{release_route_id, release_display_id, release_edge,
                         release_segment});
      }
      MoveCaptureCursorToLocalEdge(release_edge_unit);
      capture_active_ = false;
      pending_active_start_ = false;
      capture_activation_sequence_ = 0;
      capture_buttons_ = 0;
      last_hook_mouse_point_.reset();
      capture_activation_edge_unit_.reset();
      event_diagnostic_count_ = 0;
      inactive_event_diagnostic_count_ = 0;
    }
  }

  void StopInjection() {
    ReleaseInjectedButtons();
    ReleaseInjectedKeys();
    ReleaseCommonModifierKeys();
    injection_session_id_.clear();
    injected_cursor_entered_interior_ = false;
    injection_display_id_.clear();
    injection_edge_.clear();
    injection_route_id_.clear();
    injection_segment_ = EdgeSegment{};
    injection_routes_.clear();
  }

  bool InstallHooks(std::string* error_message) {
    bool installed = true;
    if (mouse_hook_ == nullptr) {
      mouse_hook_ = SetWindowsHookEx(WH_MOUSE_LL, LowLevelMouseProc,
                                     GetModuleHandle(nullptr), 0);
      if (mouse_hook_ == nullptr) {
        installed = false;
        if (error_message != nullptr) {
          *error_message += " mouseHook=" + std::to_string(GetLastError());
        }
      }
    }
    if (keyboard_hook_ == nullptr) {
      keyboard_hook_ = SetWindowsHookEx(WH_KEYBOARD_LL, LowLevelKeyboardProc,
                                        GetModuleHandle(nullptr), 0);
      if (keyboard_hook_ == nullptr) {
        installed = false;
        if (error_message != nullptr) {
          *error_message +=
              " keyboardHook=" + std::to_string(GetLastError());
        }
      }
    }
    return installed;
  }

  void UninstallHooks() {
    if (mouse_hook_ != nullptr) {
      UnhookWindowsHookEx(mouse_hook_);
      mouse_hook_ = nullptr;
    }
    if (keyboard_hook_ != nullptr) {
      UnhookWindowsHookEx(keyboard_hook_);
      keyboard_hook_ = nullptr;
    }
  }

  static LRESULT CALLBACK LowLevelMouseProc(int code,
                                            WPARAM wparam,
                                            LPARAM lparam) {
    if (code == HC_ACTION && g_plugin != nullptr &&
        g_plugin->HandleLowLevelMouse(
            wparam,
            reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam))) {
      return 1;
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }

  static LRESULT CALLBACK LowLevelKeyboardProc(int code,
                                               WPARAM wparam,
                                               LPARAM lparam) {
    if (code == HC_ACTION && g_plugin != nullptr &&
        g_plugin->HandleLowLevelKeyboard(wparam,
            reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam))) {
      return 1;
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }

  bool RegisterRawInput(bool enabled) {
    RAWINPUTDEVICE devices[2] = {};
    devices[0].usUsagePage = 0x01;
    devices[0].usUsage = 0x02;
    devices[0].dwFlags = enabled ? RIDEV_INPUTSINK : RIDEV_REMOVE;
    devices[0].hwndTarget = enabled ? window_ : nullptr;
    devices[1].usUsagePage = 0x01;
    devices[1].usUsage = 0x06;
    devices[1].dwFlags = enabled ? RIDEV_INPUTSINK : RIDEV_REMOVE;
    devices[1].hwndTarget = enabled ? window_ : nullptr;
    return RegisterRawInputDevices(devices, 2, sizeof(RAWINPUTDEVICE)) == TRUE;
  }

  void HandleRawMouse(const RAWMOUSE& mouse) {
    POINT point = {};
    GetCursorPos(&point);
    const LONG delta_x = mouse.lLastX;
    const LONG delta_y = mouse.lLastY;
    const USHORT flags = mouse.usButtonFlags;
    const bool has_button_or_wheel = flags != 0;

    bool active_start = false;
    if (!capture_active_) {
      if (!has_button_or_wheel && IsEdgeActivation(point, delta_x, delta_y)) {
        ActivateCapture("raw");
        active_start = true;
        pending_active_start_ = false;
      } else {
        return;
      }
    } else if (pending_active_start_) {
      active_start = true;
      pending_active_start_ = false;
    }

    if (flags & RI_MOUSE_LEFT_BUTTON_DOWN) {
      SetCaptureButton(0, true);
      EmitInputEvent("mouseButton", JsonBytes(MouseButtonPayload(point, 0, true)));
    }
    if (flags & RI_MOUSE_RIGHT_BUTTON_DOWN) {
      SetCaptureButton(1, true);
      EmitInputEvent("mouseButton", JsonBytes(MouseButtonPayload(point, 1, true)));
    }
    if (flags & RI_MOUSE_MIDDLE_BUTTON_DOWN) {
      SetCaptureButton(2, true);
      EmitInputEvent("mouseButton", JsonBytes(MouseButtonPayload(point, 2, true)));
    }

    if (delta_x != 0 || delta_y != 0) {
      EmitInputEvent(
          "mouseMove",
          JsonBytes(MouseMovePayload(point, delta_x, delta_y, active_start,
                                     capture_edge_, capture_route_id_,
                                     capture_buttons_, CaptureArea(),
                                     capture_segment_,
                                     active_start
                                         ? capture_activation_edge_unit_
                                         : std::nullopt)));
      if (active_start) {
        capture_activation_edge_unit_.reset();
      }
    }

    if (flags & RI_MOUSE_LEFT_BUTTON_UP) {
      EmitInputEvent("mouseButton", JsonBytes(MouseButtonPayload(point, 0, false)));
      SetCaptureButton(0, false);
    }
    if (flags & RI_MOUSE_RIGHT_BUTTON_UP) {
      EmitInputEvent("mouseButton", JsonBytes(MouseButtonPayload(point, 1, false)));
      SetCaptureButton(1, false);
    }
    if (flags & RI_MOUSE_MIDDLE_BUTTON_UP) {
      EmitInputEvent("mouseButton", JsonBytes(MouseButtonPayload(point, 2, false)));
      SetCaptureButton(2, false);
    }
    if (flags & RI_MOUSE_WHEEL) {
      const auto delta = static_cast<SHORT>(mouse.usButtonData);
      EmitInputEvent("mouseWheel", JsonBytes(MouseWheelPayload(0, delta)));
    }
    if (flags & RI_MOUSE_HWHEEL) {
      const auto delta = static_cast<SHORT>(mouse.usButtonData);
      EmitInputEvent("mouseWheel", JsonBytes(MouseWheelPayload(delta, 0)));
    }
  }

  void HandleRawKeyboard(const RAWKEYBOARD&) {}

  void MoveCaptureCursorToLocalEdge(double edge_unit = -1) const {
    const ScreenArea area = CaptureArea();
    const int left = area.left;
    const int top = area.top;
    const int right = area.right;
    const int bottom = area.bottom;
    constexpr int inset = 2;

    POINT current = {};
    if (GetCursorPos(&current) != TRUE) {
      current.x = left + area.width() / 2;
      current.y = top + area.height() / 2;
    }
    int x =
        ClampInt(static_cast<int>(current.x), left + inset, right - inset);
    int y =
        ClampInt(static_cast<int>(current.y), top + inset, bottom - inset);
    if (HasSegment(capture_segment_)) {
      const double unit = edge_unit >= 0
                              ? ClampedUnit(edge_unit)
                              : EdgeUnitForPoint(current, capture_edge_,
                                                 capture_segment_);
      const int coordinate = SegmentCoordinate(unit, capture_segment_);
      if (capture_edge_ == "left" || capture_edge_ == "right") {
        y = ClampInt(coordinate, top + inset, bottom - inset);
      } else {
        x = ClampInt(coordinate, left + inset, right - inset);
      }
    }
    POINT target = {right - inset, y};
    if (capture_edge_ == "left") {
      target = {left + inset, y};
    } else if (capture_edge_ == "top") {
      target = {x, top + inset};
    } else if (capture_edge_ == "bottom") {
      target = {x, bottom - inset};
    }
    SetCursorPos(target.x, target.y);
  }

  ScreenArea CaptureAreaForDisplay(const std::string& display_id) const {
    const auto display = MonitorDisplayForId(display_id);
    return display.has_value() ? display->area : VirtualScreenArea();
  }

  bool IsEdgeActivation(POINT point, LONG delta_x, LONG delta_y) {
    const DoublePoint current_point{static_cast<double>(point.x),
                                    static_cast<double>(point.y)};
    const DoublePoint previous_point{
        static_cast<double>(point.x - delta_x),
        static_cast<double>(point.y - delta_y)};
    const auto crossing =
        ResolveCaptureCrossing(previous_point, current_point);
    if (!crossing.has_value()) {
      return false;
    }
    ApplyCaptureRoute(crossing->route);
    capture_activation_edge_unit_ = crossing->edge_unit;
    return true;
  }

  std::optional<CaptureCrossing> ResolveCaptureCrossing(
      DoublePoint previous_point,
      DoublePoint current_point) const {
    const std::vector<CaptureRoute> routes = CaptureRoutesForMatching();
    std::vector<CaptureCrossing> candidates;
    for (const auto& route : routes) {
      const auto crossing =
          CaptureCrossingForRoute(route, previous_point, current_point, routes);
      if (crossing.has_value()) {
        candidates.push_back(crossing.value());
      }
    }
    if (candidates.empty()) {
      return std::nullopt;
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

  std::vector<CaptureRoute> CaptureRoutesForMatching() const {
    if (!capture_routes_.empty()) {
      return capture_routes_;
    }
    return std::vector<CaptureRoute>{CaptureRoute{
        capture_route_id_,
        capture_display_id_,
        capture_edge_,
        capture_segment_,
    }};
  }

  std::optional<CaptureCrossing> CaptureCrossingForRoute(
      const CaptureRoute& route,
      DoublePoint previous_point,
      DoublePoint current_point,
      const std::vector<CaptureRoute>& routes) const {
    const ScreenArea area = CaptureAreaForDisplay(route.source_display_id);
    const double delta_x = current_point.x - previous_point.x;
    const double delta_y = current_point.y - previous_point.y;
    if (delta_x == 0 && delta_y == 0) {
      return std::nullopt;
    }
    const double line = EdgeLine(area, route.source_edge);
    const auto t = IntersectionParameter(route.source_edge, line,
                                         previous_point, delta_x, delta_y);
    if (!t.has_value() || t.value() < 0 || t.value() > 1) {
      return std::nullopt;
    }
    const double normal_motion =
        EdgeNormalMotion(route.source_edge, delta_x, delta_y);
    if (normal_motion <= 0) {
      return std::nullopt;
    }
    const DoublePoint intersection{
        previous_point.x + delta_x * t.value(),
        previous_point.y + delta_y * t.value()};
    const double coordinate =
        AxisCoordinate(intersection, route.source_edge);
    if (!SegmentContains(coordinate, route.source_segment,
                         route.source_display_id, route.source_edge, routes)) {
      return std::nullopt;
    }
    const double length = route.source_segment.end - route.source_segment.start;
    if (length <= 0) {
      return std::nullopt;
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

  double EdgeLine(const ScreenArea& area, const std::string& edge) const {
    if (edge == "left") {
      return static_cast<double>(area.left);
    }
    if (edge == "top") {
      return static_cast<double>(area.top);
    }
    if (edge == "bottom") {
      return static_cast<double>(area.bottom);
    }
    return static_cast<double>(area.right);
  }

  std::optional<double> IntersectionParameter(const std::string& edge,
                                              double line,
                                              DoublePoint previous_point,
                                              double delta_x,
                                              double delta_y) const {
    if (edge == "left" || edge == "right") {
      if (delta_x == 0) {
        return std::nullopt;
      }
      return (line - previous_point.x) / delta_x;
    }
    if (delta_y == 0) {
      return std::nullopt;
    }
    return (line - previous_point.y) / delta_y;
  }

  double EdgeNormalMotion(const std::string& edge,
                          double delta_x,
                          double delta_y) const {
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

  double AxisCoordinate(DoublePoint point, const std::string& edge) const {
    if (edge == "left" || edge == "right") {
      return point.y;
    }
    return point.x;
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

  bool IsCursorAtRouteEdge(
      const CaptureRoute& route,
      POINT point,
      const std::vector<CaptureRoute>& routes) const {
    const ScreenArea area = CaptureAreaForDisplay(route.source_display_id);
    const int left = area.left;
    const int top = area.top;
    const int right = area.right;
    const int bottom = area.bottom;

    if (!CursorCoordinateInRouteSegment(route, point, routes)) {
      return false;
    }

    if (route.source_edge == "left") {
      return point.x <= left + kEdgeThreshold;
    }
    if (route.source_edge == "top") {
      return point.y <= top + kEdgeThreshold;
    }
    if (route.source_edge == "bottom") {
      return point.y >= bottom - kEdgeThreshold;
    }
    return point.x >= right - kEdgeThreshold;
  }

  bool CursorCoordinateInRouteSegment(
      const CaptureRoute& route,
      POINT point,
      const std::vector<CaptureRoute>& routes) const {
    if (!HasSegment(route.source_segment)) {
      return true;
    }
    const double coordinate = AxisValue(point, route.source_edge);
    if (coordinate < route.source_segment.start - kEdgeThreshold ||
        coordinate > route.source_segment.end + kEdgeThreshold) {
      return false;
    }
    if (coordinate >= route.source_segment.start &&
        coordinate <= route.source_segment.end) {
      return SegmentContains(coordinate, route.source_segment,
                             route.source_display_id, route.source_edge,
                             routes);
    }
    return true;
  }

  bool IsStrictCaptureSegmentHit(const CaptureRoute& route,
                                 POINT point) const {
    if (!HasSegment(route.source_segment)) {
      return true;
    }
    const double coordinate = AxisValue(point, route.source_edge);
    return coordinate > route.source_segment.start &&
           coordinate < route.source_segment.end;
  }

  double CaptureRouteEdgeDistance(const CaptureRoute& route,
                                  POINT point) const {
    const ScreenArea area = CaptureAreaForDisplay(route.source_display_id);
    const double edge_line = EdgeLine(area, route.source_edge);
    if (route.source_edge == "left" || route.source_edge == "right") {
      return std::abs(static_cast<double>(point.x) - edge_line);
    }
    return std::abs(static_cast<double>(point.y) - edge_line);
  }

  double CaptureRouteSegmentDistance(const CaptureRoute& route,
                                     POINT point) const {
    if (!HasSegment(route.source_segment)) {
      return 0;
    }
    const double coordinate = AxisValue(point, route.source_edge);
    if (coordinate < route.source_segment.start) {
      return route.source_segment.start - coordinate;
    }
    if (coordinate > route.source_segment.end) {
      return coordinate - route.source_segment.end;
    }
    return 0;
  }

  std::optional<CaptureRoute> ResolveCaptureCursorRoute(POINT point) const {
    struct CaptureCursorCandidate {
      CaptureRoute route;
      bool strict_segment_hit = false;
      double segment_distance = 0;
      double edge_distance = 0;
    };

    const std::vector<CaptureRoute> routes = CaptureRoutesForMatching();
    std::vector<CaptureCursorCandidate> candidates;
    for (const auto& route : routes) {
      if (!IsCursorAtRouteEdge(route, point, routes)) {
        continue;
      }
      candidates.push_back(CaptureCursorCandidate{
          route,
          IsStrictCaptureSegmentHit(route, point),
          CaptureRouteSegmentDistance(route, point),
          CaptureRouteEdgeDistance(route, point),
      });
    }
    if (candidates.empty()) {
      return std::nullopt;
    }
    std::sort(candidates.begin(), candidates.end(),
              [](const CaptureCursorCandidate& lhs,
                 const CaptureCursorCandidate& rhs) {
                if (lhs.strict_segment_hit != rhs.strict_segment_hit) {
                  return lhs.strict_segment_hit;
                }
                if (lhs.segment_distance != rhs.segment_distance) {
                  return lhs.segment_distance < rhs.segment_distance;
                }
                if (lhs.edge_distance != rhs.edge_distance) {
                  return lhs.edge_distance < rhs.edge_distance;
                }
                return lhs.route.route_id < rhs.route.route_id;
              });
    return candidates.front().route;
  }

  bool IsCursorAtCaptureEdge(POINT point) {
    const auto route = ResolveCaptureCursorRoute(point);
    if (!route.has_value()) {
      return false;
    }
    ApplyCaptureRoute(route.value());
    return true;
  }

  void ApplyCaptureRoute(const CaptureRoute& route) {
    capture_route_id_ = route.route_id;
    capture_display_id_ = route.source_display_id;
    capture_edge_ = route.source_edge;
    capture_segment_ = route.source_segment;
  }

  void EmitInactiveEventDiagnostic(bool down, bool up) {
    if (!ShouldTraceRemoteInput() ||
        inactive_event_diagnostic_count_ >= 20 || (!down && !up)) {
      return;
    }
    EmitDiagnostic(RemoteInputDiagnosticEvent::kEventIgnored);
    ++inactive_event_diagnostic_count_;
  }

  void ActivateCapture(const char* source) {
    if (capture_active_) {
      return;
    }
    capture_active_ = true;
    pending_active_start_ = true;
    capture_activation_sequence_ = sequence_ + 1;
    capture_buttons_ = CurrentMouseButtonsMask();
    event_diagnostic_count_ = 0;
    (void)source;
    EmitDiagnostic(RemoteInputDiagnosticEvent::kCaptureActive);
  }

  bool IsReleaseHotkey(USHORT virtual_key) const {
    if (release_hotkey_ != "ctrl+alt+esc" || virtual_key != VK_ESCAPE) {
      return false;
    }
    return (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 &&
           (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
  }

  ScreenArea CaptureArea() const {
    return CaptureAreaForDisplay(capture_display_id_);
  }

  ScreenArea InjectionArea() const {
    const auto display = MonitorDisplayForId(injection_display_id_);
    return display.has_value() ? display->area : VirtualScreenArea();
  }

  double CaptureEdgeUnit(POINT point) const {
    return EdgeUnitForPoint(point, capture_edge_, capture_segment_);
  }

  double InjectionEdgeUnit(POINT point) const {
    if (injection_edge_.empty()) {
      return 0;
    }
    return EdgeUnitForPoint(point, injection_edge_, injection_segment_);
  }

  std::optional<InjectionReleaseRoute> ReverseInjectionSourceEdgeUnit(
      POINT point,
      int delta_x,
      int delta_y) const {
    if (injection_routes_.empty()) {
      return std::nullopt;
    }
    const DoublePoint previous_point{static_cast<double>(point.x),
                                     static_cast<double>(point.y)};
    const DoublePoint current_point{static_cast<double>(point.x + delta_x),
                                    static_cast<double>(point.y + delta_y)};
    const auto crossing =
        ResolveInjectionReleaseCrossing(previous_point, current_point);
    if (!crossing.has_value()) {
      return std::nullopt;
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

  std::optional<InjectionReleaseCrossing> ResolveInjectionReleaseCrossing(
      DoublePoint previous_point,
      DoublePoint current_point) const {
    std::vector<InjectionReleaseCrossing> candidates;
    for (const auto& route : injection_routes_) {
      const auto crossing =
          InjectionReleaseCrossingForRoute(route, previous_point, current_point);
      if (crossing.has_value()) {
        candidates.push_back(crossing.value());
      }
    }
    if (candidates.empty()) {
      return std::nullopt;
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

  std::optional<InjectionReleaseCrossing> InjectionReleaseCrossingForRoute(
      const InjectionRoute& route,
      DoublePoint previous_point,
      DoublePoint current_point) const {
    const auto display = MonitorDisplayForId(route.sink_display_id);
    const ScreenArea area =
        display.has_value() ? display->area : VirtualScreenArea();
    const double delta_x = current_point.x - previous_point.x;
    const double delta_y = current_point.y - previous_point.y;
    if (delta_x == 0 && delta_y == 0) {
      return std::nullopt;
    }
    const double line = EdgeLine(area, route.sink_edge);
    const auto t = IntersectionParameter(route.sink_edge, line,
                                         previous_point, delta_x, delta_y);
    if (!t.has_value() || t.value() < 0 || t.value() > 1) {
      return std::nullopt;
    }
    const double normal_motion =
        EdgeNormalMotion(route.sink_edge, delta_x, delta_y);
    if (normal_motion <= 0) {
      return std::nullopt;
    }
    const DoublePoint intersection{
        previous_point.x + delta_x * t.value(),
        previous_point.y + delta_y * t.value()};
    const double coordinate = AxisCoordinate(intersection, route.sink_edge);
    if (!SegmentContains(coordinate, route.sink_segment,
                         route.sink_display_id, route.sink_edge,
                         injection_routes_)) {
      return std::nullopt;
    }
    const double length = route.sink_segment.end - route.sink_segment.start;
    if (length <= 0) {
      return std::nullopt;
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

  flutter::EncodableValue DisplayTopologyValue() const {
    flutter::EncodableList displays;
    for (const auto& display : MonitorDisplays()) {
      flutter::EncodableMap item;
      item[flutter::EncodableValue("displayId")] =
          flutter::EncodableValue(display.id);
      item[flutter::EncodableValue("name")] =
          flutter::EncodableValue(display.name);
      item[flutter::EncodableValue("x")] =
          flutter::EncodableValue(static_cast<int32_t>(display.area.left));
      item[flutter::EncodableValue("y")] =
          flutter::EncodableValue(static_cast<int32_t>(display.area.top));
      item[flutter::EncodableValue("width")] =
          flutter::EncodableValue(static_cast<int32_t>(display.area.width()));
      item[flutter::EncodableValue("height")] =
          flutter::EncodableValue(static_cast<int32_t>(display.area.height()));
      item[flutter::EncodableValue("scale")] =
          flutter::EncodableValue(display.scale);
      item[flutter::EncodableValue("isPrimary")] =
          flutter::EncodableValue(display.primary);
      displays.push_back(flutter::EncodableValue(std::move(item)));
    }
    flutter::EncodableMap topology;
    topology[flutter::EncodableValue("platform")] =
        flutter::EncodableValue("windows");
    topology[flutter::EncodableValue("updatedAt")] =
        flutter::EncodableValue(static_cast<int64_t>(NowMicros() / 1000));
    topology[flutter::EncodableValue("displays")] =
        flutter::EncodableValue(std::move(displays));
    return flutter::EncodableValue(std::move(topology));
  }

  void UpdateInjectionRouteFromPayload(const std::string& json) {
    const std::string sink_edge = JsonString(json, "sinkEdge", "");
    if (sink_edge.empty()) {
      return;
    }
    injection_display_id_ =
        JsonString(json, "sinkDisplayId", injection_display_id_);
    injection_edge_ = sink_edge;
    injection_route_id_ = JsonString(json, "routeId", injection_route_id_);
    injection_segment_ = EdgeSegment{
        JsonNumber(json, "sinkSegmentStart").value_or(0),
        JsonNumber(json, "sinkSegmentEnd").value_or(0),
    };
  }

  POINT CursorPointForEntry(const std::string& json) {
    UpdateInjectionRouteFromPayload(json);
    const auto edge_unit = JsonNumber(json, "edgeUnit");
    if (edge_unit.has_value() && HasSegment(injection_segment_) &&
        !injection_edge_.empty()) {
      return EdgePoint(InjectionArea(), injection_edge_, edge_unit.value(),
                       injection_segment_);
    }
    const ScreenArea area = VirtualScreenArea();
    const int left = area.left;
    const int top = area.top;
    const int right = area.right;
    const int bottom = area.bottom;
    const int unit_width = area.width() > 1 ? area.width() - 1 : 1;
    const int unit_height = area.height() > 1 ? area.height() - 1 : 1;
    const int inset = 2;
    const double unit_x = ClampedUnit(JsonNumber(json, "unitX").value_or(0));
    const double unit_y = ClampedUnit(JsonNumber(json, "unitY").value_or(0));
    const std::string edge = JsonString(json, "edge", "right");

    int x = left + inset;
    int y = ClampInt(
        top + static_cast<int>(std::round(unit_y * unit_height)),
        top, bottom);
    if (edge == "left") {
      x = right - inset;
      y = ClampInt(
          top + static_cast<int>(std::round(unit_y * unit_height)),
          top, bottom);
    } else if (edge == "top") {
      x = ClampInt(
          left + static_cast<int>(std::round(unit_x * unit_width)),
          left, right);
      y = bottom - inset;
    } else if (edge == "bottom") {
      x = ClampInt(
          left + static_cast<int>(std::round(unit_x * unit_width)),
          left, right);
      y = top + inset;
    }
    return POINT{x, y};
  }

  POINT CurrentCursorPoint() const {
    const ScreenArea area = InjectionArea();
    POINT current = {};
    if (GetCursorPos(&current) != TRUE) {
      current.x = area.left + area.width() / 2;
      current.y = area.top + area.height() / 2;
    }
    return current;
  }

  POINT ClampToVirtualScreen(POINT point) const {
    const ScreenArea area = VirtualScreenArea();
    const int left = area.left;
    const int top = area.top;
    const int right = area.right;
    const int bottom = area.bottom;
    constexpr int inset = 2;
    point.x = ClampInt(static_cast<int>(point.x), left + inset, right - inset);
    point.y = ClampInt(static_cast<int>(point.y), top + inset, bottom - inset);
    return point;
  }

  void MoveCursorToPoint(POINT point) const {
    const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    const int unit_width = width > 1 ? width - 1 : 1;
    const int unit_height = height > 1 ? height - 1 : 1;
    point = ClampToVirtualScreen(point);

    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dx = static_cast<LONG>(std::lround(
        static_cast<double>(point.x - left) * 65535.0 /
        static_cast<double>(unit_width)));
    input.mi.dy = static_cast<LONG>(std::lround(
        static_cast<double>(point.y - top) * 65535.0 /
        static_cast<double>(unit_height)));
    input.mi.dwFlags =
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    SendInput(1, &input, sizeof(INPUT));
  }

  void SendMouseButton(int button, bool down) {
    INPUT input = MouseButtonInput(button, down);
    SendInput(1, &input, sizeof(INPUT));
  }

  INPUT MouseButtonInput(int button, bool down) const {
    INPUT input = {};
    input.type = INPUT_MOUSE;
    if (button == 1) {
      input.mi.dwFlags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
    } else if (button == 2) {
      input.mi.dwFlags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
    } else {
      input.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
    }
    return input;
  }

  void SendMouseButtonClick(int button) {
    INPUT inputs[2] = {
        MouseButtonInput(button, true),
        MouseButtonInput(button, false),
    };
    SendInput(2, inputs, sizeof(INPUT));
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

  void SetCaptureButton(int button, bool down) {
    const int bit = MouseButtonBit(button);
    if (down) {
      capture_buttons_ |= bit;
    } else {
      capture_buttons_ &= ~bit;
    }
  }

  void SetInjectedButton(int button, bool down) {
    const int bit = MouseButtonBit(button);
    if (down) {
      injected_buttons_ |= bit;
    } else {
      injected_buttons_ &= ~bit;
    }
  }

  void QueueInjectedButtonDown(int button) {
    const int bit = MouseButtonBit(button);
    if ((injected_buttons_ & bit) != 0) {
      return;
    }
    pending_injected_buttons_ |= bit;
  }

  void FlushPendingInjectedButtons() {
    FlushPendingInjectedButton(0);
    FlushPendingInjectedButton(1);
    FlushPendingInjectedButton(2);
  }

  void FlushPendingInjectedButton(int button) {
    const int bit = MouseButtonBit(button);
    if ((pending_injected_buttons_ & bit) == 0) {
      return;
    }
    pending_injected_buttons_ &= ~bit;
    SendMouseButton(button, true);
    SetInjectedButton(button, true);
  }

  void ReleaseInjectedButton(int button) {
    const int bit = MouseButtonBit(button);
    const bool is_pending = (pending_injected_buttons_ & bit) != 0;
    const bool is_down = (injected_buttons_ & bit) != 0;
    if (is_pending && !is_down) {
      pending_injected_buttons_ &= ~bit;
      SendMouseButtonClick(button);
      return;
    }
    pending_injected_buttons_ &= ~bit;
    if (is_down) {
      SendMouseButton(button, false);
      SetInjectedButton(button, false);
    }
  }

  void SyncInjectedButtons(int desired_buttons) {
    SyncInjectedButton(0, desired_buttons);
    SyncInjectedButton(1, desired_buttons);
    SyncInjectedButton(2, desired_buttons);
  }

  void SyncInjectedButton(int button, int desired_buttons) {
    const int bit = MouseButtonBit(button);
    const bool should_be_down = (desired_buttons & bit) != 0;
    const bool is_down = (injected_buttons_ & bit) != 0;
    const bool is_pending = (pending_injected_buttons_ & bit) != 0;
    if (should_be_down) {
      if (!is_down && !is_pending) {
        QueueInjectedButtonDown(button);
      }
      return;
    }
    if (is_pending) {
      pending_injected_buttons_ &= ~bit;
    }
    if (is_down) {
      SendMouseButton(button, false);
      SetInjectedButton(button, false);
    }
  }

  void ReleaseInjectedButtons() {
    if (injected_buttons_ == 0 && pending_injected_buttons_ == 0) {
      return;
    }
    pending_injected_buttons_ = 0;
    SyncInjectedButtons(0);
  }

  void SendKeyboardKey(WORD key, bool down) {
    if (key == 0) {
      return;
    }
    const UINT scan_code = MapVirtualKeyW(key, MAPVK_VK_TO_VSC);
    INPUT input = {};
    input.type = INPUT_KEYBOARD;
    if (scan_code == 0) {
      input.ki.wVk = key;
      input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
    } else {
      input.ki.wScan = static_cast<WORD>(scan_code);
      input.ki.dwFlags = KEYEVENTF_SCANCODE;
      if (!down) {
        input.ki.dwFlags |= KEYEVENTF_KEYUP;
      }
      if (IsExtendedKeyboardKey(key)) {
        input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
      }
    }
    SendInput(1, &input, sizeof(INPUT));
  }

  bool IsExtendedKeyboardKey(WORD key) const {
    switch (key) {
      case VK_RCONTROL:
      case VK_RMENU:
      case VK_INSERT:
      case VK_DELETE:
      case VK_HOME:
      case VK_END:
      case VK_PRIOR:
      case VK_NEXT:
      case VK_LEFT:
      case VK_RIGHT:
      case VK_UP:
      case VK_DOWN:
      case VK_NUMLOCK:
      case VK_DIVIDE:
      case VK_LWIN:
      case VK_RWIN:
      case VK_APPS:
        return true;
      default:
        return false;
    }
  }

  void SetInjectedKey(WORD key, bool down) {
    if (key == 0) {
      return;
    }
    const auto it = std::find(injected_keys_.begin(), injected_keys_.end(), key);
    if (down) {
      if (it == injected_keys_.end()) {
        injected_keys_.push_back(key);
      }
      return;
    }
    if (it != injected_keys_.end()) {
      injected_keys_.erase(it);
    }
  }

  void ReleaseInjectedKeys() {
    if (injected_keys_.empty()) {
      return;
    }
    const auto keys = injected_keys_;
    injected_keys_.clear();
    for (auto it = keys.rbegin(); it != keys.rend(); ++it) {
      SendKeyboardKey(*it, false);
    }
  }

  void ReleaseCommonModifierKeys() {
    constexpr WORD keys[] = {
        VK_CONTROL, VK_LCONTROL, VK_RCONTROL, VK_SHIFT, VK_LSHIFT, VK_RSHIFT,
        VK_MENU, VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN};
    for (const WORD key : keys) {
      if ((GetAsyncKeyState(key) & 0x8000) != 0) {
        SendKeyboardKey(key, false);
      }
    }
  }

  void InjectEvent(const std::string& session_id,
                   const std::string& event_type,
                   const std::vector<uint8_t>& payload) {
    if (session_id != injection_session_id_) {
      return;
    }
    const auto json = PayloadString(payload);
    if (event_type == "mouseMove") {
      const int delta_x = static_cast<int>(std::round(JsonNumber(json, "deltaX").value_or(0)));
      const int delta_y = static_cast<int>(std::round(JsonNumber(json, "deltaY").value_or(0)));
      POINT current = CurrentCursorPoint();
      const auto routed_edge_unit =
          !JsonBool(json, "activeStart") && injected_cursor_entered_interior_
              ? ReverseInjectionSourceEdgeUnit(current, delta_x, delta_y)
              : std::nullopt;
      if (routed_edge_unit.has_value()) {
        const std::string release_session_id = injection_session_id_;
        ReleaseInjectedButtons();
        ReleaseInjectedKeys();
        ReleaseCommonModifierKeys();
        const auto release_route = routed_edge_unit.value();
        EmitReleaseForSession(
            release_session_id,
            "edge",
            release_route.edge_unit,
            true,
            release_route.route_id,
            release_route.source_display_id,
            release_route.source_edge,
            release_route.source_segment);
        return;
      }
      if (IsInjectionReverseRelease(json, current, delta_x, delta_y)) {
        const std::string release_session_id = injection_session_id_;
        const double edge_unit = InjectionEdgeUnit(current);
        ReleaseInjectedButtons();
        ReleaseInjectedKeys();
        ReleaseCommonModifierKeys();
        EmitReleaseForSession(release_session_id, "edge", edge_unit);
        return;
      }
      if (JsonBool(json, "activeStart")) {
        current = CursorPointForEntry(json);
        MoveCursorToPoint(current);
        injected_cursor_entered_interior_ = false;
      }
      POINT final_point = current;
      const auto buttons = JsonNumber(json, "buttons");
      if (buttons.has_value()) {
        SyncInjectedButtons(static_cast<int>(std::round(buttons.value())));
      }
      if (delta_x != 0 || delta_y != 0) {
        FlushPendingInjectedButtons();
        POINT target = {current.x + delta_x, current.y + delta_y};
        target = ClampToVirtualScreen(target);
        MoveCursorToPoint(target);
        final_point = target;
      }
      UpdateInjectedCursorInteriorState(json, final_point);
      return;
    }

    if (event_type == "mouseButton") {
      const int button = static_cast<int>(JsonNumber(json, "button").value_or(0));
      const bool down = JsonBool(json, "down");
      if (down) {
        QueueInjectedButtonDown(button);
      } else {
        ReleaseInjectedButton(button);
      }
      return;
    }

    if (event_type == "mouseWheel") {
      const int delta_y = static_cast<int>(std::round(JsonNumber(json, "deltaY").value_or(0)));
      const int delta_x = static_cast<int>(std::round(JsonNumber(json, "deltaX").value_or(0)));
      if (delta_y != 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_WHEEL;
        input.mi.mouseData = delta_y;
        SendInput(1, &input, sizeof(INPUT));
      }
      if (delta_x != 0) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
        input.mi.mouseData = delta_x;
        SendInput(1, &input, sizeof(INPUT));
      }
      return;
    }

    if (event_type == "key") {
      const auto windows_key = JsonNumber(json, "windowsKeyCode");
      const int raw_key = static_cast<int>(
          windows_key.value_or(JsonNumber(json, "keyCode").value_or(0)));
      const bool down = JsonBool(json, "down");
      const WORD key = windows_key.has_value()
                           ? static_cast<WORD>(raw_key)
                           : MacVirtualKeyToWindows(raw_key);
      SendKeyboardKey(key, down);
      SetInjectedKey(key, down);
    }
  }

  bool IsInjectionReverseRelease(const std::string& json,
                                 POINT point,
                                 int delta_x,
                                 int delta_y) const {
    if (injection_session_id_.empty() || JsonBool(json, "activeStart")) {
      return false;
    }
    if (HasSegment(injection_segment_) && !injection_edge_.empty()) {
      const ScreenArea area = InjectionArea();
      if (!PointInSegment(point, injection_edge_, injection_segment_,
                          kEdgeThreshold)) {
        return false;
      }
      if (injection_edge_ == "left") {
        return point.x <= area.left + kEdgeThreshold && delta_x < 0;
      }
      if (injection_edge_ == "right") {
        return point.x >= area.right - kEdgeThreshold && delta_x > 0;
      }
      if (injection_edge_ == "top") {
        return point.y <= area.top + kEdgeThreshold && delta_y < 0;
      }
      if (injection_edge_ == "bottom") {
        return point.y >= area.bottom - kEdgeThreshold && delta_y > 0;
      }
    }
    const ScreenArea area = VirtualScreenArea();
    const int left = area.left;
    const int top = area.top;
    const int right = area.right;
    const int bottom = area.bottom;
    const std::string edge = JsonString(json, "edge", "right");

    if (edge == "left") {
      return point.x >= right - kEdgeThreshold && delta_x > 0;
    }
    if (edge == "top") {
      return point.y >= bottom - kEdgeThreshold && delta_y > 0;
    }
    if (edge == "bottom") {
      return point.y <= top + kEdgeThreshold && delta_y < 0;
    }
    return point.x <= left + kEdgeThreshold && delta_x < 0;
  }

  void UpdateInjectedCursorInteriorState(const std::string& json,
                                         POINT point) {
    if (JsonBool(json, "activeStart")) {
      injected_cursor_entered_interior_ = false;
      return;
    }
    if (injected_cursor_entered_interior_) {
      return;
    }
    const bool using_configured_edge =
        HasSegment(injection_segment_) && !injection_edge_.empty();
    const ScreenArea area =
        using_configured_edge ? InjectionArea() : VirtualScreenArea();
    const std::string edge =
        using_configured_edge ? injection_edge_ : JsonString(json, "edge", "right");
    constexpr int distance = 32;
    bool interior = false;
    if (using_configured_edge) {
      if (edge == "left") {
        interior = point.x >= area.left + distance;
      } else if (edge == "right") {
        interior = point.x <= area.right - distance;
      } else if (edge == "top") {
        interior = point.y >= area.top + distance;
      } else if (edge == "bottom") {
        interior = point.y <= area.bottom - distance;
      }
    } else if (edge == "left") {
      interior = point.x <= area.right - distance;
    } else if (edge == "top") {
      interior = point.y <= area.bottom - distance;
    } else if (edge == "bottom") {
      interior = point.y >= area.top + distance;
    } else {
      interior = point.x >= area.left + distance;
    }
    if (interior) {
      injected_cursor_entered_interior_ = true;
    }
  }

  void EmitInputEvent(const std::string& event_type,
                      std::vector<uint8_t> payload) {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(capture_session_id_);
    arguments[flutter::EncodableValue("sequence")] =
        flutter::EncodableValue(static_cast<int64_t>(++sequence_));
    arguments[flutter::EncodableValue("timestampMicros")] =
        flutter::EncodableValue(NowMicros());
    arguments[flutter::EncodableValue("eventType")] =
        flutter::EncodableValue(event_type);
    arguments[flutter::EncodableValue("payload")] =
        flutter::EncodableValue(std::move(payload));

    std::lock_guard<std::mutex> lock(channel_mutex_);
    channel_->InvokeMethod(
        "onInputEvent",
        std::make_unique<flutter::EncodableValue>(std::move(arguments)));
  }

  void EmitRelease(const std::string& reason) {
    EmitReleaseForSession(capture_session_id_, reason,
                          CaptureEdgeUnit(CurrentCursorPoint()));
  }

  void EmitReleaseForSession(const std::string& session_id,
                             const std::string& reason,
                             double edge_unit = 0,
                             bool source_edge_unit = false,
                             const std::string& route_id = "",
                             const std::string& source_display_id = "",
                             const std::string& source_edge = "",
                             EdgeSegment source_segment = EdgeSegment{}) {
    if (session_id.empty()) {
      return;
    }
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(session_id);
    arguments[flutter::EncodableValue("reason")] =
        flutter::EncodableValue(reason);
    arguments[flutter::EncodableValue("edgeUnit")] =
        flutter::EncodableValue(edge_unit);
    if (source_edge_unit) {
      arguments[flutter::EncodableValue("sourceEdgeUnit")] =
          flutter::EncodableValue(true);
    }
    if (!route_id.empty()) {
      arguments[flutter::EncodableValue("routeId")] =
          flutter::EncodableValue(route_id);
    }
    if (!source_display_id.empty()) {
      arguments[flutter::EncodableValue("sourceDisplayId")] =
          flutter::EncodableValue(source_display_id);
    }
    if (!source_edge.empty()) {
      arguments[flutter::EncodableValue("sourceEdge")] =
          flutter::EncodableValue(source_edge);
    }
    if (source_segment.end > source_segment.start) {
      arguments[flutter::EncodableValue("sourceSegmentStart")] =
          flutter::EncodableValue(source_segment.start);
      arguments[flutter::EncodableValue("sourceSegmentEnd")] =
          flutter::EncodableValue(source_segment.end);
    }

    std::lock_guard<std::mutex> lock(channel_mutex_);
    channel_->InvokeMethod(
        "onRelease",
        std::make_unique<flutter::EncodableValue>(std::move(arguments)));
  }

  void EmitDiagnostic(RemoteInputDiagnosticEvent event) {
    if (!ShouldTraceRemoteInput()) {
      return;
    }
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("event")] =
        flutter::EncodableValue(RemoteInputDiagnosticEventName(event));

    std::lock_guard<std::mutex> lock(channel_mutex_);
    channel_->InvokeMethod(
        "onDiagnostic",
        std::make_unique<flutter::EncodableValue>(std::move(arguments)));
  }

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::mutex channel_mutex_;
  std::string capture_session_id_;
  std::string injection_session_id_;
  std::string capture_edge_ = "right";
  std::string capture_display_id_;
  std::string capture_route_id_;
  EdgeSegment capture_segment_;
  std::vector<EdgeSegment> capture_segments_;
  std::vector<CaptureRoute> capture_routes_;
  std::string injection_display_id_;
  std::string injection_edge_;
  std::string injection_route_id_;
  EdgeSegment injection_segment_;
  std::vector<InjectionRoute> injection_routes_;
  std::string release_hotkey_ = "ctrl+alt+esc";
  bool capture_active_ = false;
  bool pending_active_start_ = false;
  int capture_buttons_ = 0;
  int event_diagnostic_count_ = 0;
  int inactive_event_diagnostic_count_ = 0;
  int injected_buttons_ = 0;
  int pending_injected_buttons_ = 0;
  bool injected_cursor_entered_interior_ = false;
  std::vector<WORD> injected_keys_;
  std::optional<POINT> last_hook_mouse_point_;
  std::optional<double> capture_activation_edge_unit_;
  uint64_t sequence_ = 0;
  uint64_t capture_activation_sequence_ = 0;
  HHOOK mouse_hook_ = nullptr;
  HHOOK keyboard_hook_ = nullptr;
};

}  // namespace

void RemoteInputPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar, HWND window) {
  auto plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  auto plugin = std::make_unique<RemoteInputPlugin>(plugin_registrar, window);
  g_plugin = plugin.get();
  plugin_registrar->AddPlugin(std::move(plugin));
}

bool RemoteInputPluginHandleWindowMessage(HWND window,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam) {
  if (g_plugin == nullptr) {
    return false;
  }
  return g_plugin->HandleWindowMessage(window, message, wparam, lparam);
}
