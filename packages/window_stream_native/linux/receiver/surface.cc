#include "receiver/surface.h"

#include <pthread.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include "common/callbacks.h"
#include "common/ffmpeg.h"
#include "common/log.h"
#include "common/main_thread.h"
#include "receiver/audio_out.h"
#include "receiver/decoder.h"
#include "receiver/keymap.h"
#include "receiver/ui_strings.h"
#include "window_stream_native.h"

namespace wsn {

namespace {

// Above this many packets waiting to be decoded, deltas are dropped until
// the next keyframe so latency never builds up.
constexpr size_t kMaxQueuedPackets = 6;
constexpr int64_t kKeyframeAskIntervalUs = 300000;
constexpr int64_t kHoverIntervalUs = 1000000 / 120;
constexpr guint kResizeDebounceMs = 150;
// Wayland scroll deltas are libinput pixels / 10 (GTK 3).
constexpr double kTouchpadPixelsPerDelta = 10;
// "Picture is stable" (ws/ROUND2.md): the picture's size unchanged for
// 300 ms with a picture at that size, or 2.5 s after the first one.
constexpr int64_t kStableQuietUs = 300000;
constexpr int kStableFramesAfterChange = 1;  // a static window may send one
constexpr int64_t kStableCapUs = 2500000;
constexpr int64_t kFadeUs = 180000;
constexpr int64_t kResumeGraceUs = 300000;
constexpr int64_t kSlowConnectUs = 8000000;
constexpr guint kLoadingTickMs = 50;
constexpr double kPlaceholderDim = 0.35;
constexpr int kSpinnerSize = 32;
// The placeholder: the app's icon, and the spinner under it.
constexpr int kIconSize = 64;
constexpr int kIconCentreAbove = 28;   // icon centre above the window centre
constexpr int kSpinnerCentreBelow = 40;  // spinner centre below it (with an icon)
// REFLOW: shapes within this much of each other count as the same; a user
// resize has settled once allocations stop this long, and the other side
// then has this long to follow before the window takes the picture's shape.
constexpr double kAspectTolerance = 0.02;
constexpr guint kSettleQuietMs = 300;
constexpr guint kSettleDelayMs = 2000;
// Volume reports to Dart while a change goes on: at most ten a second.
constexpr int64_t kVolumeReportUs = 100000;
constexpr int kVolumeSliderWidth = 140;

bool SameShape(double width, double height, double video_width, double video_height) {
  if (width <= 0 || height <= 0 || video_width <= 0 || video_height <= 0) return true;
  return std::fabs((width / height) / (video_width / video_height) - 1) <= kAspectTolerance;
}

const char* VolumeIcon(double volume) {
  if (volume <= 0.001) return "audio-volume-muted-symbolic";
  if (volume < 0.34) return "audio-volume-low-symbolic";
  if (volume < 0.67) return "audio-volume-medium-symbolic";
  return "audio-volume-high-symbolic";
}

void SetAccessibleName(GtkWidget* widget, const std::string& name) {
  AtkObject* accessible = gtk_widget_get_accessible(widget);
  if (accessible != nullptr) atk_object_set_name(accessible, name.c_str());
}

int64_t NowUs() { return g_get_monotonic_time(); }

std::mutex g_surfaces_mutex;
std::map<int64_t, std::shared_ptr<Surface>> g_surfaces;
std::atomic<int64_t> g_next_surface{1};

// The work area to size a new window for: the primary monitor, else (Wayland
// has none) the one Whisper's main window is on, else the first.
GdkRectangle WorkArea() {
  GdkRectangle area = {0, 0, 1280, 800};
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) return area;
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr) {
    GtkWindow* main = nullptr;
    GApplication* app = g_application_get_default();
    if (app != nullptr && GTK_IS_APPLICATION(app)) main = gtk_application_get_active_window(GTK_APPLICATION(app));
    if (main == nullptr) {
      GList* toplevels = gtk_window_list_toplevels();
      for (GList* item = toplevels; item != nullptr; item = item->next) {
        if (gtk_widget_get_mapped(GTK_WIDGET(item->data))) {
          main = GTK_WINDOW(item->data);
          break;
        }
      }
      g_list_free(toplevels);
    }
    GdkWindow* gdk_window = main != nullptr ? gtk_widget_get_window(GTK_WIDGET(main)) : nullptr;
    if (gdk_window != nullptr) monitor = gdk_display_get_monitor_at_window(display, gdk_window);
  }
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0) monitor = gdk_display_get_monitor(display, 0);
  if (monitor != nullptr) gdk_monitor_get_workarea(monitor, &area);
  if (area.width <= 0 || area.height <= 0) area = {0, 0, 1280, 800};
  return area;
}

PangoLayout* TextLayout(GtkWidget* widget, cairo_t* cr, const std::string& text, double size, PangoWeight weight,
                        bool monospace) {
  PangoLayout* layout = pango_cairo_create_layout(cr);
  PangoFontDescription* font = nullptr;
  if (monospace) {
    font = pango_font_description_from_string("Monospace");
  } else {
    PangoContext* context = gtk_widget_get_pango_context(widget);
    font = pango_font_description_copy(pango_context_get_font_description(context));
  }
  pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
  pango_font_description_set_weight(font, weight);
  pango_layout_set_font_description(layout, font);
  pango_font_description_free(font);
  pango_layout_set_text(layout, text.c_str(), -1);
  return layout;
}

void FreeBytes(guchar* pixels, gpointer) { std::free(pixels); }

// Two box-blur passes each way over a small RGB24 image (the picture behind
// an overlay), so scaling it up shows a soft blur rather than blocks.
void BoxBlur(unsigned char* pixels, int width, int height, int stride) {
  constexpr int kRadius = 2;
  std::vector<int> line(static_cast<size_t>(std::max(width, height)) * 3);
  for (int pass = 0; pass < 2; pass++) {
    for (int y = 0; y < height; y++) {
      unsigned char* row = pixels + static_cast<size_t>(y) * stride;
      for (int x = 0; x < width; x++) {
        int sum[3] = {0, 0, 0};
        for (int k = -kRadius; k <= kRadius; k++) {
          const unsigned char* p = row + 4 * std::clamp(x + k, 0, width - 1);
          for (int c = 0; c < 3; c++) sum[c] += p[c];
        }
        for (int c = 0; c < 3; c++) line[3 * x + c] = sum[c] / (2 * kRadius + 1);
      }
      for (int x = 0; x < width; x++) {
        for (int c = 0; c < 3; c++) row[4 * x + c] = static_cast<unsigned char>(line[3 * x + c]);
      }
    }
    for (int x = 0; x < width; x++) {
      for (int y = 0; y < height; y++) {
        int sum[3] = {0, 0, 0};
        for (int k = -kRadius; k <= kRadius; k++) {
          const unsigned char* p = pixels + static_cast<size_t>(std::clamp(y + k, 0, height - 1)) * stride + 4 * x;
          for (int c = 0; c < 3; c++) sum[c] += p[c];
        }
        for (int c = 0; c < 3; c++) line[3 * y + c] = sum[c] / (2 * kRadius + 1);
      }
      for (int y = 0; y < height; y++) {
        unsigned char* p = pixels + static_cast<size_t>(y) * stride + 4 * x;
        for (int c = 0; c < 3; c++) p[c] = static_cast<unsigned char>(line[3 * y + c]);
      }
    }
  }
}

}  // namespace

// ---------------------------------------------------------------- registry

void AddSurface(const std::shared_ptr<Surface>& surface) {
  std::lock_guard<std::mutex> lock(g_surfaces_mutex);
  g_surfaces[surface->id()] = surface;
}

std::shared_ptr<Surface> FindSurface(int64_t id) {
  std::lock_guard<std::mutex> lock(g_surfaces_mutex);
  auto it = g_surfaces.find(id);
  return it == g_surfaces.end() ? nullptr : it->second;
}

std::shared_ptr<Surface> TakeSurface(int64_t id) {
  std::lock_guard<std::mutex> lock(g_surfaces_mutex);
  auto it = g_surfaces.find(id);
  if (it == g_surfaces.end()) return nullptr;
  std::shared_ptr<Surface> surface = it->second;
  g_surfaces.erase(it);
  return surface;
}

std::vector<std::shared_ptr<Surface>> TakeAllSurfaces() {
  std::lock_guard<std::mutex> lock(g_surfaces_mutex);
  std::vector<std::shared_ptr<Surface>> all;
  for (auto& entry : g_surfaces) all.push_back(entry.second);
  g_surfaces.clear();
  return all;
}

int64_t NextSurfaceId() { return g_next_surface++; }

void RefreshSurfaceStrings() {
  std::vector<std::shared_ptr<Surface>> all;
  {
    std::lock_guard<std::mutex> lock(g_surfaces_mutex);
    for (auto& entry : g_surfaces) all.push_back(entry.second);
  }
  for (const std::shared_ptr<Surface>& surface : all) surface->RefreshStrings();
}

// ---------------------------------------------------------------- lifecycle

Surface::Surface(int64_t id, std::string title, int video_width, int video_height, bool hud, bool reflow)
    : id_(id),
      hud_(hud),
      reflow_(reflow),
      title_(std::move(title)),
      opened_us_(NowUs()),
      connecting_since_us_(opened_us_),
      video_width_(video_width > 0 && video_height > 0 ? video_width : 1080),
      video_height_(video_width > 0 && video_height > 0 ? video_height : 2400),
      audio_title_(title_) {}

Surface::~Surface() {
  if (last_picture_ != nullptr && Libav().ok) Libav().frame_free(&last_picture_);
  if (icon_surface_ != nullptr) cairo_surface_destroy(icon_surface_);
}

