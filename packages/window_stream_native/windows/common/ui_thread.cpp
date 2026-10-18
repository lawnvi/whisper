// The UI thread: one STA thread with a message-only window. Every window the
// DLL creates (streamed windows, capture helpers) lives on it, and work is
// queued to it as std::function through RunOnUiThread.

#include "wsn_common.h"

#include <mfapi.h>
#include <objbase.h>

#include <condition_variable>
#include <mutex>
#include <thread>

namespace wsn {
namespace {

constexpr UINT kMsgRun = WM_APP + 0x200;
constexpr wchar_t kMessageClass[] = L"WhisperWindowStreamMessages";

std::once_flag g_ui_once;
HWND g_message_window = nullptr;
DWORD g_ui_thread_id = 0;

LRESULT CALLBACK MessageWndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kMsgRun) {
    auto* work = reinterpret_cast<std::function<void()>*>(lparam);
    if (work != nullptr) {
      (*work)();
      delete work;
    }
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

}  // namespace

void EnsureUiThread() {
  std::call_once(g_ui_once, [] {
    std::mutex ready_mutex;
    std::condition_variable ready_cv;
    bool ready = false;
    std::thread([&] {
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
      MFStartup(MF_VERSION, MFSTARTUP_LITE);
      WNDCLASSW message_class = {};
      message_class.lpfnWndProc = MessageWndProc;
      message_class.hInstance = GetModuleHandleW(nullptr);
      message_class.lpszClassName = kMessageClass;
      RegisterClassW(&message_class);
      HWND window = CreateWindowExW(0, kMessageClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                    GetModuleHandleW(nullptr), nullptr);
      {
        std::lock_guard<std::mutex> lock(ready_mutex);
        g_ui_thread_id = GetCurrentThreadId();
        g_message_window = window;
        ready = true;
      }
      ready_cv.notify_one();
      Log("ui thread up (message window %p)", static_cast<void*>(window));
      MSG message;
      while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
    }).detach();
    std::unique_lock<std::mutex> lock(ready_mutex);
    ready_cv.wait(lock, [&] { return ready; });
  });
}

bool IsUiThread() { return g_ui_thread_id != 0 && GetCurrentThreadId() == g_ui_thread_id; }

DWORD UiThreadId() { return g_ui_thread_id; }

HWND UiMessageWindow() { return g_message_window; }

bool RunOnUiThread(std::function<void()> work) {
  EnsureUiThread();
  if (g_message_window == nullptr || !work) {
    return false;
  }
  auto* boxed = new std::function<void()>(std::move(work));
  if (!PostMessageW(g_message_window, kMsgRun, 0, reinterpret_cast<LPARAM>(boxed))) {
    delete boxed;
    return false;
  }
  return true;
}

void RunOnUiThreadAndWait(std::function<void()> work) {
  if (!work) {
    return;
  }
  EnsureUiThread();
  if (IsUiThread()) {
    work();
    return;
  }
  std::mutex done_mutex;
  std::condition_variable done_cv;
  bool done = false;
  bool posted = RunOnUiThread([&] {
    work();
    {
      std::lock_guard<std::mutex> lock(done_mutex);
      done = true;
    }
    done_cv.notify_one();
  });
  if (!posted) {
    return;
  }
  std::unique_lock<std::mutex> lock(done_mutex);
  done_cv.wait(lock, [&] { return done; });
}

}  // namespace wsn
