// C ABI shared by every platform implementation of window_stream_native.
//
// One "surface" is one streamed window on the receiving desktop. Dart creates
// it from the UI isolate, then the stream isolate pushes encoded video and
// audio into it from a background thread. Native code owns decoding,
// presentation and input capture, and reports input and window events back
// through two callbacks registered with NativeCallable.listener.
//
// Threading: every function may be called from any thread. Implementations
// hop to their UI thread for windowing work and keep one serial decode queue
// per surface. Callbacks are always invoked asynchronously from a native
// thread, never from inside one of these calls (a Dart NativeCallable must
// not run while its caller is in an FFI call).
//
// Memory: buffers passed to wsn_video_push / wsn_audio_push must come from
// wsn_buffer_alloc; ownership moves to native code. Text passed to callbacks
// is heap-allocated by native code and must be released with wsn_free.

#ifndef WINDOW_STREAM_NATIVE_H
#define WINDOW_STREAM_NATIVE_H

#include <stdint.h>

#if defined(_WIN32) && defined(WSN_BUILDING)
#define WSN_API __declspec(dllexport)
#elif defined(WSN_BUILDING)
#define WSN_API __attribute__((visibility("default")))
#else
#define WSN_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define WSN_API_VERSION 1

// Surface creation flags.
#define WSN_FLAG_SHOW_HUD 0x1
// The other side lays the streamed window out for this window's size, so the
// window resizes freely (the picture letterboxed until it follows). When the
// picture's shape still differs about 2 s after a resize, the window settles
// to that shape; a new shape from the other side is followed as before.
// Without it the window keeps the picture's shape while resizing.
#define WSN_FLAG_REFLOW 0x2

// Video packet flags.
#define WSN_PACKET_CONFIG 0x1
#define WSN_PACKET_KEY 0x2

// Visual states shown over the video.
#define WSN_VISUAL_LIVE 0
#define WSN_VISUAL_CONNECTING 1
#define WSN_VISUAL_PAUSED 2
#define WSN_VISUAL_RECONNECTING 3
#define WSN_VISUAL_DISPLACED 4
#define WSN_VISUAL_SECURE 5
#define WSN_VISUAL_EXITED 6
#define WSN_VISUAL_ERROR 7

// Audio codecs.
#define WSN_AUDIO_PCM_S16LE 1

// Input event kinds (wsn_input_callback).
#define WSN_INPUT_POINTER_DOWN 1
#define WSN_INPUT_POINTER_MOVE 2
#define WSN_INPUT_POINTER_UP 3
#define WSN_INPUT_SCROLL 4
#define WSN_INPUT_KEY_DOWN 5
#define WSN_INPUT_KEY_UP 6
#define WSN_INPUT_TEXT 7
#define WSN_INPUT_POINTER_CANCEL 8

// Modifier bits.
#define WSN_MOD_SHIFT 0x1
#define WSN_MOD_CONTROL 0x2
#define WSN_MOD_OPTION 0x4
#define WSN_MOD_COMMAND 0x8
#define WSN_MOD_CAPS_LOCK 0x10
#define WSN_MOD_FUNCTION 0x20

// Window event kinds (wsn_window_callback).
#define WSN_WINDOW_CLOSE_REQUESTED 1
#define WSN_WINDOW_FOCUS 2          // a = 1 focused, 0 not
#define WSN_WINDOW_VISIBILITY 3     // a = 1 visible, 0 occluded or minimized
#define WSN_WINDOW_RESIZED 4        // a, b = content size in points, c = backing scale
#define WSN_WINDOW_FIRST_FRAME 5
#define WSN_WINDOW_NEED_KEYFRAME 6
#define WSN_WINDOW_DECODE_ERROR 7   // a = OSStatus or platform error code
#define WSN_WINDOW_ACTION 8         // a = action id (1 resume, 2 bring back)
#define WSN_WINDOW_VOLUME 9         // a = volume the user set in the window, 0..1

typedef void (*wsn_input_callback)(int64_t surface, int32_t kind, int32_t code,
                                   int32_t modifiers, double x, double y,
                                   double dx, double dy, int32_t phase,
                                   char *text);
typedef void (*wsn_window_callback)(int64_t surface, int32_t kind, double a,
                                    double b, double c, double d);

