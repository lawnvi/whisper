// Entry point of wsn_probe.exe. Usage:
//   wsn_probe <command> [--out dir] [options]
// Commands: testwin, info, w1, w2, w2b, w3, w4, w5, w6, abi.
#include "probe.h"

#include "core/wsn_image.h"
#include "core/wsn_window.h"

#include <dbghelp.h>
#include <shellapi.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <cstdio>
#include <mutex>

namespace probe {

std::wstring g_out;
std::vector<HANDLE> g_children;
namespace {
std::mutex g_log_mutex;
FILE* g_log = nullptr;
}  // namespace

std::wstring Args::Get(const wchar_t* key, const std::wstring& fallback) const {
  for (size_t i = 0; i + 1 < items.size(); ++i) {
    if (items[i] == key) return items[i + 1];
  }
  return fallback;
}

int Args::Int(const wchar_t* key, int fallback) const {
  std::wstring value = Get(key);
  return value.empty() ? fallback : _wtoi(value.c_str());
}

bool Args::Has(const wchar_t* flag) const {
  for (const auto& item : items) {
    if (item == flag) return true;
  }
  return false;
}

void Log(const char* format, ...) {
  char buffer[4096];
  va_list args;
  va_start(args, format);
  vsnprintf(buffer, sizeof(buffer), format, args);
  va_end(args);
  std::lock_guard<std::mutex> lock(g_log_mutex);
  std::string line = wsn::Format("[%10.1f] %s\n", wsn::NowMs(), buffer);
  fputs(line.c_str(), stdout);
  fflush(stdout);
  if (g_log) {
    fputs(line.c_str(), g_log);
    fflush(g_log);
  }
}

void WriteText(const std::wstring& name, const std::string& text) {
  std::wstring path = g_out + L"\\" + name;
  FILE* file = _wfopen(path.c_str(), L"ab");
  if (!file) return;
  fwrite(text.data(), 1, text.size(), file);
  fclose(file);
}

std::set<HWND> TopLevelWindows() {
  std::set<HWND> windows;
  EnumWindows(
      [](HWND window, LPARAM data) -> BOOL {
        reinterpret_cast<std::set<HWND>*>(data)->insert(window);
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&windows));
  return windows;
}

HWND WaitNewWindow(const std::set<HWND>& before, const std::function<bool(HWND)>& match, int timeout_ms) {
  double end = wsn::NowMs() + timeout_ms;
  while (wsn::NowMs() < end) {
    for (HWND window : TopLevelWindows()) {
      if (before.count(window) || !IsWindowVisible(window) || wsn::IsCloaked(window)) continue;
      if (match(window)) return window;
    }
    Sleep(100);
  }
  return nullptr;
}

bool LaunchTestWindow(const std::wstring& tag, int width, int height, TestWindow* out, const std::wstring& extra) {
  wchar_t self[MAX_PATH];
  GetModuleFileNameW(nullptr, self, MAX_PATH);
  std::wstring info = g_out + L"\\testwin_" + tag + L".json";
  out->log_path = g_out + L"\\testwin_" + tag + L".log";
  DeleteFileW(info.c_str());
  DeleteFileW(out->log_path.c_str());
  std::wstring command = L"\"" + std::wstring(self) + L"\" testwin --tag " + tag + L" --w " +
                         std::to_wstring(width) + L" --h " + std::to_wstring(height) + L" --info \"" + info +
                         L"\" --log \"" + out->log_path + L"\" " + extra;
  STARTUPINFOW startup{sizeof(startup)};
  // No standard handles: otherwise the window (which may outlive this
  // process) keeps the caller's redirected log file open.
  startup.dwFlags = STARTF_USESTDHANDLES;
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup,
                      &out->process)) {
    Log("CreateProcess testwin failed %lu", GetLastError());
    return false;
  }
  out->pid = out->process.dwProcessId;
  g_children.push_back(out->process.hProcess);
  double end = wsn::NowMs() + 8000;
  while (wsn::NowMs() < end) {
    std::string json;
    if (wsn::ReadFileBytes(info, &json) && json.find('}') != std::string::npos) {
      long long hwnd = 0, edit = 0, combo = 0;
      wsn::JsonInt(json, "hwnd", &hwnd);
      wsn::JsonInt(json, "edit", &edit);
      wsn::JsonInt(json, "combo", &combo);
      out->hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(hwnd));
      out->edit = reinterpret_cast<HWND>(static_cast<intptr_t>(edit));
      out->combo = reinterpret_cast<HWND>(static_cast<intptr_t>(combo));
      return IsWindow(out->hwnd) != FALSE;
    }
    Sleep(50);
  }
  Log("test window did not come up");
  return false;
}

