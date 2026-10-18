// The three callbacks Dart registers (input, window, capture) and the one
// place that calls them. Each emit copies what it hands over into heap
// memory the receiver releases with wsn_free, as window_stream_native.h
// promises. Emits may run on any thread, but never inside an FFI call made
// by Dart: from an entry point, hop with OnMain first.

#ifndef WSN_COMMON_CALLBACKS_H_
#define WSN_COMMON_CALLBACKS_H_

#include <cstdint>
#include <string>

#include "window_stream_native.h"

namespace wsn {

void SetInputCallback(wsn_input_callback callback);
void SetWindowCallback(wsn_window_callback callback);
void SetCaptureCallback(wsn_capture_callback callback);

// wsn_reset_all: forgets the input and window callbacks (capture keeps its
// own, it is cleared by its own reset).
void ClearSurfaceCallbacks();

void EmitWindow(int64_t surface, int32_t kind, double a = 0, double b = 0, double c = 0, double d = 0);

// `text` (may be null) is copied.
void EmitInput(int64_t surface, int32_t kind, int32_t code, int32_t modifiers, double x, double y, double dx,
               double dy, int32_t phase, const char* text);

// `data` (may be null) is copied.
void EmitCapture(int64_t id, int32_t kind, const uint8_t* data = nullptr, int32_t length = 0, int64_t pts_us = 0,
                 int32_t flags = 0, int32_t width = 0, int32_t height = 0);

// Like EmitCapture, but takes ownership of `data`, which must come from
// malloc. Freed here when no callback is registered.
void EmitCaptureOwned(int64_t id, int32_t kind, uint8_t* data, int32_t length, int64_t pts_us = 0,
                      int32_t flags = 0, int32_t width = 0, int32_t height = 0);

// UTF-8 text for Dart's window_stream.log (WSN_CAPTURE_NOTE, id 0 unless a
// request or capture is meant).
void EmitCaptureNote(int64_t id, const std::string& text);

bool HasCaptureCallback();

// Ids for capture requests and sessions (one sequence, never 0).
int64_t NewRequestId();

}  // namespace wsn

#endif  // WSN_COMMON_CALLBACKS_H_
