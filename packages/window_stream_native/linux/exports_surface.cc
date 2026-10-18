// C ABI, receiver half: streamed windows shown on this desktop
// (window_stream_native.h). Thin shims over receiver/surface.

#include <cstdlib>
#include <memory>

#include "common/callbacks.h"
#include "common/lifecycle.h"
#include "receiver/surface.h"
#include "receiver/ui_strings.h"
#include "window_stream_native.h"

using wsn::FindSurface;
using wsn::Surface;

int32_t wsn_api_version(void) { return WSN_API_VERSION; }

void wsn_reset_all(void) {
  for (const std::shared_ptr<Surface>& surface : wsn::TakeAllSurfaces()) surface->Stop();
  wsn::ClearSurfaceCallbacks();
  wsn::ResetCaptures();
}

void wsn_set_input_callback(wsn_input_callback callback) { wsn::SetInputCallback(callback); }

void wsn_set_window_callback(wsn_window_callback callback) { wsn::SetWindowCallback(callback); }

void wsn_free(void* pointer) { std::free(pointer); }

int64_t wsn_surface_create(const char* title, int32_t video_width, int32_t video_height, int32_t flags) {
  auto surface = std::make_shared<Surface>(wsn::NextSurfaceId(), title != nullptr ? title : "", video_width,
                                           video_height, (flags & WSN_FLAG_SHOW_HUD) != 0,
                                           (flags & WSN_FLAG_REFLOW) != 0);
  wsn::AddSurface(surface);
  surface->Start();
  return surface->id();
}

void wsn_surface_set_title(int64_t surface, const char* title) {
  if (auto target = FindSurface(surface)) target->SetTitle(title != nullptr ? title : "");
}

void wsn_surface_set_visual(int64_t surface, int32_t visual, const char* message) {
  if (auto target = FindSurface(surface)) target->SetVisual(visual, message != nullptr ? message : "");
}

void wsn_surface_set_hud(int64_t surface, const char* text) {
  if (auto target = FindSurface(surface)) target->SetHud(text != nullptr ? text : "");
}

void wsn_surface_set_icon(int64_t surface, const uint8_t* png, int32_t length) {
  if (auto target = FindSurface(surface)) target->SetIcon(png, length);
}

void wsn_surface_focus(int64_t surface) {
  if (auto target = FindSurface(surface)) target->Focus();
}

void wsn_surface_destroy(int64_t surface) {
  if (auto target = wsn::TakeSurface(surface)) target->Stop();
}

int32_t wsn_surface_stats(int64_t surface, double* out, int32_t count) {
  auto target = FindSurface(surface);
  return target == nullptr || out == nullptr || count <= 0 ? 0 : target->Stats(out, count);
}

int32_t wsn_surface_snapshot(int64_t surface, const char* path, int32_t max_edge) {
  auto target = FindSurface(surface);
  if (target == nullptr || path == nullptr) return -1;
  return target->Snapshot(path, max_edge);
}

void wsn_surface_set_volume(int64_t surface, double volume) {
  if (auto target = FindSurface(surface)) target->SetVolume(volume);
}

void wsn_set_strings(const char* json) {
  wsn::SetUiStrings(json);
  wsn::RefreshSurfaceStrings();
}

uint8_t* wsn_buffer_alloc(int32_t length) {
  return length > 0 ? static_cast<uint8_t*>(std::malloc(static_cast<size_t>(length))) : nullptr;
}

void wsn_video_push(int64_t surface, uint8_t* buffer, int32_t length, int64_t pts_us, int32_t flags) {
  if (buffer == nullptr) return;
  auto target = FindSurface(surface);
  if (target == nullptr || length <= 0) {
    std::free(buffer);
    return;
  }
  target->PushVideo(buffer, length, pts_us, flags);
}

void wsn_audio_configure(int64_t surface, int32_t codec, int32_t sample_rate, int32_t channels) {
  if (codec != WSN_AUDIO_PCM_S16LE || sample_rate <= 0 || channels <= 0) return;
  if (auto target = FindSurface(surface)) target->ConfigureAudio(sample_rate, channels);
}

void wsn_audio_push(int64_t surface, uint8_t* buffer, int32_t length, int64_t pts_us) {
  if (buffer == nullptr) return;
  auto target = FindSurface(surface);
  if (target == nullptr || length <= 0) {
    std::free(buffer);
    return;
  }
  target->PushAudio(buffer, length, pts_us);
}
