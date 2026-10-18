#include "capture_session.h"

#include "common/wsn_common.h"
#include "wsn_image.h"

#include <algorithm>
#include <map>
#include <set>

#include <winrt/base.h>

namespace wsn {

namespace {

// Frames smaller than this on either edge are skipped (a minimized window's
// stub); the encoders reject such sizes.
constexpr LONG kMinFrameEdge = 32;

// Command coalescing tags: a newer command with the same tag replaces one
// still waiting at the tail of the queue (only the latest matters).
constexpr int kTagMove = 1;
constexpr int kTagViewport = 2;
constexpr int kTagInset = 3;
constexpr int kTagScreen = 4;
constexpr int kTagPopups = 5;
// Beyond this many waiting commands (an app that stopped answering), new
// input is dropped instead of piling up.
constexpr size_t kMaxQueued = 512;

// Seconds a pause must last before the window is sent home (overridable for
// tests with WSN_PARK_SECONDS).
double ParkSeconds() {
  wchar_t buffer[32];
  DWORD n = GetEnvironmentVariableW(L"WSN_PARK_SECONDS", buffer, 32);
  if (n > 0 && n < 32) {
    double value = _wtof(buffer);
    if (value > 0) return value;
  }
  return 60.0;
}

// Leaked on purpose (like common/util.cpp and receiver globals): on exit(0)
// the DLL's static destructors run in DLL_PROCESS_DETACH after other threads
// are gone, and ~CaptureSession's WinRT/MF/D3D teardown could hang there (W17).
std::mutex& g_registry_mutex = *new std::mutex();
std::map<int64_t, std::shared_ptr<CaptureSession>>& g_sessions =
    *new std::map<int64_t, std::shared_ptr<CaptureSession>>();

// One journal file shared by every session (so each session's entry is kept
// when another writes). Loaded once.
std::mutex g_journal_mutex;
Journal& SharedJournal() {
  static Journal* journal = [] {
    auto* j = new Journal();
    j->Load();
    return j;
  }();
  return *journal;
}
void JournalPut(const JournalEntry& entry) {
  std::lock_guard<std::mutex> lock(g_journal_mutex);
  SharedJournal().Upsert(entry);
}
void JournalDrop(uint32_t window_id) {
  std::lock_guard<std::mutex> lock(g_journal_mutex);
  SharedJournal().Remove(window_id);
}

// One staging owner per HWND, shared by every session that stages the same
// window. The first owner saves the real home placement and style; later
// owners reuse them, so a second capture never records the staged state as
// "home" (W2/W3). The last owner restores. Slots are handed out from a free
// set so two off-screen windows never collide on the same corner (W13).
struct StageOwner {
  Placement home;
  StyleBackup style;
  int slot = 0;
  int refs = 0;
};
std::mutex g_stage_mutex;
std::map<HWND, StageOwner> g_stage_owners;
std::set<int> g_used_slots;

// Takes (or joins) ownership of [window]'s staging. Returns false when the
// style could not be applied (nothing is changed then).
bool StageAcquire(HWND window, Placement* home, StyleBackup* style, int* slot) {
  std::lock_guard<std::mutex> lock(g_stage_mutex);
  auto it = g_stage_owners.find(window);
  if (it != g_stage_owners.end()) {
    it->second.refs++;
    *home = it->second.home;
    *style = it->second.style;
    *slot = it->second.slot;
    return true;
  }
  StageOwner owner;
  owner.home = SavePlacement(window);
  if (!ApplyStageStyle(window, &owner.style)) return false;
  int count = std::max(1, StageSlotCount());
  owner.slot = 0;
  for (int s = 0; s < count; ++s) {
    if (!g_used_slots.count(s)) {
      owner.slot = s;
      break;
    }
  }
  g_used_slots.insert(owner.slot);
  owner.refs = 1;
  g_stage_owners[window] = owner;
  *home = owner.home;
  *style = owner.style;
  *slot = owner.slot;
  return true;
}

// Releases a staging reference. When it was the last one, restores the window
// (placement + style) and frees the slot, and returns true.
bool StageRelease(HWND window, bool restore_placement) {
  Placement home;
  StyleBackup style;
  bool last = false;
  {
    std::lock_guard<std::mutex> lock(g_stage_mutex);
    auto it = g_stage_owners.find(window);
    if (it == g_stage_owners.end()) return true;  // never acquired
    if (--it->second.refs > 0) return false;
    home = it->second.home;
    style = it->second.style;
    g_used_slots.erase(it->second.slot);
    g_stage_owners.erase(it);
    last = true;
  }
  if (last && IsWindow(window)) {
    RestoreStageStyle(window, style);
    if (restore_placement) RestorePlacement(window, home);
  }
  return last;
}

}  // namespace

void RestoreStagedAtExit() {
  // Other threads are gone; one may have died holding the lock, and then
  // the journal puts the windows back on the next start instead.
  if (!g_stage_mutex.try_lock()) return;
  std::vector<std::pair<HWND, StageOwner>> owners(g_stage_owners.begin(), g_stage_owners.end());
  g_stage_owners.clear();
  g_stage_mutex.unlock();
  for (auto& [window, owner] : owners) {
    // Never wait on an app that does not answer: the process is ending.
    if (!IsWindow(window) || IsHungAppWindow(window)) continue;
    RestoreStageStyle(window, owner.style);
    WINDOWPLACEMENT wp = owner.home.wp;
    wp.length = sizeof(wp);
    wp.flags |= WPF_ASYNCWINDOWPLACEMENT;
    wp.showCmd = owner.home.minimized ? SW_SHOWMINNOACTIVE : owner.home.maximized ? SW_SHOWMAXIMIZED : SW_SHOWNOACTIVATE;
    SetWindowPlacement(window, &wp);
    if (!owner.home.minimized && !owner.home.maximized) {
      const RECT& r = owner.home.rect;
      SetWindowPos(window, nullptr, r.left, r.top, RectWidth(r), RectHeight(r),
                   SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS);
    }
  }
}

std::shared_ptr<CaptureSession> RegisterCapture(std::shared_ptr<CaptureSession> session) {
  std::lock_guard<std::mutex> lock(g_registry_mutex);
  g_sessions[session->id()] = session;
  return session;
}

std::shared_ptr<CaptureSession> FindCapture(int64_t id) {
  std::lock_guard<std::mutex> lock(g_registry_mutex);
  auto it = g_sessions.find(id);
  return it == g_sessions.end() ? nullptr : it->second;
}

void RemoveCapture(int64_t id) {
  std::shared_ptr<CaptureSession> session;
  {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    auto it = g_sessions.find(id);
    if (it != g_sessions.end()) {
      session = it->second;
      g_sessions.erase(it);
    }
  }
  // Destroyed outside the lock.
}

void ResetAllCapturesImpl() {
  std::vector<std::shared_ptr<CaptureSession>> all;
  {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    for (auto& [id, session] : g_sessions) all.push_back(session);
    g_sessions.clear();
  }
  for (auto& session : all) session->Stop();
}

CaptureSession::CaptureSession(int64_t id, uint32_t window_id, int pid, int max_edge, int fps, int bit_rate)
    : id_(id),
      window_id_(window_id),
      window_(IdToHwnd(window_id)),
      pid_(pid),
      max_edge_(max_edge),
      fps_(std::max(1, std::min(fps, 120))),
      bit_rate_(bit_rate),
      converter_(nullptr) {}

CaptureSession::~CaptureSession() { Stop(); }

// The stream's end (FAILED or STOPPED) is said once, however many paths see
// it (the WGC "closed" event and the watch both notice a closed window).
void CaptureSession::EmitEnd(int32_t kind, int32_t code) {
  if (end_emitted_.exchange(true)) return;
  EmitCapture(id_, kind, nullptr, 0, 0, code);
}

void CaptureSession::Note(const std::string& text) {
  Log("capture %lld: %s", static_cast<long long>(id_), text.c_str());
  EmitCapture(id_, WSN_CAPTURE_NOTE, text.data(), static_cast<int32_t>(text.size()));
}

void CaptureSession::Start() {
  if (running_.exchange(true)) return;
  // Detached: Stop() never waits for it. The thread keeps the session alive
  // until it has put the window back and torn down.
  std::thread([self = shared_from_this()] { self->Run(); }).detach();
}

void CaptureSession::Stop() {
  if (stopped_.exchange(true)) return;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    running_ = false;
    queue_.clear();  // pending input is moot; teardown lets go of held keys
  }
  wake_.notify_all();
}

