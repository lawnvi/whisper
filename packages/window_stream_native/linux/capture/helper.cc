#include "capture/helper.h"

#include <glib.h>

#include <cstring>

#include "capture/kwin_helper.h"
#include "capture/shell_helper.h"

namespace wsn::capture {

namespace {

bool Contains(const char* haystack, const char* needle) {
  if (haystack == nullptr) return false;
  gchar* lower = g_ascii_strdown(haystack, -1);
  bool found = std::strstr(lower, needle) != nullptr;
  g_free(lower);
  return found;
}

}  // namespace

Desktop CurrentDesktop() {
  static Desktop desktop = [] {
    const char* type = g_getenv("XDG_SESSION_TYPE");
    bool wayland = (type != nullptr && std::strcmp(type, "wayland") == 0) || g_getenv("WAYLAND_DISPLAY") != nullptr;
    if (!wayland) return Desktop::kNone;
    const char* current = g_getenv("XDG_CURRENT_DESKTOP");
    if (Contains(current, "gnome")) return Desktop::kGnome;
    if (Contains(current, "kde")) return Desktop::kKde;
    return Desktop::kNone;
  }();
  return desktop;
}

const char* HelperStateName(HelperState state) {
  switch (state) {
    case HelperState::kReady: return "ready";
    case HelperState::kNoBus: return "no-bus";
    case HelperState::kMissing: return "missing";
    case HelperState::kUntrusted: return "untrusted";
    case HelperState::kOutdated: return "outdated";
    case HelperState::kDenied: return "denied";
  }
  return "?";
}

int32_t HelperFailure(HelperState state) {
  return CurrentDesktop() == Desktop::kKde && state == HelperState::kDenied ? WSN_CAPTURE_ERROR_DESKTOP
                                                                            : WSN_CAPTURE_ERROR_HELPER;
}

WindowHelper& WindowHelper::Get() {
  if (CurrentDesktop() == Desktop::kKde) return KWinHelper::Get();
  return ShellHelper::Get();
}

}  // namespace wsn::capture
