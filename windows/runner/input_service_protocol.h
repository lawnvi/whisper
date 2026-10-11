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
constexpr DWORD kVersion = 1;
constexpr wchar_t kServiceName[] = L"WhisperInputService";
// What the copy under Program Files is called, so that it can be told apart
// from the app in a process list.
constexpr wchar_t kInstalledExecutableName[] = L"whisper_input_service.exe";
constexpr wchar_t kInstallArgument[] = L"--install-input-service";
constexpr wchar_t kUninstallArgument[] = L"--uninstall-input-service";
constexpr wchar_t kServiceArgument[] = L"--input-service";
constexpr wchar_t kAgentArgument[] = L"--input-agent";
// The installer installs the service with the app and updates it on every
// upgrade. Removing it from the app's settings has to survive that, so the
// choice is recorded where the installer, running as the same user, reads it.
constexpr wchar_t kOptOutRegistryKey[] = L"Software\\Whisper";
constexpr wchar_t kOptOutRegistryValue[] = L"InputServiceOptOut";
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

}  // namespace whisper_input_service

#endif  // WHISPER_INPUT_SERVICE_PROTOCOL_H_
