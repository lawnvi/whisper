#include "common/callbacks.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace wsn {

namespace {

std::mutex g_mutex;
wsn_input_callback g_input = nullptr;
wsn_window_callback g_window = nullptr;
wsn_capture_callback g_capture = nullptr;
std::atomic<int64_t> g_next_request{1};

}  // namespace

void SetInputCallback(wsn_input_callback callback) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_input = callback;
}

void SetWindowCallback(wsn_window_callback callback) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_window = callback;
}

void SetCaptureCallback(wsn_capture_callback callback) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_capture = callback;
}

void ClearSurfaceCallbacks() {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_input = nullptr;
  g_window = nullptr;
}

bool HasCaptureCallback() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_capture != nullptr;
}

// Callbacks are invoked with the lock held: Dart clears a callback (Set…
// (nullptr)) and then closes its NativeCallable, so a call must never run
// after the clear has returned. A listener call only posts a message to the
// Dart isolate; it never blocks or calls back in.
void EmitWindow(int64_t surface, int32_t kind, double a, double b, double c, double d) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_window != nullptr) g_window(surface, kind, a, b, c, d);
}

void EmitInput(int64_t surface, int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx,
               double dy, int32_t phase, const char* text) {
  char* copy = nullptr;
  if (text != nullptr) {
    size_t length = std::strlen(text);
    copy = static_cast<char*>(std::malloc(length + 1));
    if (copy != nullptr) std::memcpy(copy, text, length + 1);
  }
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_input == nullptr) {
    std::free(copy);
    return;
  }
  g_input(surface, kind, code, modifiers, x, y, dx, dy, phase, copy);
}

void EmitCaptureOwned(int64_t id, int32_t kind, uint8_t* data, int32_t length, int64_t pts_us, int32_t flags,
                      int32_t width, int32_t height) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_capture == nullptr) {
    std::free(data);
    return;
  }
  g_capture(id, kind, data, data == nullptr ? 0 : length, pts_us, flags, width, height);
}

void EmitCapture(int64_t id, int32_t kind, const uint8_t* data, int32_t length, int64_t pts_us, int32_t flags,
                 int32_t width, int32_t height) {
  uint8_t* copy = nullptr;
  if (data != nullptr && length > 0) {
    copy = static_cast<uint8_t*>(std::malloc(static_cast<size_t>(length)));
    if (copy == nullptr) return;
    std::memcpy(copy, data, static_cast<size_t>(length));
  }
  EmitCaptureOwned(id, kind, copy, copy == nullptr ? 0 : length, pts_us, flags, width, height);
}

void EmitCaptureNote(int64_t id, const std::string& text) {
  EmitCapture(id, WSN_CAPTURE_NOTE, reinterpret_cast<const uint8_t*>(text.data()), static_cast<int32_t>(text.size()));
}

int64_t NewRequestId() { return g_next_request++; }

}  // namespace wsn
