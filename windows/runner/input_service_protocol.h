#ifndef WHISPER_INPUT_SERVICE_PROTOCOL_H_
#define WHISPER_INPUT_SERVICE_PROTOCOL_H_

#include <windows.h>

#include <shlobj.h>

#include <string>

// Shared by the app and its lock screen input service. Both are whisper.exe:
// installing the service copies the executable into Program Files, where it
// runs as LocalSystem so its agent can join the lock screen's desktop.
namespace whisper_input_service {

// Bump whenever the service's behaviour changes. The agent still serves apps
// as old as kOldestClientVersion: what they ask for has not changed.
constexpr DWORD kVersion = 5;
constexpr DWORD kOldestClientVersion = 2;
// The version that added kCommandAllowForeground, which requests of that
// command carry so that an agent from then on still serves them. Version 4
// only wakes the screen saver with pointer motion.
constexpr DWORD kAllowForegroundVersion = 3;
// The version that updates itself (kCommandUpdate). The app reports an older
// service as outdated: only reinstalling it, behind a UAC prompt, helps.
constexpr DWORD kUpdateVersion = 5;
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
// Started by the agent, as LocalSystem, once it has put an update in place.
constexpr wchar_t kRestartArgument[] = L"--restart-input-service";
// Shipped next to whisper.exe by release builds: what the service may update
// itself to, signed with the update key (see input_service_update.cpp).
constexpr wchar_t kManifestName[] = L"whisper_input_service.manifest";
constexpr wchar_t kManifestSignatureName[] =
    L"whisper_input_service.manifest.sig";
// The installer installs the service with the app. Removing it from the app's
// settings has to survive a reinstall, so the choice is recorded where the
// installer, running as the same user, reads it.
constexpr wchar_t kOptOutRegistryKey[] = L"Software\\Whisper";
constexpr wchar_t kOptOutRegistryValue[] = L"InputServiceOptOut";
// Whether the agent may also type while the session is unlocked, which is
// where UAC prompts appear. Off unless an administrator turns it on, and
// removed with the service.
constexpr wchar_t kPolicyRegistryKey[] = L"SOFTWARE\\Whisper\\InputService";
constexpr wchar_t kAllowElevatedValue[] = L"AllowElevated";
// Set by installs of a service that updates itself, so that the installer
// knows it need not ask for administrator approval on an upgrade.
constexpr wchar_t kSelfUpdatingValue[] = L"SelfUpdating";
constexpr wchar_t kPipePrefix[] = L"\\\\.\\pipe\\whisper-input-service-";
constexpr DWORD kMaxInputs = 8;

enum Command : DWORD {
  kCommandHello = 1,
  kCommandSendInput = 2,
  kCommandCursorPos = 3,
  // Version 3. Lets the client take the front from an administrator's
  // window, which it may not on its own; `count` carries one of the
  // client's own windows to bring there (window handles fit in 32 bits).
  kCommandAllowForeground = 4,
  // Version 5. Asks the service to update itself from the files beside the
  // client's executable. It takes them only when they are signed and newer.
  kCommandUpdate = 5,
};

enum Status : DWORD {
  kStatusOk = 0,
  // The input desktop is not one the agent is allowed to type on.
  kStatusRefused = 1,
  kStatusFailed = 2,
  kStatusBadRequest = 3,
  // kCommandUpdate: the service is already as new as what was offered.
  kStatusCurrent = 4,
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

// Where the service runs from: Program Files, so that only administrators can
// replace the binary LocalSystem runs; the app's own folder is writable by
// the user. Resolved from the machine's known folders rather than the
// environment, which an unelevated caller controls.
inline std::wstring InstallDirectory() {
  PWSTR program_files = nullptr;
  std::wstring directory;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_ProgramFiles, 0, nullptr,
                                     &program_files))) {
    directory = std::wstring(program_files) + L"\\Whisper Input Service";
  }
  CoTaskMemFree(program_files);
  return directory;
}

inline std::wstring InstalledExecutablePath() {
  const std::wstring directory = InstallDirectory();
  return directory.empty() ? directory
                           : directory + L"\\" + kInstalledExecutableName;
}

// The app links the C runtime dynamically and ships these next to itself.
// The service takes them along so that it does not depend on a system-wide
// runtime, which is not guaranteed to be installed.
constexpr const wchar_t* kRuntimeLibraries[] = {
    L"msvcp140.dll",
    L"vcruntime140.dll",
    L"vcruntime140_1.dll",
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
