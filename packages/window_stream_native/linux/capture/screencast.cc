#include "capture/screencast.h"

#include <gio/gio.h>

#include <cmath>
#include <deque>
#include <map>
#include <mutex>
#include <set>

#include "capture/bus.h"
#include "capture/capture_thread.h"
#include "common/log.h"

namespace wsn::capture {

namespace {

constexpr const char* kDest = "org.gnome.Mutter.ScreenCast";
constexpr const char* kSessionIface = "org.gnome.Mutter.ScreenCast.Session";
constexpr const char* kStreamIface = "org.gnome.Mutter.ScreenCast.Stream";
// From the request to a usable source; a creation that hangs (no PipeWire
// node, no negotiation) must not hold up every later one.
constexpr guint kCreateTimeoutMs = 8000;

// Virtual monitors are made one at a time: Mutter names them only once the
// stream is negotiated, so ours is told apart as "the new one".
bool g_creating = false;
std::deque<std::function<void()>> g_waiting;
std::set<std::string> g_claimed;
// Our monitors that are up, with the scale each should have.
std::map<std::string, double> g_scales;

// All of ours placed together; a scale Mutter refuses falls back to 1.
void PlaceAll(const std::string& connector) {
  std::string error;
  if (PlaceVirtualMonitors(g_scales, &error)) return;
  WSN_LOG("capture: placing virtual monitors refused: %s", error.c_str());
  auto own = g_scales.find(connector);
  if (own != g_scales.end() && own->second > 1.001) {
    own->second = 1;
    if (!PlaceVirtualMonitors(g_scales, &error)) WSN_LOG("capture: placing at scale 1 refused: %s", error.c_str());
  }
}

void NextCreation() {
  g_creating = false;
  if (g_waiting.empty()) return;
  auto next = std::move(g_waiting.front());
  g_waiting.pop_front();
  g_creating = true;
  next();
}

bool IsVirtualConnector(const DisplayState& state, const std::string& connector) {
  // Mutter calls its virtual monitors Meta-<n>.
  return connector.rfind("Meta-", 0) == 0 && state.monitors.count(connector) != 0;
}

}  // namespace

bool ScreenCastAvailable() {
  static std::once_flag once;
  static bool available = false;
  std::call_once(once, [] {
    GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if (bus == nullptr) return;
    GVariant* reply = g_dbus_connection_call_sync(
        bus, kDest, "/org/gnome/Mutter/ScreenCast", "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.gnome.Mutter.ScreenCast", "Version"), G_VARIANT_TYPE("(v)"),
        G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, nullptr);
    if (reply != nullptr) {
      GVariant* value = nullptr;
      g_variant_get(reply, "(v)", &value);
      if (value != nullptr && g_variant_is_of_type(value, G_VARIANT_TYPE_INT32)) {
        available = g_variant_get_int32(value) >= 4;
      }
      if (value != nullptr) g_variant_unref(value);
      g_variant_unref(reply);
    }
    g_object_unref(bus);
  });
  return available;
}

ScreenCast::ScreenCast(bool virtual_monitor, int pixel_width, int pixel_height, double scale, int fps,
                       PipeWireStream::FrameCallback on_frame, Callbacks callbacks)
    : virtual_(virtual_monitor),
      pixel_width_(pixel_width),
      pixel_height_(pixel_height),
      wanted_scale_(scale),
      fps_(fps),
      on_frame_(std::move(on_frame)),
      callbacks_(std::move(callbacks)),
      alive_(std::make_shared<bool>(true)) {}

std::unique_ptr<ScreenCast> ScreenCast::Virtual(int pixel_width, int pixel_height, double scale, int fps,
                                                PipeWireStream::FrameCallback on_frame, Callbacks callbacks) {
  std::unique_ptr<ScreenCast> cast(
      new ScreenCast(true, pixel_width, pixel_height, scale, fps, std::move(on_frame), std::move(callbacks)));
  std::weak_ptr<bool> alive = cast->alive_;
  ScreenCast* self = cast.get();
  auto begin = [self, alive] {
    if (alive.expired()) {
      NextCreation();
      return;
    }
    self->Begin(0);  // a failure moves the queue on (Fail)
  };
  WSN_TRACE("capture: virtual monitor %dx%d asked for%s", pixel_width, pixel_height,
            g_creating ? " (queued)" : "");
  if (g_creating) {
    g_waiting.push_back(begin);
  } else {
    g_creating = true;
    // Started from the loop, never inside the caller's own frame: callbacks
    // may then safely replace the object that is being made.
    Post(begin);
  }
  return cast;
}

