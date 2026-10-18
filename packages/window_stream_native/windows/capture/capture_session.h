// One streamed local window: the WGC capture, the NV12 conversion, the H.264
// encoder, the staging (move off-screen to a monitor corner, restore exactly
// at the end) and the input replay. The Windows counterpart of macOS
// WindowCapture + VirtualStage. Results go to Dart through the capture
// callback keyed by this session's id.
//
// Threads: every public method is called from Dart's isolate and returns at
// once. Work that can block (moving the window, input into another app,
// staging, teardown) is queued and done in order on the session's own
// thread, which alone owns the injector and the staging state. Frames come
// in on WGC's pool thread (OnFrame). Stop() only signals: the session thread
// puts the window back first, then shuts the capture down, and ends.
#pragma once

#include "common/com.h"
#include "common/wsn_common.h"

#include "capture_catalog.h"
#include "wsn_convert.h"
#include "wsn_encoder.h"
#include "wsn_inject.h"
#include "wsn_journal.h"
#include "wsn_audio.h"
#include "wsn_stage.h"
#include "wsn_textfocus.h"
#include "wsn_wgc.h"
#include "wsn_window.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>

namespace wsn {

class CaptureSession : public std::enable_shared_from_this<CaptureSession> {
 public:
  CaptureSession(int64_t id, uint32_t window_id, int pid, int max_edge, int fps, int bit_rate);
  ~CaptureSession();

  void Start();
  // Signals the stop and returns; the session thread restores the window
  // and tears down on its own.
  void Stop();

  void SetScreen(int64_t key);
  void SetViewport(double width, double height, double scale);
  void SetBottomInset(double bottom);
  void SetBusy(bool busy);
  void SetPaused(bool paused);
  void SetAudio(int mode);  // WSN_CAPTURE_AUDIO_OFF / _ON / _ON_SILENT_HERE
  void SetBitRate(int bit_rate);
  void RequestKeyframe();
  void Input(int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx, double dy,
             int32_t phase, const std::string& text);

  int64_t id() const { return id_; }

 private:
  struct Command {
    int coalesce = 0;  // non-zero: replaces a queued command with the same tag at the tail
    std::function<void()> run;
  };
  void Post(int coalesce, std::function<void()> run);
  void Wake();
  bool VideoPending() const;
  void ServiceVideo();        // keyframe / catch-up / bit-rate requests
  void Teardown();            // restore first, then shut down
  void InputNow(int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx, double dy,
                int32_t phase, const std::string& text);
  void ViewportNow(double width, double height, double scale);
  void InsetNow(double bottom);
  void PausedChanged();
  void PlacePopups();  // menus/drop-downs/dialogs of the staged window
  void Run();                 // the session thread
  bool StartCapture(std::string* error);
  bool RestartOnNewDevice();  // the GPU device was removed (W11)
  void OnFrame(ID3D11Texture2D* texture, SIZE content, int64_t time_us);
  bool EncodeLocked(ID3D11Texture2D* nv12, int64_t pts_us, bool key);  // true if accepted
  void ReencodeLast(bool key);  // frame_mutex_ held; releases the device lock first
  bool OpenEncoderLocked(int width, int height);  // frame_mutex_ held
  void EmitPacket(const uint8_t* data, size_t size, int64_t pts_us, int flags);
  bool StageNow();            // acquire ownership, move off-screen, journal it
  bool ReStage();             // re-apply the style bits and move (keep the ref)
  bool MoveOffScreen();       // place at the slot, re-fit if the app clamped
  void Unstage(bool restore_placement);  // release the ref / restore
  void FallBackInPlace(const char* why);
  void Watch();               // 1 Hz: display change, user activation, gone
  SIZE TargetContentSize() const;  // window size wanted from the viewport
  void ResizeToViewport();
  void Note(const std::string& text);
  void EmitEnd(int32_t kind, int32_t code);  // FAILED/STOPPED, once
  void JournalUpsert();

  const int64_t id_;
  const uint32_t window_id_;
  HWND window_;
  const int pid_;
  const int max_edge_;
  const int fps_;
  std::atomic<int> bit_rate_;

