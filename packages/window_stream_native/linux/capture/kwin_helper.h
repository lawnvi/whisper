// Window flow's helper on KDE Plasma (capture thread). Windows are listed,
// moved and focused by a KWin script this side loads
// (capture/kwin_script.h), which talks back over Bus(); input goes through
// KWin's fake-input protocol and thumbnails through KWin's ScreenShot2
// (capture/kwin_wayland.h). Nothing to install and no login: KWin grants
// the protocols to the executable a .desktop file names, which this writes
// when no installed one does.

#ifndef WSN_CAPTURE_KWIN_HELPER_H_
#define WSN_CAPTURE_KWIN_HELPER_H_

#include <gio/gio.h>

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "capture/helper.h"

namespace wsn::capture {

class KWinHelper : public WindowHelper {
 public:
  static KWinHelper& Get();

  HelperState Check(bool force = false) override;

  void ListWindows(std::function<void(bool ok, std::vector<HelperWindow> windows, bool locked)> done) override;
  void Stage(uint32_t id, const Rect& rect,
             std::function<void(bool ok, Rect frame, const std::string& error)> done) override;
  void Unstage(uint32_t id, Done done = {}) override;
  void Activate(uint32_t id) override;
  void Unminimize(uint32_t id) override;
  void Close(uint32_t id) override;
  void EvictStrangers(const Rect& rect, uint32_t keep) override;
  // Ours are out of the pointer's reach already (capture/kwin_screencast.h).
  void SetFence(const Rect&, bool) override {}
  void Pointer(uint32_t kind, uint32_t button, double x, double y) override;
  void Scroll(double x, double y, double dx, double dy, uint32_t source, bool finish) override;
  void Key(uint32_t evdev, bool down) override;
  void Keyval(uint32_t keysym, bool down) override;
  void Text(const std::string& text) override;
  void WarpHome() override;
  void ReleaseInput() override;
  void Thumbnail(uint32_t id, int max_edge, std::function<void(bool ok, std::vector<uint8_t> jpeg)> done) override;

  // From the bus (the script's calls).
  void OnPoll(GVariant* reply, GDBusMethodInvocation* invocation);
  void OnEvent(GVariant* event);

 private:
  using Result = std::function<void(GVariant* result, const std::string& error)>;
  struct Command {
    uint32_t seq = 0;
    GVariant* body = nullptr;  // a{sv}, owned
    Result done;
    int64_t sent_at = 0;
  };

  KWinHelper() = default;
  bool Connect(int64_t written_at, std::string* why);
  bool LoadScript(std::string* why);
  bool Register();
  // A command for the script; `done` gets its a{sv} answer (null on error).
  void Send(GVariant* body, Result done);
  void Pump();
  void Expire();
  void FailAll(const std::string& why);
  // Input waits while the window is being activated or the user's pointer
  // position is being read: in order, after them.
  void Input(std::function<void()> action, bool pointer);
  void Flush();
  // An installed app with this .desktop id, and its name.
  bool AppInfo(const std::string& app_id, std::string* name);

  HelperState state_ = HelperState::kMissing;
  int64_t checked_at_ = 0;
  guint object_id_ = 0;
  std::string script_name_;
  bool script_running_ = false;  // its first Poll arrived
  int64_t script_loaded_at_ = 0;
  GDBusMethodInvocation* held_ = nullptr;  // the script's Poll, waiting for a command
  int64_t held_at_ = 0;
  uint32_t next_seq_ = 1;
  std::deque<Command> queue_;
  Command inflight_;
  guint expire_timer_ = 0;

  uint32_t active_ = 0;  // the active window (script events)
  int waits_ = 0;        // activations and pointer reads under way
  std::deque<std::function<void()>> input_;
  bool has_home_ = false;
  bool reading_home_ = false;
  double home_x_ = 0;
  double home_y_ = 0;
  std::set<uint32_t> buttons_;
  std::set<uint32_t> keys_;
  std::set<uint32_t> keysyms_;

  std::map<uint32_t, std::string> uuids_;  // id -> KWin's window id, from the last list
  std::map<std::string, std::string> app_names_;  // installed apps' names by .desktop id
};

// Makes sure a .desktop file vouches for this executable to KWin (the
// screencast, input and screenshot protocols); writes Whisper's own one in
// ~/.local/share/applications when no installed file does. False when it
// could not. `written_at` gets when this process last wrote it (monotonic
// microseconds, 0 for never).
bool EnsureKWinPermission(std::string* why, int64_t* written_at = nullptr);

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_KWIN_HELPER_H_
