#include "single_instance.h"

#include "win32_window.h"

namespace {

constexpr const wchar_t kSingleInstanceMutexName[] =
    L"Local\\com.vireen.whisper.single-instance";
constexpr const wchar_t kSingleInstanceWakeMessageName[] =
    L"com.vireen.whisper.show-main-window";
constexpr ULONG_PTR kQuickSendCopyDataId = 0x57515331;
constexpr size_t kMaximumQuickSendBytes = 1024 * 1024;
constexpr size_t kMaximumQuickSendArguments = 128;

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

bool NotifyExistingInstance(const std::vector<std::string>& arguments) {
  const ULONGLONG deadline = GetTickCount64() + 5000;
  HWND window = nullptr;
  do {
    window = FindWindowW(Win32Window::GetWindowClassName(), nullptr);
    if (window != nullptr) {
      break;
    }
    Sleep(50);
  } while (GetTickCount64() < deadline);
  if (!window) {
    return false;
  }

  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id != 0) {
    AllowSetForegroundWindow(process_id);
  }

  if (!arguments.empty()) {
    std::vector<char> payload;
    for (const auto& argument : arguments) {
      if (argument.size() + payload.size() + 1 > kMaximumQuickSendBytes) {
        return false;
      }
      payload.insert(payload.end(), argument.begin(), argument.end());
      payload.push_back('\0');
    }
    COPYDATASTRUCT copy_data{};
    copy_data.dwData = kQuickSendCopyDataId;
    copy_data.cbData = static_cast<DWORD>(payload.size());
    copy_data.lpData = payload.data();
    DWORD_PTR delivery_result = 0;
    if (SendMessageTimeoutW(window, WM_COPYDATA, 0,
                            reinterpret_cast<LPARAM>(&copy_data),
                            SMTO_ABORTIFHUNG | SMTO_BLOCK, 2000,
                            &delivery_result) == 0 ||
        delivery_result != TRUE) {
      return false;
    }
  }

  PostMessageW(window, GetSingleInstanceWakeMessage(), 0, 0);
  return true;
}

bool ReadQuickSendCopyData(const COPYDATASTRUCT* copy_data,
                           std::vector<std::string>* arguments) {
  if (copy_data == nullptr || arguments == nullptr ||
      copy_data->dwData != kQuickSendCopyDataId || copy_data->lpData == nullptr ||
      copy_data->cbData == 0 || copy_data->cbData > kMaximumQuickSendBytes) {
    return false;
  }
  const auto* bytes = static_cast<const char*>(copy_data->lpData);
  if (bytes[copy_data->cbData - 1] != '\0') {
    return false;
  }
  arguments->clear();
  size_t start = 0;
  for (size_t index = 0; index < copy_data->cbData; ++index) {
    if (bytes[index] != '\0') {
      continue;
    }
    if (index > start) {
      arguments->emplace_back(bytes + start, index - start);
      if (arguments->size() > kMaximumQuickSendArguments) {
        arguments->clear();
        return false;
      }
    }
    start = index + 1;
  }
  return !arguments->empty();
}
