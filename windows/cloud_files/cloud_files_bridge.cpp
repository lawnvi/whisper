// Another device's files as a Cloud Files sync root: the folder Explorer
// shows in its navigation pane, like OneDrive's, with folders listed and
// files read only when something opens them.
//
// This side only registers the folder and carries the system's requests
// to Dart (lib/remote_files/mount/cloud_files_windows.dart) and its answers
// back: each callback copies what it needs into a WcfRequest, hands it to
// a NativeCallable.listener and returns at once; Dart answers later with
// wcf_list / wcf_data / wcf_ack, from any thread, as Cloud Files allows.
//
// A device that takes changes gets its placeholders writable, and is asked
// before one is deleted or renamed (wcf_ack says whether it was done
// there). What is written or made in the folder Dart finds by watching it
// (wcf_state), sends, and marks in sync (wcf_mark).

#include <windows.h>
#include <cfapi.h>
#include <sddl.h>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Provider.h>
#include <winrt/Windows.Storage.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

using winrt::Windows::Security::Cryptography::BinaryStringEncoding;
using winrt::Windows::Security::Cryptography::CryptographicBuffer;
using winrt::Windows::Storage::StorageFolder;
using namespace winrt::Windows::Storage::Provider;

constexpr NTSTATUS kSuccess = 0;
constexpr NTSTATUS kUnsuccessful = static_cast<NTSTATUS>(0xC0000001L);
constexpr NTSTATUS kAccessDenied = static_cast<NTSTATUS>(0xC0000022L);

template <typename T>
constexpr ULONG ParamSize() {
  return static_cast<ULONG>(FIELD_OFFSET(CF_OPERATION_PARAMETERS, TransferData) +
                            sizeof(T));
}

}  // namespace

extern "C" {

// What the system asked, for Dart. Freed with wcf_free.
struct WcfRequest {
  // 1 list a folder, 2 read, 3 cancel a read, 4 delete, 5 rename or move,
  // 6 a folder was opened
  int32_t kind;
  int32_t is_dir;
  int64_t ino;  // the item's number in the mount (1: the top)
  int64_t offset;
  int64_t length;
  int64_t file_size;
  int64_t optional_offset;  // read: what may come along, if wanted
  int64_t optional_length;
  int64_t connection_key;
  int64_t transfer_key;
  int64_t request_key;
  wchar_t path[1024];  // full path of the item
  wchar_t target[1024];  // rename: where to; empty when out of the folder
};

// One file or folder to show.
struct WcfEntry {
  const wchar_t* name;
  int64_t ino;
  int64_t size;
  int64_t modified;  // FILETIME
  int32_t is_dir;
  int32_t hidden;
  int32_t read_only;  // the device takes no changes
};

typedef void (*WcfNotify)(WcfRequest* request);

// Answers wcf_state_async and wcf_mark_async: [token] as given.
typedef void (*WcfDone)(int64_t token, int32_t result);

}  // extern "C"

namespace {

struct Session {
  std::wstring path;
  std::wstring id;
  WcfNotify notify = nullptr;
  CF_CONNECTION_KEY key = {};
  // Being let go (wcf_clear_async): what the system asks is answered here,
  // and nothing reaches Dart or the device.
  std::atomic<bool> leaving{false};
};

// The identity Cloud Files keeps for each placeholder: its number and
// whether it is a folder.
struct Identity {
  int64_t ino;
  int32_t is_dir;
};

void Describe(const CF_CALLBACK_INFO* info, WcfRequest* request) {
  request->connection_key = info->ConnectionKey.Internal;
  request->transfer_key = info->TransferKey.QuadPart;
  request->request_key = info->RequestKey.QuadPart;
  // No identity: the sync root itself, the top of the mount.
  request->ino = 1;
  request->is_dir = 1;
  if (info->FileIdentity != nullptr &&
      info->FileIdentityLength >= sizeof(Identity)) {
    Identity identity;
    std::memcpy(&identity, info->FileIdentity, sizeof identity);
    request->ino = identity.ino;
    request->is_dir = identity.is_dir;
  }
  std::wstring path;
  if (info->VolumeDosName != nullptr) {
    path = info->VolumeDosName;
  }
  if (info->NormalizedPath != nullptr) {
    path += info->NormalizedPath;
  }
  wcsncpy_s(request->path, path.c_str(), _TRUNCATE);
}

Session* SessionOf(const CF_CALLBACK_INFO* info) {
  return static_cast<Session*>(info->CallbackContext);
}

bool Leaving(const CF_CALLBACK_INFO* info) {
  return SessionOf(info)->leaving.load();
}

}  // namespace