void Surface::Start() {
  decode_thread_ = std::thread([self = shared_from_this()] { self->DecodeLoop(); });
  OnMain([self = shared_from_this()] { self->CreateWindow(); });
}

void Surface::Stop() {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    stopping_ = true;
  }
  queue_cv_.notify_all();
  if (decode_thread_.joinable()) decode_thread_.join();
  std::unique_ptr<AudioOut> audio;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio.swap(audio_);
  }
  // A PulseAudio write can block for a moment; never on the caller's thread.
  if (audio != nullptr) std::thread([output = std::move(audio)]() mutable { output.reset(); }).detach();
  // Strong: the registry may have held the last reference, and the window
  // must still close.
  OnMain([self = shared_from_this()] { self->DestroyWindow(); });
}

void Surface::SetTitle(std::string title) {
  {
    // For a sound stream opened later; PulseAudio's simple API cannot rename
    // one that plays.
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio_title_ = title;
  }
  OnMain([self = shared_from_this(), title = std::move(title)] {
    self->title_ = title;
    if (self->window_ != nullptr) gtk_window_set_title(GTK_WINDOW(self->window_), title.c_str());
    if (self->header_ != nullptr) gtk_header_bar_set_title(GTK_HEADER_BAR(self->header_), title.c_str());
  });
}

void Surface::SetVisual(int32_t visual, std::string message) {
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    visual_ = visual;
    message_ = std::move(message);
  }
  OnMain([self = shared_from_this(), visual] {
    int32_t before = self->main_visual_;
    self->main_visual_ = visual;
    if (visual == WSN_VISUAL_CONNECTING && before != WSN_VISUAL_CONNECTING) self->connecting_since_us_ = NowUs();
    // Input in flight belongs to the live picture.
    if (visual != WSN_VISUAL_LIVE) {
      self->ReleaseInput();
      self->resume_waiting_ = false;
      self->resume_spinner_ = false;
    } else if (before != WSN_VISUAL_LIVE && self->live_shown_) {
      // Back from a pause (or a reconnect): the last picture stays; the
      // spinner only comes if no new one arrives soon.
      std::lock_guard<std::mutex> lock(self->frame_mutex_);
      self->frames_at_resume_ = self->presented_;
      self->resumed_us_ = NowUs();
      self->resume_waiting_ = true;
      self->resume_spinner_ = false;
    }
    self->UpdateLoading();
    if (self->area_ != nullptr) gtk_widget_queue_draw(self->area_);
  });
}

void Surface::SetHud(std::string text) {
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    hud_text_ = std::move(text);
  }
  QueueDraw();
}

void Surface::SetIcon(const uint8_t* png, int32_t length) {
  if (png == nullptr || length <= 0) return;
  GdkPixbufLoader* loader = gdk_pixbuf_loader_new();
  GError* error = nullptr;
  GdkPixbuf* icon = nullptr;
  if (gdk_pixbuf_loader_write(loader, png, static_cast<gsize>(length), &error) &&
      gdk_pixbuf_loader_close(loader, &error)) {
    icon = gdk_pixbuf_loader_get_pixbuf(loader);
    if (icon != nullptr) g_object_ref(icon);
  } else {
    gdk_pixbuf_loader_close(loader, nullptr);
  }
  g_clear_error(&error);
  g_object_unref(loader);
  if (icon == nullptr) return;
  OnMain([self = shared_from_this(), icon] {
    if (self->icon_ != nullptr) g_object_unref(self->icon_);
    self->icon_ = icon;
    // Also the placeholder while the stream settles.
    if (self->icon_surface_ != nullptr) cairo_surface_destroy(self->icon_surface_);
    self->icon_surface_ = nullptr;
    self->UpdateSpinner();
    if (self->area_ != nullptr && !self->live_shown_) gtk_widget_queue_draw(self->area_);
    // Shown by X11 window managers; GNOME on Wayland uses the app's
    // desktop file instead.
    if (self->window_ != nullptr) gtk_window_set_icon(GTK_WINDOW(self->window_), icon);
  });
}

void Surface::Focus() {
  OnMain([self = shared_from_this()] {
    if (self->window_ == nullptr) return;
    gtk_window_deiconify(GTK_WINDOW(self->window_));
    gtk_window_present(GTK_WINDOW(self->window_));
  });
}

// ---------------------------------------------------------------- video

void Surface::PushVideo(uint8_t* buffer, int32_t length, int64_t pts_us, int32_t flags) {
  Packet packet;
  packet.data.assign(buffer, buffer + length);
  packet.pts_us = pts_us;
  packet.flags = flags;
  std::free(buffer);
  bool ask = false;
  bool dropped = false;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (stopping_) return;
    bool delta = (flags & (WSN_PACKET_CONFIG | WSN_PACKET_KEY)) == 0;
    if (delta && queue_.size() >= kMaxQueuedPackets) {
      dropped = true;
      waiting_for_key_ = true;
      int64_t now = NowUs();
      if (now - last_keyframe_ask_us_ > kKeyframeAskIntervalUs) {
        last_keyframe_ask_us_ = now;
        ask = true;
      }
    } else {
      queue_.push_back(std::move(packet));
    }
  }
  if (dropped) {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    dropped_++;
  }
  if (ask) EmitWindow(id_, WSN_WINDOW_NEED_KEYFRAME);
  queue_cv_.notify_one();
}

void Surface::AskKeyframe() {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    waiting_for_key_ = true;
    int64_t now = NowUs();
    if (now - last_keyframe_ask_us_ <= kKeyframeAskIntervalUs) return;
    last_keyframe_ask_us_ = now;
  }
  EmitWindow(id_, WSN_WINDOW_NEED_KEYFRAME);
}

void Surface::DecodeLoop() {
  pthread_setname_np(pthread_self(), "wsn-decode");
  Decoder decoder;
  std::vector<uint8_t> config;
  std::vector<uint8_t> unit;
  int64_t window_start = NowUs();
  int window_frames = 0;
  int failed_keyframes = 0;
  for (;;) {
    Packet packet;
    {
      std::unique_lock<std::mutex> lock(queue_mutex_);
      queue_cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
      if (stopping_) return;
      packet = std::move(queue_.front());
      queue_.pop_front();
    }
    if (packet.flags & WSN_PACKET_CONFIG) {
      config = std::move(packet.data);
      continue;
    }
    bool key = (packet.flags & WSN_PACKET_KEY) != 0;
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      if (waiting_for_key_ && !key) {
        std::lock_guard<std::mutex> frame_lock(frame_mutex_);
        dropped_++;
        continue;
      }
      if (key) waiting_for_key_ = false;
    }
    const std::vector<uint8_t>* data = &packet.data;
    if (key && !config.empty()) {
      unit.assign(config.begin(), config.end());
      unit.insert(unit.end(), packet.data.begin(), packet.data.end());
      data = &unit;
    }
    int64_t started = NowUs();
    int result = decoder.Decode(data->data(), data->size(), fit_width_.load(), fit_height_.load(),
                                [&](Decoder::Picture& picture) {
      int64_t now = NowUs();
      bool first;
      bool resized;
      {
        std::lock_guard<std::mutex> lock(frame_mutex_);
        frame_.pixels.swap(picture.pixels);
        frame_.width = picture.width;
        frame_.height = picture.height;
        frame_.stride = picture.stride;
        resized = picture.video_width != video_width_ || picture.video_height != video_height_;
        video_width_ = picture.video_width;
        video_height_ = picture.video_height;
        if (presented_ == 0) first_decoded_us_ = now;
        if (picture.video_width != decoded_width_ || picture.video_height != decoded_height_) {
          decoded_width_ = picture.video_width;
          decoded_height_ = picture.video_height;
          size_changed_us_ = now;
          frames_since_size_change_ = 0;
        }
        frames_since_size_change_++;
        decode_ms_ = static_cast<double>(now - started) / 1000;
        presented_++;
        first = !first_frame_;
        first_frame_ = true;
        window_frames++;
        if (now - window_start >= 1000000) {
          fps_ = window_frames * 1e6 / static_cast<double>(now - window_start);
          window_frames = 0;
          window_start = now;
        }
      }
      const FFmpeg& av = Libav();
      if (av.frame_clone != nullptr) {
        void* copy = av.frame_clone(picture.frame);
        std::lock_guard<std::mutex> lock(snapshot_mutex_);
        if (last_picture_ != nullptr) av.frame_free(&last_picture_);
        last_picture_ = copy;
        last_matrix_ = picture.matrix;
        last_full_range_ = picture.full_range;
      }
      if (resized) {
        int width = picture.video_width;
        int height = picture.video_height;
        OnMain([self = shared_from_this(), width, height] { self->ApplyVideoSize(width, height); });
      }
      QueueDraw();
      if (first) EmitWindow(id_, WSN_WINDOW_FIRST_FRAME);
      // Lip sync, for the log: how far the sound being heard trails the
      // picture just decoded (both pts are on the host's clock).
      if (TraceEnabled() && now - av_traced_us_ >= 2000000) {
        av_traced_us_ = now;
        int64_t heard = -1;
        {
          std::lock_guard<std::mutex> lock(audio_mutex_);
          if (audio_ != nullptr) heard = audio_->HeardPtsUs();
        }
        if (heard >= 0) {
          WSN_LOG("surface %lld: sound %+.0f ms behind the picture", static_cast<long long>(id_),
                  static_cast<double>(packet.pts_us - heard) / 1000);
        }
      }
    });
    if (result == 0 && key) failed_keyframes = 0;
    if (result == 1) {
      bool report;
      {
        std::lock_guard<std::mutex> lock(frame_mutex_);
        report = !reported_no_decoder_;
        reported_no_decoder_ = true;
        dropped_++;
      }
      if (report) {
        WSN_LOG("surface %lld: no H.264 decoder (FFmpeg missing)", static_cast<long long>(id_));
        EmitWindow(id_, WSN_WINDOW_DECODE_ERROR, 1);
      }
    } else if (result < 0) {
      WSN_TRACE("surface %lld: decode error %d", static_cast<long long>(id_), result);
      // Two keyframes in a row rejected: the stream is fine but trips the
      // strict checks, so stop asking for keyframes that cannot help.
      if (key && ++failed_keyframes >= 2) decoder.Tolerate();
      decoder.Flush();
      {
        std::lock_guard<std::mutex> lock(frame_mutex_);
        dropped_++;
      }
      EmitWindow(id_, WSN_WINDOW_DECODE_ERROR, result);
      AskKeyframe();
    }
  }
}

