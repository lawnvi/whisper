// W1 (Windows.Graphics.Capture basics), W2 (do apps keep painting when moved
// right of the virtual screen?), W2b (where their popups go).
#include "probe.h"

#include "core/wsn_image.h"
#include "core/wsn_stage.h"
#include "core/wsn_wgc.h"
#include "core/wsn_window.h"

#include <shellapi.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <mutex>
#include <thread>

namespace probe {

namespace {

struct FrameLog {
  std::mutex mutex;
  std::vector<double> times;
  std::vector<SIZE> sizes;
  std::vector<int> counters;
  std::vector<uint64_t> hashes;
  int changed = 0;
  wsn::Bitmap first;
  wsn::Bitmap last;
  int keep_index = -1;
  wsn::Bitmap kept;
  bool decode = false;
  HWND test_window = nullptr;

  wsn::Bitmap Last() {
    std::lock_guard<std::mutex> lock(mutex);
    return last;
  }

  void Reset() {
    std::lock_guard<std::mutex> lock(mutex);
    times.clear();
    sizes.clear();
    counters.clear();
    hashes.clear();
    changed = 0;
    first = wsn::Bitmap();
    last = wsn::Bitmap();
  }
};

// A coarse fingerprint (64 x 64 samples) to tell changed frames apart.
uint64_t Fingerprint(const wsn::Bitmap& bitmap) {
  uint64_t hash = 1469598103934665603ULL;
  if (bitmap.empty()) return 0;
  for (int gy = 0; gy < 64; ++gy) {
    int y = (gy * 2 + 1) * bitmap.height / 128;
    for (int gx = 0; gx < 64; ++gx) {
      int x = (gx * 2 + 1) * bitmap.width / 128;
      const uint8_t* p = bitmap.pixel(x, y);
      for (int c = 0; c < 3; ++c) {
        hash ^= static_cast<uint64_t>(p[c] >> 3);
        hash *= 1099511628211ULL;
      }
    }
  }
  return hash;
}

double MeanLuma(const wsn::Bitmap& bitmap, double* variance) {
  if (bitmap.empty()) return -1;
  double sum = 0, sum2 = 0;
  int n = 0;
  for (int y = 0; y < bitmap.height; y += 4) {
    for (int x = 0; x < bitmap.width; x += 4) {
      const uint8_t* p = bitmap.pixel(x, y);
      double l = (p[0] + 2.0 * p[1] + p[2]) / 4;
      sum += l;
      sum2 += l * l;
      ++n;
    }
  }
  double mean = sum / n;
  if (variance) *variance = sum2 / n - mean * mean;
  return mean;
}

wsn::WgcCapture::FrameFn Recorder(FrameLog* log, bool read = true) {
  return [log, read](ID3D11Texture2D* texture, SIZE content, int64_t) {
    wsn::Bitmap bitmap;
    if (read) wsn::ReadTexture(wsn::D3D::Shared(), texture, content.cx, content.cy, &bitmap);
    std::lock_guard<std::mutex> lock(log->mutex);
    int index = static_cast<int>(log->times.size());
    log->times.push_back(wsn::NowMs());
    log->sizes.push_back(content);
    uint64_t hash = Fingerprint(bitmap);
    if (!log->hashes.empty() && hash != log->hashes.back()) log->changed++;
    log->hashes.push_back(hash);
    if (log->decode) log->counters.push_back(DecodeCounter(bitmap, log->test_window));
    if (index == 0) log->first = bitmap;
    if (index == log->keep_index) log->kept = bitmap;
    log->last = std::move(bitmap);
  };
}

int YellowPixels(const wsn::Bitmap& shot) {
  int count = 0;
  for (int y = 0; y < shot.height; ++y) {
    for (int x = 0; x < shot.width; ++x) {
      // Only the outer 6 px ring: where the capture border is drawn.
      if (x >= 6 && y >= 6 && x < shot.width - 6 && y < shot.height - 6) continue;
      const uint8_t* p = shot.pixel(x, y);
      if (p[2] > 200 && p[1] > 140 && p[0] < 90) count++;
    }
  }
  return count;
}

RECT Grow(const RECT& r, int by) { return RECT{r.left - by, r.top - by, r.right + by, r.bottom + by}; }

std::string SizeText(SIZE s) { return wsn::Format("%ldx%ld", s.cx, s.cy); }
std::string RectText(const RECT& r) {
  return wsn::Format("%ld,%ld %dx%d", r.left, r.top, wsn::RectWidth(r), wsn::RectHeight(r));
}

}  // namespace

int RunW1(const Args&) {
  const auto& s = wsn::QueryWgcSupport();
  Log("WGC supported=%d IsBorderRequired=%d borderless access=%d (status %d) IncludeSecondaryWindows=%d "
      "MinUpdateInterval=%d IsCursorCaptureEnabled=%d",
      s.supported, s.border_property, s.borderless_allowed, s.access_status, s.secondary_property,
      s.min_interval_property, s.cursor_property);
  wsn::D3D* d3d = wsn::D3D::Shared();
  if (!d3d) {
    Log("no D3D device");
    return 1;
  }
  Log("adapter %s, video device %d, dxgi manager %d", wsn::Narrow(d3d->adapter_name()).c_str(),
      d3d->video_device() != nullptr, d3d->manager() != nullptr);

  TestWindow tw;
  if (!LaunchTestWindow(L"w1", 800, 600, &tw)) return 1;
  Sleep(600);
  RECT window_rect{};
  GetWindowRect(tw.hwnd, &window_rect);
  RECT frame = wsn::FrameBounds(tw.hwnd);
  Log("test window rect %s frame %s dpi %u", RectText(window_rect).c_str(), RectText(frame).c_str(),
      wsn::WindowDpi(tw.hwnd));

  std::string json = "{";
  for (int pass = 0; pass < 3; ++pass) {
    bool border = pass == 2;
    bool read = pass != 0;
    FrameLog log;
    log.decode = read;
    log.test_window = tw.hwnd;
    log.keep_index = 59;
    wsn::WgcCapture capture;
    wsn::WgcCapture::Options options;
    options.border = border;
    std::string error;
    double start = wsn::NowMs();
    if (!capture.Start(tw.hwnd, options, Recorder(&log, read), nullptr, &error)) {
      Log("capture start failed: %s", error.c_str());
      CloseTestWindow(&tw);
      return 1;
    }
    Log("item size %s", SizeText(capture.item_size()).c_str());
    Sleep(1200);
    wsn::Bitmap shot;
    wsn::ScreenBitmap(Grow(frame, 3), &shot);
    int yellow = YellowPixels(shot);
    wsn::SaveImage(g_out + (border ? L"\\w1_screen_border.png" : L"\\w1_screen_borderless.png"), shot);
    Sleep(1300);
    capture.Stop();
    std::lock_guard<std::mutex> lock(log.mutex);
    size_t n = log.times.size();
    double first_ms = n ? log.times[0] - start : -1;
    double fps = n > 1 ? (n - 1) * 1000.0 / (log.times.back() - log.times[0]) : 0;
    int decoded = 0, skipped = 0, repeated = 0;
    for (size_t i = 0; i < log.counters.size(); ++i) {
      if (log.counters[i] >= 0) decoded++;
      if (i > 0 && log.counters[i] >= 0 && log.counters[i - 1] >= 0) {
        int d = log.counters[i] - log.counters[i - 1];
        if (d > 1) skipped += d - 1;
        if (d == 0) repeated++;
      }
    }
    Log("border=%d readback=%d frames %zu first %.0f ms fps %.1f content %s decoded %d/%zu skipped %d "
        "repeated %d yellow ring pixels %d",
        border, read, n, first_ms, fps, n ? SizeText(log.sizes[0]).c_str() : "-", decoded, log.counters.size(),
        skipped, repeated, yellow);
    if (pass == 1) {
      wsn::SaveImage(g_out + L"\\w1_frame1.png", log.first);
      wsn::SaveImage(g_out + L"\\w1_frame60.png", log.kept);
    }
    json += wsn::Format(
        "\"%s\":{\"frames\":%zu,\"firstMs\":%.0f,\"fps\":%.1f,\"content\":\"%s\",\"decoded\":%d,"
        "\"skipped\":%d,\"repeated\":%d,\"yellowPixels\":%d},",
        border ? "withBorder" : read ? "borderlessReadback" : "borderless", n, first_ms, fps, n ? SizeText(log.sizes[0]).c_str() : "-", decoded,
        skipped, repeated, yellow);
  }
  json += wsn::Format(
      "\"supported\":%d,\"borderProperty\":%d,\"borderlessAllowed\":%d,\"accessStatus\":%d,"
      "\"secondaryWindows\":%d,\"minUpdateInterval\":%d,\"windowRect\":\"%s\",\"frameBounds\":\"%s\","
      "\"adapter\":%s}",
      s.supported, s.border_property, s.borderless_allowed, s.access_status, s.secondary_property,
      s.min_interval_property, RectText(window_rect).c_str(), RectText(frame).c_str(),
      wsn::JsonString(d3d->adapter_name()).c_str());
  WriteText(L"w1.json", json);
  CloseTestWindow(&tw);
  return 0;
}

struct AppSpec {
  std::wstring key;
  std::wstring file;    // ShellExecute target
  std::wstring params;
  std::function<bool(HWND)> match;
  bool own_tree = false;  // the launched process and its children are ours to end
};

namespace {

std::wstring ExeName(HWND window) {
  std::wstring path = wsn::ProcessImagePath(wsn::WindowPid(window));
  HWND core = wsn::HostedCoreWindow(window);
  if (core) path = wsn::ProcessImagePath(wsn::WindowPid(core));
  size_t slash = path.find_last_of(L"\\/");
  std::wstring name = slash == std::wstring::npos ? path : path.substr(slash + 1);
  for (auto& c : name) c = static_cast<wchar_t>(towlower(c));
  return name;
}

bool Contains(const std::wstring& text, const wchar_t* part) { return text.find(part) != std::wstring::npos; }

}  // namespace

bool FindApp(const std::wstring& key, AppSpec* spec) {
  spec->key = key;
  if (key == L"notepad") {
    spec->file = L"notepad.exe";
    spec->params = L"D:\\dev\\wsn-A\\run\\wsn_notepad.txt";
    spec->match = [](HWND w) { return wsn::WindowClass(w) == L"Notepad"; };
  } else if (key == L"explorer") {
    spec->file = L"explorer.exe";
    spec->params = L"D:\\dev\\wsn-A\\run";
    spec->match = [](HWND w) { return wsn::WindowClass(w) == L"CabinetWClass"; };
  } else if (key == L"edge") {
    spec->file = L"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
    spec->params =
        L"--user-data-dir=D:\\dev\\wsn-A\\edge --no-first-run --no-default-browser-check "
        L"--disable-features=msEdgeWelcomePage --new-window file:///D:/dev/wsn-A/run/clock.html";
    spec->match = [](HWND w) {
      return wsn::WindowClass(w) == L"Chrome_WidgetWin_1" && ExeName(w) == L"msedge.exe" &&
             Contains(wsn::WindowTitle(w), L"WSN");
    };
    spec->own_tree = true;
  } else if (key == L"settings") {
    spec->file = L"ms-settings:about";
    spec->match = [](HWND w) {
      return wsn::WindowClass(w) == L"ApplicationFrameWindow" && ExeName(w) == L"systemsettings.exe";
    };
  } else if (key == L"calc") {
    spec->file = L"calc.exe";
    spec->match = [](HWND w) {
      std::wstring exe = ExeName(w);
      return exe == L"calculatorapp.exe" || exe == L"calculator.exe";
    };
  } else if (key == L"terminal") {
    spec->file = L"wt.exe";
    spec->params = L"-w new --title WSNTerm cmd /k ping -t 127.0.0.1";
    spec->match = [](HWND w) { return wsn::WindowClass(w) == L"CASCADIA_HOSTING_WINDOW_CLASS"; };
  } else if (key == L"paint") {
    spec->file = L"mspaint.exe";
    spec->match = [](HWND w) { return ExeName(w) == L"mspaint.exe" && wsn::RectWidth(wsn::FrameBounds(w)) > 200; };
  } else {
    return false;
  }
  return true;
}

HWND LaunchApp(const AppSpec& spec, HANDLE* process) {
  // Windows already shown are the user's; hidden ones (a suspended
  // Settings frame, say) may come back as the app's window.
  std::set<HWND> before;
  for (HWND w : TopLevelWindows()) {
    if (IsWindowVisible(w) && !wsn::IsCloaked(w)) before.insert(w);
  }
  SHELLEXECUTEINFOW info{sizeof(info)};
  info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
  info.lpFile = spec.file.c_str();
  info.lpParameters = spec.params.empty() ? nullptr : spec.params.c_str();
  info.nShow = SW_SHOWNOACTIVATE;
  if (!ShellExecuteExW(&info)) {
    Log("ShellExecuteEx %s failed %lu", wsn::Narrow(spec.file).c_str(), GetLastError());
    return nullptr;
  }
  if (process) {
    *process = info.hProcess;
  } else if (info.hProcess) {
    CloseHandle(info.hProcess);
  }
  HWND window = WaitNewWindow(before, spec.match, 15000);
  if (window) {
    // Splash screens and first layout.
    Sleep(2500);
  }
  return window;
}

void KillTree(DWORD root) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return;
  std::map<DWORD, DWORD> parent;
  PROCESSENTRY32W entry{sizeof(entry)};
  for (BOOL ok = Process32FirstW(snapshot, &entry); ok; ok = Process32NextW(snapshot, &entry)) {
    parent[entry.th32ProcessID] = entry.th32ParentProcessID;
  }
  CloseHandle(snapshot);
  std::set<DWORD> tree{root};
  for (bool grew = true; grew;) {
    grew = false;
    for (auto& [pid, ppid] : parent) {
      if (tree.count(ppid) && !tree.count(pid)) {
        tree.insert(pid);
        grew = true;
      }
    }
  }
  for (DWORD pid : tree) {
    HANDLE process = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
    if (process) {
      TerminateProcess(process, 0);
      CloseHandle(process);
    }
  }
}

