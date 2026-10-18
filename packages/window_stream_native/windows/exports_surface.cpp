// C ABI (src/window_stream_native.h): core, surface and media exports.
// Thin shims over receiver/surface.*; see common/wsn_common.h for the
// threading rules.

#include "common/wsn_common.h"

#include <cstdlib>

#include "receiver/surface.h"
#include "receiver/ui_strings.h"

using namespace wsn;

WSN_EXPORT int32_t wsn_api_version(void) { return WSN_API_VERSION; }

WSN_EXPORT void wsn_reset_all(void) {
  ClearSurfaceCallbacks();
  DestroyAllSurfaces();
  ResetAllCaptures();
}

WSN_EXPORT void wsn_set_input_callback(wsn_input_callback callback) { SetInputCallback(callback); }

WSN_EXPORT void wsn_set_window_callback(wsn_window_callback callback) { SetWindowCallback(callback); }

WSN_EXPORT void wsn_free(void* pointer) { std::free(pointer); }

WSN_EXPORT int64_t wsn_surface_create(const char* title, int32_t video_width, int32_t video_height, int32_t flags) {
  return AddSurface(Utf8ToWide(title), video_width, video_height, flags);
}

WSN_EXPORT void wsn_surface_set_title(int64_t surface, const char* title) {
  if (auto target = FindSurface(surface)) target->SetTitle(Utf8ToWide(title));
}

WSN_EXPORT void wsn_surface_set_visual(int64_t surface, int32_t visual, const char* message) {
  if (auto target = FindSurface(surface)) target->SetVisual(visual, Utf8ToWide(message));
}

WSN_EXPORT void wsn_surface_set_hud(int64_t surface, const char* text) {
  if (auto target = FindSurface(surface)) target->SetHud(Utf8ToWide(text));
}

WSN_EXPORT void wsn_surface_set_icon(int64_t surface, const uint8_t* png, int32_t length) {
  if (png == nullptr || length <= 0) return;
  if (auto target = FindSurface(surface)) target->SetIcon(png, length);
}

WSN_EXPORT void wsn_surface_focus(int64_t surface) {
  if (auto target = FindSurface(surface)) {
    RunOnUiThread([target] { target->FocusOnUiThread(); });
  }
}

WSN_EXPORT void wsn_surface_destroy(int64_t surface) { DestroySurface(surface); }

WSN_EXPORT int32_t wsn_surface_stats(int64_t surface, double* out, int32_t count) {
  if (out == nullptr || count <= 0) return 0;
  auto target = FindSurface(surface);
  return target == nullptr ? 0 : target->Stats(out, count);
}

WSN_EXPORT int32_t wsn_surface_snapshot(int64_t surface, const char* path, int32_t max_edge) {
  if (path == nullptr) return -1;
  auto target = FindSurface(surface);
  return target == nullptr ? -1 : target->Snapshot(path, max_edge);
}

WSN_EXPORT void wsn_surface_set_volume(int64_t surface, double volume) {
  if (auto target = FindSurface(surface)) target->SetVolume(volume);
}

WSN_EXPORT void wsn_set_strings(const char* json) {
  SetUiStrings(json);
  RefreshSurfaceStrings();
}

WSN_EXPORT uint8_t* wsn_buffer_alloc(int32_t length) {
  return length > 0 ? static_cast<uint8_t*>(std::malloc(static_cast<size_t>(length))) : nullptr;
}

WSN_EXPORT void wsn_video_push(int64_t surface, uint8_t* buffer, int32_t length, int64_t pts_us, int32_t flags) {
  if (buffer == nullptr) return;
  auto target = FindSurface(surface);
  if (target == nullptr || length <= 0) {
    std::free(buffer);
    return;
  }
  target->PushVideo(buffer, length, pts_us, flags);
}

WSN_EXPORT void wsn_audio_configure(int64_t surface, int32_t codec, int32_t sample_rate, int32_t channels) {
  if (codec != WSN_AUDIO_PCM_S16LE) return;
  if (auto target = FindSurface(surface)) target->ConfigureAudio(sample_rate, channels);
}

WSN_EXPORT void wsn_audio_push(int64_t surface, uint8_t* buffer, int32_t length, int64_t pts_us) {
  if (buffer == nullptr) return;
  auto target = FindSurface(surface);
  if (target == nullptr || length <= 0) {
    std::free(buffer);
    return;
  }
  target->PushAudio(buffer, length, pts_us);
}