void CloseTestWindow(TestWindow* window) {
  if (window->hwnd && IsWindow(window->hwnd)) PostMessageW(window->hwnd, WM_CLOSE, 0, 0);
  if (window->process.hProcess) {
    if (WaitForSingleObject(window->process.hProcess, 3000) != WAIT_OBJECT_0) {
      TerminateProcess(window->process.hProcess, 1);
    }
    g_children.erase(std::remove(g_children.begin(), g_children.end(), window->process.hProcess),
                     g_children.end());
    CloseHandle(window->process.hProcess);
    CloseHandle(window->process.hThread);
  }
  window->process = {};
  window->hwnd = nullptr;
}

std::vector<std::string> ReadNewLines(const std::wstring& path, size_t* offset) {
  std::vector<std::string> lines;
  std::string all;
  if (!wsn::ReadFileBytes(path, &all) || all.size() <= *offset) return lines;
  size_t end = all.rfind('\n');
  if (end == std::string::npos || end < *offset) return lines;
  size_t start = *offset;
  while (start <= end) {
    size_t next = all.find('\n', start);
    if (next == std::string::npos || next > end) break;
    std::string line = all.substr(start, next - start);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    lines.push_back(line);
    start = next + 1;
  }
  *offset = end + 1;
  return lines;
}

// Reads the canonical frame counter (agent E's layout): a 20x2-cell code at
// cell (1,1) of a 22x4 grey quiet zone whose top-left is (16,16) client px.
// Row 0 = guard W B W B then bits 15..0 (1=white); row 1 = row 0 inverted.
// [test_window] gives the expected geometry; [bitmap] is a picture of the
// window's visible frame (screen screenshot) or its client content (WGC).
int DecodeCounter(const wsn::Bitmap& bitmap, HWND test_window) {
  if (bitmap.empty()) return -1;
  RECT frame = wsn::FrameBounds(test_window);
  RECT client{};
  GetClientRect(test_window, &client);
  POINT origin{0, 0};
  ClientToScreen(test_window, &origin);
  if (wsn::RectWidth(frame) <= 0 || wsn::RectHeight(frame) <= 0) return -1;
  UINT dpi = GetDpiForWindow(test_window);
  int cell_client = std::max(3, MulDiv(16, dpi, 96));
  // Client-space span of the frame picture: the frame includes the invisible
  // border, so client (0,0) maps to (origin - frame.left/top) in frame px.
  double sx = static_cast<double>(bitmap.width) / wsn::RectWidth(frame);
  double sy = static_cast<double>(bitmap.height) / wsn::RectHeight(frame);
  double cell = cell_client * (sx + sy) / 2.0;
  // The code's top-left in client px is (16 + cell_client, 16 + cell_client).
  double ox = (origin.x - frame.left + 16 + cell_client) * sx;
  double oy = (origin.y - frame.top + 16 + cell_client) * sy;
  auto cellIsWhite = [&](int col, int row, int* ok) -> bool {
    double x = ox + (col + 0.5) * cell;
    double y = oy + (row + 0.5) * cell;
    int px = static_cast<int>(x), py = static_cast<int>(y);
    if (px < 0 || py < 0 || px >= bitmap.width || py >= bitmap.height) {
      *ok = 0;
      return false;
    }
    *ok = 1;
    const uint8_t* p = bitmap.pixel(px, py);
    return (p[0] + p[1] * 2 + p[2]) / 4 > 128;
  };
  const bool guard[4] = {true, false, true, false};
  int ok = 0;
  for (int col = 0; col < 4; ++col) {
    bool w = cellIsWhite(col, 0, &ok);
    if (!ok || w != guard[col]) return -1;
    bool wl = cellIsWhite(col, 1, &ok);
    if (!ok || wl == guard[col]) return -1;  // row 1 must be inverted
  }
  int value = 0;
  for (int bit = 0; bit < 16; ++bit) {
    bool top = cellIsWhite(4 + bit, 0, &ok);
    if (!ok) return -1;
    bool bottom = cellIsWhite(4 + bit, 1, &ok);
    if (!ok || top == bottom) return -1;  // complement check
    value = (value << 1) | (top ? 1 : 0);
  }
  return value;
}

