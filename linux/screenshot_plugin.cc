#include "screenshot_plugin.h"
#include "../native/screenshot_selection.h"

#include <gtk/gtk.h>
#include <gdk/gdkkeysyms.h>
#include <keybinder.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {
using whisper::CapturePoint;
using whisper::CaptureRect;
using whisper::ScreenshotSelection;

class ScreenshotPlugin {
 public:
  explicit ScreenshotPlugin(FlMethodChannel* channel) : channel_(channel) {}
  ~ScreenshotPlugin() {
    Finish(false);
    if (!shortcut_.empty()) keybinder_unbind(shortcut_.c_str(), ShortcutPressed);
  }

  void Handle(FlMethodCall* call) {
    const char* method = fl_method_call_get_name(call);
    if (std::strcmp(method, "setShortcut") == 0) SetShortcut(call);
    else if (std::strcmp(method, "captureRegion") == 0) CaptureRegion(call);
    else fl_method_call_respond_not_implemented(call, nullptr);
  }

 private:
  static bool IsX11() {
#ifdef GDK_WINDOWING_X11
    return GDK_IS_X11_DISPLAY(gdk_display_get_default());
#else
    return false;
#endif
  }

  static bool Flag(FlValue* args, const char* name) {
    FlValue* value = fl_value_lookup_string(args, name);
    return value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(value);
  }

  static void ShortcutPressed(const char*, void* data) {
    auto* self = static_cast<ScreenshotPlugin*>(data);
    fl_method_channel_invoke_method(self->channel_, "shortcutPressed", nullptr,
                                   nullptr, nullptr, nullptr);
  }

