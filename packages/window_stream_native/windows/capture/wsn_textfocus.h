// Watches where a streamed window's keyboard focus is and says whenever it
// moves into or out of somewhere to type (an edit box, a rich-text area, a
// terminal, a UI Automation edit element), so a phone viewer can raise or
// lower its keyboard by itself. The Windows counterpart of macOS
// TextFocusWatcher; only the captured window's own controls count.
//
// A staged window is a background window, so the system focus is somewhere
// else. Its thread still keeps a focus of its own (the control our posted
// click focused), which GetGUIThreadInfo reports; the caret and the
// control's class decide most cases, UI Automation the rest (XAML, WPF).
// Web content (Chromium, Firefox) is not asked: querying it turns on its
// whole accessibility tree, which slows the app down. Those need the
// viewer's keyboard button, as on macOS.
//
// Runs on its own thread: checks shortly after input (Kick), on focus
// WinEvents from the app, and once a second otherwise. Reports changes only.
//
// The same thread also reports each top-level window the app shows (menus,
// drop-downs, flyouts, dialogs) through [on_popup], so the session can bring
// a popup of a staged window next to it, into the stream.
#pragma once

#include "wsn_util.h"

#include <atomic>
#include <functional>
#include <thread>

namespace wsn {

class TextFocusWatcher {
 public:
  TextFocusWatcher(HWND window, std::function<void(bool typing)> on_change);
  ~TextFocusWatcher();
  TextFocusWatcher(const TextFocusWatcher&) = delete;
  TextFocusWatcher& operator=(const TextFocusWatcher&) = delete;

  void Start();
  // Ends the watch; waits for the thread (at most one UI Automation call).
  void Stop();
  // Input happened: re-check soon. [hint] is the control the viewer last
  // pressed on (used when the window's thread reports no focus).
  void Kick(HWND hint);

  // Set before Start(); called on the watcher thread.
  std::function<void(HWND popup)> on_popup;

 private:
  void Run();

  const HWND window_;
  std::function<void(bool)> on_change_;
  HANDLE kick_event_ = nullptr;
  std::atomic<bool> stop_{false};
  std::atomic<HWND> hint_{nullptr};
  std::thread thread_;
};

}  // namespace wsn
