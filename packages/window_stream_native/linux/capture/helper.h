// What the capture side needs from the desktop to list, move and type into
// other apps' windows, seen from the capture thread. On Wayland only the
// compositor can do that: Whisper's GNOME Shell extension on GNOME
// (capture/shell_helper.h), a KWin script and KWin's own Wayland protocols
// on KDE Plasma (capture/kwin_helper.h).

#ifndef WSN_CAPTURE_HELPER_H_
#define WSN_CAPTURE_HELPER_H_

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "capture/display_config.h"

// Failure codes 6–10, agreed with Dart for API version 1 (see
// lib/window_stream/core/window_stream_models.dart); the header gains them.
#ifndef WSN_CAPTURE_ERROR_HELPER
#define WSN_CAPTURE_ERROR_HELPER 6   // the desktop's helper is not ready
#endif
#ifndef WSN_CAPTURE_ERROR_DESKTOP
#define WSN_CAPTURE_ERROR_DESKTOP 7  // not GNOME or KDE Plasma on Wayland
#endif
#ifndef WSN_CAPTURE_ERROR_LOCKED
#define WSN_CAPTURE_ERROR_LOCKED 10  // the session is locked
#endif

namespace wsn::capture {

// The desktops this side can be a window source on.
enum class Desktop { kNone, kGnome, kKde };

// GNOME or KDE Plasma on Wayland, else kNone (from the environment; cached).
Desktop CurrentDesktop();

enum class HelperState {
  kReady = 0,
  kNoBus,      // no session bus
  kMissing,    // the helper is not running (GNOME: not installed, disabled, or needs a new login)
  kUntrusted,  // the bus name is owned by something that is not gnome-shell
  kOutdated,   // it speaks another protocol version (reinstall)
  kDenied,     // it refuses us (GNOME: not in its allowed-exe list; KDE: KWin withholds its protocols)
};

const char* HelperStateName(HelperState state);

// The failure Dart is told about for a helper that is not ready: on KDE,
// KWin withholding its protocols means this desktop cannot be a source
// (there is nothing to install or log in again for).
int32_t HelperFailure(HelperState state);

struct HelperWindow {
  uint32_t id = 0;
  uint64_t window_id = 0;  // Mutter's window id (ScreenCast RecordWindow)
  std::string uuid;        // KWin's window id (zkde_screencast stream_window)
  std::string title;
  std::string app_id;  // .desktop id, "" for windows of no known app
  std::string app_name;
  int pid = 0;
  Rect frame;
  int monitor = -1;
  bool minimized = false;
  bool focused = false;
  bool maximized = false;
  bool fullscreen = false;
  bool on_current_workspace = true;
  bool staged = false;
  int type = 0;  // 0 normal, 3 dialog, 4 modal dialog, 7 utility (Meta.WindowType)
  uint32_t transient_for = 0;
};

class WindowHelper {
 public:
  // The helper of this desktop (GNOME's when the desktop is neither).
  static WindowHelper& Get();

  virtual ~WindowHelper() = default;

  // Asks (synchronously, capture thread) unless a recent answer is still
  // good; `force` asks again.
  virtual HelperState Check(bool force = false) = 0;

  // Events from the desktop (capture thread).
  struct Handlers {
    std::function<void()> windows_changed;
    std::function<void(uint32_t id)> window_gone;
    std::function<void(uint32_t id, bool focused)> text_focus;
    // The helper went away (disabled, shell or KWin restarted).
    std::function<void()> vanished;
  };
  void SetHandlers(Handlers handlers) { handlers_ = std::move(handlers); }

  using Done = std::function<void(bool ok, const std::string& error)>;

  virtual void ListWindows(std::function<void(bool ok, std::vector<HelperWindow> windows, bool locked)> done) = 0;
  // Moves the window onto `rect` (layout coordinates); `frame` is where it
  // settled.
  virtual void Stage(uint32_t id, const Rect& rect,
                     std::function<void(bool ok, Rect frame, const std::string& error)> done) = 0;
  // Puts a staged window back exactly as it was.
  virtual void Unstage(uint32_t id, Done done = {}) = 0;
  virtual void Activate(uint32_t id) = 0;
  virtual void Unminimize(uint32_t id) = 0;
  virtual void Close(uint32_t id) = 0;
  // Other apps' windows that landed on `rect` go back to a real monitor.
  virtual void EvictStrangers(const Rect& rect, uint32_t keep) = 0;
  // Keeps the user's own pointer out of `rect`.
  virtual void SetFence(const Rect& rect, bool on) = 0;
  // WSN_INPUT_POINTER_* at layout coordinates; button 0 primary, 1
  // secondary, 2 middle.
  virtual void Pointer(uint32_t kind, uint32_t button, double x, double y) = 0;
  // Wheel clicks (source 1) or pixels (2 finger, 3 continuous); positive dy
  // scrolls down.
  virtual void Scroll(double x, double y, double dx, double dy, uint32_t source, bool finish) = 0;
  virtual void Key(uint32_t evdev, bool down) = 0;
  virtual void Keyval(uint32_t keysym, bool down) = 0;
  virtual void Text(const std::string& text) = 0;
  // The pointer goes back to where the user left it.
  virtual void WarpHome() = 0;
  virtual void ReleaseInput() = 0;
  virtual void Thumbnail(uint32_t id, int max_edge, std::function<void(bool ok, std::vector<uint8_t> jpeg)> done) = 0;

 protected:
  Handlers handlers_;
};

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_HELPER_H_