void CaptureSession::Wake() {
  { std::lock_guard<std::mutex> lock(queue_mutex_); }
  wake_.notify_all();
}

void CaptureSession::Post(int coalesce, std::function<void()> run) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (!running_) return;
    if (coalesce != 0 && !queue_.empty() && queue_.back().coalesce == coalesce) {
      queue_.back().run = std::move(run);
    } else if (queue_.size() >= kMaxQueued) {
      if (!queue_full_noted_) {
        queue_full_noted_ = true;
        Log("capture %lld: command queue full, dropping input", static_cast<long long>(id_));
      }
      return;
    } else {
      queue_.push_back(Command{coalesce, std::move(run)});
    }
  }
  wake_.notify_all();
}

bool CaptureSession::VideoPending() const {
  return keyframe_pending_.load() || catch_up_pending_.load() || bit_rate_pending_.load();
}

// Session thread. Keyframes, the catch-up after "busy" and bit-rate changes
// go ahead of queued commands.
void CaptureSession::ServiceVideo() {
  bool key = keyframe_pending_.exchange(false);
  bool catch_up = catch_up_pending_.exchange(false);
  bool rate = bit_rate_pending_.exchange(false);
  if (!key && !catch_up && !rate) return;
  std::lock_guard<std::mutex> lock(frame_mutex_);
  if (rate) encoder_.SetBitRate(bit_rate_.load());
  if (key) {
    force_keyframe_ = true;
    skipped_while_busy_ = false;
    // A still window sends no new frame: re-encode the last one as a keyframe.
    ReencodeLast(true);
  } else if (catch_up && !busy_ && skipped_while_busy_) {
    skipped_while_busy_ = false;
    ReencodeLast(false);  // catch up to the newest frame
  }
}

