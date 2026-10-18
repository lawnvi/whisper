// A crash-safe record of windows moved off-screen for streaming, so a run
// that is killed while windows are staged can put them back next time the
// host starts (wsn_set_capture_callback). Each window's placement and
// original style are stored, keyed by HWND, pid and process start time (so a
// recycled HWND of a different process is never "restored").
//
// Written atomically to %LOCALAPPDATA%\Whisper\window_stream\staged.json.
#pragma once

#include "wsn_window.h"

#include <algorithm>
#include <string>
#include <vector>

namespace wsn {

struct JournalEntry {
  uint32_t window_id = 0;  // HWND as uint32 (sign-extended back on use)
  DWORD pid = 0;
  uint64_t process_start = 0;
  LONG_PTR ex_style = 0;    // the window's style before staging
  bool had_attributes = false;
  BYTE alpha = 255;
  Placement placement;
};

class Journal {
 public:
  explicit Journal(std::wstring path = std::wstring());

  void Upsert(const JournalEntry& entry);
  void Remove(uint32_t window_id);
  const std::vector<JournalEntry>& entries() const { return entries_; }

  bool Load();
  bool Save() const;
  void Clear();

  std::string ToJson() const;
  static bool FromJson(const std::string& json, std::vector<JournalEntry>* out);

 private:
  std::wstring path_;
  std::vector<JournalEntry> entries_;
};

// Puts back every window the journal lists that is still the same process,
// still off every monitor, restoring its placement and style. Returns a log
// line per window. Clears the journal afterwards.
std::vector<std::string> RecoverStaged(Journal* journal);

}  // namespace wsn
