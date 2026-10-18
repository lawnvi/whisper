// Test window for the Linux window-stream source checks.
//
// Draws its frame counter as a row of 16 black/white blocks (bit 15 first)
// across the top, a 21x21 cross-hair grid in the middle (so click accuracy can
// be read off the picture), and has a text entry at the bottom. Every input
// event it receives is appended as one JSON line to the log file given as
// argv[1] (stdout when absent): button presses with window-relative
// coordinates, scrolls, keys, committed text and focus changes.
//
// Usage: wsn_test_window [log] [title] [plain] [RRGGBB background]
//   WSN_TEST_SOUND=<file> plays that file in a loop from a child process
//   (`pw-play`, to WSN_TEST_SOUND_TARGET when set), so the window's app has
//   sound for the audio checks.
//   WSN_TEST_FLASH=<period ms> (1 means 2000) is the lip-sync mode instead:
//   the window plays its own stream (PulseAudio API, loaded at run time) of
//   silence with a 1 kHz beep every period, and paints the whole area white
//   from the moment that beep is heard (by the stream's reported latency)
//   for 150 ms, black otherwise. Each beep is logged as "beep" with the
//   monotonic time it starts playing, each flash as "flash" with the time
//   its first white frame was drawn. Under the beeps runs a quiet 200 Hz
//   bed (-40 dBFS) so the sound never stops, like a film's; with
//   WSN_TEST_FLASH_BED=0 it is digital silence between the beeps.
//   plain: no window shadow, so event coordinates ("wx", "wy") are frame
//   coordinates (what the checks compare against). The title bar stays:
//   GTK 3 on Wayland gets no pointer events in an undecorated window.
//
// Build: cc -O2 -o wsn_test_window wsn_test_window.c $(pkg-config --cflags --libs gtk+-3.0) -lm

#include <dlfcn.h>
#include <gtk/gtk.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static FILE *log_file;
static guint64 frame_counter;
static GtkWidget *area;
static GtkWidget *entry;
static double background[3] = {0.85, 0.9, 1.0};

// Lip-sync mode (WSN_TEST_FLASH).
static gboolean flash_mode;
static GMutex flash_lock;
static gint64 flash_next = -1;   // monotonic µs the next beep is heard
static gint64 flash_until = -1;  // white until this time
static gboolean flash_on;

// JSON string body: UTF-8 kept as is, quotes, backslashes and controls escaped.
static gchar *json_escape(const char *text) {
  GString *out = g_string_new(NULL);
  for (const unsigned char *c = (const unsigned char *)text; *c; c++) {
    if (*c == '"' || *c == '\\') {
      g_string_append_c(out, '\\');
      g_string_append_c(out, (char)*c);
    } else if (*c < 0x20) {
      g_string_append_printf(out, "\\u%04x", *c);
    } else {
      g_string_append_c(out, (char)*c);
    }
  }
  return g_string_free(out, FALSE);
}

static void log_line(const char *format, ...) {
  va_list args;
  va_start(args, format);
  gchar *body = g_strdup_vprintf(format, args);
  va_end(args);
  fprintf(log_file, "{\"t\":%.3f,%s}\n", g_get_monotonic_time() / 1e6, body);
  fflush(log_file);
  g_free(body);
}

static gboolean on_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  int width = gtk_widget_get_allocated_width(widget);
  int height = gtk_widget_get_allocated_height(widget);
  if (flash_mode) {
    cairo_set_source_rgb(cr, flash_on ? 1 : 0, flash_on ? 1 : 0, flash_on ? 1 : 0);
    cairo_paint(cr);
    return TRUE;
  }
  cairo_set_source_rgb(cr, background[0], background[1], background[2]);
  cairo_paint(cr);
  // Frame counter: 16 blocks across the top 40 px.
  double block = width / 16.0;
  for (int bit = 0; bit < 16; bit++) {
    int on = (frame_counter >> (15 - bit)) & 1;
    cairo_set_source_rgb(cr, on ? 0 : 1, on ? 0 : 1, on ? 0 : 1);
    cairo_rectangle(cr, bit * block, 0, block, 40);
    cairo_fill(cr);
  }
  // A grid of thin lines every 1/20 of the area, red at the centre.
  cairo_set_line_width(cr, 1);
  for (int i = 0; i <= 20; i++) {
    double x = (width - 1) * i / 20.0 + 0.5;
    double y = 40 + (height - 41) * i / 20.0 + 0.5;
    cairo_set_source_rgb(cr, i == 10 ? 1 : 0.6, i == 10 ? 0 : 0.6, i == 10 ? 0 : 0.6);
    cairo_move_to(cr, x, 40);
    cairo_line_to(cr, x, height);
    cairo_stroke(cr);
    cairo_move_to(cr, 0, y);
    cairo_line_to(cr, width, y);
    cairo_stroke(cr);
  }
  return TRUE;
}

