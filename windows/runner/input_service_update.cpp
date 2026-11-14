// The lock screen input service updates itself, without a UAC prompt, from
// the files a newer Whisper installed in its own folder. That folder belongs
// to the user, so nothing in it is trusted for itself: the service reads what
// a manifest signed with the update key names, and only when the signature,
// the version (strictly newer than its own) and every SHA-512 hold does any
// of it reach Program Files.

#include "input_service_update.h"

#include <algorithm>
#include <utility>
#include <vector>

#include "input_service_manifest.h"
#include "input_service_protocol.h"

#if !defined(FLUTTER_VERSION_MAJOR) || !defined(FLUTTER_VERSION_MINOR) || \
    !defined(FLUTTER_VERSION_PATCH)
#error "The runner's build defines the app version the service compares with."
#endif

namespace whisper_input_service {
namespace {

constexpr ManifestVersion kOwnVersion = {FLUTTER_VERSION_MAJOR,
                                         FLUTTER_VERSION_MINOR,
                                         FLUTTER_VERSION_PATCH};
constexpr ULONGLONG kMaxFileBytes = 128ull << 20;
constexpr wchar_t kNewSuffix[] = L".new";
constexpr wchar_t kOldSuffix[] = L".old";

// The folder [process] runs from, when it is on a local drive. A network
// path would have this machine authenticate to whoever serves it.
std::wstring LocalProcessDirectory(HANDLE process) {
  std::wstring path(32768, L'\0');
  DWORD length = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &length)) {
    return std::wstring();
  }
  path.resize(length);
  const size_t separator = path.find_last_of(L'\\');
  if (path.size() < 3 || path[1] != L':' || path[2] != L'\\' ||
      separator == std::wstring::npos ||
      GetDriveTypeW(path.substr(0, 3).c_str()) == DRIVE_REMOTE) {
    return std::wstring();
  }
  return path.substr(0, separator);
}

// Reads what the client offers as the client's own user, so that it cannot
// have the service open anything it could not open itself.
class ClientIdentity {
 public:
  explicit ClientIdentity(HANDLE process) {
    HANDLE token = nullptr;
    if (!OpenProcessToken(process, TOKEN_DUPLICATE | TOKEN_QUERY, &token)) {
      return;
    }
    HANDLE impersonation = nullptr;
    if (DuplicateTokenEx(token, TOKEN_IMPERSONATE | TOKEN_QUERY, nullptr,
                         SecurityImpersonation, TokenImpersonation,
                         &impersonation)) {
      active_ = SetThreadToken(nullptr, impersonation) != FALSE;
      CloseHandle(impersonation);
    }
    CloseHandle(token);
  }
  ClientIdentity(const ClientIdentity&) = delete;
  ClientIdentity& operator=(const ClientIdentity&) = delete;
  ~ClientIdentity() { End(); }

  bool active() const { return active_; }

  void End() {
    if (active_) {
      RevertToSelf();
      active_ = false;
    }
  }

 private:
  bool active_ = false;
};

// Reads all of a file of at most [limit] bytes. Nobody can write to it while
// it is open, so what is checked is what gets installed.
bool ReadWholeFile(const std::wstring& path,
                   ULONGLONG limit,
                   std::string* content) {
  const HANDLE file =
      CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  LARGE_INTEGER size = {};
  bool ok = GetFileType(file) == FILE_TYPE_DISK && GetFileSizeEx(file, &size) &&
            size.QuadPart >= 0 &&
            static_cast<ULONGLONG>(size.QuadPart) <= limit;
  if (ok) {
    content->resize(static_cast<size_t>(size.QuadPart));
    size_t done = 0;
    while (ok && done < content->size()) {
      const DWORD chunk =
          static_cast<DWORD>(std::min<size_t>(content->size() - done, 1 << 20));
      DWORD read = 0;
      ok = ReadFile(file, content->data() + done, chunk, &read, nullptr) &&
           read > 0;
      done += read;
    }
  }
  CloseHandle(file);
  return ok;
}

bool WriteWholeFile(const std::wstring& path, const std::string& content) {
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  bool ok = true;
  size_t done = 0;
  while (ok && done < content.size()) {
    const DWORD chunk =
        static_cast<DWORD>(std::min<size_t>(content.size() - done, 1 << 20));
    DWORD written = 0;
    ok = WriteFile(file, content.data() + done, chunk, &written, nullptr) &&
         written == chunk;
    done += written;
  }
  ok = ok && FlushFileBuffers(file);
  CloseHandle(file);
  if (!ok) {
    DeleteFileW(path.c_str());
  }
  return ok;
}

// A running image can be renamed but not deleted or overwritten. A name of
// its own keeps it clear of a later update's leftovers.
std::wstring AsideName(const std::wstring& path) {
  return path + L"." + std::to_wstring(GetTickCount64()) + kOldSuffix;
}

struct Staged {
  std::wstring path;
  std::wstring aside;
};

void Restore(const std::vector<Staged>& done) {
  for (auto it = done.rbegin(); it != done.rend(); ++it) {
    DeleteFileW(it->path.c_str());
    if (!it->aside.empty()) {
      MoveFileExW(it->aside.c_str(), it->path.c_str(), 0);
    }
  }
}

