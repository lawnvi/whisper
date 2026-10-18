// W5: crash recovery. A child process stages a window off-screen, writes
// the journal and exits WITHOUT restoring (simulating a crash); then this
// process recovers from the journal and checks the window is back where it
// was, with its style restored.
//
// W6: elevated / higher-integrity windows. Enumerate top-level windows,
// classify each by process elevation, and confirm input injection to an
// elevated window is refused (so the catalog must exclude them).
#include "probe.h"

#include "core/wsn_journal.h"
#include "core/wsn_stage.h"
#include "core/wsn_wgc.h"
#include "core/wsn_window.h"

#include <string>

namespace probe {

namespace {
std::string RectText(const RECT& r) {
  return wsn::Format("%ld,%ld %dx%d", r.left, r.top, r.right - r.left, r.bottom - r.top);
}
}  // namespace

// Child mode: stage [hwnd], journal it, and (unless --restore) leave it.
int RunStageAndLeave(const Args& args) {
  HWND window = reinterpret_cast<HWND>(static_cast<intptr_t>(_wtoi64(args.Get(L"--hwnd").c_str())));
  if (!IsWindow(window)) return 2;
  std::wstring journal_path = args.Get(L"--journal");
  wsn::Journal journal(journal_path);
  wsn::Placement home = wsn::SavePlacement(window);
  wsn::Borders borders = wsn::InvisibleBorders(window);
  RECT spot{};
  wsn::StageSpot(0, wsn::RectWidth(home.rect), wsn::RectHeight(home.rect), borders, &spot);
  wsn::StyleBackup style;
  wsn::ApplyStageStyle(window, &style);
  wsn::JournalEntry entry;
  entry.window_id = static_cast<uint32_t>(reinterpret_cast<intptr_t>(window));
  entry.pid = wsn::WindowPid(window);
  entry.process_start = wsn::ProcessStartTime(entry.pid);
  entry.ex_style = style.ex_style;
  entry.had_attributes = style.had_attributes;
  entry.alpha = style.alpha;
  entry.placement = home;
  journal.Upsert(entry);
  wsn::MoveWindowTo(window, spot);
  // Exit without restoring: a crash.
  return 0;
}

int RunW5(const Args& args) {
  TestWindow tw;
  if (!LaunchTestWindow(L"w5", 800, 600, &tw)) return 1;
  Sleep(600);
  HWND window = tw.hwnd;
  wsn::Placement home = wsn::SavePlacement(window);
  LONG_PTR home_ex = GetWindowLongPtrW(window, GWL_EXSTYLE);
  RECT home_rect{};
  GetWindowRect(window, &home_rect);
  Log("test window at %s ex 0x%llx", RectText(home_rect).c_str(), static_cast<unsigned long long>(home_ex));

  std::wstring journal_path = g_out + L"\\staged.json";
  DeleteFileW(journal_path.c_str());

  // Launch a child that stages this window and "crashes" (exits without
  // restoring). The window keeps running in our process tree's sight.
  wchar_t self[MAX_PATH];
  GetModuleFileNameW(nullptr, self, MAX_PATH);
  std::wstring command = std::wstring(L"\"") + self + L"\" stageleave --hwnd " +
                         std::to_wstring(reinterpret_cast<intptr_t>(window)) + L" --journal \"" + journal_path +
                         L"\"";
  STARTUPINFOW startup{sizeof(startup)};
  PROCESS_INFORMATION child{};
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &child)) {
    Log("child launch failed %lu", GetLastError());
    CloseTestWindow(&tw);
    return 1;
  }
  WaitForSingleObject(child.hProcess, 10000);
  CloseHandle(child.hProcess);
  CloseHandle(child.hThread);
  Sleep(400);

  RECT after_crash{};
  GetWindowRect(window, &after_crash);
  bool off_screen = !wsn::OnAnyMonitor(after_crash, 0.01);
  bool styled = wsn::HasStageStyle(window);
  std::string journal_text;
  wsn::ReadFileBytes(journal_path, &journal_text);
  Log("after 'crash': window at %s off-screen %d staged-style %d; journal: %s", RectText(after_crash).c_str(),
      off_screen, styled, journal_text.c_str());

  // Recovery, as the host does on wsn_set_capture_callback.
  wsn::Journal journal(journal_path);
  for (const auto& line : wsn::RecoverStaged(&journal)) Log("recover: %s", line.c_str());
  Sleep(400);

  RECT recovered{};
  GetWindowRect(window, &recovered);
  bool back = wsn::SameRect(recovered, home_rect, 2);
  LONG_PTR ex = GetWindowLongPtrW(window, GWL_EXSTYLE);
  bool journal_cleared = !wsn::ReadFileBytes(journal_path, &journal_text);
  Log("after recovery: window at %s (home %s) match %d; ex 0x%llx (home 0x%llx) match %d; journal cleared %d",
      RectText(recovered).c_str(), RectText(home_rect).c_str(), back, static_cast<unsigned long long>(ex),
      static_cast<unsigned long long>(home_ex), ex == home_ex, journal_cleared);

  WriteText(L"w5.json",
            wsn::Format("{\"offScreenAfterCrash\":%d,\"styledAfterCrash\":%d,\"restoredRect\":%d,"
                        "\"restoredStyle\":%d,\"journalCleared\":%d}\n",
                        off_screen, styled, back, ex == home_ex, journal_cleared));
  CloseTestWindow(&tw);
  return back && ex == home_ex ? 0 : 1;
}