extern "C" {
__declspec(dllexport) int32_t wcf_list(WcfRequest*, const WcfEntry*, int32_t,
                                       int32_t);
__declspec(dllexport) int32_t wcf_data(WcfRequest*, const uint8_t*, int64_t,
                                       int64_t, int32_t);
__declspec(dllexport) int32_t wcf_ack(WcfRequest*, int32_t);
}

namespace {

void CALLBACK OnFetchPlaceholders(const CF_CALLBACK_INFO* info,
                                  const CF_CALLBACK_PARAMETERS*) {
  if (Leaving(info)) {
    // Nothing in it: a folder never listed can then be deleted.
    WcfRequest request{};
    Describe(info, &request);
    wcf_list(&request, nullptr, 0, 0);
    return;
  }
  auto* request = new WcfRequest{};
  request->kind = 1;
  request->is_dir = 1;
  Describe(info, request);
  SessionOf(info)->notify(request);
}

void CALLBACK OnFetchData(const CF_CALLBACK_INFO* info,
                          const CF_CALLBACK_PARAMETERS* params) {
  auto* request = new WcfRequest{};
  request->kind = 2;
  Describe(info, request);
  request->offset = params->FetchData.RequiredFileOffset.QuadPart;
  request->length = params->FetchData.RequiredLength.QuadPart;
  request->optional_offset = params->FetchData.OptionalFileOffset.QuadPart;
  request->optional_length = params->FetchData.OptionalLength.QuadPart;
  request->file_size = info->FileSize.QuadPart;
  if (Leaving(info)) {
    wcf_data(request, nullptr, request->offset, request->length, 1);
    delete request;
    return;
  }
  SessionOf(info)->notify(request);
}

void CALLBACK OnNotifyDelete(const CF_CALLBACK_INFO* info,
                             const CF_CALLBACK_PARAMETERS* params) {
  auto* request = new WcfRequest{};
  request->kind = 4;
  Describe(info, request);
  request->is_dir =
      (params->Delete.Flags & CF_CALLBACK_DELETE_FLAG_IS_DIRECTORY) != 0;
  if (Leaving(info)) {
    // Deleted here only: the device keeps it.
    wcf_ack(request, 1);
    delete request;
    return;
  }
  SessionOf(info)->notify(request);
}

void CALLBACK OnNotifyRename(const CF_CALLBACK_INFO* info,
                             const CF_CALLBACK_PARAMETERS* params) {
  auto* request = new WcfRequest{};
  request->kind = 5;
  Describe(info, request);
  request->is_dir =
      (params->Rename.Flags & CF_CALLBACK_RENAME_FLAG_IS_DIRECTORY) != 0;
  if ((params->Rename.Flags & CF_CALLBACK_RENAME_FLAG_TARGET_IN_SCOPE) != 0 &&
      params->Rename.TargetPath != nullptr) {
    std::wstring target;
    if (info->VolumeDosName != nullptr) {
      target = info->VolumeDosName;
    }
    target += params->Rename.TargetPath;
    wcsncpy_s(request->target, target.c_str(), _TRUNCATE);
  }
  if (Leaving(info)) {
    wcf_ack(request, 0);
    delete request;
    return;
  }
  SessionOf(info)->notify(request);
}

// Explorer opening a folder: Dart looks at it again on the device. A
// folder is listed once (fully populated, which creating files in it
// needs) and kept up to date from then on.
void CALLBACK OnOpenCompletion(const CF_CALLBACK_INFO* info,
                               const CF_CALLBACK_PARAMETERS*) {
  if (Leaving(info)) {
    return;
  }
  WcfRequest probe{};
  Describe(info, &probe);
  if (!probe.is_dir) {
    return;
  }
  auto* request = new WcfRequest(probe);
  request->kind = 6;
  SessionOf(info)->notify(request);
}

void CALLBACK OnCancelFetchData(const CF_CALLBACK_INFO* info,
                                const CF_CALLBACK_PARAMETERS* params) {
  if (Leaving(info)) {
    return;
  }
  auto* request = new WcfRequest{};
  request->kind = 3;
  Describe(info, request);
  request->offset = params->Cancel.FetchData.FileOffset.QuadPart;
  request->length = params->Cancel.FetchData.Length.QuadPart;
  SessionOf(info)->notify(request);
}

std::wstring UserSid() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return L"";
  }
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size);
  std::wstring sid;
  if (GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
    LPWSTR text = nullptr;
    if (ConvertSidToStringSidW(
            reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &text)) {
      sid = text;
      LocalFree(text);
    }
  }
  CloseHandle(token);
  return sid;
}