// Writes every file beside the installed ones first, then swaps them in;
// a failure part way puts back what was there.
bool Replace(const std::wstring& directory,
             const std::vector<std::pair<std::wstring, std::string>>& files) {
  std::vector<std::wstring> written;
  for (const auto& [name, content] : files) {
    const std::wstring staged = directory + L"\\" + name + kNewSuffix;
    if (!WriteWholeFile(staged, content)) {
      for (const std::wstring& path : written) {
        DeleteFileW(path.c_str());
      }
      return false;
    }
    written.push_back(staged);
  }
  std::vector<Staged> done;
  for (size_t i = 0; i < files.size(); ++i) {
    Staged step{directory + L"\\" + files[i].first, std::wstring()};
    if (GetFileAttributesW(step.path.c_str()) != INVALID_FILE_ATTRIBUTES) {
      step.aside = AsideName(step.path);
      if (!MoveFileExW(step.path.c_str(), step.aside.c_str(), 0)) {
        step.aside.clear();
        Restore(done);
        for (size_t j = i; j < written.size(); ++j) {
          DeleteFileW(written[j].c_str());
        }
        return false;
      }
    }
    if (!MoveFileExW(written[i].c_str(), step.path.c_str(), 0)) {
      if (!step.aside.empty()) {
        MoveFileExW(step.aside.c_str(), step.path.c_str(), 0);
      }
      Restore(done);
      for (size_t j = i; j < written.size(); ++j) {
        DeleteFileW(written[j].c_str());
      }
      return false;
    }
    done.push_back(step);
  }
  return true;
}

// Restarting stops this agent too, so a process of its own does it, from
// the binary just put in place.
bool StartRestart(const std::wstring& executable) {
  std::wstring command =
      L"\"" + executable + L"\" " + std::wstring(kRestartArgument);
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION info = {};
  if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr,
                      FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                      &info)) {
    return false;
  }
  CloseHandle(info.hThread);
  CloseHandle(info.hProcess);
  return true;
}

void DeleteMatching(const std::wstring& directory, const wchar_t* pattern) {
  WIN32_FIND_DATAW data = {};
  const HANDLE find = FindFirstFileW((directory + pattern).c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) {
    return;
  }
  do {
    if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
      DeleteFileW((directory + L"\\" + data.cFileName).c_str());
    }
  } while (FindNextFileW(find, &data));
  FindClose(find);
}

// Reads, as the client's user, the files a valid manifest beside its
// executable names. Returns a Status; kStatusOk leaves them in [files].
DWORD ReadOffer(HANDLE process,
                std::vector<std::pair<std::wstring, std::string>>* files) {
  // Drive letters too are the user's own (a mapped share is remote).
  ClientIdentity client(process);
  const std::wstring source =
      client.active() ? LocalProcessDirectory(process) : std::wstring();
  if (source.empty()) {
    return kStatusFailed;
  }
  std::string text;
  std::string signature;
  if (!ReadWholeFile(source + L"\\" + kManifestName, kMaxManifestBytes,
                     &text) ||
      !ReadWholeFile(source + L"\\" + kManifestSignatureName,
                     kMaxManifestSignatureBytes, &signature)) {
    return kStatusFailed;
  }
  Manifest manifest;
  if (!VerifyManifest(text, signature, kManifestSigningKeys,
                      kManifestSigningKeyCount, &manifest)) {
    return kStatusRefused;
  }
  // An older signed release must not come back with what it got wrong.
  if (!IsNewer(manifest.version, kOwnVersion)) {
    return kStatusCurrent;
  }
  for (const ManifestFile& file : manifest.files) {
    // One of a few ASCII names (VerifyManifest checked).
    const std::wstring name(file.name.begin(), file.name.end());
    std::string content;
    if (!ReadWholeFile(source + L"\\" + name, kMaxFileBytes, &content)) {
      return kStatusFailed;
    }
    if (Sha512(content.data(), content.size()) != file.sha512) {
      return kStatusRefused;
    }
    files->emplace_back(
        name == L"whisper.exe" ? kInstalledExecutableName : name,
        std::move(content));
  }
  return kStatusOk;
}

}  // namespace

DWORD UpdateFromClient(DWORD client_process) {
  const std::wstring target = InstallDirectory();
  const HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, client_process);
  if (target.empty() || process == nullptr) {
    return kStatusFailed;
  }
  std::vector<std::pair<std::wstring, std::string>> files;
  const DWORD status = ReadOffer(process, &files);
  CloseHandle(process);
  if (status != kStatusOk) {
    return status;
  }
  if (!Replace(target, files)) {
    return kStatusFailed;
  }
  return StartRestart(InstalledExecutablePath()) ? kStatusOk : kStatusFailed;
}

void RemoveLeftovers() {
  const std::wstring directory = InstallDirectory();
  if (directory.empty()) {
    return;
  }
  DeleteMatching(directory, L"\\*.old");
  DeleteMatching(directory, L"\\*.new");
}

void RemoveFileNowOrLater(const std::wstring& path) {
  if (DeleteFileW(path.c_str()) || GetLastError() == ERROR_FILE_NOT_FOUND ||
      GetLastError() == ERROR_PATH_NOT_FOUND) {
    return;
  }
  // Scheduled under its own name, so that a reinstall before the restart
  // keeps the file it puts here.
  const std::wstring aside = AsideName(path);
  if (MoveFileExW(path.c_str(), aside.c_str(), 0)) {
    MoveFileExW(aside.c_str(), nullptr, MOVEFILE_DELAY_UNTIL_REBOOT);
  } else {
    MoveFileExW(path.c_str(), nullptr, MOVEFILE_DELAY_UNTIL_REBOOT);
  }
}

}  // namespace whisper_input_service
