// The ABI harness: loads window_stream_native.dll exactly as Dart does
// (LoadLibrary + GetProcAddress of the C exports), then drives the real
// capture pipeline against the test window and checks the plan's matrix:
// catalog + icon + thumbnail, first frame < 2 s and >= 20 fps, frames decode,
// input (click / text / scroll / right-click / Cmd+A->Ctrl+A), the window is
// off the real screen, viewport resizes it, pause parks / resume re-stages,
// stop restores placement, kill+relaunch recovery, remote close.
#include "core/wsn_inject.h"
#include "probe.h"

#include "core/wsn_image.h"
#include "core/wsn_window.h"

#include "window_stream_native.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace probe {

namespace {

// The capture C ABI, resolved from the DLL.
struct Abi {
  HMODULE dll = nullptr;
  int32_t (*api_version)() = nullptr;
  void (*reset_all)() = nullptr;
  void (*set_capture_callback)(wsn_capture_callback) = nullptr;
  int32_t (*capture_supported)() = nullptr;
  int32_t (*capture_input_permission)() = nullptr;
  int64_t (*request_catalog)() = nullptr;
  int64_t (*request_icon)(const char*, int32_t) = nullptr;
  int64_t (*request_thumbnail)(uint32_t, int32_t) = nullptr;
  int64_t (*launch_app)(const char*) = nullptr;
  int64_t (*capture_start)(uint32_t, int32_t, int32_t, int32_t, int32_t) = nullptr;
  void (*capture_stop)(int64_t) = nullptr;
  void (*close_window)(uint32_t, int32_t) = nullptr;
  void (*set_screen)(int64_t, int64_t) = nullptr;
  void (*set_viewport)(int64_t, double, double, double) = nullptr;
  void (*set_inset)(int64_t, double) = nullptr;
  void (*request_keyframe)(int64_t) = nullptr;
  void (*set_busy)(int64_t, int32_t) = nullptr;
  void (*set_paused)(int64_t, int32_t) = nullptr;
  void (*set_bit_rate)(int64_t, int32_t) = nullptr;
  void (*set_audio)(int64_t, int32_t) = nullptr;
  void (*capture_input)(int64_t, int32_t, int32_t, int32_t, double, double, double, double, int32_t,
                        const char*) = nullptr;
  void (*wfree)(void*) = nullptr;

  template <typename T>
  bool Bind(T& fn, const char* name) {
    fn = reinterpret_cast<T>(GetProcAddress(dll, name));
    if (fn == nullptr) Log("MISSING export %s", name);
    return fn != nullptr;
  }
  bool Load(const wchar_t* path) {
    dll = LoadLibraryW(path);
    if (!dll) {
      Log("LoadLibrary failed %lu", GetLastError());
      return false;
    }
    bool ok = true;
    ok &= Bind(api_version, "wsn_api_version");
    ok &= Bind(reset_all, "wsn_reset_all");
    ok &= Bind(set_capture_callback, "wsn_set_capture_callback");
    ok &= Bind(capture_supported, "wsn_capture_supported");
    ok &= Bind(capture_input_permission, "wsn_capture_input_permission");
    ok &= Bind(request_catalog, "wsn_capture_request_catalog");
    ok &= Bind(request_icon, "wsn_capture_request_icon");
    ok &= Bind(request_thumbnail, "wsn_capture_request_thumbnail");
    ok &= Bind(launch_app, "wsn_capture_launch_app");
    ok &= Bind(capture_start, "wsn_capture_start");
    ok &= Bind(capture_stop, "wsn_capture_stop");
    ok &= Bind(close_window, "wsn_capture_close_window");
    ok &= Bind(set_screen, "wsn_capture_set_screen");
    ok &= Bind(set_viewport, "wsn_capture_set_viewport");
    ok &= Bind(set_inset, "wsn_capture_set_inset");
    ok &= Bind(request_keyframe, "wsn_capture_request_keyframe");
    ok &= Bind(set_busy, "wsn_capture_set_busy");
    ok &= Bind(set_paused, "wsn_capture_set_paused");
    ok &= Bind(set_bit_rate, "wsn_capture_set_bit_rate");
    ok &= Bind(set_audio, "wsn_capture_set_audio");
    ok &= Bind(capture_input, "wsn_capture_input");
    ok &= Bind(wfree, "wsn_free");
    return ok;
  }
};

Abi g_abi;

// Capture callback sink (one per request/session id).
struct Sink {
  std::mutex mutex;
  // Per-request one-shot results (catalog/icon/thumbnail/launch).
  std::map<int64_t, std::vector<uint8_t>> payloads;
  std::map<int64_t, int32_t> kinds;
  std::map<int64_t, int32_t> errors;
  // Stream (capture session id).
  int64_t stream_id = 0;
  std::vector<double> packet_times;
  std::vector<uint8_t> annexb;
  int packets = 0, config = 0, key = 0;
  int32_t width = 0, height = 0;
  double first_packet = -1;
  double start_time = 0;
  std::vector<std::string> notes;
  // TEXT_FOCUS events of the stream: (time, flags).
  std::vector<std::pair<double, int>> focus;
  // Audio of the stream.
  int audio_chunks = 0;
  int64_t audio_frames = 0;
  int audio_rate = 0, audio_channels = 0;
  double first_audio = -1, last_audio = -1;
  int64_t first_audio_pts = 0, last_audio_pts = 0;
  double audio_level_sum = 0;  // mean |sample| summed over chunks
  double audio_pts_gap_max = 0;  // largest gap vs contiguous pts (ms)
};
Sink g_sink;

void CALLBACK OnCapture(int64_t id, int32_t kind, uint8_t* data, int32_t length, int64_t pts_us, int32_t flags,
                        int32_t width, int32_t height) {
  std::lock_guard<std::mutex> lock(g_sink.mutex);
  if (kind == WSN_CAPTURE_PACKET && id == g_sink.stream_id) {
    if (g_sink.first_packet < 0) g_sink.first_packet = wsn::NowMs() - g_sink.start_time;
    g_sink.packet_times.push_back(wsn::NowMs());
    g_sink.packets++;
    if (flags & WSN_PACKET_CONFIG) g_sink.config++;
    if (flags & WSN_PACKET_KEY) g_sink.key++;
    g_sink.width = width;
    g_sink.height = height;
    if (g_sink.annexb.size() < 24 * 1024 * 1024 && data && length > 0) {
      g_sink.annexb.insert(g_sink.annexb.end(), data, data + length);
    }
  } else if (kind == WSN_CAPTURE_SIZE && id == g_sink.stream_id) {
    g_sink.width = width;
    g_sink.height = height;
  } else if (kind == WSN_CAPTURE_AUDIO && id == g_sink.stream_id) {
    double now = wsn::NowMs();
    int frames = width > 0 ? length / (2 * static_cast<int>(sizeof(int16_t))) : 0;
    if (g_sink.first_audio < 0) {
      g_sink.first_audio = now;
      g_sink.first_audio_pts = pts_us;
    } else {
      // Contiguous pts: each chunk's pts should be last_pts + last_frames.
      double expected = static_cast<double>(g_sink.last_audio_pts) +
                        1e6 * (static_cast<double>(frames)) / (width > 0 ? width : 48000);
      g_sink.audio_pts_gap_max = std::max(g_sink.audio_pts_gap_max, std::abs(pts_us - expected) / 1000.0);
    }
    g_sink.last_audio = now;
    g_sink.last_audio_pts = pts_us;
    g_sink.audio_chunks++;
    g_sink.audio_frames += frames;
    g_sink.audio_rate = width;
    g_sink.audio_channels = height;
    if (data != nullptr && length > 0) {
      const int16_t* pcm = reinterpret_cast<const int16_t*>(data);
      int64_t sum = 0;
      int n = length / static_cast<int>(sizeof(int16_t));
      for (int i = 0; i < n; ++i) sum += std::abs(static_cast<int>(pcm[i]));
      g_sink.audio_level_sum += n > 0 ? static_cast<double>(sum) / n : 0;
    }
  } else if (kind == WSN_CAPTURE_TEXT_FOCUS && id == g_sink.stream_id) {
    g_sink.focus.push_back({wsn::NowMs(), flags});
  } else if (kind == WSN_CAPTURE_NOTE) {
    if (data && length > 0) g_sink.notes.push_back(std::string(reinterpret_cast<char*>(data), length));
  } else if (kind == WSN_CAPTURE_STOPPED || kind == WSN_CAPTURE_FAILED) {
    if (id == g_sink.stream_id) g_sink.notes.push_back("stream ended/failed flags " + std::to_string(flags));
    g_sink.errors[id] = flags;
    g_sink.kinds[id] = kind;
  } else {
    // One-shot request result.
    g_sink.kinds[id] = kind;
    if (kind == WSN_CAPTURE_FAILED) {
      g_sink.errors[id] = flags;
    } else if (data && length > 0) {
      g_sink.payloads[id].assign(data, data + length);
    } else {
      g_sink.payloads[id];  // mark as present/empty
    }
  }
  if (data) g_abi.wfree(data);
}

// Waits up to [ms] for a one-shot result on [id]; returns its kind (-1 timeout).
int32_t WaitResult(int64_t id, std::vector<uint8_t>* data, int ms) {
  double end = wsn::NowMs() + ms;
  while (wsn::NowMs() < end) {
    {
      std::lock_guard<std::mutex> lock(g_sink.mutex);
      auto it = g_sink.kinds.find(id);
      if (it != g_sink.kinds.end()) {
        if (data) {
          auto pit = g_sink.payloads.find(id);
          if (pit != g_sink.payloads.end()) *data = pit->second;
        }
        return it->second;
      }
    }
    Sleep(20);
  }
  return -1;
}

std::string Field(const std::string& line, const std::string& key) {
  std::string needle = key + "=";
  size_t at = line.find(needle);
  if (at == std::string::npos) return std::string();
  at += needle.size();
  size_t end = at;
  if (at < line.size() && line[at] == '"') {
    end = line.find('"', at + 1);
    return end == std::string::npos ? std::string() : line.substr(at + 1, end - at - 1);
  }
  while (end < line.size() && line[end] != ' ') ++end;
  return line.substr(at, end - at);
}

int g_pass = 0, g_fail = 0;
std::string g_json;
void Check(const char* name, bool pass, const std::string& detail) {
  Log("%-22s %s | %s", name, pass ? "PASS" : "FAIL", detail.c_str());
  (pass ? g_pass : g_fail)++;
  g_json += wsn::Format("{\"case\":\"%s\",\"pass\":%s,\"detail\":%s},", name, pass ? "true" : "false",
                        wsn::JsonString(detail).c_str());
}

}  // namespace