// WinRT's blocking calls refuse the UI thread (an STA): they run on a
// thread of their own.
template <typename F>
HRESULT OnMtaThread(F&& work) {
  HRESULT result = S_OK;
  std::thread thread([&] {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      work();
    } catch (winrt::hresult_error const& error) {
      result = error.code();
    } catch (...) {
      result = E_FAIL;
    }
    winrt::uninit_apartment();
  });
  thread.join();
  return result;
}

std::vector<CF_PLACEHOLDER_CREATE_INFO> Placeholders(
    const WcfEntry* entries,
    int32_t count,
    std::vector<Identity>& identities) {
  identities.resize(count);
  std::vector<CF_PLACEHOLDER_CREATE_INFO> out(count);
  for (int32_t i = 0; i < count; i++) {
    const WcfEntry& entry = entries[i];
    identities[i] = {entry.ino, entry.is_dir};
    CF_PLACEHOLDER_CREATE_INFO& info = out[i];
    info = {};
    info.RelativeFileName = entry.name;
    LARGE_INTEGER time;
    time.QuadPart = entry.modified;
    auto& basic = info.FsMetadata.BasicInfo;
    basic.CreationTime = basic.LastWriteTime = basic.LastAccessTime =
        basic.ChangeTime = time;
    // Read-only when nothing written here would reach the device.
    basic.FileAttributes =
        (entry.is_dir ? FILE_ATTRIBUTE_DIRECTORY
                      : (entry.read_only ? FILE_ATTRIBUTE_READONLY
                                         : FILE_ATTRIBUTE_NORMAL)) |
        (entry.hidden ? FILE_ATTRIBUTE_HIDDEN : 0);
    info.FsMetadata.FileSize.QuadPart = entry.is_dir ? 0 : entry.size;
    info.FileIdentity = &identities[i];
    info.FileIdentityLength = sizeof(Identity);
    info.Flags = CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;
  }
  return out;
}

CF_OPERATION_INFO Operation(const WcfRequest* request,
                            CF_OPERATION_TYPE type) {
  CF_OPERATION_INFO op = {};
  op.StructSize = sizeof op;
  op.Type = type;
  op.ConnectionKey.Internal = request->connection_key;
  op.TransferKey.QuadPart = request->transfer_key;
  op.RequestKey.QuadPart = request->request_key;
  return op;
}

