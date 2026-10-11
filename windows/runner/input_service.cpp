// Delivers Whisper's shared keyboard and mouse input to the Windows lock
// screen. whisper.exe takes on these roles when started with:
//
//   --install-input-service / --uninstall-input-service
//                            elevated, started by the app or the uninstaller
//   --input-service          LocalSystem service that supervises the agent
//   --input-agent <pid>      LocalSystem process inside the console session
//
// The lock screen lives on the Winlogon desktop, which only LocalSystem may
// join. The app stays an ordinary user process and asks the agent, over a
// named pipe, to inject there on its behalf.

#include "input_service.h"

#include <windows.h>

#include <sddl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wtsapi32.h>

#include <cstdlib>
#include <cwchar>
#include <string>

#include "input_service_protocol.h"

namespace {

using whisper_input_service::Request;
using whisper_input_service::Response;

constexpr wchar_t kServiceDisplayName[] = L"Whisper Input Service";
constexpr wchar_t kServiceDescription[] =
    L"Delivers Whisper's shared keyboard and mouse input to the lock screen.";
// Installed under Program Files so that only administrators can replace the
// binary LocalSystem runs; the app's own folder is writable by the user.
constexpr wchar_t kInstallFolder[] = L"Whisper Input Service";
// The app links the C runtime dynamically and ships these next to itself.
// Copying them along keeps the service from depending on a system-wide
// runtime, which is not guaranteed to be installed.
constexpr const wchar_t* kRuntimeLibraries[] = {
    L"msvcp140.dll",
    L"vcruntime140.dll",
    L"vcruntime140_1.dll",
};
constexpr wchar_t kLockDesktop[] = L"Winlogon";
constexpr wchar_t kScreenSaverDesktop[] = L"Screen-saver";
constexpr DWORD kSupervisorIntervalMs = 2000;
constexpr DWORD kServiceStateTimeoutMs = 15000;
constexpr DWORD kPipeRetryMs = 2000;
constexpr DWORD kLockGraceStepMs = 25;
constexpr int kLockGraceSteps = 10;
constexpr ULONGLONG kLockGraceCooldownMs = 1000;

std::wstring ExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

// ---------------------------------------------------------------------------
// Agent
// ---------------------------------------------------------------------------

bool SessionIsLocked(DWORD session_id) {
  WTSINFOEXW* info = nullptr;
  DWORD bytes = 0;
  if (!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session_id,
                                   WTSSessionInfoEx,
                                   reinterpret_cast<LPWSTR*>(&info), &bytes) ||
      info == nullptr) {
    return false;
  }
  const bool locked =
      bytes >= sizeof(WTSINFOEXW) && info->Level == 1 &&
      info->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK;
  WTSFreeMemory(info);
  return locked;
}

bool IsDesktop(const std::wstring& name, const wchar_t* expected) {
  return _wcsicmp(name.c_str(), expected) == 0;
}

class InputDesktop {
 public:
  InputDesktop() = default;
  InputDesktop(const InputDesktop&) = delete;
  InputDesktop& operator=(const InputDesktop&) = delete;
  ~InputDesktop() {
    if (desktop_ != nullptr) CloseDesktop(desktop_);
  }

  // Joins whichever desktop currently receives input and reports its name.
  bool Attach(std::wstring* name) {
    HDESK desktop = OpenInputDesktop(0, FALSE, GENERIC_ALL);
    if (desktop == nullptr) {
      return false;
    }
    wchar_t buffer[64] = {};
    DWORD needed = 0;
    if (!GetUserObjectInformationW(desktop, UOI_NAME, buffer, sizeof(buffer),
                                   &needed) ||
        !SetThreadDesktop(desktop)) {
      CloseDesktop(desktop);
      return false;
    }
    if (desktop_ != nullptr) CloseDesktop(desktop_);
    desktop_ = desktop;
    *name = buffer;
    return true;
  }