  void SetShortcut(FlMethodCall* call) {
    FlValue* args = fl_method_call_get_args(call);
    if (!args || fl_value_get_type(args) == FL_VALUE_TYPE_NULL) {
      if (!shortcut_.empty()) keybinder_unbind(shortcut_.c_str(), ShortcutPressed);
      shortcut_.clear();
      fl_method_call_respond_success(call, nullptr, nullptr);
      return;
    }
    if (!IsX11()) {
      fl_method_call_respond_error(call, "shortcut-unavailable", nullptr, nullptr, nullptr); return;
    }
    if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      fl_method_call_respond_error(call, "shortcut-invalid", nullptr, nullptr, nullptr); return;
    }
    FlValue* value = fl_value_lookup_string(args, "key");
    if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
      fl_method_call_respond_error(call, "shortcut-invalid", nullptr, nullptr, nullptr); return;
    }
    const char* key = fl_value_get_string(value);
    const bool valid_key = g_regex_match_simple("^([A-Z0-9]|F([1-9]|1[0-2]))$", key,
        static_cast<GRegexCompileFlags>(0), static_cast<GRegexMatchFlags>(0));
    if (!valid_key || !(Flag(args, "control") || Flag(args, "alt") || Flag(args, "meta"))) {
      fl_method_call_respond_error(call, "shortcut-invalid", nullptr, nullptr, nullptr); return;
    }
    std::string replacement;
    if (Flag(args, "control")) replacement += "<Control>";
    if (Flag(args, "alt")) replacement += "<Alt>";
    if (Flag(args, "shift")) replacement += "<Shift>";
    if (Flag(args, "meta")) replacement += "<Super>";
    replacement += key;
    if (replacement == shortcut_) {
      fl_method_call_respond_success(call, nullptr, nullptr); return;
    }
    keybinder_init();
    if (!keybinder_bind(replacement.c_str(), ShortcutPressed, this)) {
      fl_method_call_respond_error(call, "shortcut-unavailable", nullptr, nullptr, nullptr); return;
    }
    if (!shortcut_.empty()) keybinder_unbind(shortcut_.c_str(), ShortcutPressed);
    shortcut_ = replacement;
    fl_method_call_respond_success(call, nullptr, nullptr);
  }

  void CaptureRegion(FlMethodCall* call) {
    if (pending_) {
      fl_method_call_respond_error(call, "capture-busy", nullptr, nullptr, nullptr); return;
    }
    if (!IsX11()) {
      fl_method_call_respond_error(call, "unavailable", nullptr, nullptr, nullptr); return;
    }
    pending_ = FL_METHOD_CALL(g_object_ref(call));
    FlValue* labels = fl_method_call_get_args(call);
    hint_ = Label(labels, "hint");
    adjust_hint_ = Label(labels, "adjustHint");
    confirm_ = Label(labels, "confirm");
    cancel_ = Label(labels, "cancel");
    dark_ = Label(labels, "appearance") == "dark";
    GdkWindow* root = gdk_get_default_root_window();
    width_ = gdk_window_get_width(root);
    height_ = gdk_window_get_height(root);
    const int scale = gdk_window_get_scale_factor(root);
    selection_.Reset(width_, height_);
    if (width_ <= 0 || height_ <= 0 ||
        static_cast<int64_t>(width_) * height_ * scale * scale > 128 * 1024 * 1024) {
      Finish(false, "capture-failed"); return;
    }
    snapshot_ = gdk_pixbuf_get_from_window(root, 0, 0, width_, height_);
    if (!snapshot_) { Finish(false, "capture-failed"); return; }
    window_frames_.clear();
    GList* windows = gdk_screen_get_window_stack(gdk_screen_get_default());
    // EWMH lists bottom to top; freeze geometry before showing the overlay.
    for (GList* node = g_list_last(windows); node; node = node->prev) {
      auto* window = GDK_WINDOW(node->data);
      if (!gdk_window_is_viewable(window) ||
          gdk_window_get_type_hint(window) == GDK_WINDOW_TYPE_HINT_DESKTOP) continue;
      GdkRectangle bounds{};
      gdk_window_get_frame_extents(window, &bounds);
      if (bounds.width >= 2 && bounds.height >= 2) {
        window_frames_.push_back({static_cast<double>(bounds.x), static_cast<double>(bounds.y),
          static_cast<double>(bounds.x + bounds.width), static_cast<double>(bounds.y + bounds.height)});
      }
    }
    g_list_free_full(windows, g_object_unref);
    overlay_ = gtk_window_new(GTK_WINDOW_POPUP);
    gtk_window_set_decorated(GTK_WINDOW(overlay_), FALSE);
    gtk_window_set_title(GTK_WINDOW(overlay_), "Whisper Region Capture");
    gtk_window_set_accept_focus(GTK_WINDOW(overlay_), TRUE);
    gtk_window_set_keep_above(GTK_WINDOW(overlay_), TRUE);
    gtk_window_move(GTK_WINDOW(overlay_), 0, 0);
    gtk_window_resize(GTK_WINDOW(overlay_), width_, height_);
    gtk_widget_set_app_paintable(overlay_, TRUE);
    gtk_widget_set_has_tooltip(overlay_, TRUE);
    g_signal_connect(overlay_, "query-tooltip", G_CALLBACK(QueryTooltip), this);
    gtk_widget_add_events(overlay_, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
        GDK_POINTER_MOTION_MASK | GDK_KEY_PRESS_MASK);
    g_signal_connect(overlay_, "draw", G_CALLBACK(Draw), this);
    g_signal_connect(overlay_, "button-press-event", G_CALLBACK(OnButtonPress), this);
    g_signal_connect(overlay_, "button-release-event", G_CALLBACK(OnButtonRelease), this);
    g_signal_connect(overlay_, "motion-notify-event", G_CALLBACK(Motion), this);
    g_signal_connect(overlay_, "key-press-event", G_CALLBACK(OnKeyPress), this);
    g_signal_connect(overlay_, "grab-broken-event", G_CALLBACK(GrabBroken), this);
    monitors_handler_ = g_signal_connect(gdk_screen_get_default(), "monitors-changed",
        G_CALLBACK(MonitorsChanged), this);
    gtk_widget_show_all(overlay_);
    gdk_display_sync(gdk_display_get_default());
    GdkWindow* window = gtk_widget_get_window(overlay_);
    g_autoptr(GdkCursor) cursor = gdk_cursor_new_from_name(gdk_display_get_default(), "crosshair");
    seat_ = gdk_display_get_default_seat(gdk_display_get_default());
    const auto status = gdk_seat_grab(seat_, window, GDK_SEAT_CAPABILITY_ALL,
        FALSE, cursor, nullptr, nullptr, nullptr);
    if (status != GDK_GRAB_SUCCESS) { Finish(false, "capture-failed"); return; }
    gdk_window_focus(window, GDK_CURRENT_TIME);
  }

  void DrawSnapshot(cairo_t* cr) {
    cairo_save(cr);
    cairo_scale(cr, static_cast<double>(width_) / gdk_pixbuf_get_width(snapshot_),
                static_cast<double>(height_) / gdk_pixbuf_get_height(snapshot_));
    gdk_cairo_set_source_pixbuf(cr, snapshot_, 0, 0);
    cairo_paint(cr);
    cairo_restore(cr);
  }

  static gboolean Draw(GtkWidget*, cairo_t* cr, gpointer data) {
    auto* self = static_cast<ScreenshotPlugin*>(data);
    if (!self->snapshot_) return TRUE;
    self->DrawSnapshot(cr);
    cairo_set_source_rgba(cr, 0, 0, 0, 0.35);
    cairo_paint(cr);
    const auto rect = self->selection_.rect();
    if (rect.width() > 0 && rect.height() > 0) {
      cairo_save(cr);
      cairo_rectangle(cr, rect.left, rect.top, rect.width(), rect.height());
      cairo_clip(cr);
      self->DrawSnapshot(cr);
      cairo_restore(cr);
      cairo_set_source_rgb(cr, 0.145, 0.388, 0.922);
      cairo_set_line_width(cr, 2);
      cairo_rectangle(cr, rect.left, rect.top, rect.width(), rect.height());
      cairo_stroke(cr);
      for (double x : {rect.left, (rect.left + rect.right) / 2, rect.right}) {
        for (double y : {rect.top, (rect.top + rect.bottom) / 2, rect.bottom}) {
          if (x == (rect.left + rect.right) / 2 && y == (rect.top + rect.bottom) / 2) continue;
          cairo_new_sub_path(cr);
          cairo_arc(cr, x, y, 3.5, 0, 2 * G_PI);
          cairo_set_source_rgb(cr, 1, 1, 1); cairo_fill_preserve(cr);
          cairo_set_source_rgb(cr, 0.145, 0.388, 0.922);
          cairo_set_line_width(cr, 1.5); cairo_stroke(cr);
        }
      }
    }
    const auto monitor = self->MonitorBounds();
    const double hint_width = std::min(600.0, monitor.width() - 32);
    CaptureRect hint{monitor.left + (monitor.width() - hint_width) / 2,
      monitor.top + 24, monitor.left + (monitor.width() + hint_width) / 2, monitor.top + 58};
    RoundedRect(cr, hint, 9);
    self->SetSurface(cr); cairo_fill(cr);
    self->DrawText(cr, self->selection_.selected() ? self->adjust_hint_ : self->hint_, hint, 13);
    if (self->selection_.selected() && !self->selection_.dragging()) {
      const auto toolbar = self->Toolbar();
      RoundedRect(cr, toolbar, 12);
      self->SetSurface(cr); cairo_fill_preserve(cr);
      self->SetText(cr, 0.20); cairo_set_line_width(cr, 0.75); cairo_stroke(cr);
      CaptureRect cancel{toolbar.left + 4, toolbar.top + 4, toolbar.left + 40, toolbar.bottom - 4};
      CaptureRect confirm{toolbar.left + 44, toolbar.top + 4, toolbar.right - 4, toolbar.bottom - 4};
      if (cancel.contains(self->pointer_)) {
        RoundedRect(cr, cancel, 7);
        self->SetText(cr, 0.10); cairo_fill(cr);
      }
      if (confirm.contains(self->pointer_)) {
        RoundedRect(cr, confirm, 7);
        cairo_set_source_rgba(cr, 0.145, 0.388, 0.922, self->dark_ ? 0.20 : 0.10);
        cairo_fill(cr);
      }
      const double cx = (cancel.left + cancel.right) / 2, cy = (cancel.top + cancel.bottom) / 2;
      self->SetText(cr); cairo_set_line_width(cr, 1.6); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
      cairo_move_to(cr, cx - 4, cy - 4); cairo_line_to(cr, cx + 4, cy + 4);
      cairo_move_to(cr, cx - 4, cy + 4); cairo_line_to(cr, cx + 4, cy - 4); cairo_stroke(cr);
      const double x = (confirm.left + confirm.right) / 2, y = (confirm.top + confirm.bottom) / 2;
      cairo_set_source_rgb(cr, 0.145, 0.388, 0.922);
      cairo_move_to(cr, x - 3, y - 7); cairo_line_to(cr, x + 5, y - 7); cairo_line_to(cr, x + 5, y + 3); cairo_stroke(cr);
      RoundedRect(cr, {x - 6, y - 4, x + 3, y + 7}, 1.5); cairo_stroke(cr);
    }
    return TRUE;
  }

  void SetSurface(cairo_t* cr) const {
    const double shade = dark_ ? 0.12 : 1;
    cairo_set_source_rgba(cr, shade, shade, shade, 0.94);
  }

  void SetText(cairo_t* cr, double alpha = 1) const {
    if (dark_) cairo_set_source_rgba(cr, 0.90, 0.90, 0.90, alpha);
    else cairo_set_source_rgba(cr, 0.39, 0.45, 0.54, alpha);
  }

  static std::string Label(FlValue* labels, const char* name) {
    if (!labels || fl_value_get_type(labels) != FL_VALUE_TYPE_MAP) return "";
    FlValue* value = fl_value_lookup_string(labels, name);
    return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
  }

  static void RoundedRect(cairo_t* cr, CaptureRect rect, double radius) {
    constexpr double pi = 3.141592653589793;
    cairo_new_sub_path(cr);
    cairo_arc(cr, rect.right - radius, rect.top + radius, radius, -pi / 2, 0);
    cairo_arc(cr, rect.right - radius, rect.bottom - radius, radius, 0, pi / 2);
    cairo_arc(cr, rect.left + radius, rect.bottom - radius, radius, pi / 2, pi);
    cairo_arc(cr, rect.left + radius, rect.top + radius, radius, pi, 3 * pi / 2);
    cairo_close_path(cr);
  }

  void DrawText(cairo_t* cr, const std::string& text, CaptureRect rect, int size) {
    g_autoptr(PangoLayout) layout = gtk_widget_create_pango_layout(overlay_, text.c_str());
    auto* font = pango_font_description_from_string("Sans Medium");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    pango_layout_set_width(layout, static_cast<int>((rect.width() - 12) * PANGO_SCALE));
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
    pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER);
    int height = 0;
    pango_layout_get_pixel_size(layout, nullptr, &height);
    cairo_move_to(cr, rect.left + 6, rect.top + (rect.height() - height) / 2);
    SetText(cr);
    pango_cairo_show_layout(cr, layout);
  }

  CaptureRect MonitorBounds() const {
    auto* monitor = gdk_display_get_monitor_at_point(gdk_display_get_default(),
        static_cast<int>(action_point_.x), static_cast<int>(action_point_.y));
    GdkRectangle rect{0, 0, width_, height_};
    if (monitor) gdk_monitor_get_geometry(monitor, &rect);
    return {static_cast<double>(rect.x), static_cast<double>(rect.y),
            static_cast<double>(rect.x + rect.width), static_cast<double>(rect.y + rect.height)};
  }

  CaptureRect Toolbar() const {
    const auto rect = selection_.rect(), monitor = MonitorBounds();
    const double left = std::max(monitor.left + 12, std::min(rect.right - 84, monitor.right - 96));
    double top = rect.bottom + 12;
    if (top + 38 > monitor.bottom - 12) top = rect.top - 50;
    top = std::max(monitor.top + 12, std::min(top, monitor.bottom - 50));
    return {left, top, left + 84, top + 38};
  }

  void UpdateCursor() {
    const int hit = selection_.HitTest(pointer_);
    const char* name = "crosshair";
    if (selection_.selected() && !selection_.dragging() && Toolbar().contains(pointer_)) name = "pointer";
    else if (hit == ScreenshotSelection::kMove) name = "move";
    else if (hit == 1 || hit == 2) name = "ew-resize";
    else if (hit == 4 || hit == 8) name = "ns-resize";
    else if (hit == 5 || hit == 10) name = "nwse-resize";
    else if (hit == 6 || hit == 9) name = "nesw-resize";
    g_autoptr(GdkCursor) cursor = gdk_cursor_new_from_name(gdk_display_get_default(), name);
    gdk_window_set_cursor(gtk_widget_get_window(overlay_), cursor);
  }

  static gboolean OnButtonPress(GtkWidget*, GdkEventButton* event, gpointer data) {
    auto* self = static_cast<ScreenshotPlugin*>(data);
    if (event->button == 3) { self->Finish(false); return TRUE; }
    if (event->button == 1) {
      const CapturePoint point{event->x, event->y};
      const auto toolbar = self->Toolbar();
      if (self->selection_.selected() && toolbar.contains(point)) {
        self->Finish(point.x >= toolbar.left + 42); return TRUE;
      }
      self->pointer_ = self->action_point_ = point;
      auto window = self->MonitorBounds();
      for (const auto& frame : self->window_frames_) {
        if (frame.contains(point)) { window = frame; break; }
      }
      self->selection_.Begin(point, 9, window);
      gtk_widget_queue_draw(self->overlay_);
    }
    return TRUE;
  }

  static gboolean Motion(GtkWidget*, GdkEventMotion* event, gpointer data) {
    auto* self = static_cast<ScreenshotPlugin*>(data);
    self->pointer_ = {event->x, event->y};
    self->selection_.Update(self->pointer_);
    self->UpdateCursor();
    gtk_widget_queue_draw(self->overlay_);
    return TRUE;
  }

  static gboolean OnButtonRelease(GtkWidget*, GdkEventButton* event, gpointer data) {
    auto* self = static_cast<ScreenshotPlugin*>(data);
    if (event->button == 1 && self->selection_.dragging()) {
      self->pointer_ = self->action_point_ = {event->x, event->y};
      self->selection_.End(self->pointer_);
      self->UpdateCursor();
      gtk_widget_queue_draw(self->overlay_);
    }
    return TRUE;
  }

  static gboolean OnKeyPress(GtkWidget*, GdkEventKey* event, gpointer data) {
    auto* self = static_cast<ScreenshotPlugin*>(data);
    if (event->keyval == GDK_KEY_Escape) self->Finish(false);
    else if ((event->keyval == GDK_KEY_Return || event->keyval == GDK_KEY_KP_Enter) &&
             self->selection_.selected() && !self->selection_.dragging()) self->Finish(true);
    return TRUE;
  }
  static gboolean QueryTooltip(GtkWidget*, gint x, gint y, gboolean keyboard,
                               GtkTooltip* tooltip, gpointer data) {
    auto* self = static_cast<ScreenshotPlugin*>(data);
    if (keyboard || !self->selection_.selected() || self->selection_.dragging()) return FALSE;
    const auto toolbar = self->Toolbar();
    if (!toolbar.contains({static_cast<double>(x), static_cast<double>(y)})) return FALSE;
    gtk_tooltip_set_text(tooltip, (x < toolbar.left + 42 ? self->cancel_ : self->confirm_).c_str());
    return TRUE;
  }
  static gboolean GrabBroken(GtkWidget*, GdkEventGrabBroken*, gpointer data) {
    static_cast<ScreenshotPlugin*>(data)->Finish(false);
    return TRUE;
  }
  static void MonitorsChanged(GdkScreen*, gpointer data) {
    static_cast<ScreenshotPlugin*>(data)->Finish(false);
  }

  bool CopySelection() {
    const double scale_x = static_cast<double>(gdk_pixbuf_get_width(snapshot_)) / width_;
    const double scale_y = static_cast<double>(gdk_pixbuf_get_height(snapshot_)) / height_;
    const auto rect = selection_.rect();
    const int x = static_cast<int>(std::floor(rect.left * scale_x));
    const int y = static_cast<int>(std::floor(rect.top * scale_y));
    const int right = static_cast<int>(std::ceil(rect.right * scale_x));
    const int bottom = static_cast<int>(std::ceil(rect.bottom * scale_y));
    g_autoptr(GdkPixbuf) region = gdk_pixbuf_new_subpixbuf(snapshot_, x, y, right - x, bottom - y);
    // Copy the region so clipboard ownership doesn't keep the full desktop alive.
    g_autoptr(GdkPixbuf) copy = region ? gdk_pixbuf_copy(region) : nullptr;
    GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    if (!copy || !clipboard) return false;
    gtk_clipboard_set_image(clipboard, copy);
    gtk_clipboard_store(clipboard);
    return true;
  }

  void Finish(bool copy, const char* error = nullptr) {
    if (!pending_) return;
    auto* call = pending_;
    pending_ = nullptr;
    const bool copied = copy && CopySelection();
    if (monitors_handler_) g_signal_handler_disconnect(gdk_screen_get_default(), monitors_handler_);
    monitors_handler_ = 0;
    if (seat_) gdk_seat_ungrab(seat_);
    seat_ = nullptr;
    if (overlay_) gtk_widget_destroy(overlay_);
    overlay_ = nullptr;
    g_clear_object(&snapshot_);
    selection_.Reset(0, 0);
    window_frames_.clear();
    if (error || (copy && !copied)) {
      fl_method_call_respond_error(call, error ? error : "clipboard-failed", nullptr, nullptr, nullptr);
    } else {
      g_autoptr(FlValue) value = fl_value_new_bool(copied);
      fl_method_call_respond_success(call, value, nullptr);
    }
    g_object_unref(call);
  }

  FlMethodChannel* channel_;
  std::string shortcut_;
  FlMethodCall* pending_ = nullptr;
  GtkWidget* overlay_ = nullptr;
  GdkPixbuf* snapshot_ = nullptr;
  GdkSeat* seat_ = nullptr;
  gulong monitors_handler_ = 0;
  int width_ = 0;
  int height_ = 0;
  ScreenshotSelection selection_;
  std::vector<CaptureRect> window_frames_;
  CapturePoint pointer_, action_point_;
  std::string hint_, adjust_hint_, confirm_, cancel_;
  bool dark_ = false;
};
}  // namespace

void screenshot_plugin_register(FlPluginRegistry* registry) {
  FlPluginRegistrar* registrar = fl_plugin_registry_get_registrar_for_plugin(registry, "ScreenshotPlugin");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "com.vireen.whisper/screenshot", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) { static_cast<ScreenshotPlugin*>(data)->Handle(call); },
      new ScreenshotPlugin(channel), [](gpointer data) { delete static_cast<ScreenshotPlugin*>(data); });
}