// What Cloud Files says of the item at [path], from its directory entry
// (which opens nothing, so hydrates nothing).
bool PlaceholderState(const wchar_t* path, DWORD* attributes,
                      CF_PLACEHOLDER_STATE* state) {
  WIN32_FIND_DATAW data;
  HANDLE find = FindFirstFileW(path, &data);
  if (find == INVALID_HANDLE_VALUE) {
    return false;
  }
  FindClose(find);
  *attributes = data.dwFileAttributes;
  *state = CfGetPlaceholderStateFromFindData(&data);
  return true;
}

// Whether the placeholder at [path] is in sync with the device. Only the
// placeholder itself says (its directory entry does not); opening it for
// its attributes hydrates nothing.
bool InSync(const wchar_t* path) {
  HANDLE handle = CreateFileW(
      path, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    return false;
  }
  alignas(CF_PLACEHOLDER_BASIC_INFO) BYTE buffer
      [sizeof(CF_PLACEHOLDER_BASIC_INFO) + sizeof(Identity) + 16];
  DWORD returned = 0;
  HRESULT hr = CfGetPlaceholderInfo(handle, CF_PLACEHOLDER_INFO_BASIC, buffer,
                                    sizeof buffer, &returned);
  CloseHandle(handle);
  if (FAILED(hr) && hr != HRESULT_FROM_WIN32(ERROR_MORE_DATA)) {
    return false;
  }
  return reinterpret_cast<CF_PLACEHOLDER_BASIC_INFO*>(buffer)->InSyncState ==
         CF_IN_SYNC_STATE_IN_SYNC;
}

// A handle that may change an item's sync state, never its data.
HANDLE OpenForSyncState(const wchar_t* path) {
  return CreateFileW(path, FILE_READ_ATTRIBUTES | WRITE_DAC,
                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                     nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS,
                     nullptr);
}

// One of Cloud Files' own reparse tags (a placeholder), not a link.
bool CloudTag(DWORD tag) {
  return (tag & ~IO_REPARSE_TAG_CLOUD_MASK) == IO_REPARSE_TAG_CLOUD;
}

