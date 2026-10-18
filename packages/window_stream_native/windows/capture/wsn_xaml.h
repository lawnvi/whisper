// Pointer input for XAML / WinUI content in a staged window.
//
// WinUI 3 islands (Explorer's tabs, address bar, search box and command
// bar; Notepad's menus; their popup menus) and system XAML islands take
// pointer input only from the real pointer, routed by the compositor: a
// posted WM_LBUTTONDOWN does nothing, and the real pointer cannot reach a
// window that is off-screen. UI Automation can, and it is how a click on
// such content is replayed here: the element under the point is found by
// its bounding rectangle (ElementFromPoint does not work off-screen) and
// "clicked" through its pattern — Invoke, Toggle, ExpandCollapse,
// SelectionItem, or focus for a text box (whose typing then goes in as
// WM_CHAR to the island's input site, which XAML accepts while inactive).
//
// One instance per injector; used on the session thread only (COM MTA).
#pragma once

#include "wsn_util.h"

#include <memory>
#include <string>

namespace wsn {

// [hwnd] hosts XAML content (an island bridge, a XAML popup window or an
// input site), which ignores posted mouse messages.
bool IsXamlHost(HWND hwnd);

class XamlInput {
 public:
  XamlInput();
  ~XamlInput();
  XamlInput(const XamlInput&) = delete;
  XamlInput& operator=(const XamlInput&) = delete;

  struct Result {
    bool acted = false;
    bool focused_text = false;   // a text box took the focus (type into [input_site])
    HWND input_site = nullptr;   // where WM_CHAR / WM_KEYDOWN for it go
    std::string what;            // for the log: "Invoke Button 排序"
    RECT element{};              // screen rectangle of the element acted on (a popup it opens goes below it)
    bool used_alternate = false; // found at [alternate]: [element] is in XAML's coordinates
    bool uwp = false;            // a UWP core window: its text boxes take only real keyboard input
  };
  // A left click at [screen] on the XAML content hosted by [host]. When
  // nothing there responds, [alternate] is tried (the point in the
  // coordinates XAML still believes for a popup window we moved).
  Result Click(HWND host, POINT screen, const POINT* alternate = nullptr);
  // The visible content of a XAML popup window (its menu or list), which
  // WinUI may draw anywhere inside a bigger window (at the bottom when it
  // decided to open upwards). False when it cannot tell.
  bool ContentRect(HWND popup, RECT* out);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace wsn