void CaptureSession::Run() {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  // A message queue of its own, so AttachThreadInput (key state for the
  // target) works from this thread.
  MSG queue_probe;
  PeekMessageW(&queue_probe, nullptr, 0, 0, PM_NOREMOVE);
  d3d_ = D3D::Shared();
  converter_ = Converter(d3d_);
  if (!IsWindow(window_)) {
    EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_NOT_FOUND);
    running_ = false;
    return;
  }
  // The HWND may have been recycled to another process since the catalog:
  // never stream or inject into a window that is no longer the expected app.
  if (pid_ != 0) {
    HWND core = HostedCoreWindow(window_);
    DWORD frame_pid = WindowPid(window_);
    DWORD core_pid = core ? WindowPid(core) : frame_pid;
    if (static_cast<DWORD>(pid_) != frame_pid && static_cast<DWORD>(pid_) != core_pid) {
      EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_NOT_FOUND);
      running_ = false;
      return;
    }
  }
  if (d3d_ == nullptr) {
    EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_ENCODER);
    running_ = false;
    return;
  }
  injector_ = std::make_unique<Injector>(window_);
  injector_->on_note = [this](const std::string& note) { Note(note); };
  injector_->on_activated = [this] { our_activation_at_ = NowSeconds(); };

  home_ = SavePlacement(window_);
  // A minimized or maximized window is brought to a normal state as it is
  // staged (one SetWindowPlacement step, no flash at home).

  capture_options_.cursor = false;
  capture_options_.border = false;
  capture_options_.secondary = true;  // bring owned menus/dialogs into the frame
  capture_options_.min_interval_ms = 0;
  {
    // Test hook: act as if the GPU device were removed after N seconds.
    wchar_t buffer[16];
    DWORD n = GetEnvironmentVariableW(L"WSN_TEST_DEVICE_LOSS", buffer, 16);
    if (n > 0 && n < 16 && _wtof(buffer) > 0) simulate_loss_at_ = NowSeconds() + _wtof(buffer);
  }
  std::string error;
  bool ok = StartCapture(&error);
  if (!ok) {
    Note("capture start failed: " + error);
    int32_t code = error.find("not supported") != std::string::npos ? WSN_CAPTURE_ERROR_UNSUPPORTED
                                                                     : WSN_CAPTURE_ERROR_UNKNOWN;
    EmitEnd(WSN_CAPTURE_FAILED, code);
    running_ = false;
    return;
  }
  Note(Format("capturing hwnd 0x%08x pid %d", window_id_, pid_));

  // Where the window's focus is: a phone raises its keyboard for text fields.
  text_focus_ = std::make_unique<TextFocusWatcher>(window_, [id = id_](bool typing) {
    EmitCapture(id, WSN_CAPTURE_TEXT_FOCUS, nullptr, 0, 0, typing ? 1 : 0);
  });
  // Windows the app shows (menus, drop-downs, dialogs) are placed by the
  // session thread. (The watcher is stopped in Teardown, before this goes.)
  text_focus_->on_popup = [this](HWND popup) {
    {
      std::lock_guard<std::mutex> lock(popup_mutex_);
      pending_popups_.push_back(popup);
    }
    Post(kTagPopups, [this] { PlacePopups(); });
  };
  text_focus_->Start();

  // Let a few frames flow in place, then stage off-screen. (Commands wait.)
  {
    std::unique_lock<std::mutex> lock(queue_mutex_);
    for (int i = 0; i < 20 && running_ && !first_frame_sent_; ++i) {
      wake_.wait_for(lock, std::chrono::milliseconds(50), [this] { return !running_.load(); });
    }
  }
  // The viewer's viewport, inset and screen (sent right after the start)
  // apply before staging, so the window is staged at its size in one move.
  {
    std::vector<Command> setup;
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      for (auto it = queue_.begin(); it != queue_.end();) {
        if (it->coalesce == kTagViewport || it->coalesce == kTagInset || it->coalesce == kTagScreen) {
          setup.push_back(std::move(*it));
          it = queue_.erase(it);
        } else {
          ++it;
        }
      }
    }
    for (auto& command : setup) command.run();
  }
  if (running_ && !paused_) {
    // Test switch: stream every window where it is (the in-place fallback).
    if (EnvFlag(L"WSN_FORCE_IN_PLACE")) {
      FallBackInPlace("forced by WSN_FORCE_IN_PLACE");
    } else if (!StageNow()) {
      FallBackInPlace("staging refused");
    }
  }

  // Commands in order, the encoder requests first, and the watch every
  // 500 ms, until stopped.
  next_watch_ = NowSeconds() + 0.5;
  while (running_) {
    Command command;
    {
      std::unique_lock<std::mutex> lock(queue_mutex_);
      double wait_s = std::max(0.0, next_watch_ - NowSeconds());
      wake_.wait_for(lock, std::chrono::milliseconds(static_cast<int64_t>(wait_s * 1000) + 1),
                     [this] { return !running_ || !queue_.empty() || VideoPending(); });
      if (!running_) break;
      if (!queue_.empty()) {
        command = std::move(queue_.front());
        queue_.pop_front();
      }
    }
    ServiceVideo();
    if (command.run) command.run();
    if (running_ && NowSeconds() >= next_watch_) {
      Watch();
      next_watch_ = NowSeconds() + 0.5;
    }
  }
  Teardown();
}

bool CaptureSession::StartCapture(std::string* error) {
  auto self = shared_from_this();
  return capture_.Start(
      window_, capture_options_,
      [self](ID3D11Texture2D* texture, SIZE content, int64_t time_us) { self->OnFrame(texture, content, time_us); },
      [self] {  // the window was closed
        self->EmitEnd(WSN_CAPTURE_STOPPED, WSN_CAPTURE_ERROR_NOT_FOUND);
        self->running_ = false;
        self->Wake();
      },
      error);
}

// Session thread. The shared device was removed (driver update, TDR, a GPU
// going away): every texture, the video processor and the encoder on it are
// dead. Stop the capture, drop all of it, and start again on a new device;
// the next frame opens a new encoder (SIZE, parameter sets, IDR), so the
// viewer just carries on. The staging, the injector and the focus watch
// stay as they are.
bool CaptureSession::RestartOnNewDevice() {
  double now = NowSeconds();
  if (now - last_device_restart_ > 60) device_restarts_ = 0;
  if (++device_restarts_ > 3) {
    Note("GPU device lost again: giving up");
    return false;
  }
  last_device_restart_ = now;
  Note("GPU device removed: restarting the capture on a new device");
  capture_.Stop();  // waits for a frame callback in progress
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    encoder_.Close();
    converter_.Reset();
    nv12_ = nullptr;
    last_source_ = nullptr;
    last_source_size_ = SIZE{};
    encoded_size_ = SIZE{};
    in_flight_ = false;
    encoder_opened_at_ = 0;
    encoder_failed_ = false;
    convert_failures_ = 0;
    force_keyframe_ = true;
  }
  first_frame_sent_ = false;  // the encoder watchdog applies to the new encoder too
  device_lost_ = false;
  D3D* fresh = D3D::Shared();  // a new device once the old one reports removal
  if (fresh == nullptr) {
    Note("no Direct3D device after the removal");
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    d3d_ = fresh;
    converter_ = Converter(d3d_);
  }
  std::string error;
  if (!StartCapture(&error)) {
    Note("capture restart failed: " + error);
    return false;
  }
  return true;
}

