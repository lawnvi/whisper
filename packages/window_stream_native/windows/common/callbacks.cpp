// Callback registry: the three Dart callbacks and helpers to invoke them.

#include "wsn_common.h"

#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>

namespace wsn {
namespace {

// Leaked on purpose (see util.cpp): no destructors at process exit while
// the callback and decode threads may still run.
std::mutex& g_callbacks_mutex = *new std::mutex();
wsn_input_callback g_input_callback = nullptr;
wsn_window_callback g_window_callback = nullptr;
wsn_capture_callback g_capture_callback = nullptr;
std::atomic<int64_t> g_next_request{1};

// The serial callback thread behind PostCallback.
std::mutex& g_post_mutex = *new std::mutex();
std::condition_variable& g_post_cv = *new std::condition_variable();
std::deque<std::function<void()>>& g_post_queue = *new std::deque<std::function<void()>>();
bool g_post_started = false;

void PostLoop() {
  for (;;) {
    std::function<void()> work;
    {
      std::unique_lock<std::mutex> lock(g_post_mutex);
      g_post_cv.wait(lock, [] { return !g_post_queue.empty(); });
      work = std::move(g_post_queue.front());
      g_post_queue.pop_front();
    }
    work();
  }
}

}  // namespace

void SetInputCallback(wsn_input_callback callback) {
  std::lock_guard<std::mutex> lock(g_callbacks_mutex);
  g_input_callback = callback;
}

void SetWindowCallback(wsn_window_callback callback) {
  std::lock_guard<std::mutex> lock(g_callbacks_mutex);
  g_window_callback = callback;
}

void SetCaptureCallback(wsn_capture_callback callback) {
  std::lock_guard<std::mutex> lock(g_callbacks_mutex);
  g_capture_callback = callback;
}

void ClearSurfaceCallbacks() {
  std::lock_guard<std::mutex> lock(g_callbacks_mutex);
  g_input_callback = nullptr;
  g_window_callback = nullptr;
}

bool HasCaptureCallback() {
  std::lock_guard<std::mutex> lock(g_callbacks_mutex);
  return g_capture_callback != nullptr;
}

// The callbacks are invoked with g_callbacks_mutex held: Dart clears a
// callback (Set...(nullptr)) and then closes its NativeCallable right away,
// so no call may still be running once the clear has returned (the setter
// waits on the mutex for an in-flight call). Every callback is a
// NativeCallable.listener: a call only posts a message to the isolate and
// never blocks or calls back into this library, so holding the lock is cheap
// and cannot deadlock.
void EmitWindow(int64_t surface, int32_t kind, double a, double b, double c, double d) {
  std::lock_guard<std::mutex> lock(g_callbacks_mutex);
  if (g_window_callback != nullptr) {
    g_window_callback(surface, kind, a, b, c, d);
  }
}

void EmitInput(int64_t surface, int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx,
               double dy, int32_t phase, const std::string* text) {
  char* copy = nullptr;
  if (text != nullptr) {
    copy = static_cast<char*>(std::malloc(text->size() + 1));
    if (copy != nullptr) {
      std::memcpy(copy, text->c_str(), text->size() + 1);
    }
  }
  std::lock_guard<std::mutex> lock(g_callbacks_mutex);
  if (g_input_callback == nullptr) {
    std::free(copy);
    return;
  }
  g_input_callback(surface, kind, code, modifiers, x, y, dx, dy, phase, copy);
}

void EmitCapture(int64_t id, int32_t kind, const void* data, int32_t length, int64_t pts_us, int32_t flags,
                 int32_t width, int32_t height) {
  uint8_t* copy = nullptr;
  if (data != nullptr && length > 0) {
    copy = static_cast<uint8_t*>(std::malloc(static_cast<size_t>(length)));
    if (copy == nullptr) {
      return;
    }
    std::memcpy(copy, data, static_cast<size_t>(length));
  }
  EmitCaptureOwned(id, kind, copy, copy != nullptr ? length : 0, pts_us, flags, width, height);
}

void EmitCaptureOwned(int64_t id, int32_t kind, uint8_t* data, int32_t length, int64_t pts_us, int32_t flags,
                      int32_t width, int32_t height) {
  std::lock_guard<std::mutex> lock(g_callbacks_mutex);
  if (g_capture_callback == nullptr) {
    std::free(data);
    return;
  }
  g_capture_callback(id, kind, data, length, pts_us, flags, width, height);
}

void PostCallback(std::function<void()> work) {
  if (!work) {
    return;
  }
  std::lock_guard<std::mutex> lock(g_post_mutex);
  if (!g_post_started) {
    g_post_started = true;
    std::thread(PostLoop).detach();
  }
  g_post_queue.push_back(std::move(work));
  g_post_cv.notify_one();
}

int64_t NextRequestId() { return g_next_request++; }

}  // namespace wsn
