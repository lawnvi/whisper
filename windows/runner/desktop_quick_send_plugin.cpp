#include "desktop_quick_send_plugin.h"

#include "desktop_clipboard_image_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <memory>
#include <optional>
#include <utility>

namespace {

constexpr char kDesktopQuickSendChannel[] =
    "com.vireen.whisper/desktop_quick_send";
constexpr size_t kMaximumPendingCount = 32;
constexpr uint32_t kStateVersion = 2;
constexpr char kStateMagic[] = "WQSDQ01";
constexpr char kDraftLimitExceededReason[] = "draftLimitExceeded";
constexpr char kClipboardSnapshotUnavailableReason[] =
    "clipboardSnapshotUnavailable";

struct PendingEntry {
  std::string id;
  std::vector<std::string> arguments;
};

struct PendingRejection {
  std::string id;
  std::string reason;
  int32_t limit;
};

// This state is available before Flutter registers the plugin, including on a
// cold launch triggered by Explorer.
std::vector<PendingEntry> pending_before_plugin;
std::optional<PendingRejection> pending_rejection;
bool state_loaded = false;

bool IsBareQuickSendCommand(const std::vector<std::string>& arguments);
std::string NewId(const char* prefix);

std::wstring StatePath() {
  wchar_t local_app_data[32768] = {};
  const DWORD length = GetEnvironmentVariableW(
      L"LOCALAPPDATA", local_app_data,
      static_cast<DWORD>(std::size(local_app_data)));
  if (length == 0 || length >= std::size(local_app_data)) {
    return std::wstring();
  }
  std::wstring directory(local_app_data, length);
  directory += L"\\Whisper";
  if (!CreateDirectoryW(directory.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    return std::wstring();
  }
  return directory + L"\\desktop_quick_send_queue.dat";
}

void AppendUint32(std::vector<uint8_t>* output, uint32_t value) {
  output->push_back(static_cast<uint8_t>(value));
  output->push_back(static_cast<uint8_t>(value >> 8));
  output->push_back(static_cast<uint8_t>(value >> 16));
  output->push_back(static_cast<uint8_t>(value >> 24));
}

bool AppendString(std::vector<uint8_t>* output, const std::string& value) {
  if (value.size() > UINT32_MAX) {
    return false;
  }
  AppendUint32(output, static_cast<uint32_t>(value.size()));
  output->insert(output->end(), value.begin(), value.end());
  return true;
}

bool ReadUint32(const std::vector<uint8_t>& input, size_t* offset,
                uint32_t* value) {
  if (*offset > input.size() || input.size() - *offset < 4) {
    return false;
  }
  *value = static_cast<uint32_t>(input[*offset]) |
           (static_cast<uint32_t>(input[*offset + 1]) << 8) |
           (static_cast<uint32_t>(input[*offset + 2]) << 16) |
           (static_cast<uint32_t>(input[*offset + 3]) << 24);
  *offset += 4;
  return true;
}

bool ReadString(const std::vector<uint8_t>& input, size_t* offset,
                std::string* value) {
  uint32_t length = 0;
  if (!ReadUint32(input, offset, &length) ||
      *offset > input.size() || input.size() - *offset < length) {
    return false;
  }
  value->assign(reinterpret_cast<const char*>(input.data() + *offset), length);
  *offset += length;
  return true;
}

std::vector<uint8_t> EncodeState() {
  std::vector<uint8_t> output(std::begin(kStateMagic), std::end(kStateMagic));
  AppendUint32(&output, kStateVersion);
  AppendUint32(&output,
               static_cast<uint32_t>(pending_before_plugin.size()));
  for (const auto& entry : pending_before_plugin) {
    AppendString(&output, entry.id);
    AppendUint32(&output, static_cast<uint32_t>(entry.arguments.size()));
    for (const auto& argument : entry.arguments) {
      AppendString(&output, argument);
    }
  }
  AppendUint32(&output, pending_rejection.has_value() ? 1 : 0);
  if (pending_rejection.has_value()) {
    AppendString(&output, pending_rejection->id);
    AppendString(&output, pending_rejection->reason);
    AppendUint32(&output, static_cast<uint32_t>(pending_rejection->limit));
  }
  return output;
}

bool PersistState() {
  const std::wstring path = StatePath();
  if (path.empty()) {
    return false;
  }
  const std::wstring temporary = path + L".tmp";
  const std::vector<uint8_t> data = EncodeState();
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  bool saved = true;
  size_t offset = 0;
  while (offset < data.size()) {
    const DWORD requested = static_cast<DWORD>(
        std::min<size_t>(data.size() - offset, UINT32_MAX));
    DWORD written = 0;
    if (!WriteFile(file, data.data() + offset, requested, &written, nullptr) ||
        written == 0) {
      saved = false;
      break;
    }
    offset += written;
  }
  if (saved && !FlushFileBuffers(file)) {
    saved = false;
  }
  CloseHandle(file);
  if (!saved ||
      !MoveFileExW(temporary.c_str(), path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

void EnsureStateLoaded() {
  if (state_loaded) {
    return;
  }
  state_loaded = true;
  const std::wstring path = StatePath();
  if (path.empty()) {
    return;
  }
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  LARGE_INTEGER size = {};
  if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      size.QuadPart > 32 * 1024 * 1024) {
    CloseHandle(file);
    return;
  }
  std::vector<uint8_t> data(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  const bool loaded = ReadFile(file, data.data(), static_cast<DWORD>(data.size()),
                               &read, nullptr) &&
                      read == data.size();
  CloseHandle(file);
  if (!loaded || data.size() < sizeof(kStateMagic) ||
      std::memcmp(data.data(), kStateMagic, sizeof(kStateMagic)) != 0) {
    return;
  }
  size_t offset = sizeof(kStateMagic);
  uint32_t version = 0;
  uint32_t entry_count = 0;
  if (!ReadUint32(data, &offset, &version) ||
      (version != 1 && version != kStateVersion) ||
      !ReadUint32(data, &offset, &entry_count) ||
      entry_count > kMaximumPendingCount) {
    return;
  }
  std::vector<PendingEntry> decoded;
  decoded.reserve(entry_count);
  for (uint32_t index = 0; index < entry_count; ++index) {
    PendingEntry entry;
    uint32_t argument_count = 0;
    if (!ReadString(data, &offset, &entry.id) || entry.id.empty() ||
        !ReadUint32(data, &offset, &argument_count) || argument_count > 128) {
      return;
    }
    entry.arguments.reserve(argument_count);
    for (uint32_t argument_index = 0; argument_index < argument_count;
         ++argument_index) {
      std::string argument;
      if (!ReadString(data, &offset, &argument)) {
        return;
      }
      entry.arguments.emplace_back(std::move(argument));
    }
    if (entry.arguments.empty()) {
      return;
    }
    decoded.emplace_back(std::move(entry));
  }
  uint32_t has_rejection = 0;
  if (!ReadUint32(data, &offset, &has_rejection) || has_rejection > 1) {
    return;
  }
  std::optional<PendingRejection> decoded_rejection;
  if (has_rejection == 1) {
    PendingRejection rejection;
    if (!ReadString(data, &offset, &rejection.id) || rejection.id.empty()) {
      return;
    }
    if (version == 1) {
      rejection.reason = kDraftLimitExceededReason;
      rejection.limit = static_cast<int32_t>(kMaximumPendingCount);
    } else {
      uint32_t limit = 0;
      if (!ReadString(data, &offset, &rejection.reason) ||
          (rejection.reason != kDraftLimitExceededReason &&
           rejection.reason != kClipboardSnapshotUnavailableReason) ||
          !ReadUint32(data, &offset, &limit) || limit > 0x7fffffffU ||
          (rejection.reason == kDraftLimitExceededReason &&
           limit != kMaximumPendingCount) ||
          (rejection.reason == kClipboardSnapshotUnavailableReason &&
           limit != 0)) {
        return;
      }
      rejection.limit = static_cast<int32_t>(limit);
    }
    decoded_rejection = std::move(rejection);
  }
  if (offset != data.size()) {
    return;
  }
  const auto retained_end = std::remove_if(
      decoded.begin(), decoded.end(), [](const PendingEntry& entry) {
        return IsBareQuickSendCommand(entry.arguments);
      });
  const bool removed_legacy_bare = retained_end != decoded.end();
  decoded.erase(retained_end, decoded.end());
  pending_before_plugin = std::move(decoded);
  pending_rejection = std::move(decoded_rejection);
  if (removed_legacy_bare) {
    pending_rejection = PendingRejection{
        NewId("windows-rejection"), kClipboardSnapshotUnavailableReason, 0};
    // Historical bare triggers cannot be snapshotted safely: the clipboard may
    // already have changed. Persist their visible rejection before Dart reads.
    PersistState();
  }
}

bool HasQuickSendCommand(const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (argument == "--quick-send" || argument == "--quick-send-text" ||
        argument == "--quick-send-file") {
      return true;
    }
  }
  return false;
}

bool IsBareQuickSendCommand(const std::vector<std::string>& arguments) {
  const auto quick_send =
      std::find(arguments.begin(), arguments.end(), "--quick-send");
  if (quick_send == arguments.end() ||
      std::next(quick_send) != arguments.end()) {
    return false;
  }
  return std::none_of(arguments.begin(), arguments.end(), [](const auto& value) {
    return value == "--quick-send-text" || value == "--quick-send-file";
  });
}

std::string NewId(const char* prefix) {
  GUID guid = {};
  if (FAILED(CoCreateGuid(&guid))) {
    LARGE_INTEGER counter = {};
    QueryPerformanceCounter(&counter);
    char fallback[64] = {};
    sprintf_s(fallback, "%s-%lu-%lld", prefix, GetCurrentProcessId(),
              counter.QuadPart);
    return fallback;
  }
  char value[96] = {};
  sprintf_s(value,
            "%s-%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            prefix, guid.Data1, guid.Data2, guid.Data3, guid.Data4[0],
            guid.Data4[1], guid.Data4[2], guid.Data4[3], guid.Data4[4],
            guid.Data4[5], guid.Data4[6], guid.Data4[7]);
  return value;
}

flutter::EncodableValue EntryValue(const PendingEntry& entry) {
  flutter::EncodableList arguments;
  arguments.reserve(entry.arguments.size());
  for (const auto& argument : entry.arguments) {
    arguments.emplace_back(argument);
  }
  flutter::EncodableMap value;
  value[flutter::EncodableValue("id")] = flutter::EncodableValue(entry.id);
  value[flutter::EncodableValue("arguments")] =
      flutter::EncodableValue(std::move(arguments));
  return flutter::EncodableValue(std::move(value));
}

flutter::EncodableValue RejectionValue(const PendingRejection& rejection) {
  flutter::EncodableMap details;
  details[flutter::EncodableValue("reason")] =
      flutter::EncodableValue(rejection.reason);
  details[flutter::EncodableValue("limit")] =
      flutter::EncodableValue(rejection.limit);
  flutter::EncodableMap value;
  value[flutter::EncodableValue("id")] = flutter::EncodableValue(rejection.id);
  value[flutter::EncodableValue("rejection")] =
      flutter::EncodableValue(std::move(details));
  return flutter::EncodableValue(std::move(value));
}

bool Acknowledge(const std::string& id) {
  EnsureStateLoaded();
  if (pending_rejection.has_value() && pending_rejection->id == id) {
    const auto previous = pending_rejection;
    pending_rejection.reset();
    if (PersistState()) {
      return true;
    }
    pending_rejection = previous;
    return false;
  }
  const auto iterator = std::find_if(
      pending_before_plugin.begin(), pending_before_plugin.end(),
      [&id](const PendingEntry& entry) { return entry.id == id; });
  if (iterator == pending_before_plugin.end()) {
    return true;
  }
  const size_t index =
      static_cast<size_t>(iterator - pending_before_plugin.begin());
  PendingEntry removed = std::move(*iterator);
  pending_before_plugin.erase(iterator);
  if (PersistState()) {
    return true;
  }
  pending_before_plugin.insert(pending_before_plugin.begin() + index,
                               std::move(removed));
  return false;
}

class DesktopQuickSendPlugin : public flutter::Plugin {
 public:
  explicit DesktopQuickSendPlugin(
      flutter::PluginRegistrarWindows* registrar)
      : channel_(std::make_unique<
                 flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), kDesktopQuickSendChannel,
            &flutter::StandardMethodCodec::GetInstance())) {
    EnsureStateLoaded();
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "consumePendingQuickSends") {
        flutter::EncodableList pending;
        pending.reserve(pending_before_plugin.size() +
                        (pending_rejection.has_value() ? 1 : 0));
        for (const auto& entry : pending_before_plugin) {
          pending.emplace_back(EntryValue(entry));
        }
        if (pending_rejection.has_value()) {
          pending.emplace_back(RejectionValue(*pending_rejection));
        }
        result->Success(flutter::EncodableValue(std::move(pending)));
        return;
      }
      if (call.method_name() == "acknowledgeQuickSend") {
        const auto* id = std::get_if<std::string>(call.arguments());
        result->Success(flutter::EncodableValue(
            id != nullptr && Acknowledge(*id)));
        return;
      }
      result->NotImplemented();
    });
    instance_ = this;
    WakeDart();
  }

  ~DesktopQuickSendPlugin() override {
    if (instance_ == this) {
      instance_ = nullptr;
    }
  }

  void WakeDart() {
    if (!pending_before_plugin.empty() || pending_rejection.has_value()) {
      channel_->InvokeMethod("quickSendReceived", nullptr);
    }
  }

  static DesktopQuickSendPlugin* instance() { return instance_; }

 private:
  static DesktopQuickSendPlugin* instance_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