int RunW6(const Args&) {
  Log("self integrity level 0x%x, elevated %d", wsn::SelfIntegrityLevel(), wsn::SelfElevated());
  int injectable = 0, higher = 0, unknown = 0;
  std::vector<std::string> excluded;
  HWND higher_window = nullptr;
  for (HWND w : TopLevelWindows()) {
    if (!IsWindowVisible(w) || wsn::IsCloaked(w)) continue;
    HWND core = wsn::HostedCoreWindow(w);
    DWORD pid = wsn::WindowPid(core ? core : w);
    int level = wsn::ProcessIntegrityLevel(pid);
    if (level < 0) {
      unknown++;
    } else if (level > wsn::SelfIntegrityLevel()) {
      higher++;
      if (higher_window == nullptr) higher_window = w;
      if (excluded.size() < 10) {
        excluded.push_back(wsn::Format("0x%x ", level) + wsn::Narrow(wsn::WindowClass(w)) + " / " +
                           wsn::Narrow(wsn::WindowTitle(w)));
      }
    } else {
      injectable++;
    }
  }
  Log("visible top-level windows: %d injectable (<= our integrity), %d higher-integrity (excluded), %d unreadable",
      injectable, higher, unknown);
  for (const auto& title : excluded) Log("  excluded: %s", title.c_str());

  // Confirm a higher-integrity window refuses a posted message (UIPI). On a
  // machine with UAC off everything runs at High, so there may be none.
  bool injection_blocked_observed = false;
  if (higher_window != nullptr) {
    SetLastError(0);
    BOOL ok = PostMessageW(higher_window, WM_NULL, 0, 0);
    DWORD err = GetLastError();
    Log("post WM_NULL to higher-integrity %p (%s): ok %d err %lu (ERROR_ACCESS_DENIED=5)", higher_window,
        wsn::Narrow(wsn::WindowClass(higher_window)).c_str(), ok, err);
    injection_blocked_observed = !ok && err == ERROR_ACCESS_DENIED;
  } else {
    Log("no higher-integrity window to test against (UAC may be off: all processes run at our level)");
  }
  Log("rule: the catalog excludes a window only when its integrity is higher than ours (UIPI blocks injecting up)");
  WriteText(L"w6.json",
            wsn::Format("{\"selfIntegrity\":%d,\"injectable\":%d,\"higherIntegrity\":%d,\"unreadable\":%d,"
                        "\"injectionBlockedObserved\":%d,\"uacDisabled\":%d}\n",
                        wsn::SelfIntegrityLevel(), injectable, higher, unknown, injection_blocked_observed,
                        wsn::SelfIntegrityLevel() >= 0x3000 && !wsn::SelfElevated() ? 0 : (higher == 0 ? 1 : 0)));
  return 0;
}

}  // namespace probe