static gboolean tick(gpointer data) {
  frame_counter++;
  gtk_widget_queue_draw(area);
  return G_SOURCE_CONTINUE;
}

// Frame clock tick in lip-sync mode: turns white for the frame that is on
// screen when the beep starts (this frame shows about half a refresh from now).
static gboolean flash_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
  gint64 now = g_get_monotonic_time();
  gint64 refresh = 0, presentation = 0;
  gdk_frame_clock_get_refresh_info(clock, gdk_frame_clock_get_frame_time(clock), &refresh, &presentation);
  if (refresh <= 0) refresh = 16667;
  g_mutex_lock(&flash_lock);
  gint64 next = flash_next;
  if (next >= 0 && next <= now + refresh / 2) {
    flash_next = -1;
    flash_until = next + 150000;
  }
  gboolean on = flash_until >= 0 && now < flash_until;
  g_mutex_unlock(&flash_lock);
  if (on && !flash_on) log_line("\"ev\":\"flash\",\"beep\":%.6f,\"drawn\":%.6f", next / 1e6, now / 1e6);
  flash_on = on;
  gtk_widget_queue_draw(widget);
  return G_SOURCE_CONTINUE;
}

// PulseAudio "simple" API, loaded at run time so the tool keeps building
// with GTK alone.
typedef struct {
  int format;
  uint32_t rate;
  uint8_t channels;
} PaSampleSpec;
typedef struct {
  uint32_t maxlength, tlength, prebuf, minreq, fragsize;
} PaBufferAttr;
typedef void *(*PaSimpleNew)(const char *, const char *, int, const char *, const char *, const PaSampleSpec *,
                             const void *, const PaBufferAttr *, int *);
typedef int (*PaSimpleWrite)(void *, const void *, size_t, int *);
typedef uint64_t (*PaSimpleLatency)(void *, int *);

static gpointer beep_thread(gpointer data) {
  int period_ms = GPOINTER_TO_INT(data);
  void *lib = dlopen("libpulse-simple.so.0", RTLD_NOW);
  PaSimpleNew pa_new = lib ? (PaSimpleNew)dlsym(lib, "pa_simple_new") : NULL;
  PaSimpleWrite pa_write = lib ? (PaSimpleWrite)dlsym(lib, "pa_simple_write") : NULL;
  PaSimpleLatency pa_latency = lib ? (PaSimpleLatency)dlsym(lib, "pa_simple_get_latency") : NULL;
  if (pa_new == NULL || pa_write == NULL || pa_latency == NULL) {
    log_line("\"ev\":\"beep_error\",\"what\":\"no libpulse-simple\"");
    return NULL;
  }
  const int rate = 48000, chunk = 480;  // 10 ms
  PaSampleSpec spec = {3 /* PA_SAMPLE_S16LE */, (uint32_t)rate, 2};
  PaBufferAttr attr = {(uint32_t)-1, (uint32_t)(chunk * 4 * 3), (uint32_t)-1, (uint32_t)-1, (uint32_t)-1};
  int error = 0;
  void *stream = pa_new(NULL, "WSN Sound", 1 /* PA_STREAM_PLAYBACK */, NULL, "beep", &spec, NULL, &attr, &error);
  if (stream == NULL) {
    log_line("\"ev\":\"beep_error\",\"what\":\"pa_simple_new %d\"", error);
    return NULL;
  }
  const int64_t period = (int64_t)rate * period_ms / 1000;
  const int beep = rate * 80 / 1000, ramp = rate / 1000;
  const double bed = g_strcmp0(g_getenv("WSN_TEST_FLASH_BED"), "0") == 0 ? 0 : 0.01;
  int16_t samples[480 * 2];
  for (int64_t frame = 0;; frame += chunk) {
    int64_t start = -1;
    for (int i = 0; i < chunk; i++) {
      int64_t at = (frame + i) % period;
      double value = bed * sin(2 * M_PI * 200.0 * (double)((frame + i) % rate) / rate);
      if (at < beep) {
        if (at == 0) start = i;
        double gain = at < ramp ? (double)at / ramp : at > beep - ramp ? (double)(beep - at) / ramp : 1;
        value += 0.25 * gain * sin(2 * M_PI * 1000.0 * at / rate);
      }
      samples[2 * i] = samples[2 * i + 1] = (int16_t)lrint(value * 32767);
    }
    if (start >= 0) {
      // The first sample written now is heard after the stream's latency.
      gint64 heard = g_get_monotonic_time() + (gint64)pa_latency(stream, &error) + start * 1000000LL / rate;
      g_mutex_lock(&flash_lock);
      flash_next = heard;
      g_mutex_unlock(&flash_lock);
      log_line("\"ev\":\"beep\",\"heard\":%.6f", heard / 1e6);
    }
    if (pa_write(stream, samples, sizeof(samples), &error) < 0) {
      log_line("\"ev\":\"beep_error\",\"what\":\"pa_simple_write %d\"", error);
      return NULL;
    }
  }
  return NULL;
}

