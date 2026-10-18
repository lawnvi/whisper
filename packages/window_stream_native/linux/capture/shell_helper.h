// Whisper's GNOME Shell extension (com.vireen.Whisper.Shell1), seen from
// the capture thread: the only way to list, move and type into other apps'
// windows on GNOME Wayland. See
// assets/window_stream/gnome-shell/whisper-window-stream@vireen.com.

#ifndef WSN_CAPTURE_SHELL_HELPER_H_
#define WSN_CAPTURE_SHELL_HELPER_H_

#include <glib.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "capture/display_config.h"

// Failure codes 6–10, agreed with Dart for API version 1 (see
// lib/window_stream/core/window_stream_models.dart); the header gains them.
#ifndef WSN_CAPTURE_ERROR_HELPER
#define WSN_CAPTURE_ERROR_HELPER 6   // the GNOME Shell helper is not ready
#endif
#ifndef WSN_CAPTURE_ERROR_DESKTOP
#define WSN_CAPTURE_ERROR_DESKTOP 7  // not GNOME on Wayland
#endif
#ifndef WSN_CAPTURE_ERROR_LOCKED
#define WSN_CAPTURE_ERROR_LOCKED 10  // the session is locked
#endif

namespace wsn::capture {

// The extension's D-Bus protocol this build speaks.
constexpr uint32_t kHelperProtocol = 1;

enum class HelperState {
  kReady = 0,
  kNoBus,      // no session bus
  kMissing,    // the extension is not running (not installed, disabled, or needs a new login)
  kUntrusted,  // the bus name is owned by something that is not gnome-shell
  kOutdated,   // it speaks another protocol version (reinstall)
  kDenied,     // it refuses us (this executable is not in its allowed-exe list)
};

const char* HelperStateName(HelperState state);

struct HelperWindow {
  uint32_t id = 0;
  uint64_t window_id = 0;  // Mutter's window id (ScreenCast RecordWindow)
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
  int type = 0;  // Meta.WindowType (0 normal, 3 dialog, 4 modal dialog, 7 utility)
  uint32_t transient_for = 0;
};

class ShellHelper {
 public:
  static ShellHelper& Get();

  // Asks the bus (synchronously, capture thread) unless a recent answer is
  // still good; `force` asks again.
  HelperState Check(bool force = false);
  HelperState state() const { return state_; }

  // Signals from the extension (capture thread).
  struct Handlers {
    std::function<void()> windows_changed;
    std::function<void(uint32_t id)> window_gone;
    std::function<void(uint32_t id, bool focused)> text_focus;
    // The extension went away (disabled, shell restarted).
    std::function<void()> vanished;
  };
  void SetHandlers(Handlers handlers) { handlers_ = std::move(handlers); }

  using Done = std::function<void(bool ok, const std::string& error)>;

  void ListWindows(std::function<void(bool ok, std::vector<HelperWindow> windows, bool locked)> done);
  void Stage(uint32_t id, const Rect& rect, std::function<void(bool ok, Rect frame, const std::string& error)> done);
  void Unstage(uint32_t id, Done done = {});
  void Activate(uint32_t id);
  void Unminimize(uint32_t id);
  void Close(uint32_t id);
  void EvictStrangers(const Rect& rect, uint32_t keep);
  void SetFence(const Rect& rect, bool on);
  void Pointer(uint32_t kind, uint32_t button, double x, double y);
  void Scroll(double x, double y, double dx, double dy, uint32_t source, bool finish);
  void Key(uint32_t evdev, bool down);
  void Keyval(uint32_t keysym, bool down);
  void Text(const std::string& text);
  void WarpHome();
  void ReleaseInput();
  void Thumbnail(uint32_t id, int max_edge, std::function<void(bool ok, std::vector<uint8_t> jpeg)> done);

 private:
  ShellHelper() = default;
  void Watch();
  void Call(const char* method, GVariant* params, const char* reply_type,
            std::function<void(GVariant* reply, const std::string& error)> done, int timeout_ms = 5000);

  HelperState state_ = HelperState::kMissing;
  int64_t checked_at_ = 0;
  std::string owner_;
  bool watching_ = false;
  Handlers handlers_;
};

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_SHELL_HELPER_H_
