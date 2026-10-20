#include "capture/kwin_wayland.h"

#ifdef WSN_HAVE_KWIN_PROTOCOLS

#include <glib-unix.h>
#include <glib.h>
#include <wayland-client.h>

#include <cmath>
#include <map>
#include <memory>

#include "capture/capture_thread.h"
#include "common/log.h"
#include "fake-input-client-protocol.h"
#include "kde-output-device-v2-client-protocol.h"
#include "kde-output-management-v2-client-protocol.h"
#include "zkde-screencast-unstable-v1-client-protocol.h"

namespace wsn::capture::kwin {

namespace {

// The newest versions this build knows (the vendored XML in protocols/):
// KWin sends nothing newer than what was bound.
constexpr uint32_t kScreencastVersion = 5;
constexpr uint32_t kFakeInputVersion = 6;
constexpr uint32_t kDeviceVersion = 26;
constexpr uint32_t kManagementVersion = 22;
// set_custom_modes (kde_output_configuration_v2).
constexpr uint32_t kCustomModesSince = 18;

// Any listener slot this code has nothing to do for.
template <typename F>
struct Ignore;
template <typename... A>
struct Ignore<void (*)(A...)> {
  static void Fn(A...) {}
};
#define WSN_IGNORE(listener, slot) (listener).slot = Ignore<decltype((listener).slot)>::Fn

struct Mode {
  kde_output_device_mode_v2* proxy = nullptr;
  int width = 0;
  int height = 0;
  bool removed = false;
};

struct Device {
  uint32_t global = 0;
  kde_output_device_v2* proxy = nullptr;
  OutputInfo pending;
  OutputInfo current;
  Mode* current_mode = nullptr;
  std::vector<std::unique_ptr<Mode>> modes;
  bool described = false;  // a first done arrived
};

struct Stream {
  zkde_screencast_stream_unstable_v1* proxy = nullptr;
  StreamCallbacks callbacks;
};

struct State {
  wl_display* display = nullptr;
  wl_registry* registry = nullptr;
  zkde_screencast_unstable_v1* screencast = nullptr;
  org_kde_kwin_fake_input* fake = nullptr;
  kde_output_management_v2* management = nullptr;
  uint32_t management_version = 0;
  std::map<uint32_t, std::unique_ptr<Device>> devices;  // by registry name
  std::map<uint32_t, std::unique_ptr<Stream>> streams;  // by handle
  uint32_t next_handle = 1;
  GSource* source = nullptr;
  std::function<void()> outputs_changed;
};

State& S() {
  static auto* state = new State();
  return *state;
}

void Flush() {
  if (S().display != nullptr) wl_display_flush(S().display);
}

void NotifyOutputs() {
  if (S().outputs_changed) Post(S().outputs_changed);
}

Device* FindDevice(const std::string& name) {
  for (auto& entry : S().devices) {
    if (entry.second->current.name == name) return entry.second.get();
  }
  return nullptr;
}

// ------------------------------------------------------------ output devices

kde_output_device_mode_v2_listener MakeModeListener() {
  kde_output_device_mode_v2_listener l{};
  l.size = [](void* data, kde_output_device_mode_v2*, int32_t width, int32_t height) {
    auto* mode = static_cast<Mode*>(data);
    mode->width = width;
    mode->height = height;
  };
  l.removed = [](void* data, kde_output_device_mode_v2*) { static_cast<Mode*>(data)->removed = true; };
  WSN_IGNORE(l, refresh);
  WSN_IGNORE(l, preferred);
  WSN_IGNORE(l, flags);
  WSN_IGNORE(l, cvt);
  return l;
}

const kde_output_device_mode_v2_listener& ModeListener() {
  static const kde_output_device_mode_v2_listener listener = MakeModeListener();
  return listener;
}

void Describe(Device* device) {
  OutputInfo& info = device->pending;
  if (device->current_mode != nullptr) {
    info.pixel_width = device->current_mode->width;
    info.pixel_height = device->current_mode->height;
  }
  double scale = info.scale > 0 ? info.scale : 1;
  info.rect.width = static_cast<int>(std::lround(info.pixel_width / scale));
  info.rect.height = static_cast<int>(std::lround(info.pixel_height / scale));
  device->current = info;
  device->described = true;
  NotifyOutputs();
}

void DestroyDevice(Device* device) {
  for (auto& mode : device->modes) kde_output_device_mode_v2_destroy(mode->proxy);
  device->modes.clear();
  if (device->proxy != nullptr) kde_output_device_v2_destroy(device->proxy);
  device->proxy = nullptr;
}

kde_output_device_v2_listener MakeDeviceListener() {
  kde_output_device_v2_listener l{};
  l.geometry = [](void* data, kde_output_device_v2*, int32_t x, int32_t y, int32_t, int32_t, int32_t, const char*,
                  const char*, int32_t) {
    auto* device = static_cast<Device*>(data);
    device->pending.rect.x = x;
    device->pending.rect.y = y;
  };
  l.current_mode = [](void* data, kde_output_device_v2*, kde_output_device_mode_v2* mode) {
    auto* device = static_cast<Device*>(data);
    device->current_mode = mode != nullptr ? static_cast<Mode*>(kde_output_device_mode_v2_get_user_data(mode)) : nullptr;
  };
  l.mode = [](void* data, kde_output_device_v2*, kde_output_device_mode_v2* proxy) {
    auto* device = static_cast<Device*>(data);
    auto mode = std::make_unique<Mode>();
    mode->proxy = proxy;
    kde_output_device_mode_v2_add_listener(proxy, &ModeListener(), mode.get());
    device->modes.push_back(std::move(mode));
  };
  l.done = [](void* data, kde_output_device_v2*) { Describe(static_cast<Device*>(data)); };
  l.scale = [](void* data, kde_output_device_v2*, wl_fixed_t factor) {
    static_cast<Device*>(data)->pending.scale = wl_fixed_to_double(factor);
  };
  l.enabled = [](void* data, kde_output_device_v2*, int32_t enabled) {
    static_cast<Device*>(data)->pending.enabled = enabled != 0;
  };
  l.name = [](void* data, kde_output_device_v2*, const char* name) {
    static_cast<Device*>(data)->pending.name = name != nullptr ? name : "";
  };
  l.removed = [](void* data, kde_output_device_v2*) {
    // Version 21: the device announces its own end (its global stays).
    auto* device = static_cast<Device*>(data);
    uint32_t global = device->global;
    DestroyDevice(device);
    S().devices.erase(global);
    NotifyOutputs();
  };
  WSN_IGNORE(l, edid);
  WSN_IGNORE(l, uuid);
  WSN_IGNORE(l, serial_number);
  WSN_IGNORE(l, eisa_id);
  WSN_IGNORE(l, capabilities);
  WSN_IGNORE(l, overscan);
  WSN_IGNORE(l, vrr_policy);
  WSN_IGNORE(l, rgb_range);
  WSN_IGNORE(l, high_dynamic_range);
  WSN_IGNORE(l, sdr_brightness);
  WSN_IGNORE(l, wide_color_gamut);
  WSN_IGNORE(l, auto_rotate_policy);
  WSN_IGNORE(l, icc_profile_path);
  WSN_IGNORE(l, brightness_metadata);
  WSN_IGNORE(l, brightness_overrides);
  WSN_IGNORE(l, sdr_gamut_wideness);
  WSN_IGNORE(l, color_profile_source);
  WSN_IGNORE(l, brightness);
  WSN_IGNORE(l, color_power_tradeoff);
  WSN_IGNORE(l, dimming);
  WSN_IGNORE(l, replication_source);
  WSN_IGNORE(l, ddc_ci_allowed);
  WSN_IGNORE(l, max_bits_per_color);
  WSN_IGNORE(l, max_bits_per_color_range);
  WSN_IGNORE(l, automatic_max_bits_per_color_limit);
  WSN_IGNORE(l, edr_policy);
  WSN_IGNORE(l, sharpness);
  WSN_IGNORE(l, priority);
  WSN_IGNORE(l, auto_brightness);
  WSN_IGNORE(l, hdr_icc_profile_path);
  WSN_IGNORE(l, hdr_color_profile_source);
  WSN_IGNORE(l, abm_level);
  return l;
}

const kde_output_device_v2_listener& DeviceListener() {
  static const kde_output_device_v2_listener listener = MakeDeviceListener();
  return listener;
}

// ------------------------------------------------------------ registry

void OnGlobal(void*, wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
  State& s = S();
  auto bind = [&](const wl_interface* iface, uint32_t ours) {
    return wl_registry_bind(registry, name, iface, version < ours ? version : ours);
  };
  if (std::string(interface) == zkde_screencast_unstable_v1_interface.name) {
    if (version >= 2) {
      s.screencast = static_cast<zkde_screencast_unstable_v1*>(
          bind(&zkde_screencast_unstable_v1_interface, kScreencastVersion));
    }
  } else if (std::string(interface) == org_kde_kwin_fake_input_interface.name) {
    if (version >= 6) {
      s.fake = static_cast<org_kde_kwin_fake_input*>(bind(&org_kde_kwin_fake_input_interface, kFakeInputVersion));
      org_kde_kwin_fake_input_authenticate(s.fake, "Whisper", "Window flow: input from the device showing a window");
    }
  } else if (std::string(interface) == kde_output_management_v2_interface.name) {
    s.management = static_cast<kde_output_management_v2*>(bind(&kde_output_management_v2_interface, kManagementVersion));
    s.management_version = version < kManagementVersion ? version : kManagementVersion;
  } else if (std::string(interface) == kde_output_device_v2_interface.name) {
    auto device = std::make_unique<Device>();
    device->global = name;
    device->proxy = static_cast<kde_output_device_v2*>(bind(&kde_output_device_v2_interface, kDeviceVersion));
    kde_output_device_v2_add_listener(device->proxy, &DeviceListener(), device.get());
    s.devices[name] = std::move(device);
  }
}

void OnGlobalRemove(void*, wl_registry*, uint32_t name) {
  auto found = S().devices.find(name);
  if (found == S().devices.end()) return;
  DestroyDevice(found->second.get());
  S().devices.erase(found);
  NotifyOutputs();
}

const wl_registry_listener kRegistryListener = {OnGlobal, OnGlobalRemove};

// ------------------------------------------------------------ streams

zkde_screencast_stream_unstable_v1_listener MakeStreamListener() {
  zkde_screencast_stream_unstable_v1_listener l{};
  l.created = [](void* data, zkde_screencast_stream_unstable_v1*, uint32_t node) {
    uint32_t handle = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(data));
    auto found = S().streams.find(handle);
    if (found == S().streams.end() || !found->second->callbacks.node) return;
    auto callback = found->second->callbacks.node;
    Post([callback, node] { callback(node); });
  };
  auto end = [](uint32_t handle, const std::string& why) {
    auto found = S().streams.find(handle);
    if (found == S().streams.end()) return;
    auto callback = found->second->callbacks.lost;
    found->second->callbacks = {};
    if (callback) Post([callback, why] { callback(why); });
  };
  static decltype(end) s_end = end;
  l.failed = [](void* data, zkde_screencast_stream_unstable_v1*, const char* error) {
    s_end(static_cast<uint32_t>(reinterpret_cast<uintptr_t>(data)), std::string("KWin: ") + (error ? error : "?"));
  };
  l.closed = [](void* data, zkde_screencast_stream_unstable_v1*) {
    s_end(static_cast<uint32_t>(reinterpret_cast<uintptr_t>(data)), "KWin closed the stream");
  };
  WSN_IGNORE(l, serial);
  return l;
}

const zkde_screencast_stream_unstable_v1_listener& StreamListener() {
  static const zkde_screencast_stream_unstable_v1_listener listener = MakeStreamListener();
  return listener;
}

uint32_t AddStream(zkde_screencast_stream_unstable_v1* proxy, StreamCallbacks callbacks) {
  State& s = S();
  uint32_t handle = s.next_handle++;
  auto stream = std::make_unique<Stream>();
  stream->proxy = proxy;
  stream->callbacks = std::move(callbacks);
  zkde_screencast_stream_unstable_v1_add_listener(proxy, &StreamListener(),
                                                  reinterpret_cast<void*>(static_cast<uintptr_t>(handle)));
  s.streams[handle] = std::move(stream);
  Flush();
  return handle;
}

// ------------------------------------------------------------ connection

void Disconnect(const std::string& why) {
  State& s = S();
  if (s.display == nullptr) return;
  WSN_LOG("capture: KWin connection closed: %s", why.c_str());
  if (s.source != nullptr) {
    g_source_destroy(s.source);
    g_source_unref(s.source);
    s.source = nullptr;
  }
  auto streams = std::move(s.streams);
  s.streams.clear();
  for (auto& entry : streams) {
    if (entry.second->callbacks.lost) {
      auto callback = entry.second->callbacks.lost;
      Post([callback, why] { callback("KWin connection lost: " + why); });
    }
  }
  for (auto& entry : streams) wl_proxy_destroy(reinterpret_cast<wl_proxy*>(entry.second->proxy));
  for (auto& entry : s.devices) DestroyDevice(entry.second.get());
  s.devices.clear();
  for (void* proxy : {static_cast<void*>(s.screencast), static_cast<void*>(s.fake), static_cast<void*>(s.management),
                      static_cast<void*>(s.registry)}) {
    if (proxy != nullptr) wl_proxy_destroy(static_cast<wl_proxy*>(proxy));
  }
  s.screencast = nullptr;
  s.fake = nullptr;
  s.management = nullptr;
  s.management_version = 0;
  s.registry = nullptr;
  wl_display_disconnect(s.display);
  s.display = nullptr;
  NotifyOutputs();
}

gboolean OnReadable(gint, GIOCondition condition, gpointer) {
  State& s = S();
  if (s.display == nullptr) return G_SOURCE_REMOVE;
  if ((condition & (G_IO_HUP | G_IO_ERR)) != 0) {
    Post([] { Disconnect("hung up"); });
    return G_SOURCE_CONTINUE;
  }
  if (wl_display_dispatch(s.display) < 0) {
    Post([] { Disconnect("dispatch failed"); });
    return G_SOURCE_CONTINUE;
  }
  Flush();
  return G_SOURCE_CONTINUE;
}

}  // namespace

