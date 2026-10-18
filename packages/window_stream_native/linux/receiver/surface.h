// One streamed window on this desktop: a GTK window that shows decoded
// video, plays its audio and turns pointer, scroll and keyboard input into
// the shared input model (see window_stream_native.h). Behaviour follows the
// macOS receiver (StreamWindow.swift / StreamSurface.swift): its title bar
// (a GtkHeaderBar) gets a volume control once the window has sound, and
// with WSN_FLAG_REFLOW the window settles to the picture's shape when the
// picture does not follow a resize.
//
// Threads: GTK state lives on the main loop; video is decoded on the
// surface's own thread; the ABI calls arrive on any thread.

#ifndef WSN_RECEIVER_SURFACE_H_
#define WSN_RECEIVER_SURFACE_H_

#include <gtk/gtk.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace wsn {

class AudioOut;

class Surface : public std::enable_shared_from_this<Surface> {
 public:
  Surface(int64_t id, std::string title, int video_width, int video_height, bool hud, bool reflow);
  Surface(const Surface&) = delete;
  Surface& operator=(const Surface&) = delete;
  ~Surface();

  int64_t id() const { return id_; }

  void Start();
  // Stops decoding and audio and closes the window. Returns promptly.
  void Stop();

  void SetTitle(std::string title);
  void SetVisual(int32_t visual, std::string message);
  void SetHud(std::string text);
  // The app's icon: window icon, and the placeholder until the stream is
  // stable.
  void SetIcon(const uint8_t* png, int32_t length);
  void Focus();

  // Takes ownership of `buffer` (from wsn_buffer_alloc).
  void PushVideo(uint8_t* buffer, int32_t length, int64_t pts_us, int32_t flags);
  void ConfigureAudio(int sample_rate, int channels);
  // Takes ownership of `buffer`.
  void PushAudio(uint8_t* buffer, int32_t length, int64_t pts_us);
  // 0 (silent) to 1: the sound now and later, and the window's control
  // (which does not report it back).
  void SetVolume(double volume);
  // wsn_set_strings: the control's words.
  void RefreshStrings();

  int32_t Stats(double* out, int32_t count);
  // 0 on success, -2 when there is no picture yet or writing failed.
  int32_t Snapshot(const char* path, int32_t max_edge);

 private:
  struct Packet {
    std::vector<uint8_t> data;
    int64_t pts_us = 0;
    int32_t flags = 0;
  };

  struct Frame {
    std::vector<uint8_t> pixels;  // cairo RGB24
    int width = 0;                // device pixels, as scaled by the decoder
    int height = 0;
    int stride = 0;
  };

  // Decode thread.
  void DecodeLoop();
  void AskKeyframe();

  // Main thread.
  void CreateWindow();
  void DestroyWindow();
  void QueueDraw();
  void Draw(cairo_t* cr);
  void DrawOverlay(cairo_t* cr, int width, int height, const std::string& message, bool paused, bool spinner);
  void DrawCaption(cairo_t* cr, int width, int height, const std::string& message, bool below_spinner);
  void DrawFrame(cairo_t* cr, int width, int height, double scale, double alpha);
  void DrawPlaceholder(cairo_t* cr, int width, int height);
  // The loading phase ("picture is stable", see ws/ROUND2.md): main thread.
  bool Loading() const;
  void UpdateLoading();
  void StartFade();
  double FadeProgress() const;
  void UpdateSpinner();
  static bool AnimationsEnabled();
  void DrawHud(cairo_t* cr, const std::string& text);
  void VideoRect(double* x, double* y, double* w, double* h);
  bool Normalized(double px, double py, double* nx, double* ny, bool inside_only);
  void OnAllocated(int width, int height);
  void ReportSize();
  void UpdateImCursor();
  void ApplyVideoSize(int width, int height);
  // REFLOW: a user resize settled; if the picture keeps its shape the
  // window takes it.
  void ScheduleSettle();
  void CancelSettle();
  void Settle();
  // The volume control (main thread).
  void CreateVolumeControl(GtkWidget* header);
  void ShowVolumeControl();
  void SyncVolumeControl();
  void UserVolume(double volume, bool final);
  void FlushVolumeReport();
  void ApplyVolume(double volume);
  void OnButton(GdkEventButton* event, bool down);
  void OnMotion(GdkEventMotion* event);
  void SendHover();
  void OnScroll(GdkEventScroll* event);
  gboolean OnKey(GdkEventKey* event, bool down);
  void SendKeyDown(const GdkEventKey* event, int32_t code);
  void OnCommit(const char* text);
  void OnPreeditChanged();
  void ReleaseInput();
  void Paste();
  int32_t Visual();

