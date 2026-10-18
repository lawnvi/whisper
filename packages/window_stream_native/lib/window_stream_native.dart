/// dart:ffi bindings for the C ABI in `src/window_stream_native.h`.
///
/// The library is loaded lazily per isolate: the UI isolate uses it to create
/// and control windows, the stream isolate uses it to push media.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Mirrors `WSN_API_VERSION`. Bump both together.
const int wsnApiVersion = 1;

abstract final class WsnFlag {
  static const int showHud = 0x1;

  /// The window resizes freely; the other side lays the streamed window out
  /// for it (`WSN_FLAG_REFLOW`).
  static const int reflow = 0x2;
}

abstract final class WsnPacket {
  static const int config = 0x1;
  static const int key = 0x2;
}

abstract final class WsnVisual {
  static const int live = 0;
  static const int connecting = 1;
  static const int paused = 2;
  static const int reconnecting = 3;
  static const int displaced = 4;
  static const int secure = 5;
  static const int exited = 6;
  static const int error = 7;
}

abstract final class WsnAudioCodec {
  static const int pcmS16le = 1;
}

abstract final class WsnInputKind {
  static const int pointerDown = 1;
  static const int pointerMove = 2;
  static const int pointerUp = 3;
  static const int scroll = 4;
  static const int keyDown = 5;
  static const int keyUp = 6;
  static const int text = 7;
  static const int pointerCancel = 8;
}

abstract final class WsnModifier {
  static const int shift = 0x1;
  static const int control = 0x2;
  static const int option = 0x4;
  static const int command = 0x8;
  static const int capsLock = 0x10;
  static const int function = 0x20;
}

abstract final class WsnWindowEvent {
  static const int closeRequested = 1;
  static const int focus = 2;
  static const int visibility = 3;
  static const int resized = 4;
  static const int firstFrame = 5;
  static const int needKeyframe = 6;
  static const int decodeError = 7;
  static const int action = 8;

  /// a = the volume the user set in the window, 0..1.
  static const int volume = 9;
}

typedef WsnInputCallbackNative = Void Function(
  Int64 surface,
  Int32 kind,
  Int32 code,
  Int32 modifiers,
  Double x,
  Double y,
  Double dx,
  Double dy,
  Int32 phase,
  Pointer<Char> text,
);

typedef WsnCaptureCallbackNative = Void Function(
  Int64 id,
  Int32 kind,
  Pointer<Uint8> data,
  Int32 length,
  Int64 ptsUs,
  Int32 flags,
  Int32 width,
  Int32 height,
);

abstract final class WsnCaptureEvent {
  static const int packet = 1;
  static const int failed = 2;
  static const int size = 3;
  static const int catalog = 4;
  static const int thumbnail = 5;
  static const int icon = 6;
  static const int stopped = 7;
  static const int launched = 8;
  static const int note = 9;

  /// flags = 1 when the window's keyboard focus is somewhere to type.
  static const int textFocus = 10;

  /// data = PCM s16le interleaved, width = sample rate, height = channels,
  /// pts on the same clock as the video's.
  static const int audio = 11;
}

/// Modes of `wsn_capture_set_audio`.
abstract final class WsnCaptureAudio {
  static const int off = 0;

  /// The app's sound is sent and still plays here.
  static const int on = 1;

  /// The app's sound is sent and silent here, where the platform can.
  static const int onSilentHere = 2;
}

abstract final class WsnCaptureError {
  static const int unknown = 1;
  static const int unsupported = 2;
  static const int permission = 3;
  static const int notFound = 4;
  static const int encoder = 5;
  static const int helper = 6;
  static const int desktop = 7;
  static const int elevated = 8;
  static const int protectedContent = 9;
  static const int locked = 10;
}

typedef WsnWindowCallbackNative = Void Function(
  Int64 surface,
  Int32 kind,
  Double a,
  Double b,
  Double c,
  Double d,
);