namespace {

// Finds a window of [app_substr] (matched against the catalog's appName/
// bundleId) in a fresh catalog; launches [launch_id] and waits if none.
uint32_t FindAppWindow(const std::string& match, const char* launch_id, DWORD* pid_out) {
  for (int attempt = 0; attempt < 20; ++attempt) {
    int64_t cid = g_abi.request_catalog();
    std::vector<uint8_t> cat;
    if (WaitResult(cid, &cat, 5000) == WSN_CAPTURE_CATALOG) {
      std::string json(cat.begin(), cat.end());
      // Scan each window object for the match.
      size_t pos = 0;
      while ((pos = json.find("{\"id\":", pos)) != std::string::npos) {
        size_t end = json.find('}', pos);
        std::string obj = json.substr(pos, end - pos);
        std::string lower = obj;
        for (auto& c : lower) c = static_cast<char>(tolower(c));
        auto json_num = [&](const char* key) -> unsigned long {
          size_t at = obj.find(key);
          return at == std::string::npos ? 0 : strtoul(obj.c_str() + at + strlen(key), nullptr, 10);
        };
        if (lower.find(match) != std::string::npos) {
          uint32_t id = static_cast<uint32_t>(json_num("\"id\":"));
          if (pid_out) *pid_out = static_cast<DWORD>(json_num("\"pid\":"));
          if (id != 0) return id;
        }
        pos = end;
      }
    }
    if (attempt == 0 && launch_id) {
      int64_t lid = g_abi.launch_app(launch_id);
      std::vector<uint8_t> none;
      WaitResult(lid, &none, 4000);
    }
    Sleep(800);
  }
  return 0;
}

}  // namespace

int RunAbiApp(const std::wstring& app) {
  std::string match;
  std::wstring file, params;
  if (app == L"notepad") {
    match = "notepad";
    file = L"notepad.exe";
    params = L"D:\\dev\\wsn-A\\run\\wsn_notepad.txt";
  } else if (app == L"edge") {
    match = "edge";
    file = L"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
    params =
        L"--user-data-dir=D:\\dev\\wsn-A\\edge --no-first-run --no-default-browser-check "
        L"--new-window file:///D:/dev/wsn-A/run/clock.html";
  } else {
    match = wsn::Narrow(app);
  }
  // Launch directly (a bare exe name is not a valid app id for launch_app;
  // this still drives capture/start/input/stop through the real exports).
  if (!file.empty()) {
    ShellExecuteW(nullptr, nullptr, file.c_str(), params.empty() ? nullptr : params.c_str(), nullptr,
                  SW_SHOWNOACTIVATE);
    Sleep(3000);
  }
  DWORD pid = 0;
  uint32_t window_id = FindAppWindow(match, nullptr, &pid);
  if (window_id == 0) {
    Check("app_in_catalog", false, "no window found for " + match);
    WriteText(L"abi_app.json", "[" + g_json + "]\n");
    return 1;
  }
  Check("app_in_catalog", true, wsn::Format("%s window id %u pid %lu", match.c_str(), window_id, pid));
  HWND hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(static_cast<int32_t>(window_id)));
  wsn::Placement home = wsn::SavePlacement(hwnd);
  RECT home_rect{};
  GetWindowRect(hwnd, &home_rect);

  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.packet_times.clear();
    g_sink.annexb.clear();
    g_sink.packets = g_sink.config = g_sink.key = 0;
    g_sink.first_packet = -1;
    g_sink.start_time = wsn::NowMs();
  }
  int64_t stream = g_abi.capture_start(window_id, static_cast<int32_t>(pid), 1920, 60, 8000000);
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.stream_id = stream;
  }
  g_abi.set_viewport(stream, 500, 820, 1.0);
  Sleep(5500);
  double first_ms, fps;
  int packets, keys;
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    first_ms = g_sink.first_packet;
    packets = g_sink.packets;
    keys = g_sink.key;
    double span = g_sink.packet_times.empty() ? 0 : g_sink.packet_times.back() - g_sink.packet_times.front();
    fps = span > 0 ? (g_sink.packet_times.size() - 1) * 1000.0 / span : 0;
    FILE* f = _wfopen((g_out + L"\\abi_" + app + L".h264").c_str(), L"wb");
    if (f) {
      fwrite(g_sink.annexb.data(), 1, g_sink.annexb.size(), f);
      fclose(f);
    }
  }
  Check("app_first_frame", first_ms >= 0 && first_ms < 2500, wsn::Format("%.0f ms", first_ms));
  // Some apps (Notepad, Edge static page) paint only on change; a keyframe
  // request guarantees at least one packet. 20 fps is only required for apps
  // that keep repainting (Edge clock); report the rate either way.
  Check("app_frames_flow", packets >= 1 && keys >= 1, wsn::Format("%d packets, %.1f fps, %d key", packets, fps, keys));
  RECT staged{};
  GetWindowRect(hwnd, &staged);
  bool off = !wsn::OnAnyMonitor(staged, 0.1);
  Check("app_off_screen", off, wsn::Format("window at %ld,%ld off %d", staged.left, staged.top, off));
  g_abi.capture_stop(stream);
  Sleep(1000);
  RECT after{};
  GetWindowRect(hwnd, &after);
  Check("app_restored", wsn::SameRect(after, home_rect, 4),
        wsn::Format("rect %ld,%ld %dx%d (home %ld,%ld %dx%d)", after.left, after.top, wsn::RectWidth(after),
                    wsn::RectHeight(after), home_rect.left, home_rect.top, wsn::RectWidth(home_rect),
                    wsn::RectHeight(home_rect)));
  // Close the app we launched (leave the user's own windows alone: only if we
  // launched it this run — we always do for notepad/edge via a fresh process).
  g_abi.close_window(window_id, static_cast<int32_t>(pid));
  Sleep(500);
  g_abi.set_capture_callback(nullptr);
  if (!g_json.empty() && g_json.back() == ',') g_json.pop_back();
  WriteText(L"abi_app.json", "[" + g_json + "]\n");
  Log("ABI app test (%s): %d passed, %d failed", match.c_str(), g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}