// ---------------------------------------------------------------- audio

void Surface::ConfigureAudio(int sample_rate, int channels) {
  std::unique_ptr<AudioOut> old;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    if (audio_ != nullptr && audio_->Matches(sample_rate, channels)) {
      // The same format again (resume, reconnect): keep the sound stream,
      // start a new timeline.
      audio_->Reset();
      return;
    }
    old.swap(audio_);
    audio_ = std::make_unique<AudioOut>(sample_rate, channels, audio_title_, volume_);
  }
  // Closing one lets it play out its last few ms: never on the caller's thread.
  if (old != nullptr) std::thread([output = std::move(old)]() mutable { output.reset(); }).detach();
  // The window has sound: its volume control shows.
  OnMain([self = shared_from_this()] { self->ShowVolumeControl(); });
}

void Surface::SetVolume(double volume) {
  const double level = std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 1.0;
  ApplyVolume(level);
  OnMain([self = shared_from_this(), level] {
    // Not the user's change: nothing to report.
    if (self->volume_report_timer_ != 0) {
      g_source_remove(self->volume_report_timer_);
      self->volume_report_timer_ = 0;
    }
    self->shown_volume_ = level;
    self->reported_volume_ = level;
    if (level > 0.001) self->audible_volume_ = level;
    self->SyncVolumeControl();
  });
}

void Surface::ApplyVolume(double volume) {
  std::lock_guard<std::mutex> lock(audio_mutex_);
  volume_ = volume;
  if (audio_ != nullptr) audio_->SetVolume(volume);
}

void Surface::RefreshStrings() {
  OnMain([self = shared_from_this()] { self->SyncVolumeControl(); });
}

void Surface::PushAudio(uint8_t* buffer, int32_t length, int64_t pts_us) {
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    if (audio_ != nullptr) audio_->Push(buffer, static_cast<size_t>(length), pts_us);
  }
  std::free(buffer);
}

// ---------------------------------------------------------------- stats, snapshot

int32_t Surface::Stats(double* out, int32_t count) {
  double values[9] = {0};
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    values[3] = static_cast<double>(queue_.size());
  }
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    values[0] = fps_;
    values[1] = static_cast<double>(dropped_);
    values[2] = decode_ms_;
    values[4] = static_cast<double>(presented_);
  }
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    if (audio_ != nullptr) audio_->Stats(values + 5);
  }
  int32_t written = std::min<int32_t>(count, 9);
  for (int32_t i = 0; i < written; i++) out[i] = values[i];
  return written;
}

int32_t Surface::Snapshot(const char* path, int32_t max_edge) {
  std::vector<uint8_t> rgb;
  int width = 0;
  int height = 0;
  int stride = 0;
  bool have = false;
  const FFmpeg& av = Libav();
  void* picture = nullptr;
  int matrix = 0;
  bool full_range = false;
  {
    std::lock_guard<std::mutex> lock(snapshot_mutex_);
    if (last_picture_ != nullptr && av.frame_clone != nullptr) picture = av.frame_clone(last_picture_);
    matrix = last_matrix_;
    full_range = last_full_range_;
  }
  if (picture != nullptr) {
    have = Decoder::ToRgb(picture, matrix, full_range, max_edge, &rgb, &width, &height, &stride);
    av.frame_free(&picture);
  }
  GdkPixbuf* pixbuf = nullptr;
  if (have) {
    auto* pixels = static_cast<guchar*>(std::malloc(rgb.size()));
    if (pixels == nullptr) return -2;
    std::memcpy(pixels, rgb.data(), rgb.size());
    pixbuf = gdk_pixbuf_new_from_data(pixels, GDK_COLORSPACE_RGB, FALSE, 8, width, height, stride, FreeBytes,
                                      nullptr);
  } else {
    // No FFmpeg frame to go back to: the picture as shown.
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (frame_.pixels.empty()) return -2;
    pixbuf = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, frame_.width, frame_.height);
    if (pixbuf == nullptr) return -2;
    guchar* out = gdk_pixbuf_get_pixels(pixbuf);
    int out_stride = gdk_pixbuf_get_rowstride(pixbuf);
    for (int y = 0; y < frame_.height; y++) {
      const uint8_t* row = frame_.pixels.data() + static_cast<size_t>(y) * frame_.stride;
      guchar* target = out + static_cast<size_t>(y) * out_stride;
      for (int x = 0; x < frame_.width; x++) {
        target[3 * x] = row[4 * x + 2];
        target[3 * x + 1] = row[4 * x + 1];
        target[3 * x + 2] = row[4 * x];
      }
    }
    int longest = std::max(frame_.width, frame_.height);
    if (max_edge > 0 && longest > max_edge) {
      double scale = static_cast<double>(max_edge) / longest;
      GdkPixbuf* scaled = gdk_pixbuf_scale_simple(pixbuf, std::max(1, static_cast<int>(frame_.width * scale)),
                                                  std::max(1, static_cast<int>(frame_.height * scale)),
                                                  GDK_INTERP_BILINEAR);
      g_object_unref(pixbuf);
      pixbuf = scaled;
    }
  }
  if (pixbuf == nullptr) return -2;
  GError* error = nullptr;
  gboolean saved = gdk_pixbuf_save(pixbuf, path, "jpeg", &error, "quality", "85", nullptr);
  if (!saved) WSN_LOG("snapshot: %s", error != nullptr ? error->message : "failed");
  g_clear_error(&error);
  g_object_unref(pixbuf);
  return saved ? 0 : -2;
}

// ---------------------------------------------------------------- window

void Surface::CreateWindow() {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (stopping_) return;
  }
  int video_width;
  int video_height;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    video_width = video_width_;
    video_height = video_height_;
  }
  window_ = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window_), title_.c_str());
  if (icon_ != nullptr) gtk_window_set_icon(GTK_WINDOW(window_), icon_);
  // A title bar of our own (client-side, as GTK draws on Wayland anyway):
  // the title, the window buttons and, once there is sound, the volume.
  header_ = gtk_header_bar_new();
  gtk_header_bar_set_title(GTK_HEADER_BAR(header_), title_.c_str());
  gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(header_), TRUE);
  CreateVolumeControl(header_);
  gtk_window_set_titlebar(GTK_WINDOW(window_), header_);
  // As on macOS: up to 82% of the screen's height (900 at most) and 60% of
  // its width, in the picture's shape.
  GdkRectangle work = WorkArea();
  double max_height = std::max(320.0, work.height * 0.82);
  double max_width = std::max(320.0, work.width * 0.6);
  double height = std::min(max_height, 900.0);
  double width = height * video_width / video_height;
  if (width > max_width) {
    width = max_width;
    height = width * video_height / video_width;
  }
  gtk_window_set_default_size(GTK_WINDOW(window_), static_cast<int>(std::lround(width)),
                              static_cast<int>(std::lround(height)));
  gtk_window_set_position(GTK_WINDOW(window_), GTK_WIN_POS_CENTER);
  GdkGeometry geometry = {};
  geometry.min_width = 200;
  geometry.min_height = 200;
  gtk_window_set_geometry_hints(GTK_WINDOW(window_), nullptr, &geometry, GDK_HINT_MIN_SIZE);
  shown_video_width_ = video_width;
  shown_video_height_ = video_height;

  area_ = gtk_drawing_area_new();
  gtk_widget_set_can_focus(area_, TRUE);
  gtk_widget_add_events(area_, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_POINTER_MOTION_MASK |
                                   GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK | GDK_KEY_PRESS_MASK |
                                   GDK_KEY_RELEASE_MASK | GDK_FOCUS_CHANGE_MASK | GDK_LEAVE_NOTIFY_MASK);
  // The picture, and over it the system's spinner while the stream settles
  // (GTK's own: it follows the theme and stops turning when animations are
  // off). It lets every click through to the picture.
  overlay_ = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(window_), overlay_);
  gtk_container_add(GTK_CONTAINER(overlay_), area_);
  spinner_ = gtk_spinner_new();
  gtk_widget_set_size_request(spinner_, kSpinnerSize, kSpinnerSize);
  gtk_widget_set_halign(spinner_, GTK_ALIGN_CENTER);
  gtk_widget_set_valign(spinner_, GTK_ALIGN_CENTER);
  GtkCssProvider* spinner_style = gtk_css_provider_new();
  // Light on the dark picture, whatever the theme's text colour is.
  gtk_css_provider_load_from_data(spinner_style, "spinner { color: rgba(255, 255, 255, 0.9); }", -1, nullptr);
  gtk_style_context_add_provider(gtk_widget_get_style_context(spinner_), GTK_STYLE_PROVIDER(spinner_style),
                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref(spinner_style);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay_), spinner_);
  gtk_overlay_set_overlay_pass_through(GTK_OVERLAY(overlay_), spinner_, TRUE);

  im_ = gtk_im_multicontext_new();
  // The input method shows what is being composed in its own popup; only
  // the committed text is sent.
  gtk_im_context_set_use_preedit(im_, FALSE);
  g_signal_connect(im_, "commit", G_CALLBACK(OnCommitThunk), this);
  g_signal_connect(im_, "preedit-changed", G_CALLBACK(OnPreeditChangedThunk), this);
  g_signal_connect(area_, "draw", G_CALLBACK(OnDrawThunk), this);
  g_signal_connect(area_, "size-allocate", G_CALLBACK(OnAllocateThunk), this);
  g_signal_connect(area_, "button-press-event", G_CALLBACK(OnButtonPressThunk), this);
  g_signal_connect(area_, "button-release-event", G_CALLBACK(OnButtonReleaseThunk), this);
  g_signal_connect(area_, "motion-notify-event", G_CALLBACK(OnMotionThunk), this);
  g_signal_connect(area_, "scroll-event", G_CALLBACK(OnScrollThunk), this);
  g_signal_connect(area_, "key-press-event", G_CALLBACK(OnKeyPressThunk), this);
  g_signal_connect(area_, "key-release-event", G_CALLBACK(OnKeyReleaseThunk), this);
  g_signal_connect(area_, "grab-broken-event", G_CALLBACK(OnGrabBrokenThunk), this);
  // Focus moving to the volume popover: what is held is let go at the source.
  g_signal_connect(area_, "focus-out-event", G_CALLBACK(OnAreaFocusOutThunk), this);
  g_signal_connect(window_, "delete-event", G_CALLBACK(OnDeleteThunk), this);
  g_signal_connect(window_, "focus-in-event", G_CALLBACK(OnFocusInThunk), this);
  g_signal_connect(window_, "focus-out-event", G_CALLBACK(OnFocusOutThunk), this);
  g_signal_connect(window_, "window-state-event", G_CALLBACK(OnWindowStateThunk), this);
  gtk_widget_show_all(window_);
  if (has_sound_) ShowVolumeControl();
  gtk_im_context_set_client_window(im_, gtk_widget_get_window(area_));
  gtk_widget_grab_focus(area_);
  gtk_window_present(GTK_WINDOW(window_));
  UpdateLoading();
}

