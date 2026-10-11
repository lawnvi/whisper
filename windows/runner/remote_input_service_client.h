#ifndef WHISPER_REMOTE_INPUT_SERVICE_CLIENT_H_
#define WHISPER_REMOTE_INPUT_SERVICE_CLIENT_H_

#include <windows.h>

#include <aclapi.h>
#include <shellapi.h>

#include <string>

#include "input_service_protocol.h"

// Talks to the optional LocalSystem input service, which reaches the lock
// screen's desktop on the runner's behalf. Every call fails quietly when the
// service is absent, so callers keep their existing blocked-input handling.
class RemoteInputServiceClient {
 public:
  enum class State { kNotInstalled, kStopped, kRunning, kOutdated };

  RemoteInputServiceClient() = default;
  RemoteInputServiceClient(const RemoteInputServiceClient&) = delete;
  RemoteInputServiceClient& operator=(const RemoteInputServiceClient&) = delete;
  ~RemoteInputServiceClient() { Disconnect(); }

  bool SendInput(const INPUT* inputs, UINT count) {
    if (count == 0 || count > whisper_input_service::kMaxInputs) {
      return false;
    }
    whisper_input_service::Request request = {};
    request.command = whisper_input_service::kCommandSendInput;
    request.count = count;
    for (UINT i = 0; i < count; ++i) {
      request.inputs[i] = inputs[i];
    }
    whisper_input_service::Response response = {};
    return Transact(&request, &response) &&
           response.status == whisper_input_service::kStatusOk;
  }

  bool CursorPos(POINT* point) {
    whisper_input_service::Request request = {};
    request.command = whisper_input_service::kCommandCursorPos;
    whisper_input_service::Response response = {};
    if (!Transact(&request, &response) ||
        response.status != whisper_input_service::kStatusOk) {
      return false;
    }
    *point = response.cursor;
    return true;
  }

  State QueryState() {
    State state = State::kNotInstalled;
    const SC_HANDLE manager =
        OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (manager == nullptr) {
      return state;
    }
    const SC_HANDLE service = OpenServiceW(
        manager, whisper_input_service::kServiceName, SERVICE_QUERY_STATUS);
    if (service != nullptr) {
      SERVICE_STATUS status = {};
      state = QueryServiceStatus(service, &status) &&
                      status.dwCurrentState == SERVICE_RUNNING
                  ? State::kRunning
                  : State::kStopped;
      CloseServiceHandle(service);
    }
    CloseServiceHandle(manager);
    if (state != State::kRunning) {
      Disconnect();
      return state;
    }
    whisper_input_service::Request hello = {};
    hello.command = whisper_input_service::kCommandHello;
    whisper_input_service::Response response = {};
    retry_tick_ = 0;
    if (Transact(&hello, &response) &&
        response.version != whisper_input_service::kVersion) {
      state = State::kOutdated;
    }
    return state;
  }

  // Runs this executable again behind a UAC prompt to install or remove the
  // service. Success only means the user accepted the prompt; the caller
  // polls QueryState for the outcome.
  DWORD RunElevated(const wchar_t* argument) {
    Disconnect();
    std::wstring path(32768, L'\0');
    const DWORD length = GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0 || length >= path.size()) {
      return ERROR_PATH_NOT_FOUND;
    }
    path.resize(length);

    SHELLEXECUTEINFOW info = {};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_NOASYNC;
    info.lpVerb = L"runas";
    info.lpFile = path.c_str();
    info.lpParameters = argument;
    info.nShow = SW_HIDE;
    return ShellExecuteExW(&info) ? ERROR_SUCCESS : GetLastError();
  }

  // Uninstalling from the app opts out of the installer's automatic install;
  // installing from the app opts back in.
  static void RememberOptOut(bool opted_out) {
    if (opted_out) {
      const DWORD value = 1;
      RegSetKeyValueW(HKEY_CURRENT_USER,
                      whisper_input_service::kOptOutRegistryKey,
                      whisper_input_service::kOptOutRegistryValue, REG_DWORD,
                      &value, sizeof(value));
    } else {
      RegDeleteKeyValueW(HKEY_CURRENT_USER,
                         whisper_input_service::kOptOutRegistryKey,
                         whisper_input_service::kOptOutRegistryValue);
    }
  }

 private:
  static constexpr ULONGLONG kRetryMs = 1000;

  bool Transact(whisper_input_service::Request* request,
                whisper_input_service::Response* response) {
    request->version = whisper_input_service::kVersion;
    // The agent is replaced whenever the console session changes, so one
    // reconnect covers a pipe that went stale since the last call.
    for (int attempt = 0; attempt < 2; ++attempt) {
      const bool reused = pipe_ != INVALID_HANDLE_VALUE;
      if (!Connect()) {
        return false;
      }
      DWORD read = 0;
      if (TransactNamedPipe(pipe_, request, sizeof(*request), response,
                            sizeof(*response), &read, nullptr) &&
          read == sizeof(*response)) {
        return true;
      }
      Disconnect();
      if (!reused) {
        return false;
      }
    }
    return false;
  }

  bool Connect() {
    if (pipe_ != INVALID_HANDLE_VALUE) {
      return true;
    }
    // Blocked input arrives once per event; do not probe that often.
    const ULONGLONG now = GetTickCount64();
    if (now < retry_tick_) {
      return false;
    }
    retry_tick_ = now + kRetryMs;
    DWORD session_id = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &session_id)) {
      return false;
    }
    const HANDLE pipe = CreateFileW(
        whisper_input_service::PipeName(session_id).c_str(),
        GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
        SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) {
      return false;
    }
    DWORD mode = PIPE_READMODE_MESSAGE;
    if (!OwnedByLocalSystem(pipe) ||
        !SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr)) {
      CloseHandle(pipe);
      return false;
    }
    pipe_ = pipe;
    retry_tick_ = 0;
    return true;
  }

  void Disconnect() {
    if (pipe_ != INVALID_HANDLE_VALUE) {
      CloseHandle(pipe_);
      pipe_ = INVALID_HANDLE_VALUE;
    }
  }

  // Any process may create a pipe under this name while the service is
  // absent, and would then receive the keystrokes meant for the lock screen.
  // Only the real agent's pipe is owned by LocalSystem.
  static bool OwnedByLocalSystem(HANDLE pipe) {
    PSID owner = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (GetSecurityInfo(pipe, SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION,
                        &owner, nullptr, nullptr, nullptr,
                        &descriptor) != ERROR_SUCCESS) {
      return false;
    }
    const bool local_system =
        owner != nullptr && IsWellKnownSid(owner, WinLocalSystemSid) != FALSE;
    LocalFree(descriptor);
    return local_system;
  }

  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  ULONGLONG retry_tick_ = 0;
};

#endif  // WHISPER_REMOTE_INPUT_SERVICE_CLIENT_H_