// Session thread. Windows the app shows for the staged window (a menu, a
// drop-down, a flyout with its key tips, a dialog) land where the app or the
// system puts them: clamped onto a real monitor, where the user sees them
// and the stream does not. Shift them over the staged window, all by one
// offset (they are laid out relative to each other) — the biggest one goes
// where the viewer pressed, under the caret, or near the top left for one a
// key opened — so the capture (which includes owned windows) shows them, and
// tell the injector so pointer input over them goes to them.
void CaptureSession::PlacePopups() {
  Sleep(40);  // let the rest of a burst (a menu and its key tips) arrive
  std::vector<HWND> popups;
  {
    std::lock_guard<std::mutex> lock(popup_mutex_);
    popups.swap(pending_popups_);
  }
  if (!IsWindow(window_) || !injector_) return;
  std::sort(popups.begin(), popups.end());
  popups.erase(std::unique(popups.begin(), popups.end()), popups.end());
  DWORD thread = GetWindowThreadProcessId(window_, nullptr);
  bool recent_input = GetTickCount64() - injector_->last_input_tick() < 2000;
  RECT frame = FrameBounds(window_);
  std::vector<std::pair<HWND, RECT>> movable;
  for (HWND popup : popups) {
    if (!IsWindow(popup) || !IsWindowVisible(popup)) continue;
    HWND owner = GetWindow(popup, GW_OWNER);
    bool owned = owner != nullptr && GetAncestor(owner, GA_ROOT) == window_;
    bool popup_style = (GetWindowLongPtrW(popup, GWL_STYLE) & WS_POPUP) != 0;
    // Not another window of the app (a new main window, the user's own menu).
    if (!owned && !(popup_style && GetWindowThreadProcessId(popup, nullptr) == thread && recent_input)) continue;
    injector_->AddPopup(popup);
    RECT rect{};
    GetWindowRect(popup, &rect);
    RECT overlap{};
    bool over = IntersectRect(&overlap, &frame, &rect) &&
                2LL * RectWidth(overlap) * RectHeight(overlap) >= 1LL * RectWidth(rect) * RectHeight(rect);
    // Not over the window: clamped onto a real monitor (the user sees it,
    // the stream does not), or placed by WinUI relative to the off-screen
    // window but outside it (opened upwards, say) — either way not in the
    // picture.
    if (!over) movable.push_back({popup, rect});
  }
  if (movable.empty() || !staged_ || in_place_) return;  // in place they are where the user looks
  double now = NowSeconds();
  auto biggest = std::max_element(movable.begin(), movable.end(), [](const auto& a, const auto& b) {
    return 1LL * RectWidth(a.second) * RectHeight(a.second) < 1LL * RectWidth(b.second) * RectHeight(b.second);
  });
  long long area = 1LL * RectWidth(biggest->second) * RectHeight(biggest->second);
  bool new_burst = now - popup_shift_at_ > 0.6;
  if (new_burst) popup_shift_area_ = 0;
  // The burst's main popup (re)placed from the anchor at its current size
  // (WinUI resizes and re-places its popups as they open); smaller ones
  // that come after it (key tips, a tooltip) keep its shift.
  if (new_burst || area * 10 >= popup_shift_area_ * 7) {
    // Where it belongs: below the XAML element just clicked (or the text
    // box being typed in), else at the press, else under the caret, else
    // near the top left (a menu a key opened).
    UINT dpi = WindowDpi(window_);
    popup_anchor_ = POINT{frame.left + MulDiv(8, dpi, 96), frame.top + MulDiv(72, dpi, 96)};
    popup_anchor_element_ = RECT{};
    RECT anchor_element{};
    if (injector_->PopupAnchor(&anchor_element)) {
      popup_anchor_element_ = anchor_element;
      popup_anchor_ = POINT{anchor_element.left, anchor_element.bottom};
    } else if (GetTickCount64() - injector_->last_press_tick() < 1500) {
      popup_anchor_ = injector_->last_press_screen();
    } else {
      GUITHREADINFO gui{sizeof(gui)};
      if (GetGUIThreadInfo(thread, &gui) && gui.hwndCaret != nullptr &&
          (gui.hwndCaret == window_ || IsChild(window_, gui.hwndCaret))) {
        POINT caret{gui.rcCaret.left, gui.rcCaret.bottom};
        ClientToScreen(gui.hwndCaret, &caret);
        popup_anchor_ = caret;
      }
    }
    const RECT& window = biggest->second;
    const RECT& element = popup_anchor_element_;
    // Place what is visible: WinUI may draw its menu anywhere inside a
    // bigger popup window (at the bottom when it opened upwards).
    RECT rect = window;
    RECT content{};
    if (injector_->XamlContentRect(biggest->first, &content) && content.left >= window.left &&
        content.top >= window.top && content.right <= window.right && content.bottom <= window.bottom) {
      rect = content;
    }
    int width = RectWidth(rect), height = RectHeight(rect);
    int x = popup_anchor_.x, y = popup_anchor_.y;
    // Inside the window: right/bottom edges first, then above the element,
    // then top-aligned; never outside it (that is a real monitor).
    if (x + width > frame.right) x = frame.right - width;
    x = std::max<int>(x, frame.left);
    if (y + height > frame.bottom) {
      int above = element.bottom > element.top ? element.top - height : popup_anchor_.y - height;
      y = above >= frame.top ? above : frame.bottom - height;
    }
    y = std::max<int>(y, frame.top);
    popup_shift_ = POINT{x - rect.left, y - rect.top};
    popup_shift_area_ = std::max(popup_shift_area_, area);
    if (EnvFlag(L"WSN_TRACE_POPUPS")) {
      Note(Format("popup place: window %ld,%ld %dx%d content %ld,%ld %dx%d anchor %ld,%ld -> %d,%d (frame %ld,%ld)",
                  window.left - frame.left, window.top - frame.top, RectWidth(window), RectHeight(window),
                  rect.left - frame.left, rect.top - frame.top, width, height, popup_anchor_.x - frame.left,
                  popup_anchor_.y - frame.top, x - frame.left, y - frame.top, frame.left, frame.top));
    }
  }
  popup_shift_at_ = now;
  for (const auto& [popup, rect] : movable) {
    SetWindowPos(popup, nullptr, rect.left + popup_shift_.x, rect.top + popup_shift_.y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS);
    injector_->SetPopupShift(popup, popup_shift_);
  }
  wchar_t cls[64] = {};
  GetClassNameW(movable.front().first, cls, 64);
  Note(Format("%zu popup(s) (%s) moved over the window by %ld,%ld", movable.size(), WideToUtf8(cls).c_str(),
              popup_shift_.x, popup_shift_.y));
}

// Session thread, once. The window goes back first (that is what the user
// sees); stopping the capture and the encoder can take longer.
void CaptureSession::Teardown() {
  running_ = false;
  if (injector_) injector_->ReleaseAll();
  Unstage(true);
  if (text_focus_) {
    text_focus_->Stop();
    text_focus_.reset();
  }
  if (audio_) {
    audio_->Stop();
    audio_.reset();
  }
  capture_.Stop();
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    encoder_.Close();
    converter_.Reset();
    nv12_ = nullptr;
    last_source_ = nullptr;
  }
  injector_.reset();
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queue_.clear();  // drops the commands' references
  }
}