// Deletes what is in [folder], not the folder; returns how many items
// stayed. A link that is not one of Cloud Files' own goes without what it
// leads to.
int32_t ClearFolder(const std::wstring& folder) {
  WIN32_FIND_DATAW data;
  HANDLE find = FindFirstFileExW((folder + L"\\*").c_str(), FindExInfoBasic,
                                 &data, FindExSearchNameMatch, nullptr, 0);
  if (find == INVALID_HANDLE_VALUE) {
    return GetLastError() == ERROR_FILE_NOT_FOUND ? 0 : 1;
  }
  int32_t stayed = 0;
  do {
    std::wstring name(data.cFileName);
    if (name == L"." || name == L"..") {
      continue;
    }
    std::wstring item = folder + L"\\" + name;
    const DWORD attributes = data.dwFileAttributes;
    const bool dir = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    const bool link = (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 &&
                      !CloudTag(data.dwReserved0);
    if (dir && !link) {
      stayed += ClearFolder(item);
    }
    if ((attributes & FILE_ATTRIBUTE_READONLY) != 0) {
      SetFileAttributesW(item.c_str(), attributes & ~FILE_ATTRIBUTE_READONLY);
    }
    if (!(dir ? RemoveDirectoryW(item.c_str()) : DeleteFileW(item.c_str()))) {
      stayed++;
    }
  } while (FindNextFileW(find, &data));
  FindClose(find);
  return stayed;
}

// wcf_start; [leaving]: from the start, as for wcf_clear_stale_async.
Session* StartSession(const wchar_t* path,
                      const wchar_t* device,
                      const wchar_t* name,
                      const wchar_t* icon,
                      int32_t writable,
                      WcfNotify notify,
                      int32_t* error,
                      bool leaving) {
  CreateDirectoryW(path, nullptr);
  auto* session = new Session();
  session->path = path;
  session->id = std::wstring(L"Whisper!") + UserSid() + L"!" + device;
  session->notify = notify;
  session->leaving = leaving;
  HRESULT hr = OnMtaThread([&] {
    StorageProviderSyncRootInfo info;
    info.Id(session->id);
    info.Path(StorageFolder::GetFolderFromPathAsync(session->path).get());
    info.DisplayNameResource(name);
    info.IconResource(icon);
    info.HydrationPolicy(StorageProviderHydrationPolicy::Partial);
    info.HydrationPolicyModifier(StorageProviderHydrationPolicyModifier::None);
    info.PopulationPolicy(StorageProviderPopulationPolicy::Full);
    info.InSyncPolicy(StorageProviderInSyncPolicy::Default);
    info.HardlinkPolicy(StorageProviderHardlinkPolicy::None);
    info.ShowSiblingsAsGroup(false);
    info.Version(L"1");
    info.Context(CryptographicBuffer::ConvertStringToBinary(
        session->id, BinaryStringEncoding::Utf8));
    StorageProviderSyncRootManager::Register(info);
  });
  if (FAILED(hr)) {
    *error = hr;
    delete session;
    return nullptr;
  }
  static const CF_CALLBACK_REGISTRATION read_only[] = {
      {CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS, OnFetchPlaceholders},
      {CF_CALLBACK_TYPE_FETCH_DATA, OnFetchData},
      {CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, OnCancelFetchData},
      {CF_CALLBACK_TYPE_NOTIFY_FILE_OPEN_COMPLETION, OnOpenCompletion},
      CF_CALLBACK_REGISTRATION_END};
  static const CF_CALLBACK_REGISTRATION changes[] = {
      {CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS, OnFetchPlaceholders},
      {CF_CALLBACK_TYPE_FETCH_DATA, OnFetchData},
      {CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, OnCancelFetchData},
      {CF_CALLBACK_TYPE_NOTIFY_FILE_OPEN_COMPLETION, OnOpenCompletion},
      {CF_CALLBACK_TYPE_NOTIFY_DELETE, OnNotifyDelete},
      {CF_CALLBACK_TYPE_NOTIFY_RENAME, OnNotifyRename},
      CF_CALLBACK_REGISTRATION_END};
  hr = CfConnectSyncRoot(path, writable ? changes : read_only, session,
                         CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
                         &session->key);
  if (FAILED(hr)) {
    *error = hr;
    std::wstring id = session->id;
    OnMtaThread([&] { StorageProviderSyncRootManager::Unregister(id); });
    delete session;
    return nullptr;
  }
  return session;
}

}  // namespace

