#ifndef WHISPER_REMOTE_INPUT_WHEEL_CAPTURE_H_
#define WHISPER_REMOTE_INPUT_WHEEL_CAPTURE_H_

#include <windows.h>
#include <atomic>
#include <optional>
#include <sstream>
#include <string>

constexpr UINT kRemoteInputWheelMessage = WM_APP + 0x578;

// The wheel while the pointer is on another device.
//
// A precision touchpad's two-finger scroll is not a wheel at first: Windows
// hands it to the window under the pointer, and only turns it into wheel
// input when that window does not take touchpad contacts itself (browsers,
// Explorer and Flutter windows do). Raw input and the hooks hear nothing
// otherwise. So a small window of this process lies under the parked pointer
// meanwhile, and the wheel is read in the low-level mouse hook, which hears
// touchpad and mouse wheels alike.
class RemoteInputWheelCapture {
 public:
  RemoteInputWheelCapture() = default;
  RemoteInputWheelCapture(const RemoteInputWheelCapture&) = delete;
  RemoteInputWheelCapture& operator=(const RemoteInputWheelCapture&) = delete;
  ~RemoteInputWheelCapture() {
    if (sink_) DestroyWindow(sink_);
  }

  // Window thread, when the pointer has left for the other device. The hook
  // holds the pointer where it is from here on.
  void Begin() {
    pending_x_ = 0;
    pending_y_ = 0;
    POINT point{};
    if (!GetCursorPos(&point) || (!sink_ && !Create())) return;
    SetWindowPos(sink_, HWND_TOPMOST, point.x - kReach, point.y - kReach,
                 kReach * 2, kReach * 2, SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }

  // Window thread, when the pointer is back or capture stops.
  void End() {
    if (sink_) ShowWindow(sink_, SW_HIDE);
  }

  // Hook thread. Adds a wheel message to what has turned and tells `owner`;
  // anything else is left alone.
  void Take(WPARAM message, LPARAM lparam, HWND owner) {
    if (message != WM_MOUSEWHEEL && message != WM_MOUSEHWHEEL) return;
    const auto* mouse = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
    const LONG delta = static_cast<SHORT>(HIWORD(mouse->mouseData));
    (message == WM_MOUSEWHEEL ? pending_y_ : pending_x_) += delta;
    // A touchpad sends many small turns: one message carries all of them.
    if (!posted_.exchange(true) &&
        !PostMessage(owner, kRemoteInputWheelMessage, 0, 0)) {
      posted_ = false;
    }
  }

  // Window thread, on kRemoteInputWheelMessage: what has turned since the
  // last call, as the mouseWheel payload. One notch of a wheel is 120; a
  // touchpad sends far less at a time.
  std::optional<std::string> Drain() {
    posted_ = false;
    const LONG x = pending_x_.exchange(0);
    const LONG y = pending_y_.exchange(0);
    if (x == 0 && y == 0) return std::nullopt;
    std::ostringstream json;
    json << "{\"deltaX\":" << x << ",\"deltaY\":" << y << "}";
    return json.str();
  }

 private:
  // Far enough around the pointer that a pointer nudged by another program
  // is still over it.
  static constexpr int kReach = 24;

  bool Create() {
    constexpr wchar_t name[] = L"WhisperRemoteInputWheel";
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = DefWindowProcW;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = name;
    RegisterClassW(&window_class);
    sink_ = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_NOACTIVATE,
        name, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
        GetModuleHandle(nullptr), nullptr);
    if (!sink_) return false;
    // Nearly transparent: a fully transparent window is not under the
    // pointer as far as Windows is concerned.
    SetLayeredWindowAttributes(sink_, 0, 1, LWA_ALPHA);
    return true;
  }

  HWND sink_ = nullptr;
  std::atomic<LONG> pending_x_{0};
  std::atomic<LONG> pending_y_{0};
  std::atomic<bool> posted_{false};
};

#endif  // WHISPER_REMOTE_INPUT_WHEEL_CAPTURE_H_
