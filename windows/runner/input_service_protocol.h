#ifndef WHISPER_INPUT_SERVICE_PROTOCOL_H_
#define WHISPER_INPUT_SERVICE_PROTOCOL_H_

#include <windows.h>

#include <string>

// Shared by the app and its lock screen input service. Both are whisper.exe:
// installing the service copies the executable into Program Files, where it
// runs as LocalSystem so its agent can join the lock screen's desktop.
namespace whisper_input_service {

// Bump whenever the service's behaviour changes; the app reports any other
// installed version as outdated.
constexpr DWORD kVersion = 2;
constexpr wchar_t kServiceName[] = L"WhisperInputService";
// What the copy under Program Files is called, so that it can be told apart
// from the app in a process list.
constexpr wchar_t kInstalledExecutableName[] = L"whisper_input_service.exe";
constexpr wchar_t kInstallArgument[] = L"--install-input-service";
constexpr wchar_t kUninstallArgument[] = L"--uninstall-input-service";
constexpr wchar_t kServiceArgument[] = L"--input-service";
constexpr wchar_t kAgentArgument[] = L"--input-agent";
// Elevated like installing, so that reaching UAC prompts takes the same
// administrator consent the service itself needed.
constexpr wchar_t kEnableElevatedArgument[] = L"--enable-elevated-input";
constexpr wchar_t kDisableElevatedArgument[] = L"--disable-elevated-input";
// The installer installs the service with the app and updates it on every
// upgrade. Removing it from the app's settings has to survive that, so the
// choice is recorded where the installer, running as the same user, reads it.
constexpr wchar_t kOptOutRegistryKey[] = L"Software\\Whisper";
constexpr wchar_t kOptOutRegistryValue[] = L"InputServiceOptOut";
// Whether the agent may also type while the session is unlocked, which is
// where UAC prompts appear. Off unless an administrator turns it on, and
// removed with the service.
constexpr wchar_t kPolicyRegistryKey[] = L"SOFTWARE\\Whisper\\InputService";
constexpr wchar_t kAllowElevatedValue[] = L"AllowElevated";
constexpr wchar_t kPipePrefix[] = L"\\\\.\\pipe\\whisper-input-service-";
constexpr DWORD kMaxInputs = 8;

enum Command : DWORD {
  kCommandHello = 1,
  kCommandSendInput = 2,
  kCommandCursorPos = 3,
};

enum Status : DWORD {
  kStatusOk = 0,
  // The input desktop is not one the agent is allowed to type on.
  kStatusRefused = 1,
  kStatusFailed = 2,
  kStatusBadRequest = 3,
};

struct Request {
  DWORD version;
  DWORD command;
  DWORD count;
  INPUT inputs[kMaxInputs];
};

struct Response {
  DWORD version;
  DWORD status;
  DWORD sent;
  POINT cursor;
};

// One agent serves the console session, so the pipe is named after it.
inline std::wstring PipeName(DWORD session_id) {
  return std::wstring(kPipePrefix) + std::to_wstring(session_id);
}

// Read from HKLM by the agent, which acts on it, and by the app, which shows
// it. Only an administrator can write there, and a request cannot carry it,
// so a caller has no way to widen what the agent injects.
inline bool ElevatedInputAllowed() {
  DWORD value = 0;
  DWORD bytes = sizeof(value);
  return RegGetValueW(HKEY_LOCAL_MACHINE, kPolicyRegistryKey,
                      kAllowElevatedValue, RRF_RT_REG_DWORD, nullptr, &value,
                      &bytes) == ERROR_SUCCESS &&
         value != 0;
}

}  // namespace whisper_input_service

#endif  // WHISPER_INPUT_SERVICE_PROTOCOL_H_