 private:
  HDESK desktop_ = nullptr;
};

class Agent {
 public:
  explicit Agent(DWORD session_id) : session_id_(session_id) {}

  void Serve(HANDLE pipe) {
    ULONG client_session = 0;
    if (!GetNamedPipeClientSessionId(pipe, &client_session) ||
        client_session != session_id_) {
      return;
    }
    for (;;) {
      Request request = {};
      DWORD read = 0;
      if (!ReadFile(pipe, &request, sizeof(request), &read, nullptr) ||
          read != sizeof(request)) {
        return;
      }
      Response response = {};
      response.version = whisper_input_service::kVersion;
      response.status = Handle(request, &response);
      DWORD written = 0;
      if (!WriteFile(pipe, &response, sizeof(response), &written, nullptr)) {
        return;
      }
    }
  }

 private:
  DWORD Handle(const Request& request, Response* response) {
    if (request.command == whisper_input_service::kCommandHello) {
      return whisper_input_service::kStatusOk;
    }
    if (request.version != whisper_input_service::kVersion) {
      return whisper_input_service::kStatusBadRequest;
    }
    std::wstring desktop;
    if (!desktop_.Attach(&desktop)) {
      return whisper_input_service::kStatusFailed;
    }
    if (!MayInject(desktop)) {
      return whisper_input_service::kStatusRefused;
    }
    if (request.command == whisper_input_service::kCommandCursorPos) {
      return GetCursorPos(&response->cursor)
                 ? whisper_input_service::kStatusOk
                 : whisper_input_service::kStatusFailed;
    }
    if (request.command != whisper_input_service::kCommandSendInput ||
        request.count == 0 ||
        request.count > whisper_input_service::kMaxInputs) {
      return whisper_input_service::kStatusBadRequest;
    }
    INPUT inputs[whisper_input_service::kMaxInputs] = {};
    for (DWORD i = 0; i < request.count; ++i) {
      if (!CopyInput(request.inputs[i], &inputs[i])) {
        return whisper_input_service::kStatusBadRequest;
      }
    }
    response->sent = SendInput(request.count, inputs, sizeof(INPUT));
    return response->sent == request.count
               ? whisper_input_service::kStatusOk
               : whisper_input_service::kStatusFailed;
  }

  // The agent holds LocalSystem rights, so it only types where the runner
  // cannot and where nothing can be elevated: the lock screen of a locked
  // session and the screen saver. UAC consent and Ctrl+Alt+Del share the
  // Winlogon desktop but appear while the session is unlocked, and the user's
  // own desktop is the runner's job, so both stay out of reach.
  bool MayInject(const std::wstring& desktop) {
    if (IsDesktop(desktop, kScreenSaverDesktop)) {
      return true;
    }
    if (!IsDesktop(desktop, kLockDesktop)) {
      return false;
    }
    bool locked = SessionIsLocked(session_id_);
    const ULONGLONG now = GetTickCount64();
    if (!locked && now - last_refusal_tick_ > kLockGraceCooldownMs) {
      // Winlogon can take the input desktop a moment before the session
      // reports itself locked.
      for (int step = 0; step < kLockGraceSteps && !locked; ++step) {
        Sleep(kLockGraceStepMs);
        locked = SessionIsLocked(session_id_);
      }
    }
    if (!locked) {
      last_refusal_tick_ = GetTickCount64();
    }
    return locked;
  }

  // Only plain keyboard and mouse events are forwarded, without the caller's
  // timestamps or extra info.
  static bool CopyInput(const INPUT& source, INPUT* target) {
    target->type = source.type;
    if (source.type == INPUT_MOUSE) {
      target->mi.dx = source.mi.dx;
      target->mi.dy = source.mi.dy;
      target->mi.mouseData = source.mi.mouseData;
      target->mi.dwFlags = source.mi.dwFlags;
      return true;
    }
    if (source.type == INPUT_KEYBOARD) {
      target->ki.wVk = source.ki.wVk;
      target->ki.wScan = source.ki.wScan;
      target->ki.dwFlags = source.ki.dwFlags;
      return true;
    }
    return false;
  }