bool Compiled() { return true; }

bool Connected() { return S().display != nullptr; }

bool Connect(std::string* why) {
  State& s = S();
  if (s.display != nullptr) return true;
  s.display = wl_display_connect(nullptr);
  if (s.display == nullptr) {
    if (why != nullptr) *why = "no Wayland display";
    return false;
  }
  s.registry = wl_display_get_registry(s.display);
  wl_registry_add_listener(s.registry, &kRegistryListener, nullptr);
  // Globals, then what each output device says about itself.
  wl_display_roundtrip(s.display);
  wl_display_roundtrip(s.display);
  if (s.screencast == nullptr || s.fake == nullptr) {
    if (why != nullptr) {
      *why = std::string("KWin withholds ") + (s.screencast == nullptr ? "zkde_screencast_unstable_v1 " : "") +
             (s.fake == nullptr ? "org_kde_kwin_fake_input" : "");
    }
    Disconnect("protocols withheld");
    return false;
  }
  s.source = g_unix_fd_source_new(wl_display_get_fd(s.display),
                                  static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR));
  g_source_set_callback(s.source, G_SOURCE_FUNC(OnReadable), nullptr, nullptr);
  g_source_attach(s.source, Context());
  WSN_LOG("capture: connected to KWin (output management v%u, %zu outputs)", s.management_version,
          s.devices.size());
  return true;
}