WSN_API int32_t wsn_api_version(void);
WSN_API void wsn_reset_all(void);
WSN_API void wsn_set_input_callback(wsn_input_callback callback);
WSN_API void wsn_set_window_callback(wsn_window_callback callback);
WSN_API void wsn_free(void *pointer);

WSN_API int64_t wsn_surface_create(const char *title, int32_t video_width,
                           int32_t video_height, int32_t flags);
WSN_API void wsn_surface_set_title(int64_t surface, const char *title);
WSN_API void wsn_surface_set_visual(int64_t surface, int32_t visual,
                            const char *message);
WSN_API void wsn_surface_set_hud(int64_t surface, const char *text);
// The streamed app's icon (PNG, copied before returning): title bar and the
// window's Dock tile when minimized.
WSN_API void wsn_surface_set_icon(int64_t surface, const uint8_t *png,
                                  int32_t length);
WSN_API void wsn_surface_focus(int64_t surface);
WSN_API void wsn_surface_destroy(int64_t surface);
// Fills up to `count` doubles: decoded fps, dropped frames, decode ms,
// queued frames, presented frames, then (macOS) audio restarts, audio
// resyncs, audio lead ms, audio target latency ms. Returns the number
// written.
WSN_API int32_t wsn_surface_stats(int64_t surface, double *out, int32_t count);

// Writes the last presented frame as JPEG (quality 0.85), scaled so its
// longer edge is at most `max_edge` pixels (0 = full size). Returns 0 on
// success.
WSN_API int32_t wsn_surface_snapshot(int64_t surface, const char *path,
                             int32_t max_edge);

// Added after API version 1; Dart looks these up only if present.
//
// The window's sound level, 0 (muted) to 1 (as sent), for sound playing now
// and configured later. The window also offers its own control (title bar
// or corner button) and reports changes with WSN_WINDOW_VOLUME.
WSN_API void wsn_surface_set_volume(int64_t surface, double volume);
// Words the native windows show, as UTF-8 JSON (copied):
// {"volume": "Volume", "mute": "Mute", "unmute": "Unmute"}. Missing keys
// keep the English word.
WSN_API void wsn_set_strings(const char *json);

WSN_API uint8_t *wsn_buffer_alloc(int32_t length);
WSN_API void wsn_video_push(int64_t surface, uint8_t *buffer, int32_t length,
                    int64_t pts_us, int32_t flags);
WSN_API void wsn_audio_configure(int64_t surface, int32_t codec, int32_t sample_rate,
                         int32_t channels);
WSN_API void wsn_audio_push(int64_t surface, uint8_t *buffer, int32_t length,
                    int64_t pts_us);

// ---------------------------------------------------------------------------
// Capture: this desktop as a window source.
//
// Results arrive through the capture callback, keyed by the id returned from
// the request. `data` (if any) is heap-allocated; release it with wsn_free.

#define WSN_CAPTURE_PACKET 1     // data = Annex-B H.264, flags = WSN_PACKET_*
#define WSN_CAPTURE_FAILED 2     // flags = WSN_CAPTURE_ERROR_*
#define WSN_CAPTURE_SIZE 3       // width, height of the encoded video
#define WSN_CAPTURE_CATALOG 4    // data = UTF-8 JSON {"windows": [...], "apps": [...]}
#define WSN_CAPTURE_THUMBNAIL 5  // data = JPEG
#define WSN_CAPTURE_ICON 6       // data = PNG
#define WSN_CAPTURE_STOPPED 7    // the window went away or capture stopped
#define WSN_CAPTURE_LAUNCHED 8   // an app asked for by wsn_capture_launch_app runs
#define WSN_CAPTURE_NOTE 9       // data = UTF-8 text for the log
#define WSN_CAPTURE_TEXT_FOCUS 10 // flags = 1: focus is where text is typed
#define WSN_CAPTURE_AUDIO 11     // data = PCM s16le interleaved; width = sample rate,
                                 // height = channels; pts_us on the video's clock