  DWORD session_id_;
  InputDesktop desktop_;
  ULONGLONG last_refusal_tick_ = 0;
};

std::wstring SessionUserSid(DWORD session_id) {
  HANDLE token = nullptr;
  if (!WTSQueryUserToken(session_id, &token)) {
    return std::wstring();
  }
  alignas(TOKEN_USER) BYTE buffer[sizeof(TOKEN_USER) + SECURITY_MAX_SID_SIZE] =
      {};
  DWORD length = 0;
  std::wstring sid;
  if (GetTokenInformation(token, TokenUser, buffer, sizeof(buffer), &length)) {
    LPWSTR text = nullptr;
    if (ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer)->User.Sid,
                               &text)) {
      sid = text;
      LocalFree(text);
    }
  }
  CloseHandle(token);
  return sid;
}

// LocalSystem owns the pipe, which is how the runner tells it from a pipe
// someone else created under the same name, and only the user signed in to
// this session may open it.
HANDLE CreateSessionPipe(DWORD session_id) {
  const std::wstring user_sid = SessionUserSid(session_id);
  if (user_sid.empty()) {
    return INVALID_HANDLE_VALUE;
  }
  const std::wstring sddl =
      L"O:SYG:SYD:P(A;;GA;;;SY)(A;;GRGW;;;" + user_sid + L")";
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) {
    return INVALID_HANDLE_VALUE;
  }
  SECURITY_ATTRIBUTES attributes = {};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = descriptor;
  const HANDLE pipe = CreateNamedPipeW(
      whisper_input_service::PipeName(session_id).c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      1, sizeof(Response), sizeof(Request), 0, &attributes);
  LocalFree(descriptor);
  return pipe;
}

DWORD WINAPI ExitWithService(LPVOID service_process) {
  WaitForSingleObject(static_cast<HANDLE>(service_process), INFINITE);
  TerminateProcess(GetCurrentProcess(), 0);
  return 0;
}

int RunAgent(DWORD service_pid) {
  DWORD session_id = 0;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session_id)) {
    return 1;
  }
  // The agent must not outlive the service that is accountable for it.
  const HANDLE service_process = OpenProcess(SYNCHRONIZE, FALSE, service_pid);
  if (service_process == nullptr) {
    return 1;
  }
  const HANDLE watcher =
      CreateThread(nullptr, 0, ExitWithService, service_process, 0, nullptr);
  if (watcher == nullptr) {
    return 1;
  }
  CloseHandle(watcher);

  // Nobody is signed in yet at the sign-in screen, so there is no user to
  // grant the pipe to until logon.
  HANDLE pipe = CreateSessionPipe(session_id);
  while (pipe == INVALID_HANDLE_VALUE) {
    Sleep(kPipeRetryMs);
    pipe = CreateSessionPipe(session_id);
  }
  Agent agent(session_id);
  for (;;) {
    if (ConnectNamedPipe(pipe, nullptr) ||
        GetLastError() == ERROR_PIPE_CONNECTED) {
      agent.Serve(pipe);
    } else {
      Sleep(100);
    }
    DisconnectNamedPipe(pipe);
  }
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

SERVICE_STATUS_HANDLE g_status_handle = nullptr;
HANDLE g_stop_event = nullptr;
HANDLE g_wake_event = nullptr;

void ReportStatus(DWORD state) {
  SERVICE_STATUS status = {};
  status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  status.dwCurrentState = state;
  if (state == SERVICE_RUNNING) {
    status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN |
                                SERVICE_ACCEPT_SESSIONCHANGE;
  } else if (state != SERVICE_STOPPED) {
    status.dwWaitHint = 5000;
  }
  SetServiceStatus(g_status_handle, &status);
}