extern "C" {

// Registers [path] as a sync root named [name] (its icon from [icon]) for
// [device] and connects to it; [writable]: asked before deletes and
// renames. Returns the session, or 0 with [error] set.
__declspec(dllexport) int64_t wcf_start(const wchar_t* path,
                                        const wchar_t* device,
                                        const wchar_t* name,
                                        const wchar_t* icon,
                                        int32_t writable,
                                        WcfNotify notify,
                                        int32_t* error) {
  return reinterpret_cast<int64_t>(StartSession(
      path, device, name, icon, writable, notify, error, false));
}

// Empties the folder before it is let go, still connected: once nobody
// provides it, Cloud Files keeps a folder never listed (deleting one asks
// for its listing) and the sync root with it, in Explorer's navigation
// pane. Every request on the way is answered here, none goes to Dart or
// the device. On a thread of its own (deleting calls back into this
// provider); [done] gets how many items stayed.
__declspec(dllexport) void wcf_clear_async(int64_t handle,
                                           WcfDone done,
                                           int64_t token) {
  auto* session = reinterpret_cast<Session*>(handle);
  session->leaving = true;
  std::wstring folder = session->path;
  std::thread([folder, done, token]() {
    done(token, ClearFolder(folder));
  }).detach();
}

// Disconnects and takes the folder out of Explorer; Dart deletes the
// folder, emptied by wcf_clear_async. Returns how unregistering went.
__declspec(dllexport) int32_t wcf_stop(int64_t handle) {
  auto* session = reinterpret_cast<Session*>(handle);
  if (session == nullptr) {
    return S_OK;
  }
  CfDisconnectSyncRoot(session->key);
  std::wstring id = session->id;
  HRESULT hr =
      OnMtaThread([&] { StorageProviderSyncRootManager::Unregister(id); });
  delete session;
  return hr;
}

// A folder a run before this one left (it could not be emptied, or the
// run quit abruptly), which Cloud Files will not let go of unprovided:
// provided again, answering everything itself, just long enough to empty
// it. [done] gets how many items stayed, or -1 when it could not be.
__declspec(dllexport) void wcf_clear_stale_async(const wchar_t* path,
                                                 const wchar_t* icon,
                                                 WcfDone done,
                                                 int64_t token) {
  std::wstring folder(path);
  std::wstring image(icon);
  std::thread([folder, image, done, token]() {
    int32_t error = 0;
    Session* session = StartSession(folder.c_str(), L"leftover", L"Whisper",
                                    image.c_str(), 1, nullptr, &error, true);
    if (session == nullptr) {
      done(token, -1);
      return;
    }
    int32_t stayed = ClearFolder(folder);
    wcf_stop(reinterpret_cast<int64_t>(session));
    done(token, stayed);
  }).detach();
}

// Takes away Whisper's sync roots left by a run that quit abruptly.
__declspec(dllexport) int32_t wcf_unregister_stale() {
  int32_t removed = 0;
  std::wstring prefix = std::wstring(L"Whisper!") + UserSid() + L"!";
  OnMtaThread([&] {
    for (auto const& root :
         StorageProviderSyncRootManager::GetCurrentSyncRoots()) {
      std::wstring id(root.Id());
      if (id.rfind(prefix, 0) == 0) {
        StorageProviderSyncRootManager::Unregister(root.Id());
        removed++;
      }
    }
  });
  return removed;
}

// Answers a folder listing with what it does not have yet (failed:
// nothing could be listed, and it asks again). The folder is then fully
// populated: a name made in it needs nothing from the device to resolve,
// and what is new on the device comes with wcf_create.
__declspec(dllexport) int32_t wcf_list(WcfRequest* request,
                                       const WcfEntry* entries,
                                       int32_t count,
                                       int32_t failed) {
  std::vector<Identity> identities;
  auto placeholders = Placeholders(entries, failed ? 0 : count, identities);
  CF_OPERATION_INFO op =
      Operation(request, CF_OPERATION_TYPE_TRANSFER_PLACEHOLDERS);
  CF_OPERATION_PARAMETERS params = {};
  params.ParamSize = static_cast<ULONG>(
      FIELD_OFFSET(CF_OPERATION_PARAMETERS, TransferPlaceholders) +
      sizeof(params.TransferPlaceholders));
  params.TransferPlaceholders.Flags =
      failed ? CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_NONE
             : CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_DISABLE_ON_DEMAND_POPULATION;
  params.TransferPlaceholders.CompletionStatus =
      failed ? kUnsuccessful : kSuccess;
  params.TransferPlaceholders.PlaceholderTotalCount.QuadPart =
      static_cast<LONGLONG>(placeholders.size());
  params.TransferPlaceholders.PlaceholderArray =
      placeholders.empty() ? nullptr : placeholders.data();
  params.TransferPlaceholders.PlaceholderCount =
      static_cast<DWORD>(placeholders.size());
  return CfExecute(&op, &params);
}

// Hands over [length] bytes from [offset], or (failed) tells the system
// that range is not coming, so it asks again for what a reader needs.
__declspec(dllexport) int32_t wcf_data(WcfRequest* request,
                                       const uint8_t* data,
                                       int64_t offset,
                                       int64_t length,
                                       int32_t failed) {
  CF_OPERATION_INFO op = Operation(request, CF_OPERATION_TYPE_TRANSFER_DATA);
  CF_OPERATION_PARAMETERS params = {};
  params.ParamSize = ParamSize<decltype(params.TransferData)>();
  params.TransferData.CompletionStatus = failed ? kUnsuccessful : kSuccess;
  params.TransferData.Buffer = failed ? nullptr : data;
  params.TransferData.Offset.QuadPart = offset;
  params.TransferData.Length.QuadPart = length;
  return CfExecute(&op, &params);
}

// Says whether a delete (kind 4) or a rename (kind 5) was done on the
// device: if not, it is not done here either.
__declspec(dllexport) int32_t wcf_ack(WcfRequest* request, int32_t done) {
  CF_OPERATION_INFO op = Operation(
      request, request->kind == 4 ? CF_OPERATION_TYPE_ACK_DELETE
                                  : CF_OPERATION_TYPE_ACK_RENAME);
  CF_OPERATION_PARAMETERS params = {};
  if (request->kind == 4) {
    params.ParamSize = ParamSize<decltype(params.AckDelete)>();
    params.AckDelete.CompletionStatus = done ? kSuccess : kAccessDenied;
  } else {
    params.ParamSize = ParamSize<decltype(params.AckRename)>();
    params.AckRename.CompletionStatus = done ? kSuccess : kAccessDenied;
  }
  return CfExecute(&op, &params);
}

// What the item at [path] is: -1 not there; else 1 a folder, 2 one of
// the mount's placeholders, 4 in sync with the device, 8 something has it
// open for writing (or would not share it for reading).
__declspec(dllexport) int32_t wcf_state(const wchar_t* path) {
  DWORD attributes = 0;
  CF_PLACEHOLDER_STATE state = CF_PLACEHOLDER_STATE_NO_STATES;
  if (!PlaceholderState(path, &attributes, &state)) {
    return -1;
  }
  int32_t out = 0;
  if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    out |= 1;
  }
  if ((state & CF_PLACEHOLDER_STATE_PLACEHOLDER) != 0) {
    out |= 2;
    if (InSync(path)) {
      out |= 4;
    }
  }
  if ((out & 1) == 0) {
    // Opened for reading, not shared for writing: refused while anyone
    // writes it. Opening reads nothing, so hydrates nothing.
    HANDLE handle = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                                OPEN_EXISTING, 0, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
      if (GetLastError() == ERROR_SHARING_VIOLATION) {
        out |= 8;
      }
    } else {
      CloseHandle(handle);
    }
  }
  return out;
}

