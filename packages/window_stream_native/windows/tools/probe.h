// wsn_probe: measures what Windows lets a window-stream source do (probes
// W1–W6), runs the test window, and drives the plugin DLL through its C ABI.
#pragma once

#include "core/wsn_image.h"
#include "core/wsn_stage.h"
#include "core/wsn_util.h"

#include <functional>
#include <set>
#include <string>
#include <vector>

namespace probe {

struct Args {
  std::vector<std::wstring> items;
  std::wstring Get(const wchar_t* key, const std::wstring& fallback = L"") const;
  int Int(const wchar_t* key, int fallback) const;
  bool Has(const wchar_t* flag) const;
};

// Output directory of the running command (created by main).
extern std::wstring g_out;

void Log(const char* format, ...);
// Appends a line to <out>/<name>.
void WriteText(const std::wstring& name, const std::string& text);

// A test window in a child process of the probe.
struct TestWindow {
  PROCESS_INFORMATION process{};
  HWND hwnd = nullptr;
  HWND edit = nullptr;
  HWND combo = nullptr;
  DWORD pid = 0;
  std::wstring log_path;
  wsn::StyleBackup style_restore;
};
bool LaunchTestWindow(const std::wstring& tag, int width, int height, TestWindow* out,
                      const std::wstring& extra = L"");
void CloseTestWindow(TestWindow* window);
// Lines of the test window's input log appended since [*offset].
std::vector<std::string> ReadNewLines(const std::wstring& path, size_t* offset);

std::set<HWND> TopLevelWindows();
// A new visible top-level window (not in [before]) that [match] accepts.
HWND WaitNewWindow(const std::set<HWND>& before, const std::function<bool(HWND)>& match, int timeout_ms);

// The 16-bit frame counter the test window paints, read from [frame]
// (a picture of the window's visible frame). -1 when unreadable.
int DecodeCounter(const wsn::Bitmap& bitmap, HWND test_window);

int RunTestWindow(const Args& args);
int RunInfo(const Args& args);
int RunList(const Args& args);
int RunW1(const Args& args);
int RunW2(const Args& args);
int RunW2b(const Args& args);
int RunW2x(const Args& args);
int RunW3(const Args& args);
int RunW4(const Args& args);
int RunW5(const Args& args);
int RunW6(const Args& args);
int RunAbi(const Args& args);
int RunAbiApp(const std::wstring& app);
int RunStageAndLeave(const Args& args);
int RunXaml(const Args& args);
int RunAudioCheck(const Args& args);

}  // namespace probe