DWORD WINAPI ServiceControl(DWORD control, DWORD, LPVOID, LPVOID) {
  switch (control) {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
      ReportStatus(SERVICE_STOP_PENDING);
      SetEvent(g_stop_event);
      return NO_ERROR;
    case SERVICE_CONTROL_SESSIONCHANGE:
      // Whoever is at the console may have changed; re-check right away.
      SetEvent(g_wake_event);
      return NO_ERROR;
    case SERVICE_CONTROL_INTERROGATE:
      return NO_ERROR;
    default:
      return ERROR_CALL_NOT_IMPLEMENTED;
  }
}

// Starts this binary as LocalSystem inside `session_id`, where it can open the
// session's desktops; the service's own session 0 has no access to them.
HANDLE LaunchAgent(DWORD session_id) {
  HANDLE own_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY,
                        &own_token)) {
    return nullptr;
  }
  HANDLE token = nullptr;
  const BOOL duplicated =
      DuplicateTokenEx(own_token, MAXIMUM_ALLOWED, nullptr,
                       SecurityImpersonation, TokenPrimary, &token);
  CloseHandle(own_token);
  if (!duplicated) {
    return nullptr;
  }
  HANDLE process = nullptr;
  if (SetTokenInformation(token, TokenSessionId, &session_id,
                          sizeof(session_id))) {
    std::wstring command = L"\"" + ExecutablePath() + L"\" " +
                           whisper_input_service::kAgentArgument + L" " +
                           std::to_wstring(GetCurrentProcessId());
    wchar_t desktop[] = L"winsta0\\default";
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    startup.lpDesktop = desktop;
    PROCESS_INFORMATION info = {};
    if (CreateProcessAsUserW(token, nullptr, command.data(), nullptr, nullptr,
                             FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                             &startup, &info)) {
      CloseHandle(info.hThread);
      process = info.hProcess;
    }
  }
  CloseHandle(token);
  return process;
}

void StopAgent(HANDLE* agent) {
  if (*agent == nullptr) {
    return;
  }
  TerminateProcess(*agent, 0);
  WaitForSingleObject(*agent, 5000);
  CloseHandle(*agent);
  *agent = nullptr;
}

void WINAPI ServiceMain(DWORD, LPWSTR*) {
  g_status_handle = RegisterServiceCtrlHandlerExW(
      whisper_input_service::kServiceName, ServiceControl, nullptr);
  if (g_status_handle == nullptr) {
    return;
  }
  ReportStatus(SERVICE_RUNNING);

  HANDLE agent = nullptr;
  DWORD agent_session = 0;
  const HANDLE events[] = {g_stop_event, g_wake_event};
  for (;;) {
    const DWORD session_id = WTSGetActiveConsoleSessionId();
    const bool alive =
        agent != nullptr && WaitForSingleObject(agent, 0) == WAIT_TIMEOUT;
    if (session_id == 0xFFFFFFFF) {
      StopAgent(&agent);
    } else if (!alive || agent_session != session_id) {
      StopAgent(&agent);
      agent = LaunchAgent(session_id);
      agent_session = session_id;
    }
    if (WaitForMultipleObjects(2, events, FALSE, kSupervisorIntervalMs) ==
        WAIT_OBJECT_0) {
      break;
    }
  }
  StopAgent(&agent);
  ReportStatus(SERVICE_STOPPED);
}

int RunService() {
  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  g_wake_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (g_stop_event == nullptr || g_wake_event == nullptr) {
    return 1;
  }
  const SERVICE_TABLE_ENTRYW table[] = {
      {const_cast<LPWSTR>(whisper_input_service::kServiceName), ServiceMain},
      {nullptr, nullptr},
  };
  return StartServiceCtrlDispatcherW(table) ? 0 : 1;
}

// ---------------------------------------------------------------------------
// Install / uninstall
// ---------------------------------------------------------------------------