void CloseApp(const AppSpec& spec, HWND window, HANDLE process) {
  if (spec.own_tree && process) {
    KillTree(GetProcessId(process));
  } else if (IsWindow(window)) {
    PostMessageW(window, WM_SYSCOMMAND, SC_CLOSE, 0);
    for (int i = 0; i < 50 && IsWindow(window) && IsWindowVisible(window) && !wsn::IsCloaked(window); ++i) {
      Sleep(100);
    }
    if (IsWindow(window) && IsWindowVisible(window) && !wsn::IsCloaked(window)) {
      Log("window still open after SC_CLOSE");
    }
  }
  if (process) CloseHandle(process);
}

std::string PlacementDiff(const wsn::Placement& a, const wsn::Placement& b) {
  std::string out;
  if (a.wp.showCmd != b.wp.showCmd) out += wsn::Format("showCmd %u->%u ", a.wp.showCmd, b.wp.showCmd);
  if ((a.wp.flags & ~WPF_ASYNCWINDOWPLACEMENT) != (b.wp.flags & ~WPF_ASYNCWINDOWPLACEMENT)) {
    out += wsn::Format("flags %u->%u ", a.wp.flags, b.wp.flags);
  }
  if (!wsn::SameRect(a.wp.rcNormalPosition, b.wp.rcNormalPosition)) {
    out += "normal " + RectText(a.wp.rcNormalPosition) + "->" + RectText(b.wp.rcNormalPosition) + " ";
  }
  if (!wsn::SameRect(a.rect, b.rect)) out += "rect " + RectText(a.rect) + "->" + RectText(b.rect) + " ";
  if (a.minimized != b.minimized) out += "minimized ";
  if (a.maximized != b.maximized) out += "maximized ";
  return out.empty() ? "exact" : out;
}