// What was made or written at [path] is now on the device as item [ino]:
// a placeholder (made one if it is new), in sync.
__declspec(dllexport) int32_t wcf_mark(const wchar_t* path,
                                       int64_t ino,
                                       int32_t is_dir) {
  DWORD attributes = 0;
  CF_PLACEHOLDER_STATE state = CF_PLACEHOLDER_STATE_NO_STATES;
  if (!PlaceholderState(path, &attributes, &state)) {
    return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
  }
  HANDLE handle = OpenForSyncState(path);
  if (handle == INVALID_HANDLE_VALUE) {
    return HRESULT_FROM_WIN32(GetLastError());
  }
  Identity identity{ino, is_dir};
  HRESULT hr;
  if ((state & CF_PLACEHOLDER_STATE_PLACEHOLDER) == 0) {
    hr = CfConvertToPlaceholder(handle, &identity, sizeof identity,
                                CF_CONVERT_FLAG_MARK_IN_SYNC, nullptr,
                                nullptr);
  } else {
    hr = CfUpdatePlaceholder(handle, nullptr, &identity, sizeof identity,
                             nullptr, 0, CF_UPDATE_FLAG_MARK_IN_SYNC, nullptr,
                             nullptr);
  }
  CloseHandle(handle);
  return hr;
}

