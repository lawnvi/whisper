// One streamed window on this PC: its top-level window, decode thread,
// presenter (D3D11 with a GDI fallback) and audio.
//
// Behaviour follows the macOS receiver (StreamSurface / StreamWindow):
// closing hides the window and asks Dart to close; focus and visibility
// changes are reported; the window keeps the picture's shape while it is
// resized (with WSN_FLAG_REFLOW it resizes freely and settles to the
// picture's shape only when that does not follow) and follows the picture
// when that changes shape; pointer, wheel and keyboard input travel
// normalised to the video rect. Once it has sound it offers its own volume
// control (volume_control.h).

#pragma once

#include "../common/wsn_common.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "audio_out.h"
#include "frame.h"
#include "readiness.h"
#include "volume_control.h"

namespace wsn {

class D3DPresenter;
class GdiPresenter;

struct Packet {
  std::vector<uint8_t> data;
  int64_t pts_us = 0;
  int32_t flags = 0;
};

class Surface : public std::enable_shared_from_this<Surface> {
 public:
  Surface(int64_t id, std::wstring title, int width, int height, bool hud, bool reflow);
  ~Surface();

  int64_t id() const { return id_; }

  // Export threads.
  void Start();
  void Stop();
  void SetTitle(std::wstring title);
  void SetVisual(int32_t visual, std::wstring message);
  void SetHud(std::wstring text);
  void SetIcon(const uint8_t* png, int32_t length);
  void PushVideo(uint8_t* buffer, int32_t length, int64_t pts_us, int32_t flags);
  void ConfigureAudio(int sample_rate, int channels);
  void PushAudio(uint8_t* buffer, int32_t length, int64_t pts_us);
  // 0 (silent) to 1: the sound now and later, and the window's control
  // (which does not report it back).
  void SetVolume(double volume);
  int32_t Stats(double* out, int32_t count);
  int32_t Snapshot(const char* path, int32_t max_edge);

  // UI thread.
  void DestroyWindowOnUiThread();
  void FocusOnUiThread();
  void StringsChangedOnUiThread();
  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  struct PendingKey {
    int32_t mac = -1;
    int32_t modifiers = 0;
    bool repeat = false;
    bool active = false;
  };

  void CreateWindowOnUiThread();
  void DecodeLoop();
  void AskKeyframe();
  int64_t DropQueuedPicturesLocked();
  size_t QueuedPackets();
  std::shared_ptr<D3DPresenter> presenter();
  std::shared_ptr<GdiPresenter> MakeGdiPresenter();
  void PreparePresenter(D3DPresenter* presenter);
  std::function<void()> StableCallback();
  void OnStableOnUiThread();
  void FollowVideoSizeOnUiThread();
  void SetPlaceholderIcon(std::shared_ptr<const Poster> icon);
  void OnDeviceLost(HRESULT reason);
  void RecreatePresenterOnUiThread(bool use_d3d);
  void ReplaceWindowOnUiThread();
  void OverlayChanged();
  OverlayState Overlay();
  void VideoSizeChanged(int width, int height);

  // UI thread.
  RECT VideoRect();
  void UpdateGdiTarget();
  bool Normalized(int px, int py, bool clamp, double* x, double* y);
  void SendPointer(int32_t kind, int32_t button, int px, int py);
  void QueueMove(int px, int py);
  void FlushMove();
  void ReleaseInput();
  void ApplyIcon();
  void ApplyDarkTitleBar();
  void UpdateImeWindow();
  void SetVisible(bool visible);
  void ScheduleResized();
  void EmitResizedIfChanged();
  // WSN_FLAG_REFLOW: after the user resized, the window settles to the
  // picture's shape if the picture has not followed.
  void SettleOnUiThread();
  void SettleStep();
  void CancelSettle();
  void ApplyVolume(double volume);
  SIZE FrameInsets();
  bool OnKey(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result);
  void OnChar(wchar_t character);
  void SendKeyDown(int32_t mac, int32_t modifiers, bool repeat, const std::wstring& characters);
  void SendText(const std::wstring& text, bool paste);
  void Paste();

  const int64_t id_;
  const bool hud_;
  const bool reflow_;
  const std::shared_ptr<Readiness> readiness_;
  const std::wstring poster_key_;  // the title the window opened with

  // UI thread.
  HWND hwnd_ = nullptr;
  UINT dpi_ = 96;
  double scale_ = 1;
  HICON small_icon_ = nullptr;
  HICON big_icon_ = nullptr;
  int32_t pressed_button_ = -1;
  POINT last_pointer_ = {-1, -1};
  POINT last_click_ = {-1, -1};
  bool move_pending_ = false;
  POINT pending_move_ = {};
  double last_move_sent_ = 0;
  std::set<int32_t> keys_down_;
  PendingKey pending_key_;
  wchar_t high_surrogate_ = 0;
  std::wstring ime_echo_;  // committed IME text still to arrive as WM_IME_CHAR / WM_CHAR
  double ime_echo_at_ = 0;
  bool visible_ = false;
  bool active_ = false;
  bool in_size_move_ = false;
  bool resized_in_move_ = false;
  bool programmatic_resize_ = false;
  bool tracking_leave_ = false;
  bool has_sound_ = false;
  std::unique_ptr<VolumeControl> volume_control_;
  // The settle animation: from, to (window rects) and when it began.
  RECT settle_from_ = {};
  RECT settle_to_ = {};
  double settle_started_ = -1;
  double last_resized_at_ = 0;
  double last_width_ = -1;
  double last_height_ = -1;
  double last_scale_ = -1;
  std::atomic<bool> repaint_posted_{false};

  // state_mutex_.
  std::mutex state_mutex_;
  std::wstring title_;
  OverlayState overlay_;
  int video_width_;
  int video_height_;
  std::vector<uint8_t> icon_png_;
  std::shared_ptr<const Poster> poster_;  // the window's last picture, if known
  std::shared_ptr<const Poster> icon_;    // the app's icon, flattened on black
  std::shared_ptr<D3DPresenter> presenter_;
  std::shared_ptr<GdiPresenter> gdi_;
  bool software_decode_ = false;  // the hardware decoder kept failing

  HANDLE ready_ = nullptr;  // window and presenter set up
  std::atomic<bool> first_frame_seen_{false};
  std::atomic<bool> steady_{false};

  // Decode queue.
  std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<Packet> queue_;
  bool stopping_ = false;
  bool need_key_ = true;  // deltas are useless until a keyframe arrives
  std::thread decode_thread_;

  // Stats.
  std::mutex stats_mutex_;
  double fps_ = 0;
  double decode_ms_ = 0;
  int64_t decoded_ = 0;
  int64_t dropped_ = 0;
  bool first_frame_ = false;
  bool decoder_hardware_ = false;
  double last_keyframe_ask_ = 0;
  double last_error_emit_ = 0;
  int64_t decode_count_ = 0;  // decode thread

  std::mutex audio_mutex_;
  std::unique_ptr<AudioOut> audio_;
  double volume_ = 1;  // audio_mutex_
  double av_traced_at_ = 0;  // decode thread
};

// Registry of live surfaces, keyed by the id handed to Dart.
int64_t AddSurface(const std::wstring& title, int width, int height, int32_t flags);
std::shared_ptr<Surface> FindSurface(int64_t id);
// wsn_set_strings: every window's control shows the new words.
void RefreshSurfaceStrings();
void DestroySurface(int64_t id);
void DestroyAllSurfaces();

}  // namespace wsn