namespace {

struct Phase {
  size_t frames = 0;
  int changed = 0;
  double fps = 0;
  SIZE size{};
};

Phase Measure(FrameLog& log, int ms) {
  log.Reset();
  Sleep(ms);
  std::lock_guard<std::mutex> lock(log.mutex);
  Phase phase;
  phase.frames = log.times.size();
  phase.changed = log.changed;
  if (phase.frames > 1) phase.fps = (phase.frames - 1) * 1000.0 / (log.times.back() - log.times.front());
  if (phase.frames) phase.size = log.sizes.back();
  return phase;
}

std::string PhaseJson(const Phase& p) {
  return wsn::Format("{\"frames\":%zu,\"changed\":%d,\"fps\":%.1f,\"size\":\"%ldx%ld\"}", p.frames, p.changed,
                     p.fps, p.size.cx, p.size.cy);
}

}  // namespace

RECT CornerArea(const RECT& spot) {
  // 64 x 64 screen pixels around the part of [spot] that is on a monitor.
  RECT vs = wsn::VirtualScreen();
  RECT inside{};
  IntersectRect(&inside, &spot, &vs);
  LONG cx = (inside.left + inside.right) / 2, cy = (inside.top + inside.bottom) / 2;
  RECT area{cx - 32, cy - 32, cx + 32, cy + 32};
  RECT clipped{};
  IntersectRect(&clipped, &area, &vs);
  return clipped;
}

