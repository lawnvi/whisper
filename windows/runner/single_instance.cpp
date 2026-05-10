#include "single_instance.h"

#include "win32_window.h"

namespace {

constexpr const wchar_t kSingleInstanceMutexName[] =
    L"Local\\com.vireen.whisper.single-instance";
constexpr const wchar_t kSingleInstanceWakeMessageName[] =
    L"com.vireen.whisper.show-main-window";

}  // namespace

SingleInstanceLock::SingleInstanceLock() {
  mutex_ = CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  if (!mutex_) {
    is_primary_ = true;
    return;
  }
  is_primary_ = GetLastError() != ERROR_ALREADY_EXISTS;
}

SingleInstanceLock::~SingleInstanceLock() {
  if (!mutex_) {
    return;
  }
  if (is_primary_) {
    ReleaseMutex(mutex_);
  }
  CloseHandle(mutex_);
}

bool SingleInstanceLock::IsPrimary() const {
  return is_primary_;
}

UINT GetSingleInstanceWakeMessage() {
  static const UINT message =
      RegisterWindowMessageW(kSingleInstanceWakeMessageName);
  return message;
}

bool NotifyExistingInstance() {
  HWND window = FindWindowW(Win32Window::GetWindowClassName(), nullptr);
  if (!window) {
    return false;
  }

  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id != 0) {
    AllowSetForegroundWindow(process_id);
  }

  PostMessageW(window, GetSingleInstanceWakeMessage(), 0, 0);
  return true;
}