void Surface::DestroyWindow() {
  if (hover_timer_ != 0) g_source_remove(hover_timer_);
  if (resize_timer_ != 0) g_source_remove(resize_timer_);
  if (loading_timer_ != 0) g_source_remove(loading_timer_);
  if (volume_report_timer_ != 0) g_source_remove(volume_report_timer_);
  volume_report_timer_ = 0;
  CancelSettle();
  if (fade_tick_ != 0 && area_ != nullptr) gtk_widget_remove_tick_callback(area_, fade_tick_);
  hover_timer_ = 0;
  resize_timer_ = 0;
  loading_timer_ = 0;
  fade_tick_ = 0;
  if (icon_surface_ != nullptr) {
    cairo_surface_destroy(icon_surface_);
    icon_surface_ = nullptr;
  }
  if (im_ != nullptr) {
    g_signal_handlers_disconnect_by_data(im_, this);
    gtk_im_context_set_client_window(im_, nullptr);
    g_object_unref(im_);
    im_ = nullptr;
  }
  if (window_ != nullptr) {
    g_signal_handlers_disconnect_by_data(window_, this);
    if (area_ != nullptr) g_signal_handlers_disconnect_by_data(area_, this);
    if (volume_scale_ != nullptr) g_signal_handlers_disconnect_by_data(volume_scale_, this);
    if (mute_button_ != nullptr) g_signal_handlers_disconnect_by_data(mute_button_, this);
    if (volume_button_ != nullptr) {
      GtkPopover* popover = gtk_menu_button_get_popover(GTK_MENU_BUTTON(volume_button_));
      if (popover != nullptr) g_signal_handlers_disconnect_by_data(popover, this);
    }
    gtk_widget_destroy(window_);
    window_ = nullptr;
    header_ = nullptr;
    overlay_ = nullptr;
    area_ = nullptr;
    spinner_ = nullptr;
    volume_button_ = nullptr;
    volume_image_ = nullptr;
    volume_scale_ = nullptr;
    mute_button_ = nullptr;
    mute_image_ = nullptr;
  }
  if (icon_ != nullptr) {
    g_object_unref(icon_);
    icon_ = nullptr;
  }
}

void Surface::QueueDraw() {
  if (draw_queued_.exchange(true)) return;
  OnMain([self = shared_from_this()] {
    self->draw_queued_ = false;
    if (self->area_ == nullptr) return;
    self->UpdateLoading();
    gtk_widget_queue_draw(self->area_);
  });
}

// Keeps the window's height when the stream's shape changes (a phone
// rotated), as the macOS receiver does. A source that follows this
// window's size sends pictures of its shape already, so nothing moves.
void Surface::ApplyVideoSize(int width, int height) {
  if (window_ == nullptr || area_ == nullptr || width <= 0 || height <= 0) return;
  if (width == shown_video_width_ && height == shown_video_height_) return;
  shown_video_width_ = width;
  shown_video_height_ = height;
  // REFLOW: a new picture is the other side's answer, nothing to settle.
  if (reflow_) CancelSettle();
  int area_width = gtk_widget_get_allocated_width(area_);
  int area_height = gtk_widget_get_allocated_height(area_);
  if (area_width <= 1 || area_height <= 1) return;
  double video_aspect = static_cast<double>(width) / height;
  double area_aspect = static_cast<double>(area_width) / area_height;
  // REFLOW: laid out for this window (near enough), it stays as it is.
  if (reflow_ ? SameShape(area_width, area_height, width, height)
              : std::fabs(video_aspect / area_aspect - 1) < 0.03) {
    return;
  }
  // The user is dragging the edge: the source is following them.
  if (NowUs() - user_resized_us_ < 600000) return;
  GdkWindow* gdk_window = gtk_widget_get_window(window_);
  if (gdk_window != nullptr &&
      (gdk_window_get_state(gdk_window) & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                                           GDK_WINDOW_STATE_TILED)) != 0) {
    return;
  }
  int window_width = 0;
  int window_height = 0;
  gtk_window_get_size(GTK_WINDOW(window_), &window_width, &window_height);
  int new_area_width = static_cast<int>(std::lround(area_height * video_aspect));
  GdkRectangle work = WorkArea();
  if (new_area_width > work.width * 0.95) new_area_width = static_cast<int>(work.width * 0.95);
  resizing_to_video_ = true;
  gtk_window_resize(GTK_WINDOW(window_), window_width - area_width + new_area_width, window_height);
  gtk_widget_queue_draw(area_);
}

void Surface::OnAllocated(int width, int height) {
  int scale = gtk_widget_get_scale_factor(area_);
  fit_width_ = width * scale;
  fit_height_ = height * scale;
  const bool by_user = !resizing_to_video_ && reported_width_ != 0;
  if (by_user) user_resized_us_ = NowUs();
  resizing_to_video_ = false;
  if (reflow_ && by_user) ScheduleSettle();
  UpdateImCursor();
  // Reported once the size settles (the end of a drag), like macOS's
  // windowDidEndLiveResize.
  if (resize_timer_ != 0) g_source_remove(resize_timer_);
  resize_timer_ = g_timeout_add(kResizeDebounceMs, [](gpointer data) -> gboolean {
    auto* self = static_cast<Surface*>(data);
    self->resize_timer_ = 0;
    self->ReportSize();
    return G_SOURCE_REMOVE;
  }, this);
}

void Surface::ScheduleSettle() {
  CancelSettle();
  settle_quiet_timer_ = g_timeout_add(kSettleQuietMs, [](gpointer data) -> gboolean {
    auto* self = static_cast<Surface*>(data);
    self->settle_quiet_timer_ = 0;
    // The resize has settled: the other side has a moment to follow.
    self->settle_timer_ = g_timeout_add(kSettleDelayMs, [](gpointer data) -> gboolean {
      auto* self = static_cast<Surface*>(data);
      self->settle_timer_ = 0;
      self->Settle();
      return G_SOURCE_REMOVE;
    }, self);
    return G_SOURCE_REMOVE;
  }, this);
}

void Surface::CancelSettle() {
  if (settle_quiet_timer_ != 0) g_source_remove(settle_quiet_timer_);
  if (settle_timer_ != 0) g_source_remove(settle_timer_);
  settle_quiet_timer_ = 0;
  settle_timer_ = 0;
}

// The picture kept its shape after the user resized: the window takes it,
// one side shrinking so the picture fits the frame. The size it settles at
// is reported as any other (OnAllocated → ReportSize).
void Surface::Settle() {
  if (window_ == nullptr || area_ == nullptr) return;
  GdkWindow* gdk_window = gtk_widget_get_window(window_);
  if (gdk_window != nullptr &&
      (gdk_window_get_state(gdk_window) & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                                           GDK_WINDOW_STATE_TILED | GDK_WINDOW_STATE_ICONIFIED)) != 0) {
    return;
  }
  int area_width = gtk_widget_get_allocated_width(area_);
  int area_height = gtk_widget_get_allocated_height(area_);
  int video_width;
  int video_height;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    video_width = video_width_;
    video_height = video_height_;
  }
  if (area_width <= 1 || area_height <= 1 || SameShape(area_width, area_height, video_width, video_height)) return;
  double scale = std::min(static_cast<double>(area_width) / video_width,
                          static_cast<double>(area_height) / video_height);
  double width = video_width * scale;
  double height = video_height * scale;
  // No smaller than the window may be.
  double grow = std::max({1.0, 200.0 / width, 200.0 / height});
  int new_width = static_cast<int>(std::lround(width * grow));
  int new_height = static_cast<int>(std::lround(height * grow));
  int window_width = 0;
  int window_height = 0;
  gtk_window_get_size(GTK_WINDOW(window_), &window_width, &window_height);
  WSN_LOG("surface %lld: settling %dx%d to the picture's shape %dx%d", static_cast<long long>(id_), area_width,
          area_height, new_width, new_height);
  resizing_to_video_ = true;
  gtk_window_resize(GTK_WINDOW(window_), window_width - area_width + new_width,
                    window_height - area_height + new_height);
}