SIZE CaptureSession::TargetContentSize() const {
  if (viewport_w_ <= 0 || viewport_h_ <= 0) {
    RECT frame = FrameBounds(window_);
    return SIZE{std::max(1, RectWidth(frame)), std::max(1, RectHeight(frame))};
  }
  // Viewer points / text scale = logical size; times the window's DPI =
  // physical pixels of the staged window. Height minus the keyboard inset.
  double scale = viewport_scale_ > 0 ? viewport_scale_ : 1;
  UINT dpi = WindowDpi(window_);
  double logical_w = viewport_w_ / scale;
  double logical_h = (viewport_h_ / scale) * (1.0 - bottom_inset_);
  return SIZE{std::max<LONG>(160, static_cast<LONG>(logical_w * dpi / 96.0)),
              std::max<LONG>(160, static_cast<LONG>(logical_h * dpi / 96.0))};
}

// Places the window at its slot, sized for the viewport. If the app clamps
// its size so a sliver stays on a monitor, re-fits to the clamped size and
// moves again (position only). True once it is off every monitor.
bool CaptureSession::MoveOffScreen() {
  SIZE content = TargetContentSize();
  Borders borders = InvisibleBorders(window_);
  int width = content.cx + borders.left + borders.right;
  int height = content.cy + borders.top + borders.bottom;
  RECT spot{};
  if (!StageSpot(stage_slot_, width, height, borders, &spot)) {
    Note("no staging spot on any monitor");
    return false;
  }
  MoveWindowTo(window_, spot, 800);
  RECT now{};
  GetWindowRect(window_, &now);
  if (OnAnyMonitor(now, 0.02)) {
    // The app clamped its size (a minimum width, a DPI change): re-fit the
    // slot to the actual window size and move to position again.
    int w = RectWidth(now), h = RectHeight(now);
    RECT refit{};
    if (StageSpot(stage_slot_, w, h, borders, &refit)) {
      SetWindowPos(window_, nullptr, refit.left, refit.top, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS);
      for (int i = 0; i < 60; ++i) {
        GetWindowRect(window_, &now);
        if (!OnAnyMonitor(now, 0.02)) break;
        Sleep(8);
      }
    }
  }
  return !OnAnyMonitor(now, 0.02);
}

bool CaptureSession::StageNow() {
  if (staged_ || in_place_ || !IsWindow(window_)) return in_place_;
  if (holds_stage_) return ReStage();
  if (!StageAcquire(window_, &home_, &style_, &stage_slot_)) {
    Note("could not apply staging style");
    return false;
  }
  holds_stage_ = true;
  JournalUpsert();
  if (!MoveOffScreen()) {
    Note("window would not go off-screen");
    Unstage(true);  // releases the ref and restores
    return false;
  }
  staged_ = true;
  awaiting_input_frame_ = false;
  RECT now{};
  GetWindowRect(window_, &now);
  Note(Format("staged off-screen to %ld,%ld %dx%d", now.left, now.top, RectWidth(now), RectHeight(now)));
  std::lock_guard<std::mutex> lock(frame_mutex_);
  force_keyframe_ = true;
  return true;
}

// Re-applies the two staging style bits (which a Win+D / display change can
// drop) without rewriting the saved original style, and moves off-screen
// again. Keeps the existing ownership reference.
bool CaptureSession::ReStage() {
  if (!IsWindow(window_)) return false;
  LONG_PTR ex = GetWindowLongPtrW(window_, GWL_EXSTYLE);
  bool was_layered = (ex & WS_EX_LAYERED) != 0;
  SetWindowLongPtrW(window_, GWL_EXSTYLE, ex | WS_EX_LAYERED | WS_EX_TRANSPARENT);
  if (!was_layered) SetLayeredWindowAttributes(window_, 0, 255, LWA_ALPHA);
  if (!MoveOffScreen()) {
    Note("re-stage: window would not go off-screen");
    return false;
  }
  staged_ = true;
  std::lock_guard<std::mutex> lock(frame_mutex_);
  force_keyframe_ = true;
  return true;
}

void CaptureSession::Unstage(bool restore_placement) {
  staged_ = false;
  if (holds_stage_) {
    holds_stage_ = false;
    if (StageRelease(window_, restore_placement)) {
      // Last owner: the journal entry is no longer valid.
      JournalDrop(window_id_);
    }
  }
}

void CaptureSession::FallBackInPlace(const char* why) {
  if (in_place_) return;
  Note(std::string("falling back to in-place: ") + why);
  // Release staging (bringing the window home) and keep streaming in place.
  Unstage(true);
  in_place_ = true;
  if (injector_) injector_->SetInPlace(true);
}

void CaptureSession::JournalUpsert() {
  JournalEntry entry;
  entry.window_id = window_id_;
  // The HWND's own owner pid (for a UWP frame this is ApplicationFrameHost,
  // not the hosted-app pid the catalog reports), so recovery's
  // WindowPid(window) comparison matches.
  DWORD frame_pid = WindowPid(window_);
  entry.pid = frame_pid;
  entry.process_start = ProcessStartTime(frame_pid);
  entry.ex_style = style_.ex_style;
  entry.had_attributes = style_.had_attributes;
  entry.alpha = style_.alpha;
  entry.placement = home_;
  JournalPut(entry);
}