int Differing(const wsn::Bitmap& a, const wsn::Bitmap& b) {
  if (a.width != b.width || a.height != b.height) return -1;
  int count = 0;
  for (size_t i = 0; i < a.bgra.size(); i += 4) {
    int d = abs(a.bgra[i] - b.bgra[i]) + abs(a.bgra[i + 1] - b.bgra[i + 1]) + abs(a.bgra[i + 2] - b.bgra[i + 2]);
    if (d > 12) count++;
  }
  return count;
}

int RunW2(const Args& args) {
  std::wstring key = args.Get(L"--app", L"testwin");
  std::wstring state = args.Get(L"--state", L"normal");
  AppSpec spec;
  TestWindow tw;
  HWND window = nullptr;
  HANDLE process = nullptr;
  if (key == L"testwin") {
    if (!LaunchTestWindow(L"w2", 800, 600, &tw)) return 1;
    window = tw.hwnd;
    Sleep(500);
  } else {
    if (!FindApp(key, &spec)) {
      Log("unknown app");
      return 2;
    }
    window = LaunchApp(spec, &process);
  }
  if (!window) {
    Log("%s: no window", wsn::Narrow(key).c_str());
    WriteText(L"w2.jsonl", wsn::Format("{\"app\":%s,\"error\":\"no window\"}\n", wsn::JsonString(key).c_str()));
    if (process) CloseHandle(process);
    return 1;
  }
  if (state == L"minimized") {
    ShowWindow(window, SW_MINIMIZE);
    Sleep(800);
  } else if (state == L"maximized") {
    ShowWindow(window, SW_MAXIMIZE);
    Sleep(800);
  }
  DWORD pid = wsn::WindowPid(window);
  HWND core = wsn::HostedCoreWindow(window);
  DWORD app_pid = core ? wsn::WindowPid(core) : pid;
  wsn::Placement home = wsn::SavePlacement(window);
  LONG_PTR home_ex = GetWindowLongPtrW(window, GWL_EXSTYLE);
  RECT frame = wsn::FrameBounds(window);
  wsn::Borders borders = wsn::InvisibleBorders(window);
  Log("%s window %p class %s title %s exe %s pid %lu app pid %lu aumid %s/%s dpi %u frame %s state %s elevation %d "
      "ex 0x%llx borders %ld,%ld,%ld,%ld",
      wsn::Narrow(key).c_str(), window, wsn::Narrow(wsn::WindowClass(window)).c_str(),
      wsn::Narrow(wsn::WindowTitle(window)).c_str(), wsn::Narrow(ExeName(window)).c_str(), pid, app_pid,
      wsn::Narrow(wsn::WindowAumid(window)).c_str(), wsn::Narrow(wsn::ProcessAumid(app_pid)).c_str(),
      wsn::WindowDpi(window), RectText(frame).c_str(), wsn::Narrow(state).c_str(), wsn::ProcessElevation(app_pid),
      static_cast<unsigned long long>(home_ex), borders.left, borders.top, borders.right, borders.bottom);

  FrameLog log;
  log.decode = key == L"testwin";
  log.test_window = window;
  wsn::WgcCapture capture;
  std::string error;
  std::string tag = wsn::Narrow(key) + (state == L"normal" ? "" : "_" + wsn::Narrow(state));
  std::wstring wtag = wsn::Widen(tag);
  if (!capture.Start(window, {}, Recorder(&log), nullptr, &error)) Log("capture failed %s", error.c_str());
  Phase on;
  if (state != L"minimized") {
    on = Measure(log, 2500);
    wsn::SaveImage(g_out + L"\\" + wtag + L"_on.png", log.Last());
  }
  // Stage at a phone-like size.
  UINT dpi = wsn::WindowDpi(window);
  int width = MulDiv(430, dpi, 96) + borders.left + borders.right;
  int height = MulDiv(880, dpi, 96) + borders.top + borders.bottom;
  RECT spot{};
  wsn::StageSpot(0, width, height, borders, &spot);
  wsn::StyleBackup style;
  bool styled = wsn::ApplyStageStyle(window, &style);
  log.Reset();
  double t0 = wsn::NowMs();
  bool moved = wsn::MoveWindowTo(window, spot);
  double moved_ms = wsn::NowMs() - t0;
  double first_ms = -1;
  for (int i = 0; i < 200; ++i) {
    {
      std::lock_guard<std::mutex> lock(log.mutex);
      for (size_t f = 0; f < log.sizes.size(); ++f) {
        if (std::abs(log.sizes[f].cx - (width - borders.left - borders.right)) <= 2) {
          first_ms = log.times[f] - t0;
          break;
        }
      }
    }
    if (first_ms >= 0) break;
    Sleep(10);
  }
  RECT where{};
  GetWindowRect(window, &where);
  Log("staged: style %d moved %d in %.0f ms, first frame at the new size after %.0f ms, rect %s (spot %s)", styled,
      moved, moved_ms, first_ms, RectText(where).c_str(), RectText(spot).c_str());
  Sleep(500);
  Phase staged = Measure(log, 2500);
  wsn::Bitmap staged_last = log.Last();
  wsn::SaveImage(g_out + L"\\" + wtag + L"_staged.png", staged_last);
  double variance = 0;
  double mean = MeanLuma(staged_last, &variance);
  wsn::Bitmap corner_staged;
  RECT corner = CornerArea(spot);
  wsn::ScreenBitmap(corner, &corner_staged);
  // Stimulus: a second size while staged.
  RECT spot2{};
  wsn::StageSpot(0, width + 60, height - 80, borders, &spot2);
  log.Reset();
  bool moved2 = wsn::MoveWindowTo(window, spot2);
  RECT where2{};
  GetWindowRect(window, &where2);
  Sleep(1500);
  Phase resized;
  {
    std::lock_guard<std::mutex> lock(log.mutex);
    resized.frames = log.times.size();
    resized.changed = log.changed;
    if (!log.sizes.empty()) resized.size = log.sizes.back();
    for (size_t f = 0; f < log.times.size() && f < 6; ++f) {
      Log("  resized frame %zu at %.0f size %ldx%ld", f, log.times[f], log.sizes[f].cx, log.sizes[f].cy);
    }
  }
  Log("second spot %s moved %d now %s", RectText(spot2).c_str(), moved2, RectText(where2).c_str());
  wsn::Bitmap resized_last = log.Last();
  wsn::SaveImage(g_out + L"\\" + wtag + L"_staged_resized.png", resized_last);
  double resized_variance = 0;
  double resized_mean = MeanLuma(resized_last, &resized_variance);
  bool style_kept = wsn::HasStageStyle(window);
  capture.Stop();
  wsn::RestoreStageStyle(window, style);
  bool restored = wsn::RestorePlacement(window, home);
  Sleep(500);
  wsn::Bitmap corner_home;
  wsn::ScreenBitmap(corner, &corner_home);
  int footprint = Differing(corner_staged, corner_home);
  wsn::SaveImage(g_out + L"\\" + wtag + L"_corner_staged.png", corner_staged);
  wsn::Placement back = wsn::SavePlacement(window);
  LONG_PTR back_ex = GetWindowLongPtrW(window, GWL_EXSTYLE);
  std::string diff = PlacementDiff(home, back);
  Log("on: %zu frames %d changed %.1f fps", on.frames, on.changed, on.fps);
  Log("staged: %zu frames %d changed %.1f fps size %ldx%ld mean %.0f var %.0f; resized: %zu frames %d changed size "
      "%ldx%ld mean %.0f var %.0f; style kept %d; corner pixels differing %d",
      staged.frames, staged.changed, staged.fps, staged.size.cx, staged.size.cy, mean, variance, resized.frames,
      resized.changed, resized.size.cx, resized.size.cy, resized_mean, resized_variance, style_kept, footprint);
  Log("restore: returned %d, %s, ex style %s", restored, diff.c_str(), back_ex == home_ex ? "same" : "CHANGED");
  std::string json = "{\"app\":" + wsn::JsonString(tag) + ",\"class\":" + wsn::JsonString(wsn::WindowClass(window)) +
                     ",\"exe\":" + wsn::JsonString(ExeName(window)) + ",";
  json += wsn::Format(
      "\"styled\":%d,\"moved\":%d,\"firstFrameAfterStageMs\":%.0f,\"on\":%s,\"staged\":%s,\"stagedResized\":%s,"
      "\"stagedMean\":%.0f,\"stagedVariance\":%.0f,\"resizedVariance\":%.0f,\"styleKept\":%d,\"cornerPixels\":%d,"
      "\"restore\":%s,\"exStyleRestored\":%d,\"dpi\":%u}\n",
      styled, moved, first_ms, PhaseJson(on).c_str(), PhaseJson(staged).c_str(), PhaseJson(resized).c_str(), mean,
      variance, resized_variance, style_kept, footprint, wsn::JsonString(diff).c_str(), back_ex == home_ex, home.dpi);
  WriteText(L"w2.jsonl", json);
  if (key == L"testwin") {
    CloseTestWindow(&tw);
  } else if (!args.Has(L"--keep")) {
    CloseApp(spec, window, process);
  }
  return 0;
}