uint32_t StreamVirtualOutput(const std::string& name, const std::string& description, int pixel_width,
                             int pixel_height, double scale, StreamCallbacks callbacks) {
  State& s = S();
  if (s.screencast == nullptr) return 0;
  // The size is the output's mode (pixels); the scale given here is replaced
  // by KWin's own choice, so ConfigureOutput sets it afterwards.
  zkde_screencast_stream_unstable_v1* proxy;
  if (zkde_screencast_unstable_v1_get_version(s.screencast) >= 4) {
    proxy = zkde_screencast_unstable_v1_stream_virtual_output_with_description(
        s.screencast, name.c_str(), description.c_str(), pixel_width, pixel_height, wl_fixed_from_double(scale),
        ZKDE_SCREENCAST_UNSTABLE_V1_POINTER_HIDDEN);
  } else {
    proxy = zkde_screencast_unstable_v1_stream_virtual_output(s.screencast, name.c_str(), pixel_width, pixel_height,
                                                             wl_fixed_from_double(scale),
                                                             ZKDE_SCREENCAST_UNSTABLE_V1_POINTER_HIDDEN);
  }
  return AddStream(proxy, std::move(callbacks));
}

uint32_t StreamWindow(const std::string& uuid, StreamCallbacks callbacks) {
  State& s = S();
  if (s.screencast == nullptr) return 0;
  auto* proxy = zkde_screencast_unstable_v1_stream_window(s.screencast, uuid.c_str(),
                                                          ZKDE_SCREENCAST_UNSTABLE_V1_POINTER_HIDDEN);
  return AddStream(proxy, std::move(callbacks));
}