void Surface::ReportSize() {
  if (area_ == nullptr) return;
  int width = gtk_widget_get_allocated_width(area_);
  int height = gtk_widget_get_allocated_height(area_);
  int scale = gtk_widget_get_scale_factor(area_);
  if (width <= 1 || height <= 1) return;
  if (width == reported_width_ && height == reported_height_ && scale == reported_scale_) return;
  reported_width_ = width;
  reported_height_ = height;
  reported_scale_ = scale;
  EmitWindow(id_, WSN_WINDOW_RESIZED, width, height, scale);
}

// Where the candidate window opens: low in the middle of the picture, where
// it does not cover what is being typed into most of the time (as macOS).
void Surface::UpdateImCursor() {
  if (im_ == nullptr || area_ == nullptr) return;
  double x, y, w, h;
  VideoRect(&x, &y, &w, &h);
  GdkRectangle cursor = {static_cast<int>(x + w / 2 - 120), static_cast<int>(y + h - 56 - 22), 1, 22};
  gtk_im_context_set_cursor_location(im_, &cursor);
}

// ---------------------------------------------------------------- volume

// The speaker button at the end of the title bar opens a popover with a
// mute toggle and a slider. It lives in the title bar and its popover,
// never in the picture, so no pointer or key meant for it reaches the
// streamed app. Hidden until the window has sound.
void Surface::CreateVolumeControl(GtkWidget* header) {
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    shown_volume_ = volume_;
  }
  reported_volume_ = shown_volume_;
  if (shown_volume_ > 0.001) audible_volume_ = shown_volume_;
  volume_button_ = gtk_menu_button_new();
  // Clicking it leaves the keyboard with the picture.
  gtk_widget_set_focus_on_click(volume_button_, FALSE);
  gtk_widget_set_valign(volume_button_, GTK_ALIGN_CENTER);
  GtkWidget* arrow = gtk_bin_get_child(GTK_BIN(volume_button_));
  if (arrow != nullptr) gtk_container_remove(GTK_CONTAINER(volume_button_), arrow);
  volume_image_ = gtk_image_new_from_icon_name(VolumeIcon(shown_volume_), GTK_ICON_SIZE_BUTTON);
  gtk_container_add(GTK_CONTAINER(volume_button_), volume_image_);

  GtkWidget* popover = gtk_popover_new(volume_button_);
  gtk_popover_set_position(GTK_POPOVER(popover), GTK_POS_BOTTOM);
  GtkWidget* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
  gtk_container_set_border_width(GTK_CONTAINER(box), 6);
  mute_button_ = gtk_button_new();
  gtk_button_set_relief(GTK_BUTTON(mute_button_), GTK_RELIEF_NONE);
  mute_image_ = gtk_image_new_from_icon_name(VolumeIcon(shown_volume_), GTK_ICON_SIZE_BUTTON);
  gtk_container_add(GTK_CONTAINER(mute_button_), mute_image_);
  gtk_box_pack_start(GTK_BOX(box), mute_button_, FALSE, FALSE, 0);
  volume_scale_ = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.01);
  gtk_scale_set_draw_value(GTK_SCALE(volume_scale_), FALSE);
  gtk_range_set_increments(GTK_RANGE(volume_scale_), 0.02, 0.1);
  gtk_widget_set_size_request(volume_scale_, kVolumeSliderWidth, -1);
  gtk_widget_set_valign(volume_scale_, GTK_ALIGN_CENTER);
  syncing_volume_ = true;
  gtk_range_set_value(GTK_RANGE(volume_scale_), shown_volume_);
  syncing_volume_ = false;
  gtk_box_pack_start(GTK_BOX(box), volume_scale_, TRUE, TRUE, 0);
  gtk_widget_show_all(box);
  gtk_container_add(GTK_CONTAINER(popover), box);
  gtk_menu_button_set_popover(GTK_MENU_BUTTON(volume_button_), popover);
  g_signal_connect(volume_scale_, "value-changed", G_CALLBACK(OnVolumeScaleThunk), this);
  g_signal_connect(mute_button_, "clicked", G_CALLBACK(OnMuteThunk), this);
  g_signal_connect(popover, "closed", G_CALLBACK(OnVolumeClosedThunk), this);

  gtk_header_bar_pack_end(GTK_HEADER_BAR(header), volume_button_);
  // Not shown with the window: only once there is sound.
  gtk_widget_set_no_show_all(volume_button_, TRUE);
  SyncVolumeControl();
}

void Surface::ShowVolumeControl() {
  has_sound_ = true;
  if (volume_button_ == nullptr) return;
  gtk_widget_show(volume_image_);
  gtk_widget_show(volume_button_);
}

// Icons, words and the slider for shown_volume_ (never reported).
void Surface::SyncVolumeControl() {
  if (volume_button_ == nullptr) return;
  const bool muted = shown_volume_ <= 0.001;
  const std::string volume = UiString("volume");
  const std::string toggle = UiString(muted ? "unmute" : "mute");
  gtk_image_set_from_icon_name(GTK_IMAGE(volume_image_), VolumeIcon(shown_volume_), GTK_ICON_SIZE_BUTTON);
  gtk_image_set_from_icon_name(GTK_IMAGE(mute_image_), VolumeIcon(shown_volume_), GTK_ICON_SIZE_BUTTON);
  gtk_widget_set_tooltip_text(volume_button_, volume.c_str());
  gtk_widget_set_tooltip_text(mute_button_, toggle.c_str());
  SetAccessibleName(volume_button_, volume);
  SetAccessibleName(volume_scale_, volume);
  SetAccessibleName(mute_button_, toggle);
  if (std::fabs(gtk_range_get_value(GTK_RANGE(volume_scale_)) - shown_volume_) > 1e-6) {
    syncing_volume_ = true;
    gtk_range_set_value(GTK_RANGE(volume_scale_), shown_volume_);
    syncing_volume_ = false;
  }
}

// The sound follows at once; Dart hears of it at most ten times a second
// while the slider moves, and of the last value once it rests.
void Surface::UserVolume(double volume, bool final) {
  shown_volume_ = std::clamp(volume, 0.0, 1.0);
  if (shown_volume_ > 0.001) audible_volume_ = shown_volume_;
  ApplyVolume(shown_volume_);
  SyncVolumeControl();
  const int64_t now = NowUs();
  if (final || now - last_volume_report_us_ >= kVolumeReportUs) {
    FlushVolumeReport();
  } else if (volume_report_timer_ == 0) {
    const int64_t wait_us = last_volume_report_us_ + kVolumeReportUs - now;
    volume_report_timer_ = g_timeout_add(static_cast<guint>(std::max<int64_t>(1, (wait_us + 999) / 1000)),
                                         [](gpointer data) -> gboolean {
                                           auto* self = static_cast<Surface*>(data);
                                           self->volume_report_timer_ = 0;
                                           self->FlushVolumeReport();
                                           return G_SOURCE_REMOVE;
                                         },
                                         this);
  }
}

void Surface::FlushVolumeReport() {
  if (volume_report_timer_ != 0) {
    g_source_remove(volume_report_timer_);
    volume_report_timer_ = 0;
  }
  if (reported_volume_ == shown_volume_) return;
  reported_volume_ = shown_volume_;
  last_volume_report_us_ = NowUs();
  EmitWindow(id_, WSN_WINDOW_VOLUME, shown_volume_);
}

void Surface::OnVolumeScaleThunk(GtkRange* range, gpointer data) {
  auto* self = static_cast<Surface*>(data);
  if (self->syncing_volume_) return;
  self->UserVolume(gtk_range_get_value(range), false);
}

void Surface::OnMuteThunk(GtkButton*, gpointer data) {
  auto* self = static_cast<Surface*>(data);
  self->UserVolume(self->shown_volume_ > 0.001 ? 0.0 : self->audible_volume_, true);
}

void Surface::OnVolumeClosedThunk(GtkPopover*, gpointer data) {
  auto* self = static_cast<Surface*>(data);
  self->FlushVolumeReport();
  // The keyboard goes back to the picture.
  if (self->area_ != nullptr) gtk_widget_grab_focus(self->area_);
}

gboolean Surface::OnAreaFocusOutThunk(GtkWidget*, GdkEvent*, gpointer data) {
  static_cast<Surface*>(data)->ReleaseInput();
  return FALSE;
}

// ---------------------------------------------------------------- drawing

void Surface::VideoRect(double* x, double* y, double* w, double* h) {
  int width = gtk_widget_get_allocated_width(area_);
  int height = gtk_widget_get_allocated_height(area_);
  int video_width;
  int video_height;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    video_width = video_width_;
    video_height = video_height_;
  }
  double scale = std::min(static_cast<double>(width) / video_width, static_cast<double>(height) / video_height);
  *w = video_width * scale;
  *h = video_height * scale;
  *x = (width - *w) / 2;
  *y = (height - *h) / 2;
}