// Which placements keep DWM composing (WGC frames) and the app painting.
int RunW2x(const Args& args) {
  std::wstring key = args.Get(L"--app", L"testwin");
  TestWindow tw;
  AppSpec spec;
  HANDLE process = nullptr;
  HWND window = nullptr;
  if (key == L"testwin") {
    if (!LaunchTestWindow(L"w2x", 800, 600, &tw)) return 1;
    window = tw.hwnd;
    Sleep(500);
  } else {
    if (!FindApp(key, &spec)) return 2;
    window = LaunchApp(spec, &process);
    if (!window) {
      Log("no window");
      return 1;
    }
  }
  wsn::Placement home = wsn::SavePlacement(window);
  FrameLog log;
  log.decode = key == L"testwin";
  log.test_window = window;
  wsn::WgcCapture capture;
  std::string error;
  capture.Start(window, {}, Recorder(&log), nullptr, &error);
  RECT vs = wsn::VirtualScreen();
  int w = wsn::RectWidth(home.rect), h = wsn::RectHeight(home.rect);
  struct Spot {
    const char* name;
    LONG x, y;
    int layered;  // -1 none, else alpha
    bool transparent = false;
  };
  RECT frame = wsn::FrameBounds(window);
  LONG border_left = frame.left - home.rect.left, border_top = frame.top - home.rect.top;
  RECT work = wsn::PrimaryWorkArea();
  (void)border_top;
  std::vector<Spot> spots = {
      {"right_off_layered", vs.right + 64, vs.top + 32, 255},
      {"home", home.rect.left, home.rect.top, -1},
      {"home_layered", home.rect.left, home.rect.top, 255},
      {"home_layered_transparent", home.rect.left, home.rect.top, 255, true},
      {"corner_border", vs.right - border_left, vs.bottom - 1, -1},
      {"corner_border_layered", vs.right - border_left, vs.bottom - 1, 255},
      {"corner_border_layered_transparent", vs.right - border_left, vs.bottom - 1, 255, true},
      {"right_off_layered_transparent", vs.right + 64, vs.top + 32, 255, true},
  };
  RECT band{vs.left, work.bottom - 8, vs.right, vs.bottom};
  wsn::Bitmap baseline;
  LONG_PTR ex = GetWindowLongPtrW(window, GWL_EXSTYLE);
  size_t offset = 0;
  if (!tw.log_path.empty()) ReadNewLines(tw.log_path, &offset);
  std::string json;
  for (const auto& spot : spots) {
    if (spot.layered >= 0) {
      SetWindowLongPtrW(window, GWL_EXSTYLE, ex | WS_EX_LAYERED | (spot.transparent ? WS_EX_TRANSPARENT : 0));
      SetLayeredWindowAttributes(window, 0, static_cast<BYTE>(spot.layered), LWA_ALPHA);
    } else {
      SetWindowLongPtrW(window, GWL_EXSTYLE, ex);
    }
    SetWindowPos(window, nullptr, spot.x, spot.y, w, h, SWP_NOACTIVATE | SWP_NOZORDER | SWP_ASYNCWINDOWPOS |
                 SWP_FRAMECHANGED);
    Sleep(800);
    // A stimulus every app answers: a slightly different size, and back.
    std::thread stimulus([window, w, h] {
      Sleep(500);
      SetWindowPos(window, nullptr, 0, 0, w + 20, h + 10,
                   SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER | SWP_ASYNCWINDOWPOS);
      Sleep(600);
      SetWindowPos(window, nullptr, 0, 0, w, h, SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER | SWP_ASYNCWINDOWPOS);
    });
    Phase phase = Measure(log, 2500);
    stimulus.join();
    wsn::Bitmap last = log.Last();
    int counter = log.decode ? DecodeCounter(last, window) : -2;
    double variance = 0;
    double mean = MeanLuma(last, &variance);
    wsn::Bitmap shot;
    wsn::ScreenBitmap(band, &shot);
    if (baseline.empty()) baseline = shot;
    int differ = 0;
    if (shot.width == baseline.width && shot.height == baseline.height) {
      for (size_t i = 0; i < shot.bgra.size(); i += 4) {
        int d = abs(shot.bgra[i] - baseline.bgra[i]) + abs(shot.bgra[i + 1] - baseline.bgra[i + 1]) +
                abs(shot.bgra[i + 2] - baseline.bgra[i + 2]);
        if (d > 12) differ++;
      }
    }
    wsn::SaveImage(g_out + L"\\w2x_" + key + L"_" + wsn::Widen(spot.name) + L"_band.png", shot);
    Log("%-22s wgc %3zu frames %5.1f fps changed %3d counter %d mean %.0f var %.0f | band pixels differing %d",
        spot.name, phase.frames, phase.fps, phase.changed, counter, mean, variance, differ);
    wsn::SaveImage(g_out + L"\\w2x_" + key + L"_" + wsn::Widen(spot.name) + L".png", last);
    json += wsn::Format("{\"app\":%s,\"spot\":\"%s\",\"frames\":%zu,\"fps\":%.1f,\"changed\":%d}\n",
                        wsn::JsonString(key).c_str(), spot.name, phase.frames, phase.fps, phase.changed);
  }
  SetWindowLongPtrW(window, GWL_EXSTYLE, ex);
  capture.Stop();
  wsn::RestorePlacement(window, home);
  WriteText(L"w2x.jsonl", json);
  if (key == L"testwin") {
    CloseTestWindow(&tw);
  } else {
    CloseApp(spec, window, process);
  }
  return 0;
}