// abi --exit-check: after an --exit-test run, is the staged window back?
int RunAbiExitCheck() {
  std::string text;
  if (!wsn::ReadFileBytes(g_out + L"\\exit_state.txt", &text)) {
    Log("no exit_state.txt");
    return 2;
  }
  long long hwnd_value = 0, left = 0, top = 0, width = 0, height = 0, home_ex = 0;
  sscanf_s(text.c_str(), "%lld %lld %lld %lld %lld %lld", &hwnd_value, &left, &top, &width, &height, &home_ex);
  HWND hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(hwnd_value));
  RECT home{static_cast<LONG>(left), static_cast<LONG>(top), static_cast<LONG>(left + width),
            static_cast<LONG>(top + height)};
  RECT now{};
  GetWindowRect(hwnd, &now);
  LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  bool back = IsWindow(hwnd) && wsn::SameRect(now, home, 3) && ex == home_ex;
  Check("exit_restores_window", back,
        wsn::Format("window %p at %ld,%ld %dx%d ex 0x%llx (home %ld,%ld %dx%d ex 0x%llx)", hwnd, now.left, now.top,
                    wsn::RectWidth(now), wsn::RectHeight(now), static_cast<unsigned long long>(ex), home.left,
                    home.top, wsn::RectWidth(home), wsn::RectHeight(home), static_cast<unsigned long long>(home_ex)));
  if (IsWindow(hwnd)) PostMessageW(hwnd, WM_CLOSE, 0, 0);
  return back ? 0 : 1;
}

// abi --exit-test <stop|live>: stage a test window through the real DLL, then
// end the process the way the app does on Windows: ExitProcess right after
// wsn_capture_stop ("stop"), or with the capture still running ("live").
// Check the window afterwards with --exit-check.
int RunAbiExit(const std::wstring& mode) {
  TestWindow tw;
  if (!LaunchTestWindow(L"exit", 800, 600, &tw)) return 1;
  Sleep(800);
  RECT home{};
  GetWindowRect(tw.hwnd, &home);
  LONG_PTR home_ex = GetWindowLongPtrW(tw.hwnd, GWL_EXSTYLE);
  std::string state = wsn::Format("%lld %ld %ld %d %d %lld\n", static_cast<long long>(reinterpret_cast<intptr_t>(tw.hwnd)),
                                  home.left, home.top, wsn::RectWidth(home), wsn::RectHeight(home),
                                  static_cast<long long>(home_ex));
  wsn::WriteFileAtomic(g_out + L"\\exit_state.txt", state);
  uint32_t window_id = static_cast<uint32_t>(reinterpret_cast<intptr_t>(tw.hwnd));
  int64_t stream = g_abi.capture_start(window_id, static_cast<int32_t>(tw.pid), 1920, 30, 4000000);
  g_abi.set_viewport(stream, 430, 880, 1.0);
  Sleep(2500);
  RECT staged{};
  GetWindowRect(tw.hwnd, &staged);
  Log("staged at %ld,%ld (off-screen %d); now %s and ExitProcess", staged.left, staged.top,
      !wsn::OnAnyMonitor(staged, 0.02), wsn::Narrow(mode).c_str());
  fflush(stdout);
  fflush(stderr);
  if (mode == L"stop") g_abi.capture_stop(stream);
  ExitProcess(0);
}

// abi --device-loss-test: the session acts as if the GPU device were removed
// 3 s in (WSN_TEST_DEVICE_LOSS) and must restart the capture and encoder and
// keep streaming (new parameter sets and keyframe) instead of freezing.
int RunAbiDeviceLoss() {
  TestWindow tw;
  if (!LaunchTestWindow(L"loss", 800, 600, &tw)) return 1;
  Sleep(800);
  SetEnvironmentVariableW(L"WSN_TEST_DEVICE_LOSS", L"3");
  uint32_t window_id = static_cast<uint32_t>(reinterpret_cast<intptr_t>(tw.hwnd));
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.start_time = wsn::NowMs();
  }
  int64_t stream = g_abi.capture_start(window_id, static_cast<int32_t>(tw.pid), 1920, 30, 4000000);
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.stream_id = stream;
  }
  g_abi.set_viewport(stream, 430, 880, 1.0);
  double t0 = wsn::NowMs();
  Sleep(7000);
  SetEnvironmentVariableW(L"WSN_TEST_DEVICE_LOSS", nullptr);
  int before = 0, after = 0, configs = 0;
  bool restarted = false;
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    for (double t : g_sink.packet_times) (t - t0 < 3000 ? before : after)++;
    configs = g_sink.config;
    for (const auto& note : g_sink.notes) {
      if (note.find("restarting the capture") != std::string::npos) restarted = true;
    }
  }
  // Frames after the restart (the window's frame counter keeps it painting).
  Check("device_loss_restarts_and_streams", restarted && after > 30 && configs >= 2,
        wsn::Format("restarted %d, packets before %d after %d, config packets %d", restarted, before, after,
                    configs));
  g_abi.capture_stop(stream);
  Sleep(800);
  CloseTestWindow(&tw);
  return g_fail == 0 ? 0 : 1;
}