void Surface::Draw(cairo_t* cr) {
  int width = gtk_widget_get_allocated_width(area_);
  int height = gtk_widget_get_allocated_height(area_);
  double scale = gtk_widget_get_scale_factor(area_);
  cairo_set_source_rgb(cr, 0, 0, 0);
  cairo_paint(cr);
  const bool loading = Loading();
  const double fade = FadeProgress();
  std::lock_guard<std::mutex> lock(frame_mutex_);
  const int32_t visual = visual_;
  const std::string message = message_;
  const std::string hud = hud_text_;
  const bool have_frame = !frame_.pixels.empty() && frame_.width > 0 && frame_.height > 0;
  if (loading) {
    // Until the picture is stable: the placeholder and the spinner, never
    // the first frames (they come at the wrong size while the source fits
    // the window to this one). Text only when it takes long.
    DrawPlaceholder(cr, width, height);
    if (slow_hint_ && visual == WSN_VISUAL_CONNECTING) DrawCaption(cr, width, height, message, true);
  } else if (visual == WSN_VISUAL_LIVE) {
    // The first reveal fades the picture in over the placeholder; after a
    // resume the picture is there and only its dimming lifts.
    if (fade < 1 && !resume_fade_) DrawPlaceholder(cr, width, height);
    if (have_frame) DrawFrame(cr, width, height, scale, resume_fade_ ? 1.0 : fade);
    double dim = resume_spinner_ ? kPlaceholderDim : (resume_fade_ ? kPlaceholderDim * (1 - fade) : 0.0);
    if (dim > 0) {
      cairo_set_source_rgba(cr, 0, 0, 0, dim);
      cairo_paint(cr);
    }
  } else {
    if (have_frame) DrawFrame(cr, width, height, scale, -1);
    DrawOverlay(cr, width, height, message, visual == WSN_VISUAL_PAUSED, visual == WSN_VISUAL_RECONNECTING);
  }
  if (hud_ && !hud.empty()) DrawHud(cr, hud);
}

// The last picture, aspect-fit. alpha < 0: blurred, as a hint behind an
// overlay (a tiny copy scaled up). Called with frame_mutex_ held.
void Surface::DrawFrame(cairo_t* cr, int width, int height, double scale, double alpha) {
  double x, y, w, h;
  {
    double area_scale = std::min(static_cast<double>(width) / video_width_, static_cast<double>(height) / video_height_);
    w = video_width_ * area_scale;
    h = video_height_ * area_scale;
    x = (width - w) / 2;
    y = (height - h) / 2;
  }
  cairo_surface_t* image = cairo_image_surface_create_for_data(frame_.pixels.data(), CAIRO_FORMAT_RGB24, frame_.width,
                                                               frame_.height, frame_.stride);
  cairo_save(cr);
  if (alpha < 0) {
    int small_width = std::max(1, frame_.width / 24);
    int small_height = std::max(1, frame_.height / 24);
    cairo_surface_t* small = cairo_image_surface_create(CAIRO_FORMAT_RGB24, small_width, small_height);
    cairo_t* small_cr = cairo_create(small);
    cairo_scale(small_cr, static_cast<double>(small_width) / frame_.width,
                static_cast<double>(small_height) / frame_.height);
    cairo_set_source_surface(small_cr, image, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(small_cr), CAIRO_FILTER_GOOD);
    cairo_paint(small_cr);
    cairo_destroy(small_cr);
    cairo_surface_flush(small);
    BoxBlur(cairo_image_surface_get_data(small), small_width, small_height, cairo_image_surface_get_stride(small));
    cairo_surface_mark_dirty(small);
    cairo_translate(cr, x, y);
    cairo_scale(cr, w / small_width, h / small_height);
    cairo_set_source_surface(cr, small, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD);
    cairo_rectangle(cr, 0, 0, small_width, small_height);
    cairo_fill(cr);
    cairo_surface_destroy(small);
  } else {
    cairo_surface_set_device_scale(image, scale, scale);
    double image_width = frame_.width / scale;
    double image_height = frame_.height / scale;
    if (std::fabs(image_width - w) < 1.0 && std::fabs(image_height - h) < 1.0) {
      // On whole device pixels: a picture decoded at this size is a copy.
      double left = std::round(((width - image_width) / 2) * scale) / scale;
      double top = std::round(((height - image_height) / 2) * scale) / scale;
      cairo_set_source_surface(cr, image, left, top);
      cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_FAST);
    } else {
      // Mid-resize, until pictures of the new size arrive.
      cairo_translate(cr, x, y);
      cairo_scale(cr, w / image_width, h / image_height);
      cairo_set_source_surface(cr, image, 0, 0);
      cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    }
    if (alpha >= 1) {
      cairo_paint(cr);
    } else {
      cairo_paint_with_alpha(cr, alpha);
    }
  }
  cairo_restore(cr);
  cairo_surface_destroy(image);
}

// The app's icon (~64 pt) over the dark background; the spinner turns
// under it. Without an icon only the spinner shows.
void Surface::DrawPlaceholder(cairo_t* cr, int width, int height) {
  if (icon_ == nullptr) return;
  int scale = gtk_widget_get_scale_factor(area_);
  int pixels = kIconSize * scale;
  if (icon_surface_ == nullptr || icon_surface_scale_ != scale) {
    if (icon_surface_ != nullptr) cairo_surface_destroy(icon_surface_);
    GdkPixbuf* sized = gdk_pixbuf_scale_simple(icon_, pixels, pixels, GDK_INTERP_HYPER);
    icon_surface_ = sized != nullptr ? gdk_cairo_surface_create_from_pixbuf(sized, scale, nullptr) : nullptr;
    icon_surface_scale_ = scale;
    if (sized != nullptr) g_object_unref(sized);
  }
  if (icon_surface_ == nullptr) return;
  double left = std::round((width - kIconSize) / 2.0 * scale) / scale;
  double top = std::round((height / 2.0 - kIconCentreAbove - kIconSize / 2.0) * scale) / scale;
  cairo_set_source_surface(cr, icon_surface_, left, top);
  cairo_paint(cr);
}

void Surface::DrawOverlay(cairo_t* cr, int width, int height, const std::string& message, bool paused,
                          bool spinner) {
  cairo_set_source_rgba(cr, 0.07, 0.07, 0.08, paused ? 0.55 : 0.7);
  cairo_paint(cr);
  DrawCaption(cr, width, height, message, spinner);
}

// Dart's text, centred, or under the spinner when one turns.
void Surface::DrawCaption(cairo_t* cr, int width, int height, const std::string& message, bool below_spinner) {
  if (message.empty()) return;
  PangoLayout* layout = TextLayout(area_, cr, message, 15, PANGO_WEIGHT_SEMIBOLD, false);
  int label_width = std::max(80, std::min(width - 48, 320));
  pango_layout_set_width(layout, label_width * PANGO_SCALE);
  pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
  pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER);
  pango_layout_set_height(layout, -3);  // at most three lines
  pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
  int text_width = 0;
  int text_height = 0;
  pango_layout_get_pixel_size(layout, &text_width, &text_height);
  cairo_set_source_rgba(cr, 1, 1, 1, 0.92);
  double spinner_centre = height / 2.0 + (icon_ != nullptr && Loading() ? kSpinnerCentreBelow : 0);
  double top = below_spinner ? spinner_centre + kSpinnerSize / 2.0 + 14 : (height - text_height) / 2.0;
  cairo_move_to(cr, (width - label_width) / 2.0, top);
  pango_cairo_show_layout(cr, layout);
  g_object_unref(layout);
}

// ---------------------------------------------------------------- loading

bool Surface::AnimationsEnabled() {
  gboolean enabled = TRUE;
  GtkSettings* settings = gtk_settings_get_default();
  if (settings != nullptr) g_object_get(settings, "gtk-enable-animations", &enabled, nullptr);
  return enabled != FALSE;
}

// The placeholder shows while connecting, and while live until the picture
// has settled once.
bool Surface::Loading() const {
  return main_visual_ == WSN_VISUAL_CONNECTING || (main_visual_ == WSN_VISUAL_LIVE && !live_shown_);
}

double Surface::FadeProgress() const {
  if (fade_start_us_ < 0) return 1;
  double t = std::clamp(static_cast<double>(NowUs() - fade_start_us_) / kFadeUs, 0.0, 1.0);
  return t * t * (3 - 2 * t);  // ease in and out
}

void Surface::StartFade() {
  if (area_ == nullptr || !AnimationsEnabled()) {
    fade_start_us_ = -1;
    resume_fade_ = false;
    return;
  }
  fade_start_us_ = NowUs();
  if (fade_tick_ == 0) fade_tick_ = gtk_widget_add_tick_callback(area_, OnFadeTickThunk, this, nullptr);
}

gboolean Surface::OnFadeTickThunk(GtkWidget*, GdkFrameClock*, gpointer data) {
  auto* self = static_cast<Surface*>(data);
  bool done = self->FadeProgress() >= 1;
  if (done) {
    self->fade_start_us_ = -1;
    self->resume_fade_ = false;
    self->fade_tick_ = 0;
  }
  self->UpdateSpinner();
  gtk_widget_queue_draw(self->area_);
  return done ? G_SOURCE_REMOVE : G_SOURCE_CONTINUE;
}