namespace {

// Visible top-level windows of [pid] that were not there before.
std::vector<HWND> NewPopups(DWORD pid, const std::set<HWND>& before) {
  std::vector<HWND> out;
  for (HWND w : TopLevelWindows()) {
    if (before.count(w) || !IsWindowVisible(w) || wsn::IsCloaked(w)) continue;
    if (wsn::WindowPid(w) != pid) continue;
    out.push_back(w);
  }
  return out;
}

std::set<HWND> VisibleOf(DWORD pid) {
  std::set<HWND> out;
  for (HWND w : TopLevelWindows()) {
    if (IsWindowVisible(w) && wsn::WindowPid(w) == pid) out.insert(w);
  }
  return out;
}

void PostClick(HWND target, POINT client, bool right) {
  LPARAM at = MAKELPARAM(client.x, client.y);
  PostMessageW(target, WM_MOUSEMOVE, 0, at);
  PostMessageW(target, right ? WM_RBUTTONDOWN : WM_LBUTTONDOWN, right ? MK_RBUTTON : MK_LBUTTON, at);
  PostMessageW(target, right ? WM_RBUTTONUP : WM_LBUTTONUP, 0, at);
}

// How many pixels differ between two frames of the same size (-1: sizes differ).
int FrameDiff(const wsn::Bitmap& a, const wsn::Bitmap& b) { return Differing(a, b); }

struct PopupReport {
  std::string what;
  HWND popup = nullptr;
  std::string cls;
  RECT rect{};
  bool on_monitor = false;
  int frame_diff_shown = -1;
  bool moved = false;
  RECT moved_rect{};
  int frame_diff_moved = -1;
};

std::string ReportJson(const PopupReport& r) {
  return wsn::Format(
      "{\"what\":%s,\"found\":%d,\"class\":%s,\"rect\":\"%s\",\"onMonitor\":%d,\"frameDiffShown\":%d,"
      "\"moved\":%d,\"movedRect\":\"%s\",\"frameDiffMoved\":%d}",
      wsn::JsonString(r.what).c_str(), r.popup != nullptr, wsn::JsonString(r.cls).c_str(), RectText(r.rect).c_str(),
      r.on_monitor, r.frame_diff_shown, r.moved, RectText(r.moved_rect).c_str(), r.frame_diff_moved);
}

// Shows a popup with [show], then tries to move it next to [anchor] (a
// screen point inside the staged window).
PopupReport TryPopup(const char* what, HWND window, FrameLog& log, const std::function<void()>& show,
                     POINT anchor, const std::function<void(HWND)>& dismiss) {
  PopupReport report;
  report.what = what;
  DWORD pid = wsn::WindowPid(window);
  std::set<HWND> before = VisibleOf(pid);
  wsn::Bitmap base = log.Last();
  show();
  for (int i = 0; i < 40 && !report.popup; ++i) {
    Sleep(50);
    auto popups = NewPopups(pid, before);
    if (!popups.empty()) report.popup = popups.front();
  }
  if (!report.popup) {
    Log("%s: no popup appeared", what);
    return report;
  }
  Sleep(400);
  report.cls = wsn::Narrow(wsn::WindowClass(report.popup));
  GetWindowRect(report.popup, &report.rect);
  report.on_monitor = wsn::OnAnyMonitor(report.rect, 0.01);
  wsn::Bitmap shown = log.Last();
  report.frame_diff_shown = FrameDiff(base, shown);
  wsn::SaveImage(g_out + L"\\w2b_" + wsn::Widen(what) + L"_shown.png", shown);
  // The follower: put it beside the anchor, inside the staged window.
  int w = wsn::RectWidth(report.rect), h = wsn::RectHeight(report.rect);
  SetWindowPos(report.popup, nullptr, anchor.x, anchor.y, w, h,
               SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE | SWP_ASYNCWINDOWPOS);
  Sleep(400);
  GetWindowRect(report.popup, &report.moved_rect);
  report.moved = report.moved_rect.left == anchor.x && report.moved_rect.top == anchor.y;
  wsn::Bitmap moved = log.Last();
  report.frame_diff_moved = FrameDiff(base, moved);
  wsn::SaveImage(g_out + L"\\w2b_" + wsn::Widen(what) + L"_moved.png", moved);
  Log("%s: popup %p class %s at %s on monitor %d; frame differs %d px; moved %d to %s; frame differs %d px", what,
      report.popup, report.cls.c_str(), RectText(report.rect).c_str(), report.on_monitor, report.frame_diff_shown,
      report.moved, RectText(report.moved_rect).c_str(), report.frame_diff_moved);
  dismiss(report.popup);
  Sleep(400);
  return report;
}

}  // namespace

