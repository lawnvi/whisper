// ScreenCast on KDE Plasma (capture thread): virtual outputs and window
// streams through KWin's zkde_screencast protocol (capture/kwin_wayland.h).
//
// KWin lays a new output out beside the others and picks its scale itself;
// ours go one row below the real outputs with a gap, where the user's
// pointer cannot reach them (KWin keeps the pointer on the outputs; only an
// absolute move gets there), and get the scale asked for. Below, not
// beside: the outer edges belong to keyboard-and-mouse sharing.

#ifndef WSN_CAPTURE_KWIN_SCREENCAST_H_
#define WSN_CAPTURE_KWIN_SCREENCAST_H_

#include <memory>
#include <string>

#include "capture/screencast.h"

namespace wsn::capture {

std::unique_ptr<ScreenCast> KWinVirtualCast(int pixel_width, int pixel_height, double scale, int fps,
                                            PipeWireStream::FrameCallback on_frame, ScreenCast::Callbacks callbacks);

std::unique_ptr<ScreenCast> KWinWindowCast(const std::string& uuid, int fps, PipeWireStream::FrameCallback on_frame,
                                           ScreenCast::Callbacks callbacks);

// Ours are named "Virtual-Whisper-<n>".
bool IsKWinVirtualOutput(const std::string& name);

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_KWIN_SCREENCAST_H_