void CaptureSession::OnFrame(ID3D11Texture2D* texture, SIZE content, int64_t time_us) {
  if (!running_ || paused_) return;
  // A minimized window (Win+D, until Watch() restores it off-screen) delivers
  // frames of its title-bar stub; no encoder accepts that size, and reopening
  // for it would fail the stream. Keep the current encoder and skip them.
  if (content.cx < kMinFrameEdge || content.cy < kMinFrameEdge || IsIconic(window_)) return;
  frames_seen_++;
  SIZE want = EncodedSize(content.cx, content.cy, max_edge_);
  std::lock_guard<std::mutex> lock(frame_mutex_);
  if (keyframe_pending_.exchange(false)) force_keyframe_ = true;  // this frame answers it
  // Keep a copy of the newest BGRA frame (reused while the size holds) so a
  // keyframe request or a catch-up after "busy" can re-encode it.
  {
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    if (!last_source_ || last_source_size_.cx != static_cast<LONG>(desc.Width) ||
        last_source_size_.cy != static_cast<LONG>(desc.Height)) {
      last_source_ = d3d_->CreateTexture(desc.Width, desc.Height, desc.Format, desc.BindFlags);
      last_source_size_ = SIZE{static_cast<LONG>(desc.Width), static_cast<LONG>(desc.Height)};
    }
    if (last_source_) {
      D3DLock dl(d3d_);
      d3d_->context()->CopyResource(last_source_.get(), texture);
    }
    last_source_time_ = time_us;
  }
  if (awaiting_input_frame_) {
    awaiting_input_frame_ = false;  // the app answered input with a frame
    missed_input_frames_ = 0;
  }
  if (busy_) {
    skipped_while_busy_ = true;
    return;
  }
  if (in_flight_) return;  // the newest frame will be picked up after this one

  if (!nv12_ || encoded_size_.cx != want.cx || encoded_size_.cy != want.cy) {
    nv12_ = d3d_->CreateTexture(want.cx, want.cy, DXGI_FORMAT_NV12, D3D11_BIND_RENDER_TARGET);
    if (!nv12_) {
      if (d3d_->Lost()) {
        device_lost_ = true;  // the session thread moves to a new device
        return;
      }
      EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_ENCODER);
      running_ = false;
      return;
    }
    encoded_size_ = want;
    if (!OpenEncoderLocked(want.cx, want.cy)) {
      EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_ENCODER);
      running_ = false;
      return;
    }
  }
  RECT src{0, 0, content.cx, content.cy};
  {
    D3DLock dl(d3d_);
    if (!converter_.Convert(texture, src, nv12_.get())) {
      if (d3d_->Lost()) {
        device_lost_ = true;
      } else if (++convert_failures_ == 60) {
        // No video processor for this format/adapter: say so instead of
        // streaming a frozen picture.
        Note("frame conversion keeps failing (no video processor?)");
        EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_ENCODER);
        running_ = false;
      }
      return;
    }
    d3d_->context()->Flush();
  }
  convert_failures_ = 0;
  bool key = force_keyframe_;
  // Clear the keyframe request only if the frame was actually accepted,
  // otherwise the request is lost until the 4 s GOP (W8).
  if (EncodeLocked(nv12_.get(), time_us, key) && key) force_keyframe_ = false;
}

// Opens the H.264 encoder for the current size. frame_mutex_ held. Hardware
// first unless software_only_ is set. Returns false only when nothing works.
bool CaptureSession::OpenEncoderLocked(int width, int height) {
  encoder_.Close();
  // A frame the old encoder took but never answered (a stuck hardware
  // session) must not keep blocking the new one.
  in_flight_ = false;
  EncoderConfig config;
  config.width = width;
  config.height = height;
  config.fps = fps_;
  config.bit_rate = bit_rate_.load();
  config.allow_hardware = !software_only_;
  auto self = shared_from_this();
  std::string why;
  bool ok = encoder_.Open(
      d3d_, config,
      [self](const uint8_t* data, size_t size, int64_t pts, int flags) { self->EmitPacket(data, size, pts, flags); },
      [self](HRESULT hr) {
        self->encoder_failed_ = true;
        self->Note("encoder error " + HrText(hr));
      },
      &why);
  if (!ok) {
    Note("encoder open failed: " + why);
    return false;
  }
  encoder_failed_ = false;
  encoder_opened_at_ = NowSeconds();
  enc_w_ = width;
  enc_h_ = height;
  Note(Format("encoder %s hw %d %dx%d %s", WideToUtf8(encoder_.info().name).c_str(), encoder_.info().hardware,
              width, height, encoder_.info().rate_control.c_str()));
  EmitCapture(id_, WSN_CAPTURE_SIZE, nullptr, 0, 0, 0, width, height);
  force_keyframe_ = true;
  return true;
}

bool CaptureSession::EncodeLocked(ID3D11Texture2D* nv12, int64_t pts_us, bool key) {
  if (!encoder_.CanAccept()) return false;
  in_flight_since_ = NowSeconds();
  in_flight_ = true;
  if (!encoder_.Encode(nv12, pts_us, key)) {
    in_flight_ = false;
    return false;
  }
  return true;
}

void CaptureSession::EmitPacket(const uint8_t* data, size_t size, int64_t pts_us, int flags) {
  int out_flags = 0;
  if (flags & kPacketConfig) out_flags |= WSN_PACKET_CONFIG;
  if (flags & kPacketKey) out_flags |= WSN_PACKET_KEY;
  // in_flight_ is atomic, so we never re-lock frame_mutex_ here: for a
  // software (synchronous) MFT this runs inside Encode, which is already
  // called with frame_mutex_ held, and std::mutex is not recursive (W20).
  if (!(flags & kPacketConfig)) in_flight_.store(false);
  first_frame_sent_.store(true);
  EmitCapture(id_, WSN_CAPTURE_PACKET, data, static_cast<int32_t>(size), (flags & kPacketConfig) ? 0 : pts_us,
              out_flags, enc_w_.load(), enc_h_.load());
}