void CloseStream(uint32_t handle) {
  State& s = S();
  auto found = s.streams.find(handle);
  if (found == s.streams.end()) return;
  zkde_screencast_stream_unstable_v1_close(found->second->proxy);
  s.streams.erase(found);
  Flush();
}

std::vector<OutputInfo> Outputs() {
  std::vector<OutputInfo> outputs;
  for (auto& entry : S().devices) {
    if (entry.second->described) outputs.push_back(entry.second->current);
  }
  return outputs;
}

void SetOutputsChanged(std::function<void()> changed) { S().outputs_changed = std::move(changed); }

bool CanResize() { return S().management != nullptr && S().management_version >= kCustomModesSince; }

namespace {

struct Pending {
  kde_output_configuration_v2* config = nullptr;
  std::function<void(bool ok)> done;
};

kde_output_configuration_v2_listener MakeConfigListener() {
  kde_output_configuration_v2_listener l{};
  auto finish = [](void* data, bool ok) {
    auto* pending = static_cast<Pending*>(data);
    kde_output_configuration_v2_destroy(pending->config);
    auto done = std::move(pending->done);
    delete pending;
    if (done) Post([done, ok] { done(ok); });
  };
  static decltype(finish) s_finish = finish;
  l.applied = [](void* data, kde_output_configuration_v2*) { s_finish(data, true); };
  l.failed = [](void* data, kde_output_configuration_v2*) { s_finish(data, false); };
  l.failure_reason = [](void*, kde_output_configuration_v2*, const char* reason) {
    WSN_LOG("capture: KWin refused an output configuration: %s", reason != nullptr ? reason : "?");
  };
  return l;
}

const kde_output_configuration_v2_listener& ConfigListener() {
  static const kde_output_configuration_v2_listener listener = MakeConfigListener();
  return listener;
}

// Applies one configuration of `device`; `mode` may be null (unchanged).
void Apply(Device* device, Mode* mode, int x, int y, double scale, std::function<void(bool)> done) {
  State& s = S();
  auto* pending = new Pending();
  pending->config = kde_output_management_v2_create_configuration(s.management);
  pending->done = std::move(done);
  kde_output_configuration_v2_add_listener(pending->config, &ConfigListener(), pending);
  if (mode != nullptr) kde_output_configuration_v2_mode(pending->config, device->proxy, mode->proxy);
  kde_output_configuration_v2_scale(pending->config, device->proxy, wl_fixed_from_double(scale));
  kde_output_configuration_v2_position(pending->config, device->proxy, x, y);
  kde_output_configuration_v2_apply(pending->config);
  Flush();
}

Mode* FindMode(Device* device, int width, int height) {
  for (auto& mode : device->modes) {
    if (!mode->removed && mode->width == width && mode->height == height) return mode.get();
  }
  return nullptr;
}

}  // namespace