// What is new on the device in folder [dir], listed already: placeholders
// for it. On a thread of its own, like wcf_update.
__declspec(dllexport) int32_t wcf_create(const wchar_t* dir,
                                         const WcfEntry* entries,
                                         int32_t count) {
  std::wstring folder(dir);
  std::vector<std::wstring> names;
  std::vector<WcfEntry> copies(entries, entries + count);
  for (int32_t i = 0; i < count; i++) {
    names.emplace_back(entries[i].name != nullptr ? entries[i].name : L"");
  }
  std::thread([folder, names = std::move(names),
               copies = std::move(copies)]() mutable {
    for (size_t i = 0; i < copies.size(); i++) {
      copies[i].name = names[i].c_str();
    }
    std::vector<Identity> identities;
    auto placeholders = Placeholders(
        copies.data(), static_cast<int32_t>(copies.size()), identities);
    DWORD processed = 0;
    CfCreatePlaceholders(folder.c_str(), placeholders.data(),
                         static_cast<DWORD>(placeholders.size()),
                         CF_CREATE_FLAG_NONE, &processed);
  }).detach();
  return S_OK;
}

// wcf_state and wcf_mark, off the caller's thread: they open items in the
// sync root, which can call back into the provider (a folder not listed
// yet, say), and the provider is the very isolate that asks.
__declspec(dllexport) void wcf_state_async(const wchar_t* path,
                                           WcfDone done,
                                           int64_t token) {
  std::wstring item(path);
  std::thread([item, done, token]() {
    done(token, wcf_state(item.c_str()));
  }).detach();
}

__declspec(dllexport) void wcf_mark_async(const wchar_t* path,
                                          int64_t ino,
                                          int32_t is_dir,
                                          WcfDone done,
                                          int64_t token) {
  std::wstring item(path);
  std::thread([item, ino, is_dir, done, token]() {
    done(token, wcf_mark(item.c_str(), ino, is_dir));
  }).detach();
}

// A file changed on the device: its size and time here follow, and what
// was read of it goes. On a thread of its own: updating a placeholder can
// call back into the provider, which is the very isolate calling this.
// One changed here and not yet sent stays as it is.
__declspec(dllexport) int32_t wcf_update(const wchar_t* file,
                                         const WcfEntry* entry) {
  std::wstring path(file);
  std::wstring name(entry->name != nullptr ? entry->name : L"");
  WcfEntry copy = *entry;
  std::thread([path, name, copy]() mutable {
    copy.name = name.c_str();
    HANDLE handle = INVALID_HANDLE_VALUE;
    if (FAILED(CfOpenFileWithOplock(path.c_str(), CF_OPEN_FILE_FLAG_EXCLUSIVE,
                                    &handle))) {
      return;
    }
    std::vector<Identity> identities;
    auto placeholders = Placeholders(&copy, 1, identities);
    CfUpdatePlaceholder(
        handle, &placeholders[0].FsMetadata, &identities[0], sizeof(Identity),
        nullptr, 0,
        CF_UPDATE_FLAG_VERIFY_IN_SYNC | CF_UPDATE_FLAG_DEHYDRATE |
            CF_UPDATE_FLAG_MARK_IN_SYNC,
        nullptr, nullptr);
    CfCloseHandle(handle);
  }).detach();
  return S_OK;
}

// A file that went on the device goes here too, unless it was changed
// here and not yet sent. Its placeholder may be read-only, which
// DeleteFile refuses; on a thread of its own, like wcf_update.
__declspec(dllexport) int32_t wcf_remove(const wchar_t* file) {
  std::wstring path(file);
  std::thread([path]() {
    DWORD attributes = 0;
    CF_PLACEHOLDER_STATE state = CF_PLACEHOLDER_STATE_NO_STATES;
    if (!PlaceholderState(path.c_str(), &attributes, &state) ||
        (state & CF_PLACEHOLDER_STATE_PLACEHOLDER) == 0 ||
        !InSync(path.c_str())) {
      return;
    }
    SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
    DeleteFileW(path.c_str());
  }).detach();
  return S_OK;
}

__declspec(dllexport) void wcf_free(WcfRequest* request) {
  delete request;
}

}  // extern "C"