std::unique_ptr<ScreenCast> ScreenCast::Window(uint64_t window_id, int width, int height, int fps,
                                               PipeWireStream::FrameCallback on_frame, Callbacks callbacks) {
  std::unique_ptr<ScreenCast> cast(
      new ScreenCast(false, width, height, 1, fps, std::move(on_frame), std::move(callbacks)));
  std::weak_ptr<bool> alive = cast->alive_;
  ScreenCast* self = cast.get();
  Post([self, alive, window_id] {
    if (!alive.expired()) self->Begin(window_id);
  });
  return cast;
}

ScreenCast::~ScreenCast() {
  bool was_finding = virtual_ && !ready_ && !failed_ && !session_path_.empty();
  alive_.reset();
  stream_.reset();  // no frames after this
  Unsubscribe(node_signal_);
  Unsubscribe(closed_signal_);
  Unsubscribe(layout_signal_);
  CancelTimer(find_timer_);
  CancelTimer(deadline_timer_);
  if (!connector_.empty()) {
    g_claimed.erase(connector_);
    g_scales.erase(connector_);
  }
  if (!session_path_.empty()) {
    capture::Call(kDest, session_path_.c_str(), kSessionIface, "Stop", nullptr, nullptr, 3000, {});
  }
  if (was_finding) NextCreation();
}

bool ScreenCast::Begin(uint64_t window_id) {
  std::weak_ptr<bool> guard = alive_;
  deadline_timer_ = PostAfter(kCreateTimeoutMs, [this, guard] {
    if (guard.expired()) return;
    deadline_timer_ = 0;
    if (!ready_) Fail("timed out");
  });
  GError* error = nullptr;
  GVariant* reply = CallSync(kDest, "/org/gnome/Mutter/ScreenCast", "org.gnome.Mutter.ScreenCast", "CreateSession",
                             g_variant_new_parsed("(@a{sv} {},)"), "(o)", 3000, &error);
  if (reply == nullptr) {
    Fail(std::string("CreateSession: ") + (error != nullptr ? error->message : "?"));
    if (error != nullptr) g_error_free(error);
    return false;
  }
  const gchar* path = nullptr;
  g_variant_get(reply, "(&o)", &path);
  session_path_ = path;
  g_variant_unref(reply);

  GVariantBuilder props;
  g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
  // The pointer stays out of the picture: the viewer has its own, and the
  // synthetic one only jumps from tap to tap.
  g_variant_builder_add(&props, "{sv}", "cursor-mode", g_variant_new_uint32(0));
  const char* method = "RecordVirtual";
  if (!virtual_) {
    method = "RecordWindow";
    g_variant_builder_add(&props, "{sv}", "window-id", g_variant_new_uint64(window_id));
  }
  reply = CallSync(kDest, session_path_.c_str(), kSessionIface, method, g_variant_new("(a{sv})", &props), "(o)", 3000,
                   &error);
  if (reply == nullptr) {
    Fail(std::string(method) + ": " + (error != nullptr ? error->message : "?"));
    if (error != nullptr) g_error_free(error);
    return false;
  }
  g_variant_get(reply, "(&o)", &path);
  stream_path_ = path;
  g_variant_unref(reply);
  WSN_TRACE("capture: %s %s", method, stream_path_.c_str());

  std::weak_ptr<bool> alive = alive_;
  node_signal_ = Subscribe(nullptr, kStreamIface, "PipeWireStreamAdded", stream_path_.c_str(),
                           [this, alive](const char*, const char*, GVariant* params) {
                             if (alive.expired() || !g_variant_is_of_type(params, G_VARIANT_TYPE("(u)"))) return;
                             guint32 node = 0;
                             g_variant_get(params, "(u)", &node);
                             OnNode(node);
                           });
  closed_signal_ = Subscribe(nullptr, kSessionIface, "Closed", session_path_.c_str(),
                             [this, alive](const char*, const char*, GVariant*) {
                               if (!alive.expired()) Fail("screencast session closed");
                             });
  capture::Call(kDest, session_path_.c_str(), kSessionIface, "Start", nullptr, nullptr, 5000,
                [this, alive](GVariant*, const GError* error) {
                  if (!alive.expired() && error != nullptr) Fail(std::string("Start: ") + error->message);
                });
  return true;
}

void ScreenCast::OnNode(uint32_t node) {
  WSN_TRACE("capture: PipeWire node %u", node);
  std::weak_ptr<bool> alive = alive_;
  stream_ = PipeWireStream::Connect(
      node, pixel_width_, pixel_height_, fps_, on_frame_,
      [alive, this](bool failed, const char* error, int width, int height) {
        std::string why = error != nullptr ? error : "";
        Post([alive, this, failed, why, width, height] {
          if (alive.expired()) return;
          if (failed) {
            Fail("PipeWire: " + why);
          } else {
            OnNegotiated(width, height);
          }
        });
      });
  if (stream_ == nullptr) Fail("PipeWire unavailable");
}