final class WindowStreamNativeBindings {
  WindowStreamNativeBindings._(DynamicLibrary library)
      : apiVersion = library.lookupFunction<Int32 Function(), int Function()>(
            'wsn_api_version'),
        resetAll = library.lookupFunction<Void Function(), void Function()>(
          'wsn_reset_all',
        ),
        setInputCallback = library.lookupFunction<
                Void Function(Pointer<NativeFunction<WsnInputCallbackNative>>),
                void Function(Pointer<NativeFunction<WsnInputCallbackNative>>)>(
            'wsn_set_input_callback'),
        setWindowCallback = library.lookupFunction<
                Void Function(Pointer<NativeFunction<WsnWindowCallbackNative>>),
                void Function(
                    Pointer<NativeFunction<WsnWindowCallbackNative>>)>(
            'wsn_set_window_callback'),
        free = library.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('wsn_free'),
        _surfaceCreate = library.lookupFunction<
            Int64 Function(Pointer<Utf8>, Int32, Int32, Int32),
            int Function(Pointer<Utf8>, int, int, int)>('wsn_surface_create'),
        _surfaceSetTitle = library.lookupFunction<
            Void Function(Int64, Pointer<Utf8>),
            void Function(int, Pointer<Utf8>)>('wsn_surface_set_title'),
        _surfaceSetVisual = library.lookupFunction<
            Void Function(Int64, Int32, Pointer<Utf8>),
            void Function(int, int, Pointer<Utf8>)>('wsn_surface_set_visual'),
        _surfaceSetIcon = library.lookupFunction<
            Void Function(Int64, Pointer<Uint8>, Int32),
            void Function(int, Pointer<Uint8>, int)>('wsn_surface_set_icon'),
        _surfaceSetHud = library.lookupFunction<
            Void Function(Int64, Pointer<Utf8>),
            void Function(int, Pointer<Utf8>)>('wsn_surface_set_hud'),
        surfaceFocus =
            library.lookupFunction<Void Function(Int64), void Function(int)>(
          'wsn_surface_focus',
        ),
        surfaceDestroy =
            library.lookupFunction<Void Function(Int64), void Function(int)>(
          'wsn_surface_destroy',
        ),
        _surfaceStats = library.lookupFunction<
            Int32 Function(Int64, Pointer<Double>, Int32),
            int Function(int, Pointer<Double>, int)>('wsn_surface_stats'),
        _surfaceSnapshot = library.lookupFunction<
            Int32 Function(Int64, Pointer<Utf8>, Int32),
            int Function(int, Pointer<Utf8>, int)>('wsn_surface_snapshot'),
        setCaptureCallback =
            library.lookupFunction<
                    Void Function(
                        Pointer<NativeFunction<WsnCaptureCallbackNative>>),
                    void Function(
                        Pointer<NativeFunction<WsnCaptureCallbackNative>>)>(
                'wsn_set_capture_callback'),
        captureSupported =
            library.lookupFunction<Int32 Function(), int Function()>(
          'wsn_capture_supported',
        ),
        captureInputPermission =
            library.lookupFunction<Int32 Function(), int Function()>(
          'wsn_capture_input_permission',
        ),
        captureRequestCatalog =
            library.lookupFunction<Int64 Function(), int Function()>(
          'wsn_capture_request_catalog',
        ),
        _captureRequestIcon = library.lookupFunction<
            Int64 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)>('wsn_capture_request_icon'),
        captureRequestThumbnail = library.lookupFunction<
            Int64 Function(Uint32, Int32), int Function(int, int)>(
          'wsn_capture_request_thumbnail',
        ),
        _captureLaunchApp = library.lookupFunction<
            Int64 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)>('wsn_capture_launch_app'),
        captureStart = library.lookupFunction<
            Int64 Function(Uint32, Int32, Int32, Int32, Int32),
            int Function(int, int, int, int, int)>('wsn_capture_start'),
        captureStop =
            library.lookupFunction<Void Function(Int64), void Function(int)>(
          'wsn_capture_stop',
        ),
        captureCloseWindow = library.lookupFunction<
            Void Function(Uint32, Int32), void Function(int, int)>(
          'wsn_capture_close_window',
        ),
        captureSetScreen = library.lookupFunction<Void Function(Int64, Int64),
            void Function(int, int)>(
          'wsn_capture_set_screen',
        ),
        captureSetViewport = library.lookupFunction<
            Void Function(Int64, Double, Double, Double),
            void Function(int, double, double, double)>(
          'wsn_capture_set_viewport',
        ),
        captureSetInset = library.lookupFunction<Void Function(Int64, Double),
            void Function(int, double)>('wsn_capture_set_inset'),
        captureRequestKeyframe =
            library.lookupFunction<Void Function(Int64), void Function(int)>(
          'wsn_capture_request_keyframe',
        ),
        captureSetBusy = library.lookupFunction<Void Function(Int64, Int32),
            void Function(int, int)>(
          'wsn_capture_set_busy',
        ),
        captureSetPaused = library.lookupFunction<Void Function(Int64, Int32),
            void Function(int, int)>(
          'wsn_capture_set_paused',
        ),
        captureSetBitRate = library.lookupFunction<Void Function(Int64, Int32),
            void Function(int, int)>(
          'wsn_capture_set_bit_rate',
        ),
        // Added after API version 1: a build without it streams no sound.
        _captureSetAudio = library.providesSymbol('wsn_capture_set_audio')
            ? library.lookupFunction<Void Function(Int64, Int32),
                void Function(int, int)>('wsn_capture_set_audio')
            : null,
        _captureSetPixelRatio =
            library.providesSymbol('wsn_capture_set_pixel_ratio')
                ? library.lookupFunction<Void Function(Int64, Double),
                    void Function(int, double)>('wsn_capture_set_pixel_ratio')
                : null,
        _surfaceSetVolume = library.providesSymbol('wsn_surface_set_volume')
            ? library.lookupFunction<Void Function(Int64, Double),
                void Function(int, double)>('wsn_surface_set_volume')
            : null,
        _setStrings = library.providesSymbol('wsn_set_strings')
            ? library.lookupFunction<Void Function(Pointer<Utf8>),
                void Function(Pointer<Utf8>)>('wsn_set_strings')
            : null,
        _captureInput = library.lookupFunction<
            Void Function(
              Int64,
              Int32,
              Int32,
              Int32,
              Double,
              Double,
              Double,
              Double,
              Int32,
              Pointer<Utf8>,
            ),
            void Function(
              int,
              int,
              int,
              int,
              double,
              double,
              double,
              double,
              int,
              Pointer<Utf8>,
            )>('wsn_capture_input'),
        bufferAlloc = library.lookupFunction<Pointer<Uint8> Function(Int32),
            Pointer<Uint8> Function(int)>('wsn_buffer_alloc', isLeaf: true),
        videoPush = library.lookupFunction<
            Void Function(Int64, Pointer<Uint8>, Int32, Int64, Int32),
            void Function(
                int, Pointer<Uint8>, int, int, int)>('wsn_video_push'),
        audioConfigure = library.lookupFunction<
            Void Function(Int64, Int32, Int32, Int32),
            void Function(int, int, int, int)>('wsn_audio_configure'),
        audioPush = library.lookupFunction<
            Void Function(Int64, Pointer<Uint8>, Int32, Int64),
            void Function(int, Pointer<Uint8>, int, int)>('wsn_audio_push');

  static WindowStreamNativeBindings? _instance;

  /// Returns null on platforms without a native implementation yet.
  static WindowStreamNativeBindings? load() {
    final existing = _instance;
    if (existing != null) {
      return existing;
    }
    final library = _openLibrary();
    if (library == null) {
      return null;
    }
    final bindings = WindowStreamNativeBindings._(library);
    if (bindings.apiVersion() != wsnApiVersion) {
      return null;
    }
    return _instance = bindings;
  }

  static DynamicLibrary? _openLibrary() {
    try {
      if (Platform.isMacOS) {
        return DynamicLibrary.open(
          'window_stream_native.framework/window_stream_native',
        );
      }
      if (Platform.isWindows) {
        return DynamicLibrary.open('window_stream_native.dll');
      }
      if (Platform.isLinux) {
        return DynamicLibrary.open('libwindow_stream_native.so');
      }
    } on ArgumentError {
      return null;
    }
    return null;
  }

  final int Function() apiVersion;
  final void Function() resetAll;
  final void Function(Pointer<NativeFunction<WsnInputCallbackNative>>)
      setInputCallback;
  final void Function(Pointer<NativeFunction<WsnWindowCallbackNative>>)
      setWindowCallback;
  final void Function(Pointer<Void>) free;
  final int Function(Pointer<Utf8>, int, int, int) _surfaceCreate;
  final void Function(int, Pointer<Utf8>) _surfaceSetTitle;
  final void Function(int, int, Pointer<Utf8>) _surfaceSetVisual;
  final void Function(int, Pointer<Utf8>) _surfaceSetHud;
  final void Function(int, Pointer<Uint8>, int) _surfaceSetIcon;
  final void Function(int) surfaceFocus;
  final void Function(int) surfaceDestroy;
  final int Function(int, Pointer<Double>, int) _surfaceStats;
  final int Function(int, Pointer<Utf8>, int) _surfaceSnapshot;
  final void Function(Pointer<NativeFunction<WsnCaptureCallbackNative>>)
      setCaptureCallback;
  final int Function() captureSupported;
  final int Function() captureInputPermission;
  final int Function() captureRequestCatalog;
  final int Function(Pointer<Utf8>, int) _captureRequestIcon;
  final int Function(int, int) captureRequestThumbnail;
  final int Function(Pointer<Utf8>) _captureLaunchApp;

  /// window id, pid, max edge (px), fps, bit rate → capture id.
  final int Function(int, int, int, int, int) captureStart;
  final void Function(int) captureStop;

  /// 1 while the network is behind: frames are skipped, not queued.
  final void Function(int, int) captureSetBusy;

  /// Closes window [id] of process [pid] as its close button would.
  final void Function(int, int) captureCloseWindow;

  /// Which viewer the capture shows on; one viewer's windows share a display.
  final void Function(int, int) captureSetScreen;

  /// The viewer's screen (its points) and text scale: the window is staged
  /// on a virtual display at that size where the platform can.
  final void Function(int, double, double, double) captureSetViewport;

  /// The viewer's keyboard covers this fraction of the picture's bottom.
  final void Function(int, double) captureSetInset;
  final void Function(int) captureRequestKeyframe;
  final void Function(int, int) captureSetPaused;
  final void Function(int, int) captureSetBitRate;
  final void Function(int, int)? _captureSetAudio;

  /// Whether this build captures windows' sound ([captureSetAudio]).
  bool get captureAudioSupported => _captureSetAudio != null;

  /// The captured window's app sound: [WsnCaptureAudio] mode. Arrives as
  /// [WsnCaptureEvent.audio].
  void captureSetAudio(int capture, int mode) =>
      _captureSetAudio?.call(capture, mode);
  final void Function(
    int,
    int,
    int,
    int,
    double,
    double,
    double,
    double,
    int,
    Pointer<Utf8>,
  ) _captureInput;
  final void Function(int, double)? _captureSetPixelRatio;
  final void Function(int, double)? _surfaceSetVolume;
  final void Function(Pointer<Utf8>)? _setStrings;

  /// The viewer's pixels per point for [capture]; a build without it keeps
  /// the host's own density.
  void captureSetPixelRatio(int capture, double ratio) =>
      _captureSetPixelRatio?.call(capture, ratio);

  /// Whether this build's windows have a volume control.
  bool get surfaceVolumeSupported => _surfaceSetVolume != null;

  /// The window's sound level, 0 (muted) to 1.
  void surfaceSetVolume(int surface, double volume) =>
      _surfaceSetVolume?.call(surface, volume.clamp(0.0, 1.0));

  /// Words the native windows show (`volume`, `mute`, `unmute`).
  void setStrings(Map<String, String> strings) {
    final call = _setStrings;
    if (call == null) {
      return;
    }
    _withUtf8(jsonEncode(strings), call);
  }

  final Pointer<Uint8> Function(int) bufferAlloc;
  final void Function(int, Pointer<Uint8>, int, int, int) videoPush;
  final void Function(int, int, int, int) audioConfigure;
  final void Function(int, Pointer<Uint8>, int, int) audioPush;

  int surfaceCreate(
    String title, {
    required int videoWidth,
    required int videoHeight,
    int flags = 0,
  }) {
    return _withUtf8(
      title,
      (pointer) => _surfaceCreate(pointer, videoWidth, videoHeight, flags),
    );
  }

  void surfaceSetTitle(int surface, String title) {
    _withUtf8(title, (pointer) => _surfaceSetTitle(surface, pointer));
  }

  void surfaceSetVisual(int surface, int visual, String message) {
    _withUtf8(
        message, (pointer) => _surfaceSetVisual(surface, visual, pointer));
  }

  void surfaceSetHud(int surface, String text) {
    _withUtf8(text, (pointer) => _surfaceSetHud(surface, pointer));
  }

  /// The streamed app's icon as PNG (copied before returning).
  void surfaceSetIcon(int surface, Uint8List png) {
    if (png.isEmpty) {
      return;
    }
    final pointer = malloc<Uint8>(png.length);
    try {
      pointer.asTypedList(png.length).setAll(0, png);
      _surfaceSetIcon(surface, pointer, png.length);
    } finally {
      malloc.free(pointer);
    }
  }

  /// decoded fps, dropped frames, decode ms, queued frames, presented
  /// frames; then, where the platform reports them, audio restarts, audio
  /// resyncs, audio lead ms and audio target latency ms.
  List<double> surfaceStats(int surface) {
    final out = calloc<Double>(9);
    try {
      final count = _surfaceStats(surface, out, 9);
      return [for (var i = 0; i < count; i++) out[i]];
    } finally {
      calloc.free(out);
    }
  }

  /// Writes the last presented frame as JPEG. Returns true on success.
  bool surfaceSnapshot(int surface, String path, {int maxEdge = 0}) {
    return _withUtf8(
            path, (pointer) => _surfaceSnapshot(surface, pointer, maxEdge)) ==
        0;
  }

  int captureRequestIcon(String appId, {int size = 128}) {
    return _withUtf8(appId, (pointer) => _captureRequestIcon(pointer, size));
  }

  /// Starts or reopens an installed app; answers [WsnCaptureEvent.launched].
  int captureLaunchApp(String appId) {
    return _withUtf8(appId, _captureLaunchApp);
  }

  void captureInput(
    int capture, {
    required int kind,
    int code = 0,
    int modifiers = 0,
    double x = 0,
    double y = 0,
    double dx = 0,
    double dy = 0,
    int phase = 0,
    String? text,
  }) {
    if (text == null) {
      _captureInput(
          capture, kind, code, modifiers, x, y, dx, dy, phase, nullptr);
      return;
    }
    _withUtf8(
      text,
      (pointer) => _captureInput(
          capture, kind, code, modifiers, x, y, dx, dy, phase, pointer),
    );
  }

  /// Copies and releases a callback data buffer.
  Uint8List takeBytes(Pointer<Uint8> data, int length) {
    if (data == nullptr) {
      return Uint8List(0);
    }
    try {
      return Uint8List.fromList(data.asTypedList(length));
    } finally {
      free(data.cast());
    }
  }

  /// Reads and releases a callback text pointer.
  String? takeText(Pointer<Char> text) {
    if (text == nullptr) {
      return null;
    }
    try {
      return text.cast<Utf8>().toDartString();
    } finally {
      free(text.cast());
    }
  }

  static T _withUtf8<T>(String value, T Function(Pointer<Utf8>) body) {
    final pointer = value.toNativeUtf8();
    try {
      return body(pointer);
    } finally {
      malloc.free(pointer);
    }
  }
}