  static gboolean OnDrawThunk(GtkWidget*, cairo_t* cr, gpointer self);
  static void OnAllocateThunk(GtkWidget*, GdkRectangle* allocation, gpointer self);
  static gboolean OnButtonPressThunk(GtkWidget*, GdkEventButton* event, gpointer self);
  static gboolean OnButtonReleaseThunk(GtkWidget*, GdkEventButton* event, gpointer self);
  static gboolean OnMotionThunk(GtkWidget*, GdkEventMotion* event, gpointer self);
  static gboolean OnScrollThunk(GtkWidget*, GdkEventScroll* event, gpointer self);
  static gboolean OnKeyPressThunk(GtkWidget*, GdkEventKey* event, gpointer self);
  static gboolean OnKeyReleaseThunk(GtkWidget*, GdkEventKey* event, gpointer self);
  static gboolean OnGrabBrokenThunk(GtkWidget*, GdkEvent*, gpointer self);
  static gboolean OnDeleteThunk(GtkWidget* widget, GdkEvent*, gpointer self);
  static gboolean OnFocusInThunk(GtkWidget*, GdkEvent*, gpointer self);
  static gboolean OnFocusOutThunk(GtkWidget*, GdkEvent*, gpointer self);
  static gboolean OnWindowStateThunk(GtkWidget*, GdkEventWindowState* event, gpointer self);
  static void OnCommitThunk(GtkIMContext*, gchar* text, gpointer self);
  static void OnPreeditChangedThunk(GtkIMContext*, gpointer self);
  static gboolean OnLoadingTimerThunk(gpointer self);
  static gboolean OnFadeTickThunk(GtkWidget*, GdkFrameClock*, gpointer self);
  static void OnVolumeScaleThunk(GtkRange* range, gpointer self);
  static void OnMuteThunk(GtkButton*, gpointer self);
  static void OnVolumeClosedThunk(GtkPopover*, gpointer self);
  static gboolean OnAreaFocusOutThunk(GtkWidget*, GdkEvent*, gpointer self);

  const int64_t id_;
  const bool hud_;
  const bool reflow_;

  // Main thread only.
  std::string title_;
  GtkWidget* window_ = nullptr;
  GtkWidget* header_ = nullptr;
  GtkWidget* overlay_ = nullptr;
  GtkWidget* area_ = nullptr;
  GtkWidget* spinner_ = nullptr;
  GtkIMContext* im_ = nullptr;
  GdkPixbuf* icon_ = nullptr;
  int32_t pressed_ = -1;
  double last_x_ = 0;
  double last_y_ = 0;
  std::map<guint16, int32_t> keys_down_;  // hardware keycode → mac code sent down
  const GdkEventKey* pending_key_ = nullptr;
  bool composing_ = false;
  bool composing_before_ = false;
  bool scrolling_ = false;
  double hover_x_ = 0;
  double hover_y_ = 0;
  int32_t hover_modifiers_ = 0;
  int64_t last_hover_us_ = 0;
  guint hover_timer_ = 0;
  guint resize_timer_ = 0;
  int reported_width_ = 0;
  int reported_height_ = 0;
  int reported_scale_ = 0;
  int64_t user_resized_us_ = 0;
  bool resizing_to_video_ = false;
  int shown_video_width_ = 0;
  int shown_video_height_ = 0;
  guint settle_quiet_timer_ = 0;
  guint settle_timer_ = 0;