void Surface::UpdateSpinner() {
  if (spinner_ == nullptr) return;
  bool busy = Loading() || resume_spinner_ || main_visual_ == WSN_VISUAL_RECONNECTING;
  // Fading out with the placeholder (or dimming) it stood on.
  bool fading = !busy && fade_start_us_ >= 0;
  bool show = busy || fading;
  if (show) {
    // Under the icon while loading with one; centred otherwise.
    int below = icon_ != nullptr && (Loading() || (fading && !resume_fade_)) ? kSpinnerCentreBelow : 0;
    if (gtk_widget_get_margin_top(spinner_) != 2 * below) gtk_widget_set_margin_top(spinner_, 2 * below);
    gtk_widget_set_opacity(spinner_, busy ? 1.0 : 1.0 - FadeProgress());
    if (!gtk_widget_get_visible(spinner_)) gtk_widget_show(spinner_);
    gtk_spinner_start(GTK_SPINNER(spinner_));  // no-op when already turning
  } else if (gtk_widget_get_visible(spinner_)) {
    gtk_spinner_stop(GTK_SPINNER(spinner_));
    gtk_widget_hide(spinner_);
  }
}

void Surface::UpdateLoading() {
  if (area_ == nullptr) return;
  const int64_t now = NowUs();
  int64_t frames;
  int64_t first;
  int64_t changed;
  int since;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    frames = presented_;
    first = first_decoded_us_;
    changed = size_changed_us_;
    since = frames_since_size_change_;
  }
  bool redraw = false;
  if (!settled_ && frames > 0) {
    bool quiet = now - changed >= kStableQuietUs && since >= kStableFramesAfterChange;
    if (quiet || now - first >= kStableCapUs) {
      settled_ = true;
      WSN_TRACE("surface %lld: picture stable after %lld ms (%s)", static_cast<long long>(id_),
                static_cast<long long>((now - opened_us_) / 1000), quiet ? "settled" : "cap");
    }
  }
  if (settled_ && !live_shown_ && main_visual_ == WSN_VISUAL_LIVE) {
    live_shown_ = true;
    resume_fade_ = false;
    StartFade();
    redraw = true;
  }
  if (resume_waiting_) {
    if (frames > frames_at_resume_) {
      resume_waiting_ = false;
      if (resume_spinner_) {
        resume_spinner_ = false;
        resume_fade_ = true;
        StartFade();
      }
      redraw = true;
    } else if (!resume_spinner_ && now - resumed_us_ >= kResumeGraceUs) {
      resume_spinner_ = true;
      redraw = true;
    }
  }
  bool slow = main_visual_ == WSN_VISUAL_CONNECTING && now - connecting_since_us_ >= kSlowConnectUs;
  if (slow != slow_hint_) {
    slow_hint_ = slow;
    redraw = true;
  }
  UpdateSpinner();
  if (redraw) gtk_widget_queue_draw(area_);
  // Keep checking while something is pending: stability, the 8 s hint, a
  // resume without frames.
  bool pending = !live_shown_ || resume_waiting_ || (main_visual_ == WSN_VISUAL_CONNECTING && !slow_hint_);
  if (pending && loading_timer_ == 0) {
    loading_timer_ = g_timeout_add(kLoadingTickMs, OnLoadingTimerThunk, this);
  }
}

gboolean Surface::OnLoadingTimerThunk(gpointer data) {
  auto* self = static_cast<Surface*>(data);
  self->loading_timer_ = 0;
  self->UpdateLoading();
  return G_SOURCE_REMOVE;
}

void Surface::DrawHud(cairo_t* cr, const std::string& text) {
  PangoLayout* layout = TextLayout(area_, cr, text, 10.5, PANGO_WEIGHT_MEDIUM, true);
  int text_width = 0;
  int text_height = 0;
  pango_layout_get_pixel_size(layout, &text_width, &text_height);
  cairo_set_source_rgba(cr, 0, 0, 0, 0.55);
  cairo_rectangle(cr, 8, 8, text_width + 8, text_height + 4);
  cairo_fill(cr);
  cairo_set_source_rgb(cr, 1, 1, 1);
  cairo_move_to(cr, 12, 10);
  pango_cairo_show_layout(cr, layout);
  g_object_unref(layout);
}

// ---------------------------------------------------------------- pointer

int32_t Surface::Visual() {
  std::lock_guard<std::mutex> lock(frame_mutex_);
  return visual_;
}

// 0–1 inside the video rect, origin top-left. With `inside_only`, false for
// points outside the picture (letterbox bars); otherwise clamped.
bool Surface::Normalized(double px, double py, double* nx, double* ny, bool inside_only) {
  double x, y, w, h;
  VideoRect(&x, &y, &w, &h);
  if (w <= 0 || h <= 0) return false;
  double fx = (px - x) / w;
  double fy = (py - y) / h;
  if (inside_only && (fx < 0 || fx > 1 || fy < 0 || fy > 1)) return false;
  *nx = std::clamp(fx, 0.0, 1.0);
  *ny = std::clamp(fy, 0.0, 1.0);
  return true;
}

void Surface::OnButton(GdkEventButton* event, bool down) {
  if (event->type == GDK_2BUTTON_PRESS || event->type == GDK_3BUTTON_PRESS) return;
  if (event->button < 1 || event->button > 3) return;
  int32_t button = event->button == 3 ? 1 : (event->button == 2 ? 2 : 0);
  int32_t visual = Visual();
  double x, y;
  if (down) {
    gtk_widget_grab_focus(area_);
    if (visual == WSN_VISUAL_PAUSED || visual == WSN_VISUAL_DISPLACED) {
      EmitWindow(id_, WSN_WINDOW_ACTION, visual == WSN_VISUAL_PAUSED ? 1 : 2);
      return;
    }
    if (visual != WSN_VISUAL_LIVE || !live_shown_ || pressed_ >= 0) return;
    if (!Normalized(event->x, event->y, &x, &y, true)) return;
    pressed_ = button;
    if (hover_timer_ != 0) {
      g_source_remove(hover_timer_);
      hover_timer_ = 0;
    }
  } else {
    if (pressed_ != button) return;
    pressed_ = -1;
    if (!Normalized(event->x, event->y, &x, &y, false)) return;
  }
  last_x_ = x;
  last_y_ = y;
  EmitInput(id_, down ? WSN_INPUT_POINTER_DOWN : WSN_INPUT_POINTER_UP, button, Modifiers(event->state), x, y, 0, 0,
            0, nullptr);
}

void Surface::OnMotion(GdkEventMotion* event) {
  if (Visual() != WSN_VISUAL_LIVE || !live_shown_) return;
  double x, y;
  if (pressed_ >= 0) {
    if (Normalized(event->x, event->y, &x, &y, false)) {
      last_x_ = x;
      last_y_ = y;
      EmitInput(id_, WSN_INPUT_POINTER_MOVE, pressed_, Modifiers(event->state), x, y, 0, 0, 0, nullptr);
    }
    return;
  }
  // Hover: inside the picture only, at most 120 a second; the last position
  // always goes out.
  if (!Normalized(event->x, event->y, &x, &y, true)) return;
  hover_x_ = x;
  hover_y_ = y;
  hover_modifiers_ = Modifiers(event->state);
  int64_t wait_us = kHoverIntervalUs - (NowUs() - last_hover_us_);
  if (wait_us <= 0) {
    SendHover();
  } else if (hover_timer_ == 0) {
    hover_timer_ = g_timeout_add(static_cast<guint>((wait_us + 999) / 1000), [](gpointer data) -> gboolean {
      auto* self = static_cast<Surface*>(data);
      self->hover_timer_ = 0;
      if (self->pressed_ < 0 && self->Visual() == WSN_VISUAL_LIVE && self->live_shown_) self->SendHover();
      return G_SOURCE_REMOVE;
    }, this);
  }
}

void Surface::SendHover() {
  if (hover_timer_ != 0) {
    g_source_remove(hover_timer_);
    hover_timer_ = 0;
  }
  last_hover_us_ = NowUs();
  last_x_ = hover_x_;
  last_y_ = hover_y_;
  EmitInput(id_, WSN_INPUT_POINTER_MOVE, 0, hover_modifiers_, hover_x_, hover_y_, 0, 0, 0, nullptr);
}

void Surface::OnScroll(GdkEventScroll* event) {
  if (Visual() != WSN_VISUAL_LIVE || !live_shown_) return;
  double x, y;
  if (!Normalized(event->x, event->y, &x, &y, false)) return;
  double dx = 0;
  double dy = 0;
  int32_t phase = 0;
  switch (event->direction) {
    case GDK_SCROLL_UP: dy = 1; break;
    case GDK_SCROLL_DOWN: dy = -1; break;
    case GDK_SCROLL_LEFT: dx = 1; break;
    case GDK_SCROLL_RIGHT: dx = -1; break;
    case GDK_SCROLL_SMOOTH: {
      GdkDevice* device = gdk_event_get_source_device(reinterpret_cast<GdkEvent*>(event));
      GdkInputSource source = device != nullptr ? gdk_device_get_source(device) : GDK_SOURCE_MOUSE;
      bool precise = source == GDK_SOURCE_TOUCHPAD || source == GDK_SOURCE_TOUCHSCREEN ||
                     source == GDK_SOURCE_TRACKPOINT;
      if (!precise) {
        // A wheel (high-resolution ones give fractions): lines.
        dx = -event->delta_x;
        dy = -event->delta_y;
        break;
      }
      // Trackpad: fractions of the picture, so the source can move a finger
      // by the same distance (as macOS), with the gesture's phases.
      double vx, vy, vw, vh;
      VideoRect(&vx, &vy, &vw, &vh);
      dx = vw > 0 ? -event->delta_x * kTouchpadPixelsPerDelta / vw : 0;
      dy = vh > 0 ? -event->delta_y * kTouchpadPixelsPerDelta / vh : 0;
      bool stop = gdk_event_is_scroll_stop_event(reinterpret_cast<GdkEvent*>(event));
      if (stop) {
        if (!scrolling_) return;
        phase = 8;  // ended
        scrolling_ = false;
      } else if (!scrolling_) {
        phase = 1;  // began
        scrolling_ = true;
      } else {
        phase = 4;  // changed
      }
      phase |= 1 << 16;
      break;
    }
    default: return;
  }
  if (dx == 0 && dy == 0 && (phase & 0xff) != 8) return;
  EmitInput(id_, WSN_INPUT_SCROLL, 0, Modifiers(event->state), x, y, dx, dy, phase, nullptr);
}