void CaptureSession::Watch() {
  if (!IsWindow(window_)) {
    EmitEnd(WSN_CAPTURE_STOPPED, WSN_CAPTURE_ERROR_NOT_FOUND);
    running_ = false;
    return;
  }
  double now = NowSeconds();
  if (injector_) injector_->Tick();  // give the front back once a shortcut's menu has closed

  // WinUI keeps some popup windows (tooltips, key tips) shown and only
  // changes what they draw, so no event says they appeared. Twice a second,
  // anything of ours left on a real monitor is brought over the window.
  if (staged_ && !in_place_) {
    struct Sweep {
      HWND window;
      std::vector<HWND> found;
    } sweep{window_, {}};
    EnumThreadWindows(
        GetWindowThreadProcessId(window_, nullptr),
        [](HWND w, LPARAM p) -> BOOL {
          auto* s = reinterpret_cast<Sweep*>(p);
          HWND owner = GetWindow(w, GW_OWNER);
          RECT r{};
          if (w != s->window && IsWindowVisible(w) && owner != nullptr && GetAncestor(owner, GA_ROOT) == s->window &&
              GetWindowRect(w, &r) && OnAnyMonitor(r, 0.01)) {
            s->found.push_back(w);
          }
          return TRUE;
        },
        reinterpret_cast<LPARAM>(&sweep));
    if (!sweep.found.empty()) {
      {
        std::lock_guard<std::mutex> lock(popup_mutex_);
        pending_popups_.insert(pending_popups_.end(), sweep.found.begin(), sweep.found.end());
      }
      PlacePopups();
    }
  }

  // The GPU device went away: start over on a new one (before the encoder
  // watchdog, which would otherwise blame the encoder).
  bool simulated = simulate_loss_at_ > 0 && now >= simulate_loss_at_;
  if (device_lost_ || simulated || (d3d_ != nullptr && d3d_->Lost())) {
    simulate_loss_at_ = 0;
    if (!RestartOnNewDevice()) {
      EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_ENCODER);
      running_ = false;
    }
    return;
  }

  // Encoder watchdog: a hardware encoder that opened but produces nothing
  // (its per-GPU session was taken) never asks for input, so every frame is
  // dropped and the viewer sees a frozen window. If no packet has gone out
  // ~0.8 s after the encoder opened, or it reported an error, reopen with
  // software encoding. Fail the stream only if software fails too.
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    bool stuck = encoder_opened_at_ > 0 && !first_frame_sent_ && now - encoder_opened_at_ > 0.8;
    if ((stuck || encoder_failed_) && encoded_size_.cx > 0) {
      if (!software_only_) {
        software_only_ = true;
        Note("encoder produced nothing; switching to the software encoder");
        if (!OpenEncoderLocked(encoded_size_.cx, encoded_size_.cy)) {
          EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_ENCODER);
          running_ = false;
          return;
        }
      } else if (stuck || encoder_failed_) {
        // Even software did not deliver: give up on this stream.
        EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_ENCODER);
        running_ = false;
        return;
      }
    }
    // Mid-stream stall: the encoder took a frame and never answered (a
    // hardware session that went bad). Every later frame waits on it, so the
    // viewer freezes. Reopen once; if it stalls again, go to software.
    if (in_flight_ && encoded_size_.cx > 0 && now - in_flight_since_.load() > 1.0) {
      bool software = software_only_ || ++encoder_stalls_ > 1;
      software_only_ = software;
      Note(Format("encoder stalled (%lld frames seen): reopening%s", static_cast<long long>(frames_seen_.load()),
                  software ? " with the software encoder" : ""));
      if (!OpenEncoderLocked(encoded_size_.cx, encoded_size_.cy)) {
        EmitEnd(WSN_CAPTURE_FAILED, WSN_CAPTURE_ERROR_ENCODER);
        running_ = false;
        return;
      }
      keyframe_pending_ = true;  // re-send the current picture
    }
  }

  // Paused long enough: send the window home (and stop capturing) until the
  // viewer comes back.
  if (paused_) {
    if (staged_ && !parked_ && park_at_ > 0 && now >= park_at_) {
      Note("paused a while: window back home");
      Unstage(true);
      parked_ = true;
    }
    return;
  }
  if (parked_) {
    // Resumed: re-stage.
    parked_ = false;
    if (!in_place_ && !StageNow()) FallBackInPlace("re-stage after pause failed");
    return;
  }

  if (in_place_) {
    return;  // nothing to supervise off-screen
  }

  if (!staged_) {
    return;
  }

  // (We do not fall back on the window merely being foreground: our own input
  // injection foregrounds it, so foreground is not a reliable "the local user
  // wants it back" signal. The window is off-screen and click-through, so the
  // local user cannot practically drive it; if the app itself moves it onto a
  // monitor, the on-screen check below re-stages it.)

  // Win+D / Show desktop minimizes staged windows: restore without
  // activating, back to the staging spot.
  if (IsIconic(window_)) {
    Note("window was minimized (show desktop): restoring off-screen");
    staged_ = false;
    if (!ReStage()) FallBackInPlace("re-stage after minimize failed");
    return;
  }

  // The window drifted back onto a monitor (display change, snap): re-stage
  // (ReStage re-applies the style bits without rewriting the saved style, W2).
  RECT rect{};
  GetWindowRect(window_, &rect);
  if (OnAnyMonitor(rect, 0.2)) {
    Note("window returned on-screen: re-staging");
    staged_ = false;
    if (!ReStage()) FallBackInPlace("re-stage failed");
    return;
  }

  // Inputs that should have changed the picture produced no frame in time:
  // this app does not render off-screen. Fall back to in-place. Twice in a
  // row, so one press on an empty spot does not bring the window back.
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (awaiting_input_frame_ && now >= last_input_change_deadline_) {
      awaiting_input_frame_ = false;
      if (++missed_input_frames_ < 2) return;
      missed_input_frames_ = 0;
      // Release the lock before re-entering staging logic.
    } else {
      return;
    }
  }
  FallBackInPlace("no frame after input (app does not render off-screen)");
}

void CaptureSession::SetScreen(int64_t key) {
  // The actual off-screen corner is handed out from a free set when staging
  // (StageAcquire), so two windows never collide; the key is kept only for
  // the log / future per-viewer grouping.
  Post(kTagScreen, [this, key] { screen_key_ = key; });
}

void CaptureSession::SetViewport(double width, double height, double scale) {
  Post(kTagViewport, [this, width, height, scale] { ViewportNow(width, height, scale); });
}

void CaptureSession::SetBottomInset(double bottom) {
  Post(kTagInset, [this, bottom] { InsetNow(bottom); });
}

void CaptureSession::ViewportNow(double width, double height, double scale) {
  bool changed = width != viewport_w_ || height != viewport_h_ || scale != viewport_scale_;
  viewport_w_ = width;
  viewport_h_ = height;
  viewport_scale_ = scale > 0 ? scale : 1;
  if (changed && staged_) ResizeToViewport();
}