int RunList(const Args& args) {
  if (!args.Get(L"--close").empty()) {
    HWND target = reinterpret_cast<HWND>(static_cast<intptr_t>(_wcstoui64(args.Get(L"--close").c_str(), nullptr, 16)));
    Log("closing %p class %s: %d", target, wsn::Narrow(wsn::WindowClass(target)).c_str(),
        PostMessageW(target, WM_SYSCOMMAND, SC_CLOSE, 0));
    Sleep(2000);
  }
  if (!args.Get(L"--launch").empty()) {
    ShellExecuteW(nullptr, nullptr, args.Get(L"--launch").c_str(), nullptr, nullptr, SW_SHOWNOACTIVATE);
    Sleep(args.Int(L"--wait", 4000));
  }
  for (HWND w : TopLevelWindows()) {
    if (!IsWindowVisible(w) && !args.Has(L"--all")) continue;
    DWORD cloak = 0;
    wsn::IsCloaked(w, &cloak);
    HWND core = wsn::HostedCoreWindow(w);
    DWORD pid = wsn::WindowPid(w);
    std::wstring exe = wsn::ProcessImagePath(core ? wsn::WindowPid(core) : pid);
    RECT f = wsn::FrameBounds(w);
    HWND owner = GetWindow(w, GW_OWNER);
    LONG_PTR ex = GetWindowLongPtrW(w, GWL_EXSTYLE);
    LONG_PTR style = GetWindowLongPtrW(w, GWL_STYLE);
    Log("%p vis %d cloak %lu owner %p ex 0x%llx style 0x%llx class %s title %s exe %s core %p frame %ld,%ld %dx%d "
        "aumid %s",
        w, IsWindowVisible(w), cloak, owner, static_cast<unsigned long long>(ex),
        static_cast<unsigned long long>(style), wsn::Narrow(wsn::WindowClass(w)).c_str(),
        wsn::Narrow(wsn::WindowTitle(w)).c_str(), wsn::Narrow(exe).c_str(), core, f.left, f.top,
        wsn::RectWidth(f), wsn::RectHeight(f), wsn::Narrow(wsn::WindowAumid(w)).c_str());
  }
  return 0;
}

int RunInfo(const Args&) {
  RECT vs = wsn::VirtualScreen();
  Log("virtual screen %ld,%ld %dx%d", vs.left, vs.top, wsn::RectWidth(vs), wsn::RectHeight(vs));
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM) -> BOOL {
        MONITORINFOEXW info{};
        info.cbSize = sizeof(info);
        GetMonitorInfoW(monitor, &info);
        UINT dx = 0, dy = 0;
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dx, &dy);
        Log("monitor %s rect %ld,%ld,%ld,%ld work %ld,%ld,%ld,%ld dpi %u primary %d",
            wsn::Narrow(info.szDevice).c_str(), info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right,
            info.rcMonitor.bottom, info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom, dx,
            (info.dwFlags & MONITORINFOF_PRIMARY) ? 1 : 0);
        return TRUE;
      },
      0);
  Log("self elevated %d, session %lu", wsn::SelfElevated() ? 1 : 0, WTSGetActiveConsoleSessionId());
  HDESK desk = OpenInputDesktop(0, FALSE, GENERIC_READ);
  wchar_t name[128] = L"?";
  if (desk) {
    GetUserObjectInformationW(desk, UOI_NAME, name, sizeof(name), nullptr);
    CloseDesktop(desk);
  }
  Log("input desktop %s (open %d)", wsn::Narrow(name).c_str(), desk != nullptr);
  HWND foreground = GetForegroundWindow();
  Log("foreground %p class %s pid %lu", foreground, wsn::Narrow(wsn::WindowClass(foreground)).c_str(),
      wsn::WindowPid(foreground));
  return 0;
}

