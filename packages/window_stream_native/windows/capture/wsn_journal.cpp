#include "wsn_journal.h"

#include "wsn_stage.h"

#include <cstdlib>

namespace wsn {

Journal::Journal(std::wstring path) : path_(std::move(path)) {
  if (path_.empty()) {
    std::wstring dir = StateDirectory();
    if (!dir.empty()) path_ = dir + L"\\staged.json";
  }
}

void Journal::Upsert(const JournalEntry& entry) {
  for (auto& existing : entries_) {
    if (existing.window_id == entry.window_id) {
      existing = entry;
      Save();
      return;
    }
  }
  entries_.push_back(entry);
  Save();
}

void Journal::Remove(uint32_t window_id) {
  size_t before = entries_.size();
  entries_.erase(std::remove_if(entries_.begin(), entries_.end(),
                                [&](const JournalEntry& e) { return e.window_id == window_id; }),
                 entries_.end());
  if (entries_.size() != before) Save();
}

std::string Journal::ToJson() const {
  std::string out = "{\"version\":1,\"windows\":[";
  for (size_t i = 0; i < entries_.size(); ++i) {
    const auto& e = entries_[i];
    out += wsn::Format(
        "{\"windowId\":%u,\"pid\":%lu,\"start\":%llu,\"ex\":%lld,\"hadAttributes\":%d,\"alpha\":%u,",
        e.window_id, e.pid, static_cast<unsigned long long>(e.process_start),
        static_cast<long long>(e.ex_style), e.had_attributes ? 1 : 0, e.alpha);
    out += PlacementJson(e.placement);
    out += "}";
    if (i + 1 < entries_.size()) out += ",";
  }
  out += "]}";
  return out;
}

bool Journal::FromJson(const std::string& json, std::vector<JournalEntry>* out) {
  size_t pos = json.find("\"windows\"");
  if (pos == std::string::npos) return false;
  // Each window object is a flat run between '{' and '}'.
  size_t array = json.find('[', pos);
  if (array == std::string::npos) return false;
  size_t i = array;
  while ((i = json.find('{', i)) != std::string::npos) {
    size_t end = json.find('}', i);
    if (end == std::string::npos) break;
    std::string obj = json.substr(i, end - i + 1);
    JournalEntry entry;
    long long v = 0;
    if (JsonInt(obj, "windowId", &v)) entry.window_id = static_cast<uint32_t>(v);
    if (JsonInt(obj, "pid", &v)) entry.pid = static_cast<DWORD>(v);
    if (JsonInt(obj, "start", &v)) entry.process_start = static_cast<uint64_t>(v);
    if (JsonInt(obj, "ex", &v)) entry.ex_style = static_cast<LONG_PTR>(v);
    if (JsonInt(obj, "hadAttributes", &v)) entry.had_attributes = v != 0;
    if (JsonInt(obj, "alpha", &v)) entry.alpha = static_cast<BYTE>(v);
    if (PlacementFromJson(obj, &entry.placement)) out->push_back(entry);
    i = end + 1;
  }
  return true;
}

void Journal::Clear() {
  entries_.clear();
  if (!path_.empty()) DeleteFileW(path_.c_str());
}

bool Journal::Load() {
  entries_.clear();
  if (path_.empty()) return false;
  std::string json;
  if (!ReadFileBytes(path_, &json)) return false;
  return FromJson(json, &entries_);
}

bool Journal::Save() const {
  if (path_.empty()) return false;
  if (entries_.empty()) {
    DeleteFileW(path_.c_str());
    return true;
  }
  return WriteFileAtomic(path_, ToJson());
}

std::vector<std::string> RecoverStaged(Journal* journal) {
  std::vector<std::string> log;
  if (!journal->Load()) return log;
  for (const auto& entry : journal->entries()) {
    HWND window = reinterpret_cast<HWND>(static_cast<intptr_t>(static_cast<int32_t>(entry.window_id)));
    if (!IsWindow(window)) {
      log.push_back(Format("window 0x%08x gone", entry.window_id));
      continue;
    }
    DWORD pid = WindowPid(window);
    if (pid != entry.pid || (entry.process_start != 0 && ProcessStartTime(pid) != entry.process_start)) {
      // The HWND belongs to a different process now: do not touch it.
      log.push_back(Format("window 0x%08x now another process, skipped", entry.window_id));
      continue;
    }
    // Already back (the exit-time restore did it): leave it where the user
    // may have moved it since.
    RECT rect{};
    GetWindowRect(window, &rect);
    if (!HasStageStyle(window) && (IsIconic(window) || OnAnyMonitor(rect, 0.5))) {
      log.push_back(Format("window 0x%08x already back", entry.window_id));
      continue;
    }
    // Put the original style back (clear our layered/transparent bits).
    LONG_PTR now = GetWindowLongPtrW(window, GWL_EXSTYLE);
    LONG_PTR ours = WS_EX_LAYERED | WS_EX_TRANSPARENT;
    SetWindowLongPtrW(window, GWL_EXSTYLE, (now & ~ours) | (entry.ex_style & ours));
    if ((entry.ex_style & WS_EX_LAYERED) && entry.had_attributes) {
      SetLayeredWindowAttributes(window, 0, entry.alpha, LWA_ALPHA);
    }
    bool ok = RestorePlacement(window, entry.placement);
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    log.push_back(Format("window 0x%08x restored %s", entry.window_id, ok ? "exactly" : "approximately"));
  }
  journal->Clear();
  return log;
}

}  // namespace wsn