// ---------------------------------------------------------------- keyboard

gboolean Surface::OnKey(GdkEventKey* event, bool down) {
  if (Visual() != WSN_VISUAL_LIVE || !live_shown_) {
    if (!down) keys_down_.erase(event->hardware_keycode);
    return TRUE;
  }
  int32_t modifiers = Modifiers(event->state);
  int32_t code = MacKeyCode(event);
  if (!down) {
    // Input methods follow releases too.
    gtk_im_context_filter_keypress(im_, event);
    auto it = keys_down_.find(event->hardware_keycode);
    if (it == keys_down_.end()) return TRUE;
    int32_t sent = it->second;
    keys_down_.erase(it);
    char characters[8];
    KeyCharacters(event, characters);
    EmitInput(id_, WSN_INPUT_KEY_UP, sent, modifiers, 0, 0, 0, 0, 0, characters[0] != 0 ? characters : nullptr);
    return TRUE;
  }
  // ⌘V (Ctrl+V here): paste this desktop's clipboard as text.
  if (code == 9 && (modifiers & ~WSN_MOD_CAPS_LOCK) == WSN_MOD_COMMAND) {
    Paste();
    return TRUE;
  }
  // Shortcuts go to the source as keys. Everything else goes through the
  // input method first, so pinyin, kana and dead keys compose here and only
  // the committed text is sent.
  if ((modifiers & WSN_MOD_COMMAND) != 0 || (event->state & GDK_SUPER_MASK) != 0) {
    SendKeyDown(event, code);
    return TRUE;
  }
  pending_key_ = event;
  composing_before_ = composing_;
  gboolean handled = gtk_im_context_filter_keypress(im_, event);
  pending_key_ = nullptr;
  if (!handled) SendKeyDown(event, code);
  return TRUE;
}

void Surface::SendKeyDown(const GdkEventKey* event, int32_t code) {
  if (code < 0) return;
  bool repeat = keys_down_.count(event->hardware_keycode) != 0;
  keys_down_[event->hardware_keycode] = code;
  char characters[8];
  KeyCharacters(event, characters);
  EmitInput(id_, WSN_INPUT_KEY_DOWN, code, Modifiers(event->state), 0, 0, 0, 0, repeat ? 1 : 0,
            characters[0] != 0 ? characters : nullptr);
}

void Surface::OnCommit(const char* text) {
  if (text == nullptr || *text == '\0') return;
  bool was_composing = composing_before_ || composing_;
  // A plain keystroke stays a key (games and shortcuts keep working); what
  // an input method committed goes as text.
  if (pending_key_ != nullptr && !was_composing) {
    char characters[8];
    KeyCharacters(pending_key_, characters);
    int32_t code = MacKeyCode(pending_key_);
    if (code >= 0 && std::strcmp(characters, text) == 0) {
      SendKeyDown(pending_key_, code);
      return;
    }
  }
  if (Visual() != WSN_VISUAL_LIVE || !live_shown_) return;
  EmitInput(id_, WSN_INPUT_TEXT, 0, 0, 0, 0, 0, 0, 0, text);
}

void Surface::OnPreeditChanged() {
  gchar* preedit = nullptr;
  gtk_im_context_get_preedit_string(im_, &preedit, nullptr, nullptr);
  composing_ = preedit != nullptr && *preedit != '\0';
  g_free(preedit);
}

void Surface::Paste() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  auto* weak = new std::weak_ptr<Surface>(shared_from_this());
  gtk_clipboard_request_text(clipboard, [](GtkClipboard*, const gchar* text, gpointer data) {
    auto* weak_self = static_cast<std::weak_ptr<Surface>*>(data);
    std::shared_ptr<Surface> self = weak_self->lock();
    delete weak_self;
    if (self == nullptr || text == nullptr || *text == '\0' || self->Visual() != WSN_VISUAL_LIVE ||
        !self->live_shown_) {
      return;
    }
    EmitInput(self->id_, WSN_INPUT_TEXT, 1, 0, 0, 0, 0, 0, 0, text);
  }, weak);
}

// Keys and buttons held when focus or the live picture goes away are let go
// at the source too, so nothing stays stuck there.
void Surface::ReleaseInput() {
  for (const auto& entry : keys_down_) {
    EmitInput(id_, WSN_INPUT_KEY_UP, entry.second, 0, 0, 0, 0, 0, 0, nullptr);
  }
  keys_down_.clear();
  if (pressed_ >= 0) {
    EmitInput(id_, WSN_INPUT_POINTER_CANCEL, pressed_, 0, last_x_, last_y_, 0, 0, 0, nullptr);
    pressed_ = -1;
  }
  if (scrolling_) {
    EmitInput(id_, WSN_INPUT_SCROLL, 0, 0, last_x_, last_y_, 0, 0, 8 | (1 << 16), nullptr);
    scrolling_ = false;
  }
  if (hover_timer_ != 0) {
    g_source_remove(hover_timer_);
    hover_timer_ = 0;
  }
}

// ---------------------------------------------------------------- signal thunks

gboolean Surface::OnDrawThunk(GtkWidget*, cairo_t* cr, gpointer self) {
  static_cast<Surface*>(self)->Draw(cr);
  return TRUE;
}

void Surface::OnAllocateThunk(GtkWidget*, GdkRectangle* allocation, gpointer self) {
  static_cast<Surface*>(self)->OnAllocated(allocation->width, allocation->height);
}

gboolean Surface::OnButtonPressThunk(GtkWidget*, GdkEventButton* event, gpointer self) {
  static_cast<Surface*>(self)->OnButton(event, true);
  return TRUE;
}

gboolean Surface::OnButtonReleaseThunk(GtkWidget*, GdkEventButton* event, gpointer self) {
  static_cast<Surface*>(self)->OnButton(event, false);
  return TRUE;
}

gboolean Surface::OnMotionThunk(GtkWidget*, GdkEventMotion* event, gpointer self) {
  static_cast<Surface*>(self)->OnMotion(event);
  return TRUE;
}

gboolean Surface::OnScrollThunk(GtkWidget*, GdkEventScroll* event, gpointer self) {
  static_cast<Surface*>(self)->OnScroll(event);
  return TRUE;
}

gboolean Surface::OnKeyPressThunk(GtkWidget*, GdkEventKey* event, gpointer self) {
  return static_cast<Surface*>(self)->OnKey(event, true);
}

gboolean Surface::OnKeyReleaseThunk(GtkWidget*, GdkEventKey* event, gpointer self) {
  return static_cast<Surface*>(self)->OnKey(event, false);
}

gboolean Surface::OnGrabBrokenThunk(GtkWidget*, GdkEvent*, gpointer self) {
  auto* surface = static_cast<Surface*>(self);
  if (surface->pressed_ >= 0) {
    EmitInput(surface->id_, WSN_INPUT_POINTER_CANCEL, surface->pressed_, 0, surface->last_x_, surface->last_y_, 0,
              0, 0, nullptr);
    surface->pressed_ = -1;
  }
  return FALSE;
}

gboolean Surface::OnDeleteThunk(GtkWidget* widget, GdkEvent*, gpointer self) {
  auto* surface = static_cast<Surface*>(self);
  surface->ReleaseInput();
  EmitWindow(surface->id_, WSN_WINDOW_CLOSE_REQUESTED);
  // Dart destroys the surface; until then the window is out of the way.
  gtk_widget_hide(widget);
  return TRUE;
}

gboolean Surface::OnFocusInThunk(GtkWidget*, GdkEvent*, gpointer self) {
  auto* surface = static_cast<Surface*>(self);
  if (surface->im_ != nullptr) {
    gtk_im_context_focus_in(surface->im_);
    surface->UpdateImCursor();
  }
  EmitWindow(surface->id_, WSN_WINDOW_FOCUS, 1);
  return FALSE;
}

gboolean Surface::OnFocusOutThunk(GtkWidget*, GdkEvent*, gpointer self) {
  auto* surface = static_cast<Surface*>(self);
  if (surface->im_ != nullptr) gtk_im_context_focus_out(surface->im_);
  surface->composing_ = false;
  surface->ReleaseInput();
  EmitWindow(surface->id_, WSN_WINDOW_FOCUS, 0);
  return FALSE;
}

gboolean Surface::OnWindowStateThunk(GtkWidget*, GdkEventWindowState* event, gpointer self) {
  if ((event->changed_mask & GDK_WINDOW_STATE_ICONIFIED) != 0) {
    bool hidden = (event->new_window_state & GDK_WINDOW_STATE_ICONIFIED) != 0;
    EmitWindow(static_cast<Surface*>(self)->id_, WSN_WINDOW_VISIBILITY, hidden ? 0 : 1);
  }
  return FALSE;
}

void Surface::OnCommitThunk(GtkIMContext*, gchar* text, gpointer self) { static_cast<Surface*>(self)->OnCommit(text); }

void Surface::OnPreeditChangedThunk(GtkIMContext*, gpointer self) { static_cast<Surface*>(self)->OnPreeditChanged(); }

}  // namespace wsn