LONG WINAPI OnCrash(EXCEPTION_POINTERS* info) {
  HANDLE process = GetCurrentProcess();
  SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME);
  SymInitialize(process, nullptr, TRUE);
  CONTEXT context = *info->ContextRecord;
  STACKFRAME64 frame{};
  frame.AddrPC.Offset = context.Rip;
  frame.AddrPC.Mode = AddrModeFlat;
  frame.AddrFrame.Offset = context.Rbp;
  frame.AddrFrame.Mode = AddrModeFlat;
  frame.AddrStack.Offset = context.Rsp;
  frame.AddrStack.Mode = AddrModeFlat;
  Log("CRASH code 0x%08lx at %p", info->ExceptionRecord->ExceptionCode, info->ExceptionRecord->ExceptionAddress);
  for (int depth = 0; depth < 24; ++depth) {
    if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, process, GetCurrentThread(), &frame, &context, nullptr,
                     SymFunctionTableAccess64, SymGetModuleBase64, nullptr)) {
      break;
    }
    char buffer[sizeof(SYMBOL_INFO) + 256] = {};
    auto* symbol = reinterpret_cast<SYMBOL_INFO*>(buffer);
    symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
    symbol->MaxNameLen = 255;
    DWORD64 displacement = 0;
    IMAGEHLP_LINE64 line{sizeof(line)};
    DWORD line_displacement = 0;
    bool named = SymFromAddr(process, frame.AddrPC.Offset, &displacement, symbol) != FALSE;
    bool lined = SymGetLineFromAddr64(process, frame.AddrPC.Offset, &line_displacement, &line) != FALSE;
    Log("  #%d %s %s:%lu", depth, named ? symbol->Name : "?", lined ? line.FileName : "?",
        lined ? line.LineNumber : 0);
  }
  if (g_log) fflush(g_log);
  for (HANDLE child : g_children) TerminateProcess(child, 1);
  return EXCEPTION_EXECUTE_HANDLER;
}

}  // namespace probe

int wmain(int argc, wchar_t** argv) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  SetConsoleOutputCP(CP_UTF8);
  SetUnhandledExceptionFilter(probe::OnCrash);
  if (argc < 2) {
    fputs("usage: wsn_probe <testwin|info|w1|w2|w2b|w3|w4|w5|w6|abi> [--out dir] ...\n", stderr);
    return 2;
  }
  probe::Args args;
  for (int i = 2; i < argc; ++i) args.items.push_back(argv[i]);
  std::wstring command = argv[1];
  if (command == L"testwin") return probe::RunTestWindow(args);
  if (command == L"stageleave") {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    return probe::RunStageAndLeave(args);
  }

  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  probe::g_out = args.Get(L"--out", L"D:\\dev\\wsn-A\\out\\" + command);
  CreateDirectoryW(probe::g_out.c_str(), nullptr);
  std::wstring log = probe::g_out + L"\\" + command + L".log";
  probe::g_log = _wfopen(log.c_str(), L"ab");
  probe::Log("=== %s ===", wsn::Narrow(command).c_str());
  LASTINPUTINFO last{sizeof(last)};
  GetLastInputInfo(&last);
  probe::Log("idle %lu s", (GetTickCount() - last.dwTime) / 1000);
  if (args.Has(L"--display-off")) {
    SendMessageTimeoutW(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2, SMTO_ABORTIFHUNG, 2000, nullptr);
    Sleep(4000);
    probe::Log("display off requested");
  }
  if (args.Has(L"--keep-display")) {
    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
    Sleep(1500);
    probe::Log("display required set");
  }
  if (args.Has(L"--wake")) {
    // A zero mouse move counts as input: the display comes back on.
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_MOVE;
    SendInput(1, &input, sizeof(input));
    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
    Sleep(1500);
    probe::Log("woke the display");
  }
  int code = 2;
  try {
    if (command == L"info") code = probe::RunInfo(args);
    else if (command == L"list") code = probe::RunList(args);
    else if (command == L"w1") code = probe::RunW1(args);
    else if (command == L"w2") code = probe::RunW2(args);
    else if (command == L"w2b") code = probe::RunW2b(args);
    else if (command == L"w2x") code = probe::RunW2x(args);
    else if (command == L"w3") code = probe::RunW3(args);
    else if (command == L"w4") code = probe::RunW4(args);
    else if (command == L"w5") code = probe::RunW5(args);
    else if (command == L"w6") code = probe::RunW6(args);
    else if (command == L"abi") code = probe::RunAbi(args);
    else if (command == L"xaml") code = probe::RunXaml(args);
    else if (command == L"audiocheck") code = probe::RunAudioCheck(args);
    else probe::Log("unknown command");
  } catch (winrt::hresult_error const& e) {
    probe::Log("hresult_error %s %s", wsn::HrText(e.code()).c_str(), wsn::Narrow(e.message()).c_str());
    code = 3;
  } catch (std::exception const& e) {
    probe::Log("exception %s", e.what());
    code = 3;
  }
  probe::Log("=== done %d ===", code);
  if (probe::g_log) fclose(probe::g_log);
  return code;
}