static void window_coords(GtkWidget *widget, double x, double y, int *wx, int *wy) {
  GtkWidget *top = gtk_widget_get_toplevel(widget);
  gtk_widget_translate_coordinates(widget, top, (int)x, (int)y, wx, wy);
}

static gboolean on_button(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  int wx = 0, wy = 0;
  window_coords(widget, event->x, event->y, &wx, &wy);
  const char *type = event->type == GDK_BUTTON_PRESS ? "down"
                     : event->type == GDK_BUTTON_RELEASE ? "up"
                     : event->type == GDK_2BUTTON_PRESS ? "double" : "other";
  log_line("\"ev\":\"button\",\"type\":\"%s\",\"button\":%u,\"x\":%.1f,\"y\":%.1f,\"wx\":%d,\"wy\":%d,"
           "\"aw\":%d,\"ah\":%d,\"state\":%u",
           type, event->button, event->x, event->y, wx, wy, gtk_widget_get_allocated_width(widget),
           gtk_widget_get_allocated_height(widget), event->state);
  return FALSE;
}

static gboolean on_motion(GtkWidget *widget, GdkEventMotion *event, gpointer data) {
  static gint64 last;
  gint64 now = g_get_monotonic_time();
  if (now - last < 100000) return FALSE;
  last = now;
  log_line("\"ev\":\"motion\",\"x\":%.1f,\"y\":%.1f", event->x, event->y);
  return FALSE;
}

static gboolean on_scroll(GtkWidget *widget, GdkEventScroll *event, gpointer data) {
  double dx = 0, dy = 0;
  if (event->direction == GDK_SCROLL_SMOOTH) {
    gdk_event_get_scroll_deltas((GdkEvent *)event, &dx, &dy);
  }
  log_line("\"ev\":\"scroll\",\"direction\":%d,\"dx\":%.2f,\"dy\":%.2f,\"x\":%.1f,\"y\":%.1f", event->direction, dx,
           dy, event->x, event->y);
  return FALSE;
}

static gboolean on_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  gchar *name = json_escape(gdk_keyval_name(event->keyval) ? gdk_keyval_name(event->keyval) : "?");
  log_line("\"ev\":\"key\",\"type\":\"%s\",\"keyval\":%u,\"name\":\"%s\",\"keycode\":%u,\"state\":%u,"
           "\"ctrl\":%s,\"shift\":%s",
           event->type == GDK_KEY_PRESS ? "down" : "up", event->keyval, name, event->hardware_keycode, event->state,
           (event->state & GDK_CONTROL_MASK) ? "true" : "false", (event->state & GDK_SHIFT_MASK) ? "true" : "false");
  g_free(name);
  return FALSE;
}

static void on_entry_changed(GtkEditable *editable, gpointer data) {
  gchar *escaped = json_escape(gtk_entry_get_text(GTK_ENTRY(entry)));
  log_line("\"ev\":\"text\",\"value\":\"%s\"", escaped);
  g_free(escaped);
}

static gboolean on_focus(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  log_line("\"ev\":\"focus\",\"in\":%s,\"what\":\"%s\"", event->in ? "true" : "false", (const char *)data);
  return FALSE;
}

static gboolean on_configure(GtkWidget *widget, GdkEventConfigure *event, gpointer data) {
  log_line("\"ev\":\"configure\",\"width\":%d,\"height\":%d", event->width, event->height);
  return FALSE;
}

// Where the drawing area (and so the counter) sits inside the window.
static void on_area_allocate(GtkWidget *widget, GdkRectangle *allocation, gpointer data) {
  int x = 0, y = 0;
  gtk_widget_translate_coordinates(widget, gtk_widget_get_toplevel(widget), 0, 0, &x, &y);
  log_line("\"ev\":\"layout\",\"area_x\":%d,\"area_y\":%d,\"area_w\":%d,\"area_h\":%d", x, y,
           allocation->width, allocation->height);
}

static gboolean on_delete(GtkWidget *widget, GdkEvent *event, gpointer data) {
  log_line("\"ev\":\"close\"");
  return FALSE;
}