  // The volume control in the title bar (main thread): a button that opens
  // a popover with a mute toggle and a slider.
  GtkWidget* volume_button_ = nullptr;
  GtkWidget* volume_image_ = nullptr;
  GtkWidget* volume_scale_ = nullptr;
  GtkWidget* mute_button_ = nullptr;
  GtkWidget* mute_image_ = nullptr;
  bool has_sound_ = false;
  bool syncing_volume_ = false;  // the slider moved by us, not the user
  double shown_volume_ = 1;
  double audible_volume_ = 1;    // what unmuting goes back to
  double reported_volume_ = 1;
  int64_t last_volume_report_us_ = 0;
  guint volume_report_timer_ = 0;

  // Loading phase (main thread). Until the picture is stable the window
  // shows a placeholder (the app icon on black) and a spinner; then the
  // picture fades in once. A resume that brings no frame within 300 ms
  // shows the spinner over the dimmed last picture.
  const int64_t opened_us_;
  int64_t connecting_since_us_;
  int32_t main_visual_ = 1;  // WSN_VISUAL_CONNECTING; mirrors visual_ in order
  bool settled_ = false;     // the picture became stable once
  bool live_shown_ = false;  // ... and was revealed
  bool slow_hint_ = false;   // nothing decoded for 8 s: Dart's text shows
  int64_t fade_start_us_ = -1;
  bool resume_fade_ = false;  // the running fade lifts a resume dimming
  guint fade_tick_ = 0;
  guint loading_timer_ = 0;
  bool resume_waiting_ = false;
  bool resume_spinner_ = false;
  int64_t resumed_us_ = 0;
  int64_t frames_at_resume_ = 0;
  cairo_surface_t* icon_surface_ = nullptr;  // icon_ at kIconSize
  int icon_surface_scale_ = 0;

  // Decode queue.
  std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<Packet> queue_;
  bool stopping_ = false;
  bool waiting_for_key_ = true;
  int64_t last_keyframe_ask_us_ = 0;
  std::thread decode_thread_;

  // Device-pixel size the decoder scales pictures to (the drawing area).
  std::atomic<int> fit_width_{0};
  std::atomic<int> fit_height_{0};
  std::atomic<bool> draw_queued_{false};

  // Shared with the decode thread.
  std::mutex frame_mutex_;
  Frame frame_;
  int video_width_;
  int video_height_;
  int32_t visual_ = 1;  // WSN_VISUAL_CONNECTING
  std::string message_;
  std::string hud_text_;
  double fps_ = 0;
  double decode_ms_ = 0;
  int64_t presented_ = 0;
  int64_t dropped_ = 0;
  bool first_frame_ = false;
  bool reported_no_decoder_ = false;
  // When the picture's size last changed (the stream's SIZE), how many
  // pictures came since, and when the first one came.
  int64_t first_decoded_us_ = 0;
  int64_t size_changed_us_ = 0;
  int frames_since_size_change_ = 0;
  int decoded_width_ = 0;
  int decoded_height_ = 0;

  // The last decoded picture as FFmpeg gave it (an AVFrame reference), for
  // full-size snapshots.
  std::mutex snapshot_mutex_;
  void* last_picture_ = nullptr;
  int last_matrix_ = 0;
  bool last_full_range_ = false;

  std::mutex audio_mutex_;
  std::unique_ptr<AudioOut> audio_;
  double volume_ = 1;
  std::string audio_title_;  // names the sound stream (the window's title)
  int64_t av_traced_us_ = 0;  // decode thread
};

// The surfaces by id (any thread).
void AddSurface(const std::shared_ptr<Surface>& surface);
std::shared_ptr<Surface> FindSurface(int64_t id);
std::shared_ptr<Surface> TakeSurface(int64_t id);
std::vector<std::shared_ptr<Surface>> TakeAllSurfaces();
int64_t NextSurfaceId();
// wsn_set_strings: every window's control shows the new words.
void RefreshSurfaceStrings();

}  // namespace wsn

#endif  // WSN_RECEIVER_SURFACE_H_