std::wstring InstallDirectory() {
  // Resolved from the machine's known folders rather than the environment,
  // which the unelevated caller controls.
  PWSTR program_files = nullptr;
  std::wstring directory;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_ProgramFiles, 0, nullptr,
                                     &program_files))) {
    directory = std::wstring(program_files) + L"\\" + kInstallFolder;
  }
  CoTaskMemFree(program_files);
  return directory;
}

bool WaitForServiceState(SC_HANDLE service, DWORD state) {
  const ULONGLONG deadline = GetTickCount64() + kServiceStateTimeoutMs;
  for (;;) {
    SERVICE_STATUS status = {};
    if (!QueryServiceStatus(service, &status)) {
      return false;
    }
    if (status.dwCurrentState == state) {
      return true;
    }
    if (GetTickCount64() >= deadline) {
      return false;
    }
    Sleep(200);
  }
}

void StopService(SC_HANDLE service) {
  SERVICE_STATUS status = {};
  ControlService(service, SERVICE_CONTROL_STOP, &status);
  WaitForServiceState(service, SERVICE_STOPPED);
}

// The stopped service and its agent can hold the file for a moment longer.
bool RetryFileOperation(bool (*operation)(const std::wstring&,
                                          const std::wstring&),
                        const std::wstring& first,
                        const std::wstring& second) {
  for (int attempt = 0; attempt < 20; ++attempt) {
    if (operation(first, second)) {
      return true;
    }
    Sleep(250);
  }
  return false;
}

bool CopyOver(const std::wstring& source, const std::wstring& target) {
  return CopyFileW(source.c_str(), target.c_str(), FALSE) != FALSE;
}

bool DeleteExisting(const std::wstring& path, const std::wstring&) {
  return DeleteFileW(path.c_str()) != FALSE ||
         GetLastError() == ERROR_FILE_NOT_FOUND ||
         GetLastError() == ERROR_PATH_NOT_FOUND;
}

std::wstring DirectoryOf(const std::wstring& path) {
  const size_t separator = path.find_last_of(L'\\');
  return separator == std::wstring::npos ? std::wstring()
                                         : path.substr(0, separator);
}