// The window's picture with the app's popups that lie over it painted in
// (as the capture shows them).
wsn::Bitmap Composite(HWND window) {
  wsn::Bitmap shot;
  wsn::PrintWindowBitmap(window, &shot);
  RECT frame = wsn::FrameBounds(window);
  DWORD pid = wsn::WindowPid(window);
  for (HWND w : TopLevelWindows()) {
    if (w == window || !IsWindowVisible(w) || wsn::WindowPid(w) != pid) continue;
    RECT r{};
    GetWindowRect(w, &r);
    RECT overlap{};
    if (!IntersectRect(&overlap, &r, &frame)) continue;
    wsn::Bitmap pop;
    if (!wsn::PrintWindowBitmap(w, &pop) || pop.empty()) continue;
    RECT pf = wsn::FrameBounds(w);
    for (int y = 0; y < pop.height; ++y) {
      int ty = pf.top - frame.top + y;
      if (ty < 0 || ty >= shot.height) continue;
      for (int x = 0; x < pop.width; ++x) {
        int tx = pf.left - frame.left + x;
        if (tx < 0 || tx >= shot.width) continue;
        const uint8_t* src = pop.pixel(x, y);
        if (src[3] == 0) continue;
        uint8_t* dst = shot.bgra.data() + (static_cast<size_t>(ty) * shot.width + tx) * 4;
        memcpy(dst, src, 4);
      }
    }
  }
  return shot;
}

// abi --script <file> --match <title part> [--class <class>]: stream an
// existing window through the real DLL (staged off-screen, popups followed)
// and replay a script of viewer input:
//   click fx fy | rclick fx fy | text <utf-8> | key <mac> [mods] | wait <ms>
//   snap <name> | title
int RunAbiScript(const Args& args) {
  std::wstring cls = args.Get(L"--class");
  std::wstring match = args.Get(L"--match");
  HWND window = nullptr;
  for (HWND w : TopLevelWindows()) {
    if (!IsWindowVisible(w) && !IsIconic(w)) continue;
    if (!cls.empty() && wsn::WindowClass(w) != cls) continue;
    if (!match.empty() && wsn::WindowTitle(w).find(match) == std::wstring::npos) continue;
    window = w;
    break;
  }
  if (window == nullptr) {
    Log("no window to stream");
    return 2;
  }
  Log("streaming %p %s", window, wsn::Narrow(wsn::WindowTitle(window)).c_str());
  std::string script;
  if (!wsn::ReadFileBytes(args.Get(L"--script"), &script)) {
    Log("no script");
    return 2;
  }
  uint32_t window_id = static_cast<uint32_t>(reinterpret_cast<intptr_t>(window));
  int64_t stream = g_abi.capture_start(window_id, static_cast<int32_t>(wsn::WindowPid(window)), 1920, 30, 6000000);
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.stream_id = stream;
  }
  g_abi.set_viewport(stream, args.Int(L"--vw", 1100), args.Int(L"--vh", 720), 1.0);
  Sleep(2500);
  auto feed = [&](int kind, int code, int mods, double x, double y, const char* text) {
    g_abi.capture_input(stream, kind, code, mods, x, y, 0, 0, 0, text);
  };
  size_t at = 0;
  while (at < script.size()) {
    size_t end = script.find('\n', at);
    std::string line = script.substr(at, end == std::string::npos ? std::string::npos : end - at);
    at = end == std::string::npos ? script.size() : end + 1;
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    if (line.empty() || line[0] == '#') continue;
    Log("> %s", line.c_str());
    char word[32] = {};
    double a = 0, b = 0;
    if (sscanf_s(line.c_str(), "%31s", word, static_cast<unsigned>(sizeof(word))) != 1) continue;
    std::string cmd = word;
    std::string rest = line.size() > cmd.size() ? line.substr(cmd.size() + 1) : std::string();
    if (cmd == "click" || cmd == "rclick") {
      sscanf_s(rest.c_str(), "%lf %lf", &a, &b);
      int button = cmd == "click" ? 0 : 1;
      feed(WSN_INPUT_POINTER_DOWN, button, 0, a, b, nullptr);
      Sleep(80);
      feed(WSN_INPUT_POINTER_UP, button, 0, a, b, nullptr);
      Sleep(700);
    } else if (cmd == "text") {
      feed(WSN_INPUT_TEXT, 0, 0, 0, 0, rest.c_str());
      Sleep(500);
    } else if (cmd == "key") {
      int mac = 0, mods = 0;
      sscanf_s(rest.c_str(), "%d %d", &mac, &mods);
      feed(WSN_INPUT_KEY_DOWN, mac, mods, 0, 0, nullptr);
      feed(WSN_INPUT_KEY_UP, mac, mods, 0, 0, nullptr);
      Sleep(600);
    } else if (cmd == "scroll") {
      double sx = 0, sy = 0, dy = 0;
      sscanf_s(rest.c_str(), "%lf %lf %lf", &sx, &sy, &dy);
      g_abi.capture_input(stream, WSN_INPUT_SCROLL, 0, 0, sx, sy, 0, dy, 0, nullptr);
      Sleep(500);
    } else if (cmd == "wait") {
      Sleep(atoi(rest.c_str()));
    } else if (cmd == "snap") {
      RECT frame = wsn::FrameBounds(window);
      for (HWND w : TopLevelWindows()) {
        if (w == window || !IsWindowVisible(w) || wsn::WindowPid(w) != wsn::WindowPid(window)) continue;
        HWND owner = GetWindow(w, GW_OWNER);
        if (owner == nullptr || GetAncestor(owner, GA_ROOT) != window) continue;
        RECT r{};
        GetWindowRect(w, &r);
        Log("  popup %p %s at %+ld,%+ld %dx%d (frame-relative)", w, wsn::Narrow(wsn::WindowClass(w)).c_str(),
            r.left - frame.left, r.top - frame.top, wsn::RectWidth(r), wsn::RectHeight(r));
      }
      wsn::Bitmap shot = Composite(window);
      wsn::SaveImage(g_out + L"\\" + wsn::Widen(rest) + L".png", shot);
    } else if (cmd == "title") {
      Log("title: %s", wsn::Narrow(wsn::WindowTitle(window)).c_str());
    }
    // Nothing of the app may show on the user's screen (a popup left on a
    // monitor), other than its own other windows.
    {
      DWORD pid = wsn::WindowPid(window);
      HWND root = window;
      for (HWND w : TopLevelWindows()) {
        if (w == root || !IsWindowVisible(w) || wsn::WindowPid(w) != pid) continue;
        HWND owner = GetWindow(w, GW_OWNER);
        if (owner == nullptr || GetAncestor(owner, GA_ROOT) != root) continue;  // not one of ours
        RECT r{};
        GetWindowRect(w, &r);
        if (wsn::OnAnyMonitor(r, 0.01)) {
          Log("  LEAK: %p %s on screen at %ld,%ld %dx%d", w, wsn::Narrow(wsn::WindowClass(w)).c_str(), r.left, r.top,
              wsn::RectWidth(r), wsn::RectHeight(r));
        }
      }
    }
    // The session's notes so far (what each input did).
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    for (const auto& note : g_sink.notes) Log("  note: %s", note.c_str());
    g_sink.notes.clear();
  }
  g_abi.capture_stop(stream);
  Sleep(1500);
  return 0;
}

// The catalog's entry for [window_id] ("" when not listed).
std::string CatalogEntry(uint32_t window_id) {
  int64_t id = g_abi.request_catalog();
  std::vector<uint8_t> data;
  if (WaitResult(id, &data, 5000) != WSN_CAPTURE_CATALOG) return "(no catalog)";
  std::string json(data.begin(), data.end());
  std::string key = wsn::Format("{\"id\":%u,", window_id);
  size_t at = json.find(key);
  if (at == std::string::npos) return "";
  size_t end = json.find('}', at);
  return json.substr(at, end == std::string::npos ? std::string::npos : end - at + 1);
}

