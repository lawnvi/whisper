#include "remote_input_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cmath>
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

std::string PayloadString(const std::vector<uint8_t>& payload) {
  return std::string(payload.begin(), payload.end());
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
  const auto key_pos = json.find("\"" + key + "\"");
  if (key_pos == std::string::npos) {
    return fallback;
  }
  const auto colon = json.find(':', key_pos);
  if (colon == std::string::npos) {
    return fallback;
  }
  const auto quote = json.find('"', colon + 1);
  if (quote == std::string::npos) {
    return fallback;
  }
  const auto end = json.find('"', quote + 1);
  if (end == std::string::npos) {
    return fallback;
  }
  return json.substr(quote + 1, end - quote - 1);
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
                             int buttons,
                             const ScreenArea& area,
                             const EdgeSegment& segment) {
  std::ostringstream json;
  json << "{\"x\":" << point.x << ",\"y\":" << point.y
       << ",\"deltaX\":" << delta_x << ",\"deltaY\":" << delta_y
       << ",\"activeStart\":" << (active_start ? "true" : "false")
       << ",\"edge\":\"" << edge << "\""
       << ",\"buttons\":" << buttons
       << ",\"unitX\":" << Normalized(point.x, area.left, area.width())
       << ",\"unitY\":" << Normalized(point.y, area.top, area.height());
  if (HasSegment(segment)) {
    json << ",\"edgeUnit\":" << EdgeUnitForPoint(point, edge, segment);
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
      EmitInactiveKeyboardDiagnostic(
          virtual_key, down, up, keyboard->flags, point, has_cursor, at_edge);
      if (!at_edge) {
        return false;
      }
      ActivateCapture("keyboard");
    }
    if (keyboard_diagnostic_count_ < 20 && (down || up)) {
      std::ostringstream diagnostic;
      diagnostic << "windows keyboard hook vk=" << virtual_key
                 << " down=" << (down ? 1 : 0)
                 << " up=" << (up ? 1 : 0)
                 << " flags=" << keyboard->flags
                 << " captureActive=1";
      EmitDiagnostic(diagnostic.str());
      ++keyboard_diagnostic_count_;
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
      const auto error = StartCapture(
          *session_id, edge == nullptr ? "right" : *edge,
          display_id == nullptr ? "" : *display_id, segment,
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
      PauseCapture(*session_id, release_sequence, release_activation_sequence,
                   release_edge_unit);
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
      const auto* display_id = args == nullptr
                                   ? nullptr
                                   : GetMapValue<std::string>(*args, "displayId");
      const auto* edge =
          args == nullptr ? nullptr : GetMapValue<std::string>(*args, "edge");
      injection_display_id_ = display_id == nullptr ? "" : *display_id;
      injection_edge_ = edge == nullptr ? "" : *edge;
      injection_segment_ = EdgeSegment{
          args == nullptr ? 0 : GetMapDouble(*args, "segmentStart"),
          args == nullptr ? 0 : GetMapDouble(*args, "segmentEnd"),
      };
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
                                          std::string release_hotkey) {
    StopCapture();
    capture_session_id_ = std::move(session_id);
    capture_edge_ = std::move(edge);
    capture_display_id_ = std::move(display_id);
    capture_segment_ = segment;
    release_hotkey_ = std::move(release_hotkey);
    capture_active_ = false;
    pending_active_start_ = false;
    capture_activation_sequence_ = 0;
    capture_buttons_ = 0;
    last_hook_mouse_point_.reset();
    keyboard_diagnostic_count_ = 0;
    inactive_keyboard_diagnostic_count_ = 0;
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
    EmitDiagnostic(diagnostic.str());
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
    capture_segment_ = EdgeSegment{};
    capture_active_ = false;
    pending_active_start_ = false;
    capture_activation_sequence_ = 0;
    capture_buttons_ = 0;
    last_hook_mouse_point_.reset();
    inactive_keyboard_diagnostic_count_ = 0;
  }

  void PauseCapture(const std::string& session_id,
                    int64_t release_sequence,
                    int64_t release_activation_sequence,
                    double release_edge_unit) {
    if (session_id == capture_session_id_) {
      if (release_activation_sequence > 0 &&
          capture_activation_sequence_ >
              static_cast<uint64_t>(release_activation_sequence)) {
        std::ostringstream diagnostic;
        diagnostic << "windows remote input ignored stale pause "
                   << "releaseSequence=" << release_sequence
                   << " releaseActivationSequence="
                   << release_activation_sequence
                   << " nativeSequence=" << sequence_;
        EmitDiagnostic(diagnostic.str());
        return;
      }
      std::ostringstream diagnostic;
      diagnostic << "windows remote input capture paused edge="
                 << capture_edge_
                 << " releaseSequence=" << release_sequence
                 << " releaseActivationSequence="
                 << release_activation_sequence
                 << " nativeSequence=" << sequence_
                 << " activationSequence=" << capture_activation_sequence_
                 << " wasActive=" << (capture_active_ ? 1 : 0);
      EmitDiagnostic(diagnostic.str());
      ReleaseCommonModifierKeys();
      MoveCaptureCursorToLocalEdge(release_edge_unit);
      capture_active_ = false;
      pending_active_start_ = false;
      capture_activation_sequence_ = 0;
      capture_buttons_ = 0;
      last_hook_mouse_point_.reset();
      keyboard_diagnostic_count_ = 0;
      inactive_keyboard_diagnostic_count_ = 0;
    }
  }

  void StopInjection() {
    ReleaseInjectedButtons();
    ReleaseInjectedKeys();
    ReleaseCommonModifierKeys();
    injection_session_id_.clear();
    injection_display_id_.clear();
    injection_edge_.clear();
    injection_segment_ = EdgeSegment{};
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
                                     capture_edge_, capture_buttons_,
                                     CaptureArea(), capture_segment_)));
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

  bool IsEdgeActivation(POINT point, LONG delta_x, LONG delta_y) const {
    const ScreenArea area = CaptureArea();
    const int left = area.left;
    const int top = area.top;
    const int right = area.right;
    const int bottom = area.bottom;

    if (!PointInSegment(point, capture_edge_, capture_segment_,
                        kEdgeThreshold)) {
      return false;
    }

    if (capture_edge_ == "left") {
      return point.x <= left + kEdgeThreshold && delta_x < 0;
    }
    if (capture_edge_ == "top") {
      return point.y <= top + kEdgeThreshold && delta_y < 0;
    }
    if (capture_edge_ == "bottom") {
      return point.y >= bottom - kEdgeThreshold && delta_y > 0;
    }
    return point.x >= right - kEdgeThreshold && delta_x > 0;
  }

  bool IsCursorAtCaptureEdge(POINT point) const {
    const ScreenArea area = CaptureArea();
    const int left = area.left;
    const int top = area.top;
    const int right = area.right;
    const int bottom = area.bottom;

    if (!PointInSegment(point, capture_edge_, capture_segment_,
                        kEdgeThreshold)) {
      return false;
    }

    if (capture_edge_ == "left") {
      return point.x <= left + kEdgeThreshold;
    }
    if (capture_edge_ == "top") {
      return point.y <= top + kEdgeThreshold;
    }
    if (capture_edge_ == "bottom") {
      return point.y >= bottom - kEdgeThreshold;
    }
    return point.x >= right - kEdgeThreshold;
  }

  void EmitInactiveKeyboardDiagnostic(USHORT virtual_key,
                                      bool down,
                                      bool up,
                                      DWORD flags,
                                      POINT point,
                                      bool has_cursor,
                                      bool at_edge) {
    if (inactive_keyboard_diagnostic_count_ >= 20 || (!down && !up)) {
      return;
    }
    std::ostringstream diagnostic;
    diagnostic << "windows keyboard hook inactive vk=" << virtual_key
               << " down=" << (down ? 1 : 0)
               << " up=" << (up ? 1 : 0)
               << " flags=" << flags
               << " edge=" << capture_edge_
               << " hasCursor=" << (has_cursor ? 1 : 0)
               << " cursor=" << point.x << "," << point.y
               << " atEdge=" << (at_edge ? 1 : 0);
    EmitDiagnostic(diagnostic.str());
    ++inactive_keyboard_diagnostic_count_;
  }

  void ActivateCapture(const char* source) {
    if (capture_active_) {
      return;
    }
    capture_active_ = true;
    pending_active_start_ = true;
    capture_activation_sequence_ = sequence_ + 1;
    capture_buttons_ = CurrentMouseButtonsMask();
    keyboard_diagnostic_count_ = 0;
    std::ostringstream diagnostic;
    diagnostic << "windows remote input capture active edge="
               << capture_edge_
               << " via=" << source
               << " activationSequence=" << capture_activation_sequence_
               << " mouseHook=" << (mouse_hook_ != nullptr ? 1 : 0)
               << " keyboardHook=" << (keyboard_hook_ != nullptr ? 1 : 0);
    EmitDiagnostic(diagnostic.str());
  }

  bool IsReleaseHotkey(USHORT virtual_key) const {
    if (release_hotkey_ != "ctrl+alt+esc" || virtual_key != VK_ESCAPE) {
      return false;
    }
    return (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 &&
           (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
  }

  ScreenArea CaptureArea() const {
    const auto display = MonitorDisplayForId(capture_display_id_);
    return display.has_value() ? display->area : VirtualScreenArea();
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

  POINT CursorPointForEntry(const std::string& json) const {
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
    const ScreenArea area =
        injection_display_id_.empty() ? VirtualScreenArea() : InjectionArea();
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
      }
      const auto buttons = JsonNumber(json, "buttons");
      if (buttons.has_value()) {
        SyncInjectedButtons(static_cast<int>(std::round(buttons.value())));
      }
      if (delta_x != 0 || delta_y != 0) {
        FlushPendingInjectedButtons();
        POINT target = {current.x + delta_x, current.y + delta_y};
        target = ClampToVirtualScreen(target);
        MoveCursorToPoint(target);
      }
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
                             double edge_unit = 0) {
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

    std::lock_guard<std::mutex> lock(channel_mutex_);
    channel_->InvokeMethod(
        "onRelease",
        std::make_unique<flutter::EncodableValue>(std::move(arguments)));
  }

  void EmitDiagnostic(const std::string& message) {
    if (capture_session_id_.empty()) {
      return;
    }
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(capture_session_id_);
    arguments[flutter::EncodableValue("message")] =
        flutter::EncodableValue(message);

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
  EdgeSegment capture_segment_;
  std::string injection_display_id_;
  std::string injection_edge_;
  EdgeSegment injection_segment_;
  std::string release_hotkey_ = "ctrl+alt+esc";
  bool capture_active_ = false;
  bool pending_active_start_ = false;
  int capture_buttons_ = 0;
  int keyboard_diagnostic_count_ = 0;
  int inactive_keyboard_diagnostic_count_ = 0;
  int injected_buttons_ = 0;
  int pending_injected_buttons_ = 0;
  std::vector<WORD> injected_keys_;
  std::optional<POINT> last_hook_mouse_point_;
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