#define WSN_CAPTURE_ERROR_UNKNOWN 1
#define WSN_CAPTURE_ERROR_UNSUPPORTED 2
#define WSN_CAPTURE_ERROR_PERMISSION 3
#define WSN_CAPTURE_ERROR_NOT_FOUND 4
#define WSN_CAPTURE_ERROR_ENCODER 5
#define WSN_CAPTURE_ERROR_HELPER 6     // Linux: GNOME Shell helper missing/disabled/needs re-login
#define WSN_CAPTURE_ERROR_DESKTOP 7    // Linux: not a GNOME Wayland session
#define WSN_CAPTURE_ERROR_ELEVATED 8   // Windows: the window's process is elevated (UIPI)
#define WSN_CAPTURE_ERROR_PROTECTED 9  // the window excludes itself from capture
#define WSN_CAPTURE_ERROR_LOCKED 10    // the desktop is locked / on the secure desktop

typedef void (*wsn_capture_callback)(int64_t id, int32_t kind, uint8_t *data,
                                     int32_t length, int64_t pts_us,
                                     int32_t flags, int32_t width,
                                     int32_t height);

WSN_API void wsn_set_capture_callback(wsn_capture_callback callback);
WSN_API int32_t wsn_capture_supported(void);
// 1 when input can be injected (macOS: Accessibility permission).
WSN_API int32_t wsn_capture_input_permission(void);
WSN_API int64_t wsn_capture_request_catalog(void);
WSN_API int64_t wsn_capture_request_icon(const char *app_id, int32_t size);
WSN_API int64_t wsn_capture_request_thumbnail(uint32_t window_id, int32_t max_edge);
// Starts (or reopens) an installed app so it gets a window to stream.
WSN_API int64_t wsn_capture_launch_app(const char *app_id);
WSN_API int64_t wsn_capture_start(uint32_t window_id, int32_t pid, int32_t max_edge,
                          int32_t fps, int32_t bit_rate);
WSN_API void wsn_capture_stop(int64_t capture);
// Closes a window as its own close button would (the app may ask to save).
WSN_API void wsn_capture_close_window(uint32_t window_id, int32_t pid);
// Which viewer the capture shows on: one viewer's windows share one display.
WSN_API void wsn_capture_set_screen(int64_t capture, int64_t key);
// The viewer's screen in its points and its text scale (Aa): the window is
// staged on a virtual display at that size where the platform can.
WSN_API void wsn_capture_set_viewport(int64_t capture, double width,
                              double height, double scale);
// The viewer's keyboard covers this fraction of the picture's bottom (0 when
// it is down): the window stops above it.
WSN_API void wsn_capture_set_inset(int64_t capture, double bottom);
WSN_API void wsn_capture_request_keyframe(int64_t capture);
// The network is behind: skip encoding until it catches up, then send the
// newest picture.
WSN_API void wsn_capture_set_busy(int64_t capture, int32_t busy);
WSN_API void wsn_capture_set_paused(int64_t capture, int32_t paused);
WSN_API void wsn_capture_set_bit_rate(int64_t capture, int32_t bit_rate);
// The captured window's app sound (added after API version 1; Dart looks it
// up optionally): WSN_CAPTURE_AUDIO_OFF, _ON (it still plays here) or
// _ON_SILENT_HERE (it plays only on the viewer, where the platform can).
// Delivered as WSN_CAPTURE_AUDIO events until turned off or stopped.
#define WSN_CAPTURE_AUDIO_OFF 0
#define WSN_CAPTURE_AUDIO_ON 1
#define WSN_CAPTURE_AUDIO_ON_SILENT_HERE 2
WSN_API void wsn_capture_set_audio(int64_t capture, int32_t mode);
// The viewer's pixels per point (1 on most Windows and Linux screens, 2 on a
// Retina Mac), set before or after wsn_capture_set_viewport (optional
// symbol): a host that draws the window at a higher density sends no more
// pixels than the viewer can show. 0 or unset keeps the host's own density.
WSN_API void wsn_capture_set_pixel_ratio(int64_t capture, double ratio);
// Replays viewer input on the captured window; kinds and modifiers as for
// wsn_input_callback, coordinates as fractions of the window.
WSN_API void wsn_capture_input(int64_t capture, int32_t kind, int32_t code,
                       int32_t modifiers, double x, double y, double dx,
                       double dy, int32_t phase, const char *text);

#ifdef __cplusplus
}
#endif

#endif