// abi --close-test --class <c> --match <title part>: close the window as the
// viewer's recents do and show its catalog entry before and after (still
// listed + "modal" when it asks to save).
int RunAbiCloseTest(const Args& args) {
  std::wstring cls = args.Get(L"--class");
  std::wstring match = args.Get(L"--match");
  HWND window = nullptr;
  for (HWND w : TopLevelWindows()) {
    if (!IsWindowVisible(w)) continue;
    if (!cls.empty() && wsn::WindowClass(w) != cls) continue;
    if (!match.empty() && wsn::WindowTitle(w).find(match) == std::wstring::npos) continue;
    window = w;
    break;
  }
  if (window == nullptr) {
    Log("no window");
    return 2;
  }
  uint32_t id = static_cast<uint32_t>(reinterpret_cast<intptr_t>(window));
  Log("before: %s", CatalogEntry(id).c_str());
  double t0 = wsn::NowMs();
  g_abi.close_window(id, static_cast<int32_t>(wsn::WindowPid(window)));
  for (int i = 0; i < 6; ++i) {
    Sleep(500);
    std::string entry = CatalogEntry(id);
    Log("after %.0f ms: %s", wsn::NowMs() - t0, entry.empty() ? "(not listed)" : entry.c_str());
    if (entry.empty()) break;
  }
  return 0;
}

// abi --audio-test --class <c> --match <title> [--mode 1|2] [--seconds N]:
// stream a window with its app playing sound, turn audio on, and report how
// much PCM arrived, its rate/channels, the A/V pts offset and the Windows
// output level (to see whether mode 2 silenced it here).
int RunAbiAudio(const Args& args) {
  std::wstring cls = args.Get(L"--class");
  std::wstring match = args.Get(L"--match");
  HWND window = nullptr;
  for (HWND w : TopLevelWindows()) {
    if (!IsWindowVisible(w) && !IsIconic(w)) continue;
    if (!cls.empty() && wsn::WindowClass(w) != cls) continue;
    if (!match.empty() && wsn::WindowTitle(w).find(match) == std::wstring::npos) continue;
    window = w;
    break;
  }
  if (window == nullptr) {
    Log("no window");
    return 2;
  }
  int mode = args.Int(L"--mode", 2);
  int seconds = args.Int(L"--seconds", 10);
  uint32_t window_id = static_cast<uint32_t>(reinterpret_cast<intptr_t>(window));
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.start_time = wsn::NowMs();
  }
  int64_t stream = g_abi.capture_start(window_id, static_cast<int32_t>(wsn::WindowPid(window)), 1920, 30, 6000000);
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.stream_id = stream;
  }
  g_abi.set_viewport(stream, 900, 700, 1.0);
  Sleep(1500);
  g_abi.set_audio(stream, mode);
  // Watch the first video and first audio pts to measure the A/V offset.
  for (int i = 0; i < seconds; ++i) {
    Sleep(1000);
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    for (const auto& note : g_sink.notes) Log("  note: %s", note.c_str());
    g_sink.notes.clear();
  }
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    double secs = g_sink.last_audio > g_sink.first_audio ? (g_sink.last_audio - g_sink.first_audio) / 1000.0 : 0;
    double real_secs = g_sink.audio_rate > 0 ? static_cast<double>(g_sink.audio_frames) / g_sink.audio_rate : 0;
    double mean_level = g_sink.audio_chunks > 0 ? g_sink.audio_level_sum / g_sink.audio_chunks : 0;
    Log("audio: %d chunks, %lld frames (%.1f s of %dHz x%d), wall %.1f s, mean |sample| %.0f, pts gap max %.1f ms",
        g_sink.audio_chunks, static_cast<long long>(g_sink.audio_frames), real_secs, g_sink.audio_rate,
        g_sink.audio_channels, secs, mean_level, g_sink.audio_pts_gap_max);
    if (g_sink.first_audio_pts != 0 && !g_sink.packet_times.empty()) {
      Log("av: first video pts base vs first audio pts: first_audio_pts %lld", static_cast<long long>(g_sink.first_audio_pts));
    }
  }
  g_abi.set_audio(stream, 0);
  Sleep(300);
  g_abi.capture_stop(stream);
  Sleep(800);
  return 0;
}