  D3D* d3d_ = nullptr;
  WgcCapture capture_;
  WgcCapture::Options capture_options_;
  Converter converter_;
  H264Encoder encoder_;
  std::unique_ptr<Injector> injector_;          // session thread only
  std::unique_ptr<TextFocusWatcher> text_focus_;  // session thread only
  std::unique_ptr<AudioCapture> audio_;           // session thread only
  std::atomic<int> audio_mode_{0};

  // Encoder feed (capture thread + frame callbacks).
  std::mutex frame_mutex_;
  winrt::com_ptr<ID3D11Texture2D> nv12_;
  SIZE encoded_size_{};
  winrt::com_ptr<ID3D11Texture2D> last_source_;  // newest BGRA frame, for keyframes
  SIZE last_source_size_{};
  int64_t last_source_time_ = 0;
  std::atomic<bool> in_flight_{false};
  std::atomic<int> enc_w_{0}, enc_h_{0};  // encoded size, read from the MF thread
  std::atomic<bool> busy_{false};
  bool skipped_while_busy_ = false;
  bool force_keyframe_ = true;
  bool have_config_ = false;
  std::vector<uint8_t> parameter_sets_;
  double last_input_change_deadline_ = 0;  // input happened; expect a frame by then
  bool awaiting_input_frame_ = false;
  int missed_input_frames_ = 0;  // inputs in a row that brought no frame
  std::atomic<double> in_flight_since_{0};  // when the encoder took the frame it still owes
  int encoder_stalls_ = 0;
  std::atomic<int64_t> frames_seen_{0};     // WGC frames (diagnostics)
  // GPU device removal (driver update, TDR): the session moves to a new
  // device instead of freezing (W11).
  std::atomic<bool> device_lost_{false};
  int convert_failures_ = 0;      // in a row, frame_mutex_
  int device_restarts_ = 0;
  double last_device_restart_ = 0;
  double simulate_loss_at_ = 0;   // test hook (WSN_TEST_DEVICE_LOSS seconds)
  // Encoder watchdog / software fallback (W4).
  double encoder_opened_at_ = 0;
  std::atomic<bool> encoder_failed_{false};
  bool software_only_ = false;

  // Requests from Dart for the encoder side, served by the session thread
  // ahead of queued commands (and keyframes also by the next frame).
  std::atomic<bool> keyframe_pending_{false};
  std::atomic<bool> catch_up_pending_{false};
  std::atomic<bool> bit_rate_pending_{false};

  // Staging state (session thread; staged_/in_place_ also read by OnFrame).
  std::atomic<bool> staged_{false};
  std::atomic<bool> in_place_{false};
  Placement home_;
  StyleBackup style_;
  int stage_slot_ = 0;
  bool holds_stage_ = false;  // this session owns a staging reference
  int64_t screen_key_ = 0;
  double viewport_w_ = 0, viewport_h_ = 0, viewport_scale_ = 1;
  double bottom_inset_ = 0;
  std::atomic<bool> paused_{false};
  bool parked_ = false;
  double park_at_ = 0;  // when paused long enough to send home
  double our_activation_at_ = 0;
  double next_watch_ = 0;

  std::atomic<bool> running_{false};
  std::atomic<bool> stopped_{false};
  std::atomic<bool> first_frame_sent_{false};
  std::atomic<bool> end_emitted_{false};
  bool queue_full_noted_ = false;
  // Popups the watcher reported, placed in a batch by the session thread.
  std::mutex popup_mutex_;
  std::vector<HWND> pending_popups_;
  POINT popup_shift_{};
  double popup_shift_at_ = 0;
  long long popup_shift_area_ = 0;  // size of the popup the shift was computed for
  POINT popup_anchor_{};            // where this burst's popups belong
  RECT popup_anchor_element_{};     // the element they open from (empty: none)
  // The command queue; wake_ is signalled with queue_mutex_ held or after.
  std::mutex queue_mutex_;
  std::condition_variable wake_;
  std::deque<Command> queue_;
};

// Registry (exports_capture.cpp uses it).
std::shared_ptr<CaptureSession> RegisterCapture(std::shared_ptr<CaptureSession> session);
std::shared_ptr<CaptureSession> FindCapture(int64_t id);
void RemoveCapture(int64_t id);
void ResetAllCapturesImpl();
// Process exit (DLL_PROCESS_DETACH while the process ends, other threads
// already gone): puts back every window still staged, without waiting.
void RestoreStagedAtExit();

}  // namespace wsn