bool FileExists(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// Copies this executable, and the runtime libraries shipped beside it, to
// where the service runs from. Flutter and the plugins are deliberately left
// behind: they load on first use and the service roles never use them.
bool CopyServiceFiles(const std::wstring& source, const std::wstring& target) {
  if (_wcsicmp(source.c_str(), target.c_str()) == 0) {
    return true;
  }
  if (!RetryFileOperation(CopyOver, source, target)) {
    return false;
  }
  for (const wchar_t* library : kRuntimeLibraries) {
    const std::wstring from = DirectoryOf(source) + L"\\" + library;
    if (FileExists(from) &&
        !RetryFileOperation(CopyOver, from,
                            DirectoryOf(target) + L"\\" + library)) {
      return false;
    }
  }
  return true;
}

DWORD Install() {
  const std::wstring source = ExecutablePath();
  const std::wstring directory = InstallDirectory();
  if (source.empty() || directory.empty()) {
    return ERROR_PATH_NOT_FOUND;
  }
  const std::wstring target =
      directory + L"\\" + whisper_input_service::kInstalledExecutableName;
  const std::wstring command =
      L"\"" + target + L"\" " + whisper_input_service::kServiceArgument;

  const SC_HANDLE manager = OpenSCManagerW(
      nullptr, nullptr, SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
  if (manager == nullptr) {
    return GetLastError();
  }
  SC_HANDLE service = OpenServiceW(
      manager, whisper_input_service::kServiceName, SERVICE_ALL_ACCESS);
  if (service != nullptr) {
    // Releases the installed copy so that an update can replace it.
    StopService(service);
  }

  DWORD error = NO_ERROR;
  if (!CreateDirectoryW(directory.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    error = GetLastError();
  }
  if (error == NO_ERROR && !CopyServiceFiles(source, target)) {
    error = ERROR_SHARING_VIOLATION;
  }
  if (error == NO_ERROR && service != nullptr) {
    if (!ChangeServiceConfigW(service, SERVICE_WIN32_OWN_PROCESS,
                              SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                              command.c_str(), nullptr, nullptr, nullptr,
                              nullptr, nullptr, kServiceDisplayName)) {
      error = GetLastError();
    }
  } else if (error == NO_ERROR) {
    service = CreateServiceW(
        manager, whisper_input_service::kServiceName, kServiceDisplayName,
        SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START,
        SERVICE_ERROR_NORMAL, command.c_str(), nullptr, nullptr, nullptr,
        nullptr, nullptr);
    if (service == nullptr) {
      error = GetLastError();
    }
  }
  if (error == NO_ERROR) {
    SERVICE_DESCRIPTIONW description = {};
    description.lpDescription = const_cast<LPWSTR>(kServiceDescription);
    ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, &description);
    if (!StartServiceW(service, 0, nullptr) &&
        GetLastError() != ERROR_SERVICE_ALREADY_RUNNING) {
      error = GetLastError();
    }
  }
  if (service != nullptr) CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return error;
}

void RemoveInstalledFile(const std::wstring& path) {
  if (!RetryFileOperation(DeleteExisting, path, std::wstring())) {
    MoveFileExW(path.c_str(), nullptr, MOVEFILE_DELAY_UNTIL_REBOOT);
  }
}

DWORD Uninstall() {
  const SC_HANDLE manager =
      OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) {
    return GetLastError();
  }
  DWORD error = NO_ERROR;
  const SC_HANDLE service =
      OpenServiceW(manager, whisper_input_service::kServiceName,
                   SERVICE_STOP | SERVICE_QUERY_STATUS | DELETE);
  if (service != nullptr) {
    StopService(service);
    if (!DeleteService(service) &&
        GetLastError() != ERROR_SERVICE_MARKED_FOR_DELETE) {
      error = GetLastError();
    }
    CloseServiceHandle(service);
  } else if (GetLastError() != ERROR_SERVICE_DOES_NOT_EXIST) {
    error = GetLastError();
  }
  CloseServiceHandle(manager);

  const std::wstring directory = InstallDirectory();
  if (!directory.empty()) {
    RemoveInstalledFile(directory + L"\\" +
                        whisper_input_service::kInstalledExecutableName);
    for (const wchar_t* library : kRuntimeLibraries) {
      RemoveInstalledFile(directory + L"\\" + library);
    }
    RemoveDirectoryW(directory.c_str());
  }
  return error;
}

// The copy under Program Files has none of the app next to it and must never
// go on to start it, whatever it is launched with.
bool IsInstalledCopy() {
  const std::wstring path = ExecutablePath();
  const size_t separator = path.find_last_of(L'\\');
  return separator != std::wstring::npos &&
         _wcsicmp(path.c_str() + separator + 1,
                  whisper_input_service::kInstalledExecutableName) == 0;
}

}  // namespace

std::optional<int> RunInputServiceCommand() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  const std::wstring mode = argv != nullptr && argc > 1 ? argv[1] : L"";
  const std::wstring parameter = argv != nullptr && argc > 2 ? argv[2] : L"";
  LocalFree(argv);
  if (mode == whisper_input_service::kServiceArgument) {
    return RunService();
  }
  if (mode == whisper_input_service::kAgentArgument && !parameter.empty()) {
    return RunAgent(wcstoul(parameter.c_str(), nullptr, 10));
  }
  if (mode == whisper_input_service::kInstallArgument) {
    return static_cast<int>(Install());
  }
  if (mode == whisper_input_service::kUninstallArgument) {
    return static_cast<int>(Uninstall());
  }
  if (IsInstalledCopy()) {
    return static_cast<int>(ERROR_INVALID_PARAMETER);
  }
  return std::nullopt;
}
