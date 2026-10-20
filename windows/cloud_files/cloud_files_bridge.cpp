// Another device's files as a Cloud Files sync root: the folder Explorer
// shows in its navigation pane, like OneDrive's, with folders listed and
// files read only when something opens them.
//
// This side only registers the folder and carries the system's requests
// to Dart (lib/remote_files/mount/cloud_files_windows.dart) and its answers
// back: each callback copies what it needs into a WcfRequest, hands it to
// a NativeCallable.listener and returns at once; Dart answers later with
// wcf_list / wcf_data, from any thread, as Cloud Files allows.

#include <windows.h>
#include <cfapi.h>
#include <sddl.h>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Provider.h>
#include <winrt/Windows.Storage.h>

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

template <typename T>
constexpr ULONG ParamSize() {
  return static_cast<ULONG>(FIELD_OFFSET(CF_OPERATION_PARAMETERS, TransferData) +
                            sizeof(T));
}

}  // namespace

extern "C" {

// What the system asked, for Dart. Freed with wcf_free.
struct WcfRequest {
  int32_t kind;  // 1 list a folder, 2 read, 3 cancel a read
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
};

// One file or folder to show.
struct WcfEntry {
  const wchar_t* name;
  int64_t ino;
  int64_t size;
  int64_t modified;  // FILETIME
  int32_t is_dir;
  int32_t hidden;
};

typedef void (*WcfNotify)(WcfRequest* request);

}  // extern "C"

namespace {

struct Session {
  std::wstring path;
  std::wstring id;
  WcfNotify notify = nullptr;
  CF_CONNECTION_KEY key = {};
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

void CALLBACK OnFetchPlaceholders(const CF_CALLBACK_INFO* info,
                                  const CF_CALLBACK_PARAMETERS*) {
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
  SessionOf(info)->notify(request);
}

void CALLBACK OnCancelFetchData(const CF_CALLBACK_INFO* info,
                                const CF_CALLBACK_PARAMETERS* params) {
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
    // Read-only for now: nothing written here would reach the device.
    basic.FileAttributes =
        (entry.is_dir ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_READONLY) |
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

}  // namespace

extern "C" {

// Registers [path] as a sync root named [name] (its icon from [icon]) for
// [device] and connects to it. Returns the session, or 0 with [error] set.
__declspec(dllexport) int64_t wcf_start(const wchar_t* path,
                                        const wchar_t* device,
                                        const wchar_t* name,
                                        const wchar_t* icon,
                                        WcfNotify notify,
                                        int32_t* error) {
  CreateDirectoryW(path, nullptr);
  auto* session = new Session();
  session->path = path;
  session->id = std::wstring(L"Whisper!") + UserSid() + L"!" + device;
  session->notify = notify;
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
    return 0;
  }
  static const CF_CALLBACK_REGISTRATION callbacks[] = {
      {CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS, OnFetchPlaceholders},
      {CF_CALLBACK_TYPE_FETCH_DATA, OnFetchData},
      {CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, OnCancelFetchData},
      CF_CALLBACK_REGISTRATION_END};
  hr = CfConnectSyncRoot(path, callbacks, session,
                         CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
                         &session->key);
  if (FAILED(hr)) {
    *error = hr;
    std::wstring id = session->id;
    OnMtaThread([&] { StorageProviderSyncRootManager::Unregister(id); });
    delete session;
    return 0;
  }
  return reinterpret_cast<int64_t>(session);
}

// Disconnects and takes the folder out of Explorer; Dart deletes what was
// in it.
__declspec(dllexport) void wcf_stop(int64_t handle) {
  auto* session = reinterpret_cast<Session*>(handle);
  if (session == nullptr) {
    return;
  }
  CfDisconnectSyncRoot(session->key);
  std::wstring id = session->id;
  OnMtaThread([&] { StorageProviderSyncRootManager::Unregister(id); });
  delete session;
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
// nothing could be listed). The folder is left asking again each time it
// is shown, which is when what changed on the device shows up.
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
  params.TransferPlaceholders.Flags = CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_NONE;
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

// A file changed on the device: its size and time here follow, and what
// was read of it goes. On a thread of its own: updating a placeholder can
// call back into the provider, which is the very isolate calling this.
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
        nullptr, 0, CF_UPDATE_FLAG_DEHYDRATE | CF_UPDATE_FLAG_MARK_IN_SYNC,
        nullptr, nullptr);
    CfCloseHandle(handle);
  }).detach();
  return S_OK;
}

// A file that went on the device goes here too. Its placeholder is
// read-only, which DeleteFile refuses; on a thread of its own, like
// wcf_update.
__declspec(dllexport) int32_t wcf_remove(const wchar_t* file) {
  std::wstring path(file);
  std::thread([path]() {
    SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
    DeleteFileW(path.c_str());
  }).detach();
  return S_OK;
}

__declspec(dllexport) void wcf_free(WcfRequest* request) {
  delete request;
}

}  // extern "C"