void ConfigureOutput(const std::string& name, int x, int y, double scale, int pixel_width, int pixel_height,
                     std::function<void(bool ok)> done) {
  State& s = S();
  Device* device = FindDevice(name);
  if (s.management == nullptr || device == nullptr) {
    Post([done] { done(false); });
    return;
  }
  bool resize = pixel_width > 0 && pixel_height > 0 &&
                (pixel_width != device->current.pixel_width || pixel_height != device->current.pixel_height);
  if (!resize) {
    Apply(device, nullptr, x, y, scale, std::move(done));
    return;
  }
  if (Mode* existing = FindMode(device, pixel_width, pixel_height)) {
    Apply(device, existing, x, y, scale, std::move(done));
    return;
  }
  if (!CanResize()) {
    Post([done] { done(false); });
    return;
  }
  // The new size as the output's only custom mode first; then that mode.
  auto* list = kde_output_management_v2_create_mode_list(s.management);
  kde_mode_list_v2_set_resolution(list, static_cast<uint32_t>(pixel_width), static_cast<uint32_t>(pixel_height));
  kde_mode_list_v2_set_refresh_rate(list, 60000);
  kde_mode_list_v2_add_mode(list);
  auto* pending = new Pending();
  pending->config = kde_output_management_v2_create_configuration(s.management);
  uint32_t global = device->global;
  pending->done = [global, x, y, scale, pixel_width, pixel_height, done](bool ok) {
    auto found = S().devices.find(global);
    Mode* mode = ok && found != S().devices.end() ? FindMode(found->second.get(), pixel_width, pixel_height) : nullptr;
    if (mode == nullptr) {
      done(false);
      return;
    }
    Apply(found->second.get(), mode, x, y, scale, done);
  };
  kde_output_configuration_v2_add_listener(pending->config, &ConfigListener(), pending);
  kde_output_configuration_v2_set_custom_modes(pending->config, device->proxy, list);
  kde_output_configuration_v2_apply(pending->config);
  kde_mode_list_v2_destroy(list);
  Flush();
}