DesktopQuickSendPlugin* DesktopQuickSendPlugin::instance_ = nullptr;

}  // namespace

void DesktopQuickSendPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  plugin_registrar->AddPlugin(
      std::make_unique<DesktopQuickSendPlugin>(plugin_registrar));
}

DesktopQuickSendEnqueueOutcome DesktopQuickSendPluginEmitArguments(
    const std::vector<std::string>& arguments) {
  if (!HasQuickSendCommand(arguments)) {
    return DesktopQuickSendEnqueueOutcome::kIgnored;
  }
  EnsureStateLoaded();

  std::optional<std::vector<std::string>> clipboard_arguments;
  const std::vector<std::string>* queued_arguments = &arguments;
  if (IsBareQuickSendCommand(arguments)) {
    clipboard_arguments = DesktopClipboardSnapshotQuickSendArguments();
    if (!clipboard_arguments.has_value()) {
      const auto previous = pending_rejection;
      pending_rejection = PendingRejection{
          NewId("windows-rejection"), kClipboardSnapshotUnavailableReason, 0};
      if (!PersistState()) {
        pending_rejection = previous;
      }
      if (auto* plugin = DesktopQuickSendPlugin::instance()) {
        plugin->WakeDart();
      }
      return DesktopQuickSendEnqueueOutcome::kRejected;
    }
    queued_arguments = &*clipboard_arguments;
  }

  if (pending_before_plugin.size() >= kMaximumPendingCount) {
    const auto previous = pending_rejection;
    pending_rejection = PendingRejection{
        NewId("windows-rejection"), kDraftLimitExceededReason,
        static_cast<int32_t>(kMaximumPendingCount)};
    if (!PersistState()) {
      pending_rejection = previous;
    }
    if (auto* plugin = DesktopQuickSendPlugin::instance()) {
      plugin->WakeDart();
    }
    return DesktopQuickSendEnqueueOutcome::kRejected;
  }
  pending_before_plugin.push_back(
      PendingEntry{NewId("windows"), *queued_arguments});
  if (!PersistState()) {
    pending_before_plugin.pop_back();
    return DesktopQuickSendEnqueueOutcome::kRejected;
  }
  if (auto* plugin = DesktopQuickSendPlugin::instance()) {
    plugin->WakeDart();
  }
  return DesktopQuickSendEnqueueOutcome::kAccepted;
}