int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  if (argc > 4 && strlen(argv[4]) == 6) {
    unsigned value = (unsigned)strtoul(argv[4], NULL, 16);
    background[0] = ((value >> 16) & 0xff) / 255.0;
    background[1] = ((value >> 8) & 0xff) / 255.0;
    background[2] = (value & 0xff) / 255.0;
  }
  log_file = argc > 1 ? fopen(argv[1], "a") : stdout;
  if (log_file == NULL) return 1;
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), argc > 2 ? argv[2] : "WSN Test Window");
  gtk_window_set_default_size(GTK_WINDOW(window), 640, 480);
  if (argc > 3 && strcmp(argv[3], "plain") == 0) {
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(css, "decoration { box-shadow: none; margin: 0; border-radius: 0; }", -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), GTK_STYLE_PROVIDER(css),
                                              GTK_STYLE_PROVIDER_PRIORITY_USER);
  }
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  area = gtk_drawing_area_new();
  gtk_widget_set_can_focus(area, TRUE);
  gtk_widget_add_events(area, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_POINTER_MOTION_MASK |
                                  GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK | GDK_KEY_PRESS_MASK | GDK_KEY_RELEASE_MASK |
                                  GDK_FOCUS_CHANGE_MASK);
  entry = gtk_entry_new();
  gtk_box_pack_start(GTK_BOX(box), area, TRUE, TRUE, 0);
  gtk_box_pack_start(GTK_BOX(box), entry, FALSE, FALSE, 0);
  gtk_container_add(GTK_CONTAINER(window), box);
  g_signal_connect(area, "draw", G_CALLBACK(on_draw), NULL);
  g_signal_connect(area, "size-allocate", G_CALLBACK(on_area_allocate), NULL);
  g_signal_connect(area, "button-press-event", G_CALLBACK(on_button), NULL);
  g_signal_connect(area, "button-release-event", G_CALLBACK(on_button), NULL);
  g_signal_connect(area, "motion-notify-event", G_CALLBACK(on_motion), NULL);
  g_signal_connect(area, "scroll-event", G_CALLBACK(on_scroll), NULL);
  g_signal_connect(window, "key-press-event", G_CALLBACK(on_key), NULL);
  g_signal_connect(window, "key-release-event", G_CALLBACK(on_key), NULL);
  g_signal_connect(entry, "changed", G_CALLBACK(on_entry_changed), NULL);
  g_signal_connect(entry, "focus-in-event", G_CALLBACK(on_focus), "entry");
  g_signal_connect(entry, "focus-out-event", G_CALLBACK(on_focus), "entry");
  g_signal_connect(area, "focus-in-event", G_CALLBACK(on_focus), "area");
  g_signal_connect(window, "configure-event", G_CALLBACK(on_configure), NULL);
  g_signal_connect(window, "delete-event", G_CALLBACK(on_delete), NULL);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
  g_timeout_add(1000 / 60, tick, NULL);
  const char *flash = g_getenv("WSN_TEST_FLASH");
  if (flash != NULL && *flash != '\0') {
    int period_ms = atoi(flash);
    if (period_ms <= 1) period_ms = 2000;
    flash_mode = TRUE;
    gtk_widget_add_tick_callback(area, flash_tick, NULL, NULL);
    g_thread_new("beep", beep_thread, GINT_TO_POINTER(period_ms));
    log_line("\"ev\":\"flash_mode\",\"period_ms\":%d", period_ms);
  }
  gtk_widget_show_all(window);
  const char *sound = g_getenv("WSN_TEST_SOUND");
  if (sound != NULL && *sound != '\0') {
    const char *target = g_getenv("WSN_TEST_SOUND_TARGET");
    // WSN_TEST_SOUND_PULSE=1 plays through the PulseAudio API (GStreamer's
    // pulsesink), as most desktop apps do, instead of PipeWire's own.
    gboolean pulse = g_strcmp0(g_getenv("WSN_TEST_SOUND_PULSE"), "1") == 0;
    gchar *script = pulse ? g_strdup_printf("while :; do gst-launch-1.0 -q filesrc location='%s' ! wavparse ! "
                                            "audioconvert ! pulsesink %s%s || sleep 1; done",
                                            sound, target != NULL ? "device=" : "", target != NULL ? target : "")
                          : g_strdup_printf("while :; do pw-play %s%s '%s' || sleep 1; done",
                                            target != NULL ? "--target " : "", target != NULL ? target : "", sound);
    gchar *argv_sound[] = {(gchar *)"sh", (gchar *)"-c", script, NULL};
    GPid child = 0;
    // A direct child (no double fork), reaped by GLib.
    if (g_spawn_async(NULL, argv_sound, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL, &child,
                      NULL)) {
      g_child_watch_add(child, (GChildWatchFunc)g_spawn_close_pid, NULL);
    }
    log_line("\"ev\":\"sound\",\"pid\":%d", (int)child);
    g_free(script);
  }
  log_line("\"ev\":\"start\",\"pid\":%d", (int)getpid());
  gtk_main();
  return 0;
}