void ScreenCast::OnNegotiated(int width, int height) {
  WSN_TRACE("capture: negotiated %dx%d", width, height);
  if (!virtual_) {
    pixel_width_ = width;
    pixel_height_ = height;
    if (!ready_) {
      ready_ = true;
      CancelTimer(deadline_timer_);
      deadline_timer_ = 0;
      if (callbacks_.ready) callbacks_.ready(Rect{0, 0, width, height}, 1);
    }
    return;
  }
  if (ready_) return;  // a resize: the layout change tells the rest
  if (find_timer_ == 0) FindMonitor(0);
}

void ScreenCast::FindMonitor(int attempt) {
  find_timer_ = 0;
  DisplayState state;
  if (ReadDisplayState(&state)) {
    for (const LogicalMonitor& lm : state.logical) {
      for (const std::string& connector : lm.connectors) {
        if (!IsVirtualConnector(state, connector) || g_claimed.count(connector) != 0) continue;
        const MonitorInfo& info = state.monitors.at(connector);
        if (info.pixel_width != pixel_width_ || info.pixel_height != pixel_height_) continue;
        connector_ = connector;
        g_claimed.insert(connector);
        WSN_TRACE("capture: virtual monitor is %s", connector.c_str());
        g_scales[connector] = PickScale(info.scales, wanted_scale_);
        PlaceAll(connector);
        DisplayState now;
        const LogicalMonitor* ours = ReadDisplayState(&now) ? now.ForConnector(connector) : nullptr;
        rect_ = ours != nullptr ? ours->rect : lm.rect;
        scale_ = ours != nullptr ? ours->scale : lm.scale;
        ready_ = true;
        CancelTimer(deadline_timer_);
        deadline_timer_ = 0;
        std::weak_ptr<bool> alive = alive_;
        layout_signal_ = Subscribe(nullptr, "org.gnome.Mutter.DisplayConfig", "MonitorsChanged",
                                   "/org/gnome/Mutter/DisplayConfig",
                                   [this, alive](const char*, const char*, GVariant*) {
                                     if (!alive.expired()) OnLayoutChanged();
                                   });
        NextCreation();
        if (callbacks_.ready) callbacks_.ready(rect_, scale_);
        return;
      }
    }
  }
  if (attempt >= 60) {  // 3 s
    Fail("virtual monitor never appeared");
    return;
  }
  std::weak_ptr<bool> alive = alive_;
  find_timer_ = PostAfter(50, [this, alive, attempt] {
    if (!alive.expired()) FindMonitor(attempt + 1);
  });
}

void ScreenCast::OnLayoutChanged() {
  if (!ready_ || failed_ || connector_.empty()) return;
  DisplayState state;
  if (!ReadDisplayState(&state)) return;
  const LogicalMonitor* ours = state.ForConnector(connector_);
  if (ours == nullptr) {
    Fail("virtual monitor removed");
    return;
  }
  auto info = state.monitors.find(connector_);
  if (info != state.monitors.end()) {
    // After a mode change Mutter starts the monitor over at scale 1, and it
    // may put it back beside the real monitors after any layout change.
    if (resizing_ && info->second.pixel_width == pixel_width_ && info->second.pixel_height == pixel_height_) {
      resizing_ = false;
      g_scales[connector_] = PickScale(info->second.scales, wanted_scale_);
    }
    auto layout = LayoutBelow(state, g_scales);
    auto place = layout.find(connector_);
    bool misplaced = place != layout.end() && (std::abs(g_scales[connector_] - ours->scale) > 0.001 ||
                                               ours->rect.x != place->second.x || ours->rect.y != place->second.y);
    if (misplaced && placements_ < 4) {
      placements_++;
      PlaceAll(connector_);
      return;  // the next change reports the result
    }
    if (!misplaced) placements_ = 0;
  }
  if (ours->rect != rect_ || std::abs(ours->scale - scale_) > 0.001) {
    rect_ = ours->rect;
    scale_ = ours->scale;
    if (callbacks_.moved) callbacks_.moved(rect_, scale_);
  }
}

void ScreenCast::Resize(int pixel_width, int pixel_height, double scale) {
  if (!virtual_ || stream_ == nullptr) return;
  pixel_width_ = pixel_width;
  pixel_height_ = pixel_height;
  wanted_scale_ = scale;
  resizing_ = true;
  stream_->Resize(pixel_width, pixel_height);
}

void ScreenCast::Fail(const std::string& why) {
  if (failed_) return;
  failed_ = true;
  WSN_LOG("capture: screencast %s", why.c_str());
  bool finding = virtual_ && !ready_;
  CancelTimer(find_timer_);
  find_timer_ = 0;
  CancelTimer(deadline_timer_);
  deadline_timer_ = 0;
  if (finding) NextCreation();
  // The owner may delete this object from the callback.
  auto lost = callbacks_.lost;
  if (lost) lost(why);
}

}  // namespace wsn::capture