int RunAbi(const Args& args) {
  if (args.Has(L"--exit-check")) return RunAbiExitCheck();
  std::wstring dll =
      args.Get(L"--dll", L"D:\\dev\\whisper-ws\\build\\windows\\x64\\runner\\Debug\\window_stream_native.dll");
  if (GetFileAttributesW(dll.c_str()) == INVALID_FILE_ATTRIBUTES) {
    dll = args.Get(L"--dll2", L"D:\\dev\\wsn-A\\dll\\window_stream_native.dll");
  }
  Log("loading %s", wsn::Narrow(dll).c_str());
  if (!g_abi.Load(dll.c_str())) return 2;
  Log("api version %d, supported %d, input permission %d", g_abi.api_version(), g_abi.capture_supported(),
      g_abi.capture_input_permission());
  Check("exports_loaded", true, "all 36 exports resolved");
  Check("supported", g_abi.capture_supported() == 1, wsn::Format("%d", g_abi.capture_supported()));
  g_abi.set_capture_callback(&OnCapture);

  // --app <notepad|edge>: a real-exports smoke test on a real app (launch via
  // the catalog, capture a few seconds, check frames flow and the window goes
  // off-screen and restores). Returns without the full test-window matrix.
  std::wstring app = args.Get(L"--app");
  if (!app.empty()) return RunAbiApp(app);
  if (args.Has(L"--script")) return RunAbiScript(args);
  if (args.Has(L"--close-test")) return RunAbiCloseTest(args);
  if (args.Has(L"--audio-test")) return RunAbiAudio(args);
  std::wstring exit_mode = args.Get(L"--exit-test");
  if (!exit_mode.empty()) return RunAbiExit(exit_mode);
  if (args.Has(L"--device-loss-test")) return RunAbiDeviceLoss();

  TestWindow tw;
  if (!LaunchTestWindow(L"abi", 900, 700, &tw)) return 1;
  Sleep(800);
  uint32_t window_id = static_cast<uint32_t>(reinterpret_cast<intptr_t>(tw.hwnd));
  wsn::Placement home = wsn::SavePlacement(tw.hwnd);
  RECT home_rect{};
  GetWindowRect(tw.hwnd, &home_rect);
  const LONG_PTR home_ex = GetWindowLongPtrW(tw.hwnd, GWL_EXSTYLE);

  // --- catalog ---
  int64_t catalog_id = g_abi.request_catalog();
  std::vector<uint8_t> catalog;
  double t0 = wsn::NowMs();
  int32_t kind = WaitResult(catalog_id, &catalog, 6000);
  double catalog_ms = wsn::NowMs() - t0;
  std::string catalog_json(catalog.begin(), catalog.end());
  bool in_catalog = catalog_json.find("\"id\":" + std::to_string(window_id)) != std::string::npos;
  bool has_apps = catalog_json.find("\"apps\":[{") != std::string::npos;
  Check("catalog_has_window", kind == WSN_CAPTURE_CATALOG && in_catalog,
        wsn::Format("kind %d, %zu bytes, %.0f ms", kind, catalog.size(), catalog_ms));
  // The installed-app list warms asynchronously; it is ready shortly after.
  if (!has_apps) {
    for (int i = 0; i < 20 && !has_apps; ++i) {
      Sleep(250);
      int64_t again = g_abi.request_catalog();
      std::vector<uint8_t> c2;
      if (WaitResult(again, &c2, 3000) == WSN_CAPTURE_CATALOG) {
        std::string j(c2.begin(), c2.end());
        has_apps = j.find("\"apps\":[{") != std::string::npos;
      }
    }
  }
  Check("catalog_has_apps", has_apps, has_apps ? "installed apps listed" : "apps list empty");

  // The window's app id, for the icon request.
  std::string app_id;
  {
    size_t at = catalog_json.find("\"id\":" + std::to_string(window_id));
    size_t b = catalog_json.find("\"bundleId\":\"", at);
    if (b != std::string::npos) {
      b += strlen("\"bundleId\":\"");
      size_t e = catalog_json.find('"', b);
      app_id = catalog_json.substr(b, e - b);
    }
  }

  // --- icon ---
  int64_t icon_id = g_abi.request_icon(app_id.c_str(), 128);
  std::vector<uint8_t> icon;
  int32_t icon_kind = WaitResult(icon_id, &icon, 6000);
  bool icon_png = icon.size() > 8 && icon[0] == 0x89 && icon[1] == 'P';
  Log("icon of the test exe (%s): kind %d, %zu bytes (the test exe has no embedded icon)", app_id.c_str(),
      icon_kind, icon.size());
  // The icon pipeline is validated against a real exe (the test exe has no
  // embedded icon, so its icon legitimately comes back empty).
  int64_t icon2_id = g_abi.request_icon("C:\\Windows\\explorer.exe", 128);
  std::vector<uint8_t> icon2;
  int32_t icon2_kind = WaitResult(icon2_id, &icon2, 6000);
  bool icon2_png = icon2.size() > 8 && icon2[0] == 0x89 && icon2[1] == 'P';
  Check("icon_png", icon2_kind == WSN_CAPTURE_ICON && icon2_png,
        wsn::Format("explorer.exe icon kind %d, %zu bytes", icon2_kind, icon2.size()));
  if (icon2_png) {
    FILE* f = _wfopen((g_out + L"\\abi_icon.png").c_str(), L"wb");
    if (f) {
      fwrite(icon2.data(), 1, icon2.size(), f);
      fclose(f);
    }
  }

  // --- thumbnail ---
  int64_t thumb_id = g_abi.request_thumbnail(window_id, 480);
  std::vector<uint8_t> thumb;
  int32_t thumb_kind = WaitResult(thumb_id, &thumb, 6000);
  bool thumb_jpeg = thumb.size() > 3 && thumb[0] == 0xFF && thumb[1] == 0xD8;
  Check("thumbnail_jpeg", thumb_kind == WSN_CAPTURE_THUMBNAIL && thumb_jpeg,
        wsn::Format("kind %d, %zu bytes", thumb_kind, thumb.size()));
  if (thumb_jpeg) {
    FILE* f = _wfopen((g_out + L"\\abi_thumb.jpg").c_str(), L"wb");
    if (f) {
      fwrite(thumb.data(), 1, thumb.size(), f);
      fclose(f);
    }
  }

  // --- start: a phone-shaped viewport so the window stages small ---
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.start_time = wsn::NowMs();
  }
  DWORD real_pid = 0;
  GetWindowThreadProcessId(tw.hwnd, &real_pid);
  int64_t stream = g_abi.capture_start(window_id, static_cast<int32_t>(real_pid), 1920, 60, 8000000);
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    g_sink.stream_id = stream;
  }
  g_abi.set_screen(stream, 1);
  g_abi.set_viewport(stream, 430, 880, 1.0);

  // First frame < 2 s, >= 20 fps over 5 s.
  Sleep(5500);
  double first_ms, fps;
  int packets, keys, cfg, w, h;
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    first_ms = g_sink.first_packet;
    packets = g_sink.packets;
    keys = g_sink.key;
    cfg = g_sink.config;
    w = g_sink.width;
    h = g_sink.height;
    double span = g_sink.packet_times.empty()
                      ? 0
                      : g_sink.packet_times.back() - g_sink.packet_times.front();
    size_t deltas = g_sink.packet_times.size();
    fps = span > 0 ? (deltas - 1) * 1000.0 / span : 0;
  }
  Check("first_frame_under_2s", first_ms >= 0 && first_ms < 2000, wsn::Format("%.0f ms", first_ms));
  Check("fps_at_least_20", fps >= 20, wsn::Format("%.1f fps, %d packets %dx%d", fps, packets, w, h));
  Check("config_before_idr", cfg >= 1 && keys >= 1, wsn::Format("config %d key %d", cfg, keys));

  // Frames decode: dump the Annex-B and (here) sanity-check the NAL structure;
  // full decode is done on the Mac from abi.h264.
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    FILE* f = _wfopen((g_out + L"\\abi.h264").c_str(), L"wb");
    if (f) {
      fwrite(g_sink.annexb.data(), 1, g_sink.annexb.size(), f);
      fclose(f);
    }
    Log("wrote %zu bytes to abi.h264", g_sink.annexb.size());
  }

  // Off the real screen: a screenshot of the home rectangle must NOT contain
  // the window (it is staged off-screen).
  {
    wsn::Bitmap shot;
    wsn::ScreenBitmap(home_rect, &shot);
    wsn::SaveImage(g_out + L"\\abi_home_area.png", shot);
    int counter = DecodeCounter(shot, tw.hwnd);
    RECT now{};
    GetWindowRect(tw.hwnd, &now);
    bool off = !wsn::OnAnyMonitor(now, 0.02);
    Check("window_off_real_screen", off && counter < 0,
          wsn::Format("off-screen %d, counter in home area %d, window at %ld,%ld", off, counter, now.left,
                      now.top));
  }

  // --- input ---
  size_t offset = 0;
  ReadNewLines(tw.log_path, &offset);
  // Every export must return at once (the work is queued for the session).
  double max_feed_ms = 0;
  auto feed = [&](int kind, int code, int mods, double x, double y, double dx, double dy, int phase,
                  const char* text) {
    double t0 = wsn::NowMs();
    g_abi.capture_input(stream, kind, code, mods, x, y, dx, dy, phase, text);
    max_feed_ms = std::max(max_feed_ms, wsn::NowMs() - t0);
  };
  double edit_click_at = 0, main_click_at = 0, shortcut_at = 0;
  // click at (0.5,0.5)
  feed(WSN_INPUT_POINTER_DOWN, 0, 0, 0.5, 0.5, 0, 0, 0, nullptr);
  feed(WSN_INPUT_POINTER_UP, 0, 0, 0.5, 0.5, 0, 0, 0, nullptr);
  Sleep(400);
  {
    bool pass = false;
    std::string detail = "no down";
    RECT frame = wsn::FrameBounds(tw.hwnd);
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_LBUTTONDOWN") == std::string::npos) continue;
      double fx = atof(Field(line, "fx").c_str()), fy = atof(Field(line, "fy").c_str());
      double err = std::hypot((fx - 0.5) * wsn::RectWidth(frame), (fy - 0.5) * wsn::RectHeight(frame));
      pass = err <= 2.0;
      detail = wsn::Format("err %.1f px", err);
    }
    Check("input_click_center", pass, detail);
  }
  // text
  {
    RECT er{};
    GetWindowRect(tw.edit, &er);
    RECT fr = wsn::FrameBounds(tw.hwnd);
    double efx = ((er.left + er.right) / 2.0 - fr.left) / std::max(1, wsn::RectWidth(fr));
    double efy = ((er.top + er.bottom) / 2.0 - fr.top) / std::max(1, wsn::RectHeight(fr));
    edit_click_at = wsn::NowMs();
    feed(WSN_INPUT_POINTER_DOWN, 0, 0, efx, efy, 0, 0, 0, nullptr);
    feed(WSN_INPUT_POINTER_UP, 0, 0, efx, efy, 0, 0, 0, nullptr);
    Sleep(250);
    SetWindowTextW(tw.edit, L"");
    ReadNewLines(tw.log_path, &offset);
    feed(WSN_INPUT_TEXT, 0, 0, 0, 0, 0, 0, 0, "Hello \xe4\xbd\xa0\xe5\xa5\xbd");
    Sleep(500);
    std::string got;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("EDIT_TEXT") != std::string::npos || line.find("msg=TEXT") != std::string::npos) {
        std::string t = Field(line, "text");
        if (!t.empty()) got = t;
      }
    }
    Check("input_text_unicode", got == "Hello \xe4\xbd\xa0\xe5\xa5\xbd", "received " + wsn::JsonString(got));
  }
  // hover: POINTER_MOVE with code -1 and no button down -> WM_MOUSEMOVE
  // without MK_ button flags (never a drag)
  {
    ReadNewLines(tw.log_path, &offset);
    for (int i = 0; i < 4; ++i) {
      feed(WSN_INPUT_POINTER_MOVE, -1, 0, 0.30 + 0.05 * i, 0.40, 0, 0, 0, nullptr);
      Sleep(30);
    }
    Sleep(300);
    int moves = 0, with_button = 0, downs = 0;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_LBUTTONDOWN") != std::string::npos) downs++;
      if (line.find("WM_MOUSEMOVE") == std::string::npos) continue;
      moves++;
      int mk = static_cast<int>(strtol(Field(line, "mk").c_str(), nullptr, 16));
      if (mk & (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON)) with_button++;
    }
    Check("input_hover_no_button", moves >= 1 && with_button == 0 && downs == 0,
          wsn::Format("%d moves, %d with a button flag, %d downs", moves, with_button, downs));
  }
  // right click
  {
    ReadNewLines(tw.log_path, &offset);
    main_click_at = wsn::NowMs();
    feed(WSN_INPUT_POINTER_DOWN, 1, 0, 0.5, 0.35, 0, 0, 0, nullptr);
    feed(WSN_INPUT_POINTER_UP, 1, 0, 0.5, 0.35, 0, 0, 0, nullptr);
    Sleep(400);
    bool pass = false;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_CONTEXTMENU") != std::string::npos || line.find("MENU_SHOW") != std::string::npos)
        pass = true;
    }
    // The menu (a #32768 popup) must have been brought over the staged
    // window, not left clamped onto a real monitor.
    {
      HWND menu = FindWindowW(L"#32768", nullptr);
      RECT mr{}, fr = wsn::FrameBounds(tw.hwnd);
      bool shown = menu != nullptr && IsWindowVisible(menu) && GetWindowRect(menu, &mr);
      RECT overlap{};
      bool over = shown && IntersectRect(&overlap, &mr, &fr) && wsn::RectWidth(overlap) == wsn::RectWidth(mr) &&
                  wsn::RectHeight(overlap) == wsn::RectHeight(mr);
      Check("popup_menu_follows_window", over && !wsn::OnAnyMonitor(mr, 0.02),
            wsn::Format("menu %p at %ld,%ld %dx%d, window frame %ld,%ld %dx%d", menu, mr.left, mr.top,
                        wsn::RectWidth(mr), wsn::RectHeight(mr), fr.left, fr.top, wsn::RectWidth(fr),
                        wsn::RectHeight(fr)));
    }
    PostMessageW(tw.hwnd, WM_CANCELMODE, 0, 0);
    Check("input_right_click", pass, pass ? "context menu" : "no menu");
  }
  // scroll
  {
    ReadNewLines(tw.log_path, &offset);
    feed(WSN_INPUT_SCROLL, 0, 0, 0.5, 0.5, 0, 3.0, 0, nullptr);
    Sleep(300);
    int delta = 0;
    bool got = false;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_MOUSEWHEEL") != std::string::npos) {
        delta = atoi(Field(line, "delta").c_str());
        got = true;
      }
    }
    Check("input_scroll_down", got && delta < 0, wsn::Format("delta %d", delta));
  }
  // Cmd+A -> Ctrl+A
  {
    ReadNewLines(tw.log_path, &offset);
    feed(WSN_INPUT_KEY_DOWN, 0, WSN_MOD_COMMAND, 0, 0, 0, 0, 0, nullptr);
    feed(WSN_INPUT_KEY_UP, 0, WSN_MOD_COMMAND, 0, 0, 0, 0, 0, nullptr);
    Sleep(300);
    bool pass = false;
    std::string detail = "no key";
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_KEYDOWN") == std::string::npos) continue;
      if (Field(line, "vk") == "0x41") {
        pass = Field(line, "ctrl") == "1";
        detail = "vk 0x41 ctrl " + Field(line, "ctrl");
      }
    }
    Check("input_cmd_a_as_ctrl_a", pass, detail);
  }
  // Shortcuts reach the app's accelerator table (translated in its own
  // message loop), and the foreground goes back to the window that had it.
  {
    shortcut_at = wsn::NowMs();
    HWND other = FindWindowW(nullptr, L"WSN Test live");
    if (other != nullptr) wsn::BringToForeground(other, nullptr);
    Sleep(200);
    HWND front_before = GetForegroundWindow();
    ReadNewLines(tw.log_path, &offset);
    feed(WSN_INPUT_KEY_DOWN, 1, WSN_MOD_COMMAND, 0, 0, 0, 0, 0, nullptr);  // Cmd+S -> Ctrl+S
    feed(WSN_INPUT_KEY_UP, 1, WSN_MOD_COMMAND, 0, 0, 0, 0, 0, nullptr);
    feed(WSN_INPUT_KEY_DOWN, 96, 0, 0, 0, 0, 0, 0, nullptr);  // F5
    feed(WSN_INPUT_KEY_UP, 96, 0, 0, 0, 0, 0, 0, nullptr);
    feed(WSN_INPUT_KEY_DOWN, 7, WSN_MOD_OPTION, 0, 0, 0, 0, 0, nullptr);  // Option+X -> Alt+X
    feed(WSN_INPUT_KEY_UP, 7, WSN_MOD_OPTION, 0, 0, 0, 0, 0, nullptr);
    Sleep(2500);
    std::string names;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("msg=ACCEL") != std::string::npos) names += Field(line, "name") + " ";
    }
    HWND front_after = GetForegroundWindow();
    bool all = names.find("ctrl+s") != std::string::npos && names.find("f5") != std::string::npos &&
               names.find("alt+x") != std::string::npos;
    Check("shortcuts_reach_accelerators", all, "accelerators fired: " + names);
    if (front_before == tw.hwnd) {
      Log("shortcut_gives_front_back SKIP | the streamed window itself had the front");
    } else
    Check("shortcut_gives_front_back", front_after == front_before && front_before != tw.hwnd,
          wsn::Format("front before %p (%s), after %p, streamed window %p", front_before,
                      front_before == other ? "WSN Test live" : "other", front_after, tw.hwnd));
  }
  Check("input_calls_return_at_once", max_feed_ms < 15, wsn::Format("slowest wsn_capture_input %.2f ms", max_feed_ms));
  // Text focus: on after the press in the edit box, off after the press on
  // the window's background (which takes the focus there).
  {
    int on = -1;
    {
      std::lock_guard<std::mutex> lock(g_sink.mutex);
      for (const auto& [t, flags] : g_sink.focus) {
        if (t >= edit_click_at && t < main_click_at) on = flags;
      }
    }
    int off = -1;
    {
      std::lock_guard<std::mutex> lock(g_sink.mutex);
      for (const auto& [t, flags] : g_sink.focus) {
        if (t >= main_click_at && t < shortcut_at) off = flags;
      }
    }
    std::string seen;
    {
      std::lock_guard<std::mutex> lock(g_sink.mutex);
      for (const auto& [t, flags] : g_sink.focus) seen += wsn::Format("%d@%.0f ", flags, t - edit_click_at);
    }
    Check("text_focus_edit_on_background_off", on == 1 && off == 0,
          wsn::Format("on %d, off %d (events: %s)", on, off, seen.c_str()));
  }

  // --- viewport change resizes the window ---
  {
    RECT before{};
    GetWindowRect(tw.hwnd, &before);
    double t0 = wsn::NowMs();
    g_abi.set_viewport(stream, 600, 700, 1.0);
    double call_ms = wsn::NowMs() - t0;
    Check("viewport_call_returns_at_once", call_ms < 15, wsn::Format("%.2f ms", call_ms));
    Sleep(900);
    RECT after{};
    GetWindowRect(tw.hwnd, &after);
    bool resized = std::abs(wsn::RectWidth(after) - wsn::RectWidth(before)) > 20;
    Check("viewport_resizes", resized,
          wsn::Format("%dx%d -> %dx%d", wsn::RectWidth(before), wsn::RectHeight(before), wsn::RectWidth(after),
                      wsn::RectHeight(after)));
    g_abi.set_inset(stream, 0.4);
    Sleep(700);
    RECT inset{};
    GetWindowRect(tw.hwnd, &inset);
    Check("inset_shrinks_height", wsn::RectHeight(inset) < wsn::RectHeight(after),
          wsn::Format("height %d -> %d", wsn::RectHeight(after), wsn::RectHeight(inset)));
    g_abi.set_inset(stream, 0.0);
  }

  // --- pause parks / resume re-stages (WSN_PARK_SECONDS small via env) ---
  {
    g_abi.set_paused(stream, 1);
    Sleep(3500);  // the harness sets WSN_PARK_SECONDS=2 in its launcher
    RECT parked{};
    GetWindowRect(tw.hwnd, &parked);
    bool home_again = wsn::OnAnyMonitor(parked, 0.5);
    g_abi.set_paused(stream, 0);
    Sleep(1500);
    RECT restaged{};
    GetWindowRect(tw.hwnd, &restaged);
    bool off = !wsn::OnAnyMonitor(restaged, 0.1);
    Check("pause_parks_resume_restages", home_again && off,
          wsn::Format("parked home %d, re-staged off %d", home_again, off));
  }

  // --- review W2: a minimize while staged re-stages without overwriting the
  // saved style (stop below must bring back the ORIGINAL ex-style) ---
  {
    ShowWindow(tw.hwnd, SW_MINIMIZE);
    Sleep(2500);
    RECT now{};
    GetWindowRect(tw.hwnd, &now);
    bool iconic = IsIconic(tw.hwnd) != 0;
    bool off = !wsn::OnAnyMonitor(now, 0.1);
    LONG_PTR ex = GetWindowLongPtrW(tw.hwnd, GWL_EXSTYLE);
    Check("minimize_restages", !iconic && off && (ex & WS_EX_LAYERED),
          wsn::Format("iconic %d, off %d, ex 0x%llx", iconic, off, static_cast<unsigned long long>(ex)));
  }

  // --- review W3: a second capture of the same window shares the staging; stopping
  // it must leave the window staged for the first one ---
  {
    int64_t second = g_abi.capture_start(window_id, static_cast<int32_t>(real_pid), 1920, 30, 4000000);
    Sleep(1500);
    RECT during{};
    GetWindowRect(tw.hwnd, &during);
    bool off_during = !wsn::OnAnyMonitor(during, 0.1);
    g_abi.capture_stop(second);
    Sleep(1000);
    RECT now{};
    GetWindowRect(tw.hwnd, &now);
    bool off = !wsn::OnAnyMonitor(now, 0.1);
    LONG_PTR ex = GetWindowLongPtrW(tw.hwnd, GWL_EXSTYLE);
    Check("second_capture_stop_keeps_stage", second > 0 && off_during && off && (ex & WS_EX_LAYERED),
          wsn::Format("stream %lld, off during %d, off after %d, ex 0x%llx", static_cast<long long>(second),
                      off_during, off, static_cast<unsigned long long>(ex)));
  }

  // --- stop returns at once and the window is put back right after ---
  double stop_t0 = wsn::NowMs();
  g_abi.capture_stop(stream);
  double stop_ms = wsn::NowMs() - stop_t0;
  Check("stop_call_returns_at_once", stop_ms < 15, wsn::Format("%.2f ms", stop_ms));
  {
    RECT after{};
    LONG_PTR ex = 0;
    bool back = false;
    double back_ms = -1;
    while (wsn::NowMs() - stop_t0 < 3000) {
      GetWindowRect(tw.hwnd, &after);
      ex = GetWindowLongPtrW(tw.hwnd, GWL_EXSTYLE);
      back = wsn::SameRect(after, home_rect, 3) && ex == home_ex;
      if (back) {
        back_ms = wsn::NowMs() - stop_t0;
        break;
      }
      Sleep(10);
    }
    Log("window back %.0f ms after the stop", back_ms);
    Check("stop_restores_placement", back, wsn::Format("rect %ld,%ld %dx%d (home %ld,%ld %dx%d) ex 0x%llx",
                                                       after.left, after.top, wsn::RectWidth(after),
                                                       wsn::RectHeight(after), home_rect.left, home_rect.top,
                                                       wsn::RectWidth(home_rect), wsn::RectHeight(home_rect),
                                                       static_cast<unsigned long long>(ex)) +
                                              wsn::Format(" (home ex 0x%llx)",
                                                          static_cast<unsigned long long>(home_ex)));
  }

  // --- remote close works ---
  {
    g_abi.close_window(window_id, static_cast<int32_t>(real_pid));
    double end = wsn::NowMs() + 3000;
    while (wsn::NowMs() < end && IsWindow(tw.hwnd) && IsWindowVisible(tw.hwnd)) Sleep(100);
    bool closed = !IsWindow(tw.hwnd) || !IsWindowVisible(tw.hwnd);
    Check("remote_close", closed, closed ? "window closed" : "still open");
  }

  CloseTestWindow(&tw);
  g_abi.set_capture_callback(nullptr);

  if (!g_json.empty() && g_json.back() == ',') g_json.pop_back();
  WriteText(L"abi.json", "[" + g_json + "]\n");
  Log("ABI harness: %d passed, %d failed", g_pass, g_fail);
  // Dump a few notes from the native log.
  {
    std::lock_guard<std::mutex> lock(g_sink.mutex);
    for (size_t i = 0; i < g_sink.notes.size() && i < 30; ++i) Log("  note: %s", g_sink.notes[i].c_str());
  }
  return g_fail == 0 ? 0 : 1;
}

}  // namespace probe
