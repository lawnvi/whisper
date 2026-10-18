// Shared plumbing of window_stream_native.dll on Windows.
//
// Layout of this directory tree:
//   common/    UI thread, callback registry, logging, string and time helpers
//              (used by both halves)
//   receiver/  streamed windows on this PC: surface window, decoder,
//              presenter, audio, input capture
//   capture/   this PC as a window source (WGC, encoder, injection, catalog)
//   exports_surface.cpp / exports_capture.cpp  the C ABI of
//              src/window_stream_native.h, thin shims over the two halves
//
// Threading rules (see the header): every export may be called from any
// thread. Window work hops to the one UI thread with RunOnUiThread. Callbacks
// into Dart must never run inside an export (a NativeCallable must not
// re-enter an FFI call): emit them from the UI thread, a worker thread, or
// PostCallback.

#pragma once

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>

#include "window_stream_native.h"

#define WSN_EXPORT extern "C" __declspec(dllexport)

namespace wsn {

// ---------------------------------------------------------------- strings

std::wstring Utf8ToWide(const char* text);
std::wstring Utf8ToWide(const std::string& text);
// `length` < 0: NUL-terminated (the NUL is not part of the result).
std::string WideToUtf8(const wchar_t* text, int length = -1);
std::string WideToUtf8(const std::wstring& text);

// True when the environment variable is "1" (test switches such as
// WSN_FORCE_GDI, WSN_FORCE_SW_DECODE).
bool EnvFlag(const wchar_t* name);

// ---------------------------------------------------------------- time

// Monotonic clock (QueryPerformanceCounter).
double NowSeconds();
int64_t NowMicros();

// ---------------------------------------------------------------- logging

// One line of lifecycle logging (no user content): OutputDebugString and
// %LOCALAPPDATA%\Whisper\window_stream\native.log (kept under 1 MB, one
// previous file is kept as native.1.log). printf-style.
void Log(const char* format, ...);

// ---------------------------------------------------------------- UI thread

// Starts the UI thread once: COM single-threaded apartment, Media Foundation
// started, a message-only window, and a message loop that also serves every
// window created on it. Safe to call from any thread, any number of times.
void EnsureUiThread();
bool IsUiThread();
DWORD UiThreadId();
// The message-only window of the UI thread (nullptr before EnsureUiThread).
HWND UiMessageWindow();
// Queues `work` on the UI thread (starting it if needed). Returns false if it
// could not be queued; `work` is then dropped without running.
bool RunOnUiThread(std::function<void()> work);
// Runs `work` on the UI thread and waits for it (runs inline when already on
// the UI thread). Never call while holding a lock the UI thread may take.
void RunOnUiThreadAndWait(std::function<void()> work);

// ---------------------------------------------------------------- callbacks

void SetInputCallback(wsn_input_callback callback);
void SetWindowCallback(wsn_window_callback callback);
void SetCaptureCallback(wsn_capture_callback callback);
// Forgets the input and window callbacks (wsn_reset_all).
void ClearSurfaceCallbacks();
bool HasCaptureCallback();

void EmitWindow(int64_t surface, int32_t kind, double a = 0, double b = 0,
                double c = 0, double d = 0);
// `text` (may be null) is copied into a malloc'd string Dart frees.
void EmitInput(int64_t surface, int32_t kind, int32_t code, int32_t modifiers,
               double x, double y, double dx, double dy, int32_t phase,
               const std::string* text);
// `data` (may be null) is copied into a malloc'd buffer Dart frees with
// wsn_free. Runs the callback on the calling thread.
void EmitCapture(int64_t id, int32_t kind, const void* data, int32_t length,
                 int64_t pts_us = 0, int32_t flags = 0, int32_t width = 0,
                 int32_t height = 0);
// Same as EmitCapture, but `data` is already malloc'd and ownership moves to
// Dart (no copy). Freed here when no callback is registered.
void EmitCaptureOwned(int64_t id, int32_t kind, uint8_t* data, int32_t length,
                      int64_t pts_us = 0, int32_t flags = 0, int32_t width = 0,
                      int32_t height = 0);
// Runs `work` on one serial background thread: the place to emit results
// that are ready while still inside an export (e.g. an immediate failure).
// Preserves order.
void PostCallback(std::function<void()> work);
// Unique ids for capture requests and sessions.
int64_t NextRequestId();

// ---------------------------------------------------------------- hooks

// Implemented by the capture half (exports_capture.cpp / capture/*):
// stop every capture session and restore staged windows. Called by
// wsn_reset_all.
void ResetAllCaptures();

}  // namespace wsn