void CaptureSession::InsetNow(double bottom) {
  bottom = std::min(std::max(bottom, 0.0), 0.8);
  if (std::abs(bottom - bottom_inset_) < 0.01) return;
  bottom_inset_ = bottom;
  if (staged_) ResizeToViewport();
}

void CaptureSession::ResizeToViewport() {
  if (!staged_ || !IsWindow(window_)) return;
  MoveOffScreen();  // re-fits the slot to the new viewport size
  std::lock_guard<std::mutex> lock(frame_mutex_);
  force_keyframe_ = true;
}

// Re-encodes the newest frame (for "busy" catch-up or a keyframe request).
// The D3D device lock must be released before calling EncodeLocked, which
// takes the encoder mutex — holding both in this order deadlocks against the
// MF event thread (ABBA). frame_mutex_ must be held on entry.
void CaptureSession::ReencodeLast(bool key) {
  if (in_flight_ || !last_source_ || paused_ || !running_) return;
  SIZE want = EncodedSize(last_source_size_.cx, last_source_size_.cy, max_edge_);
  if (!nv12_ || encoded_size_.cx != want.cx || encoded_size_.cy != want.cy) return;
  RECT src{0, 0, last_source_size_.cx, last_source_size_.cy};
  {
    D3DLock dl(d3d_);
    if (!converter_.Convert(last_source_.get(), src, nv12_.get())) return;
    d3d_->context()->Flush();
  }  // release the device lock before encoding
  if (EncodeLocked(nv12_.get(), last_source_time_ + (key ? 1000 : 1), key) && key) force_keyframe_ = false;
}

void CaptureSession::SetBusy(bool busy) {
  busy_ = busy;  // OnFrame skips (and remembers) frames while set
  if (!busy) {
    catch_up_pending_ = true;
    Wake();
  }
}

void CaptureSession::SetPaused(bool paused) {
  if (paused_.exchange(paused) == paused) return;  // OnFrame stops/starts at once
  Post(0, [this] { PausedChanged(); });
}

// Session thread: the park timer and the re-stage follow the current state.
void CaptureSession::PausedChanged() {
  if (paused_) {
    if (park_at_ == 0) park_at_ = NowSeconds() + ParkSeconds();
  } else {
    park_at_ = 0;
    keyframe_pending_ = true;
    next_watch_ = 0;  // re-stage a parked window right away
  }
}

void CaptureSession::SetAudio(int mode) {
  audio_mode_ = mode;
  Post(0, [this, mode] {
    if (mode == WSN_CAPTURE_AUDIO_OFF) {
      if (audio_) {
        audio_->Stop();
        audio_.reset();
      }
      return;
    }
    if (!audio_) {
      // The window's app process (UWP: the CoreWindow's, which actually plays).
      HWND core = HostedCoreWindow(window_);
      DWORD pid = WindowPid(core ? core : window_);
      audio_ = std::make_unique<AudioCapture>(
          pid,
          [this](const int16_t* pcm, int frames, int64_t pts_us) {
            if (paused_ || !running_) return;
            EmitCapture(id_, WSN_CAPTURE_AUDIO, pcm, frames * 2 * static_cast<int>(sizeof(int16_t)), pts_us, 0, 48000,
                        2);
          },
          [this](const std::string& note) { Note(note); });
      audio_->Start(mode);
    } else {
      audio_->SetMode(mode);
    }
  });
}

void CaptureSession::SetBitRate(int bit_rate) {
  bit_rate_ = bit_rate;
  bit_rate_pending_ = true;
  Wake();
}

void CaptureSession::RequestKeyframe() {
  keyframe_pending_ = true;
  Wake();
}

void CaptureSession::Input(int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx,
                           double dy, int32_t phase, const std::string& text) {
  // Hover/drag moves: only the newest one waiting matters.
  int coalesce = kind == WSN_INPUT_POINTER_MOVE ? kTagMove : 0;
  Post(coalesce, [this, kind, code, modifiers, x, y, dx, dy, phase, text] {
    InputNow(kind, code, modifiers, x, y, dx, dy, phase, text);
  });
}

void CaptureSession::InputNow(int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx,
                              double dy, int32_t phase, const std::string& text) {
  if (!injector_) return;
  // Refuse input while the session is locked / on a secure desktop: nothing
  // can (or should) be driven there.
  if (SessionLocked()) return;
  switch (kind) {
    case WSN_INPUT_POINTER_DOWN:
      injector_->Pointer(1, code, x, y, modifiers);
      break;
    case WSN_INPUT_POINTER_MOVE:
      injector_->Pointer(2, code, x, y, modifiers);
      break;
    case WSN_INPUT_POINTER_UP:
      injector_->Pointer(3, code, x, y, modifiers);
      break;
    case WSN_INPUT_POINTER_CANCEL:
      injector_->Pointer(8, code, x, y, modifiers);
      break;
    case WSN_INPUT_SCROLL:
      injector_->Scroll(x, y, dx, dy, (phase & (1 << 16)) != 0);
      break;
    case WSN_INPUT_KEY_DOWN:
      injector_->Key(true, code, modifiers, Utf8ToWide(text));
      break;
    case WSN_INPUT_KEY_UP:
      injector_->Key(false, code, modifiers, Utf8ToWide(text));
      break;
    case WSN_INPUT_TEXT:
      injector_->Text(Utf8ToWide(text), code == 1);
      break;
    default:
      return;
  }
  // A press or a key (Tab) can move the focus into or out of a text field.
  if (text_focus_ && (kind == WSN_INPUT_POINTER_DOWN || kind == WSN_INPUT_POINTER_UP || kind == WSN_INPUT_KEY_DOWN)) {
    text_focus_->Kick(injector_->key_target());
  }
  // Input that should change the picture (a press, typed text — not keys
  // like Esc or a scroll at the end, which may change nothing): expect a
  // frame soon, else this app does not render off-screen.
  if (staged_ && (kind == WSN_INPUT_POINTER_DOWN || kind == WSN_INPUT_TEXT)) {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    awaiting_input_frame_ = true;
    last_input_change_deadline_ = NowSeconds() + 1.5;
  }
}

}  // namespace wsn