int RunW2b(const Args& args) {
  std::string json = "{";
  // 1. The test window: menu, combo box drop-down, open dialog.
  {
    TestWindow tw;
    if (!LaunchTestWindow(L"w2b", 800, 600, &tw)) return 1;
    Sleep(500);
    HWND window = tw.hwnd;
    wsn::Placement home = wsn::SavePlacement(window);
    wsn::Borders borders = wsn::InvisibleBorders(window);
    FrameLog log;
    wsn::WgcCapture capture;
    std::string error;
    capture.Start(window, {}, Recorder(&log), nullptr, &error);
    Sleep(300);
    RECT spot{};
    wsn::StageSpot(0, wsn::RectWidth(home.rect), wsn::RectHeight(home.rect), borders, &spot);
    wsn::StyleBackup style;
    wsn::ApplyStageStyle(window, &style);
    wsn::MoveWindowTo(window, spot);
    Sleep(500);
    RECT frame = wsn::FrameBounds(window);
    RECT client{};
    GetClientRect(window, &client);
    POINT center{client.right / 2, client.bottom * 2 / 5};
    POINT anchor = center;
    ClientToScreen(window, &anchor);
    auto escape = [](HWND popup) {
      PostMessageW(popup, WM_KEYDOWN, VK_ESCAPE, 0);
      PostMessageW(popup, WM_KEYUP, VK_ESCAPE, 0);
    };
    PopupReport menu = TryPopup(
        "testwin_menu", window, log, [&] { PostClick(window, center, true); }, anchor,
        [&](HWND) { PostMessageW(window, WM_CANCELMODE, 0, 0); });
    // TrackPopupMenu ends on WM_CANCELMODE to its owner.
    Sleep(300);
    RECT combo_rect{};
    GetWindowRect(tw.combo, &combo_rect);
    POINT combo_anchor{combo_rect.left, combo_rect.bottom};
    PopupReport combo = TryPopup(
        "testwin_combo", window, log, [&] { PostMessageW(tw.combo, CB_SHOWDROPDOWN, TRUE, 0); }, combo_anchor,
        [&](HWND) { PostMessageW(tw.combo, CB_SHOWDROPDOWN, FALSE, 0); });
    POINT dialog_anchor{frame.left + 40, frame.top + 40};
    PopupReport dialog = TryPopup(
        "testwin_open_dialog", window, log, [&] { PostMessageW(window, WM_APP + 5, 0, 0); }, dialog_anchor,
        [&](HWND popup) { PostMessageW(popup, WM_COMMAND, IDCANCEL, 0); });
    capture.Stop();
    wsn::RestoreStageStyle(window, style);
    wsn::RestorePlacement(window, home);
    CloseTestWindow(&tw);
    json += "\"testwin\":[" + ReportJson(menu) + "," + ReportJson(combo) + "," + ReportJson(dialog) + "],";
    Log("staged frame %s", RectText(frame).c_str());
  }
  // 2. Notepad (WinUI 3): its context menu is a XAML popup window.
  if (!args.Has(L"--no-notepad")) {
    AppSpec spec;
    FindApp(L"notepad", &spec);
    HANDLE process = nullptr;
    HWND window = LaunchApp(spec, &process);
    if (window) {
      wsn::Placement home = wsn::SavePlacement(window);
      wsn::Borders borders = wsn::InvisibleBorders(window);
      FrameLog log;
      wsn::WgcCapture capture;
      std::string error;
      capture.Start(window, {}, Recorder(&log), nullptr, &error);
      RECT spot{};
      wsn::StageSpot(0, wsn::RectWidth(home.rect), wsn::RectHeight(home.rect), borders, &spot);
      wsn::StyleBackup style;
      wsn::ApplyStageStyle(window, &style);
      wsn::MoveWindowTo(window, spot);
      Sleep(700);
      // The text area: the deepest child at 50% / 40% of the window.
      RECT frame = wsn::FrameBounds(window);
      POINT screen{(frame.left + frame.right) / 2, frame.top + wsn::RectHeight(frame) * 2 / 5};
      HWND target = window;
      for (;;) {
        POINT client = screen;
        ScreenToClient(target, &client);
        HWND child = ChildWindowFromPointEx(target, client, CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT);
        if (!child || child == target) break;
        target = child;
      }
      POINT client = screen;
      ScreenToClient(target, &client);
      Log("notepad target %p class %s client %ld,%ld", target, wsn::Narrow(wsn::WindowClass(target)).c_str(),
          client.x, client.y);
      PopupReport menu = TryPopup(
          "notepad_menu", window, log, [&] { PostClick(target, client, true); }, screen,
          [&](HWND popup) { PostMessageW(popup, WM_KEYDOWN, VK_ESCAPE, 0); });
      // Still open? Close it the hard way: activate nothing, post Esc to the window.
      PostMessageW(target, WM_KEYDOWN, VK_ESCAPE, 0);
      PostMessageW(target, WM_KEYUP, VK_ESCAPE, 0);
      capture.Stop();
      wsn::RestoreStageStyle(window, style);
      wsn::RestorePlacement(window, home);
      json += "\"notepad\":[" + ReportJson(menu) + "],";
      CloseApp(spec, window, process);
    }
  }
  json += "\"done\":1}\n";
  WriteText(L"w2b.json", json);
  return 0;
}

}  // namespace probe
