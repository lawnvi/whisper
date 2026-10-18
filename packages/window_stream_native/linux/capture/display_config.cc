#include "capture/display_config.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <vector>

#include "capture/bus.h"
#include "common/log.h"

namespace wsn::capture {

namespace {

constexpr const char* kDest = "org.gnome.Mutter.DisplayConfig";
constexpr const char* kPath = "/org/gnome/Mutter/DisplayConfig";
constexpr const char* kIface = "org.gnome.Mutter.DisplayConfig";

}  // namespace

const LogicalMonitor* DisplayState::ForConnector(const std::string& connector) const {
  for (const LogicalMonitor& monitor : logical) {
    for (const std::string& name : monitor.connectors) {
      if (name == connector) return &monitor;
    }
  }
  return nullptr;
}

bool ReadDisplayState(DisplayState* out) {
  GError* error = nullptr;
  GVariant* reply = CallSync(kDest, kPath, kIface, "GetCurrentState", nullptr,
                             "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})", 2000, &error);
  if (reply == nullptr) {
    WSN_LOG("capture: GetCurrentState failed: %s", error != nullptr ? error->message : "?");
    if (error != nullptr) g_error_free(error);
    return false;
  }
  DisplayState state;
  GVariant* monitors = nullptr;
  GVariant* logical = nullptr;
  GVariant* properties = nullptr;
  g_variant_get(reply, "(u@a((ssss)a(siiddada{sv})a{sv})@a(iiduba(ssss)a{sv})@a{sv})", &state.serial, &monitors,
                &logical, &properties);

  guint32 layout = 1;
  if (g_variant_lookup(properties, "layout-mode", "u", &layout)) state.logical_layout = layout != 2;

  GVariantIter monitor_iter;
  g_variant_iter_init(&monitor_iter, monitors);
  GVariant* monitor = nullptr;
  while ((monitor = g_variant_iter_next_value(&monitor_iter)) != nullptr) {
    const gchar* connector = nullptr;
    GVariant* modes = nullptr;
    GVariant* props = nullptr;
    g_variant_get(monitor, "((&ssss)@a(siiddada{sv})@a{sv})", &connector, nullptr, nullptr, nullptr, &modes, &props);
    MonitorInfo info;
    info.connector = connector != nullptr ? connector : "";
    gboolean builtin = FALSE;
    if (g_variant_lookup(props, "is-builtin", "b", &builtin)) info.builtin = builtin;
    guint32 value = 0;
    if (g_variant_lookup(props, "color-mode", "u", &value)) {
      info.has_color_mode = true;
      info.color_mode = value;
    }
    if (g_variant_lookup(props, "rgb-range", "u", &value)) {
      info.has_rgb_range = true;
      info.rgb_range = value;
    }
    gboolean underscanning = FALSE;
    if (g_variant_lookup(props, "is-underscanning", "b", &underscanning)) info.underscanning = underscanning;
    GVariantIter mode_iter;
    g_variant_iter_init(&mode_iter, modes);
    GVariant* mode = nullptr;
    while ((mode = g_variant_iter_next_value(&mode_iter)) != nullptr) {
      const gchar* id = nullptr;
      gint32 width = 0;
      gint32 height = 0;
      gdouble refresh = 0;
      gdouble preferred = 0;
      GVariant* scales = nullptr;
      GVariant* mode_props = nullptr;
      g_variant_get(mode, "(&siidd@ad@a{sv})", &id, &width, &height, &refresh, &preferred, &scales, &mode_props);
      gboolean current = FALSE;
      g_variant_lookup(mode_props, "is-current", "b", &current);
      if (current) {
        info.mode_id = id != nullptr ? id : "";
        info.pixel_width = width;
        info.pixel_height = height;
        gsize count = 0;
        const gdouble* values = static_cast<const gdouble*>(g_variant_get_fixed_array(scales, &count, sizeof(gdouble)));
        info.scales.assign(values, values + count);
      }
      g_variant_unref(scales);
      g_variant_unref(mode_props);
      g_variant_unref(mode);
    }
    state.monitors[info.connector] = info;
    g_variant_unref(modes);
    g_variant_unref(props);
    g_variant_unref(monitor);
  }

  GVariantIter logical_iter;
  g_variant_iter_init(&logical_iter, logical);
  GVariant* entry = nullptr;
  while ((entry = g_variant_iter_next_value(&logical_iter)) != nullptr) {
    LogicalMonitor lm;
    gboolean primary = FALSE;
    GVariant* specs = nullptr;
    g_variant_get(entry, "(iidub@a(ssss)@a{sv})", &lm.rect.x, &lm.rect.y, &lm.scale, &lm.transform, &primary, &specs,
                  nullptr);
    lm.primary = primary;
    GVariantIter spec_iter;
    g_variant_iter_init(&spec_iter, specs);
    const gchar* connector = nullptr;
    while (g_variant_iter_next(&spec_iter, "(&sss&s)", &connector, nullptr, nullptr, nullptr)) {
      lm.connectors.emplace_back(connector);
    }
    g_variant_unref(specs);
    if (!lm.connectors.empty()) {
      auto found = state.monitors.find(lm.connectors.front());
      if (found != state.monitors.end()) {
        int width = found->second.pixel_width;
        int height = found->second.pixel_height;
        if (lm.transform % 2 == 1) std::swap(width, height);  // 90° / 270°
        double divisor = state.logical_layout && lm.scale > 0 ? lm.scale : 1;
        lm.rect.width = static_cast<int>(std::lround(width / divisor));
        lm.rect.height = static_cast<int>(std::lround(height / divisor));
      }
    }
    state.logical.push_back(lm);
    g_variant_unref(entry);
  }
  g_variant_unref(monitors);
  g_variant_unref(logical);
  g_variant_unref(properties);
  g_variant_unref(reply);
  *out = std::move(state);
  return true;
}

double PickScale(const std::vector<double>& supported, double wanted) {
  double best = 1;
  for (double scale : supported) {
    if (scale <= wanted + 0.01 && scale > best) best = scale;
  }
  return best;
}

namespace {

// The monitor's own settings, as ApplyMonitorsConfig takes them.
GVariant* MonitorProperties(const MonitorInfo& info) {
  GVariantBuilder props;
  g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
  if (info.has_color_mode) g_variant_builder_add(&props, "{sv}", "color-mode", g_variant_new_uint32(info.color_mode));
  if (info.has_rgb_range) g_variant_builder_add(&props, "{sv}", "rgb-range", g_variant_new_uint32(info.rgb_range));
  if (info.underscanning) {
    // The key changed name between Mutter releases; unknown keys are ignored.
    for (const char* key : {"enable_underscanning", "underscanning", "underscan"}) {
      g_variant_builder_add(&props, "{sv}", key, g_variant_new_boolean(TRUE));
    }
  }
  return g_variant_builder_end(&props);
}

}  // namespace

std::map<std::string, Rect> LayoutBelow(const DisplayState& state, const std::map<std::string, double>& ours) {
  // Under the real monitor that reaches lowest (the leftmost of those), from
  // its left edge: the row touches it, whatever the other monitors' heights.
  int left = 0;
  int bottom = 0;
  bool any = false;
  for (const LogicalMonitor& lm : state.logical) {
    if (lm.connectors.empty() || ours.count(lm.connectors.front()) != 0) continue;
    int lm_bottom = lm.rect.y + lm.rect.height;
    if (!any || lm_bottom > bottom || (lm_bottom == bottom && lm.rect.x < left)) {
      bottom = lm_bottom;
      left = lm.rect.x;
    }
    any = true;
  }
  auto number = [](const std::string& name) {
    size_t dash = name.rfind('-');
    return dash == std::string::npos ? 0 : std::atoi(name.c_str() + dash + 1);
  };
  std::vector<std::pair<int, std::string>> row;
  for (const auto& [connector, scale] : ours) {
    if (state.monitors.count(connector) != 0 && state.ForConnector(connector) != nullptr) {
      row.emplace_back(number(connector), connector);
    }
  }
  std::sort(row.begin(), row.end());
  std::map<std::string, Rect> layout;
  int x = left;
  for (const auto& [n, connector] : row) {
    const MonitorInfo& info = state.monitors.at(connector);
    double scale = ours.at(connector);
    double divisor = state.logical_layout && scale > 0 ? scale : 1;
    Rect rect{x, bottom, static_cast<int>(std::lround(info.pixel_width / divisor)),
              static_cast<int>(std::lround(info.pixel_height / divisor))};
    layout[connector] = rect;
    x += rect.width;
  }
  return layout;
}

bool PlaceVirtualMonitors(const std::map<std::string, double>& ours, std::string* error) {
  for (int attempt = 0; attempt < 2; attempt++) {
    DisplayState state;
    if (!ReadDisplayState(&state)) {
      *error = "no display state";
      return false;
    }
    std::map<std::string, Rect> layout = LayoutBelow(state, ours);
    bool changed = false;
    for (const auto& [connector, rect] : layout) {
      const LogicalMonitor* lm = state.ForConnector(connector);
      if (lm->rect.x != rect.x || lm->rect.y != rect.y || std::fabs(lm->scale - ours.at(connector)) > 0.001) {
        changed = true;
      }
    }
    if (!changed) return true;
    GVariantBuilder logical;
    g_variant_builder_init(&logical, G_VARIANT_TYPE("a(iiduba(ssa{sv}))"));
    for (const LogicalMonitor& lm : state.logical) {
      GVariantBuilder specs;
      g_variant_builder_init(&specs, G_VARIANT_TYPE("a(ssa{sv})"));
      for (const std::string& name : lm.connectors) {
        auto found = state.monitors.find(name);
        if (found == state.monitors.end()) continue;
        g_variant_builder_add(&specs, "(ss@a{sv})", name.c_str(), found->second.mode_id.c_str(),
                              MonitorProperties(found->second));
      }
      auto placed = lm.connectors.empty() ? layout.end() : layout.find(lm.connectors.front());
      bool mine = placed != layout.end();
      g_variant_builder_add(&logical, "(iiduba(ssa{sv}))", mine ? placed->second.x : lm.rect.x,
                            mine ? placed->second.y : lm.rect.y, mine ? ours.at(placed->first) : lm.scale,
                            lm.transform, lm.primary, &specs);
    }
    GError* failure = nullptr;
    // Method 1: temporary (applied, never stored, no confirmation dialog).
    GVariant* reply = CallSync(kDest, kPath, kIface, "ApplyMonitorsConfig",
                               g_variant_new("(uua(iiduba(ssa{sv}))@a{sv})", state.serial, 1u, &logical,
                                             g_variant_new_array(G_VARIANT_TYPE("{sv}"), nullptr, 0)),
                               nullptr, 3000, &failure);
    if (reply != nullptr) {
      g_variant_unref(reply);
      return true;
    }
    *error = failure != nullptr ? failure->message : "?";
    bool stale = failure != nullptr && g_strstr_len(failure->message, -1, "serial") != nullptr;
    if (failure != nullptr) g_error_free(failure);
    if (!stale) return false;  // a changed layout (another monitor came) is retried once
  }
  return false;
}

}  // namespace wsn::capture