void PointerAbsolute(double x, double y) {
  if (S().fake == nullptr) return;
  org_kde_kwin_fake_input_pointer_motion_absolute(S().fake, wl_fixed_from_double(x), wl_fixed_from_double(y));
  Flush();
}

void Button(uint32_t code, bool down) {
  if (S().fake == nullptr) return;
  org_kde_kwin_fake_input_button(S().fake, code, down ? WL_POINTER_BUTTON_STATE_PRESSED
                                                      : WL_POINTER_BUTTON_STATE_RELEASED);
  Flush();
}

void Axis(uint32_t axis, double value) {
  if (S().fake == nullptr) return;
  org_kde_kwin_fake_input_axis(S().fake, axis, wl_fixed_from_double(value));
  Flush();
}

void Key(uint32_t evdev, bool down) {
  if (S().fake == nullptr) return;
  org_kde_kwin_fake_input_keyboard_key(S().fake, evdev, down ? WL_KEYBOARD_KEY_STATE_PRESSED
                                                             : WL_KEYBOARD_KEY_STATE_RELEASED);
  Flush();
}

void Keysym(uint32_t keysym, bool down) {
  if (S().fake == nullptr) return;
  org_kde_kwin_fake_input_keyboard_keysym(S().fake, keysym, down ? WL_KEYBOARD_KEY_STATE_PRESSED
                                                                 : WL_KEYBOARD_KEY_STATE_RELEASED);
  Flush();
}

}  // namespace wsn::capture::kwin

#else  // !WSN_HAVE_KWIN_PROTOCOLS

namespace wsn::capture::kwin {

bool Compiled() { return false; }
bool Connected() { return false; }
bool Connect(std::string* why) {
  if (why != nullptr) *why = "built without the KWin protocols";
  return false;
}
uint32_t StreamVirtualOutput(const std::string&, const std::string&, int, int, double, StreamCallbacks) { return 0; }
uint32_t StreamWindow(const std::string&, StreamCallbacks) { return 0; }
void CloseStream(uint32_t) {}
std::vector<OutputInfo> Outputs() { return {}; }
void SetOutputsChanged(std::function<void()>) {}
void ConfigureOutput(const std::string&, int, int, double, int, int, std::function<void(bool)> done) {
  if (done) done(false);
}
bool CanResize() { return false; }
void PointerAbsolute(double, double) {}
void Button(uint32_t, bool) {}
void Axis(uint32_t, double) {}
void Key(uint32_t, bool) {}
void Keysym(uint32_t, bool) {}

}  // namespace wsn::capture::kwin

#endif  // WSN_HAVE_KWIN_PROTOCOLS
