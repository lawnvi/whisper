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

#include "capture/helper.h"

namespace wsn::capture {

// The extension's D-Bus protocol this build speaks.
constexpr uint32_t kHelperProtocol = 1;

class ShellHelper : public WindowHelper {
 public:
  static ShellHelper& Get();

  HelperState Check(bool force = false) override;
  HelperState state() const { return state_; }

  void ListWindows(std::function<void(bool ok, std::vector<HelperWindow> windows, bool locked)> done) override;
  void Stage(uint32_t id, const Rect& rect,
             std::function<void(bool ok, Rect frame, const std::string& error)> done) override;
  void Unstage(uint32_t id, Done done = {}) override;
  void Activate(uint32_t id) override;
  void Unminimize(uint32_t id) override;
  void Close(uint32_t id) override;
  void EvictStrangers(const Rect& rect, uint32_t keep) override;
  void SetFence(const Rect& rect, bool on) override;
  void Pointer(uint32_t kind, uint32_t button, double x, double y) override;
  void Scroll(double x, double y, double dx, double dy, uint32_t source, bool finish) override;
  void Key(uint32_t evdev, bool down) override;
  void Keyval(uint32_t keysym, bool down) override;
  void Text(const std::string& text) override;
  void WarpHome() override;
  void ReleaseInput() override;
  void Thumbnail(uint32_t id, int max_edge, std::function<void(bool ok, std::vector<uint8_t> jpeg)> done) override;

 private:
  ShellHelper() = default;
  void Watch();
  void Call(const char* method, GVariant* params, const char* reply_type,
            std::function<void(GVariant* reply, const std::string& error)> done, int timeout_ms = 5000);

  HelperState state_ = HelperState::kMissing;
  int64_t checked_at_ = 0;
  std::string owner_;
  bool watching_ = false;
};

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_SHELL_HELPER_H_
