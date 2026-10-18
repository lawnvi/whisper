import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:window_stream_native/window_stream_native.dart';

import 'native_bootstrap.dart';
import 'texture_surface.dart';

/// What a streamed window looks like, independent of where it is drawn.
enum SurfaceVisual {
  live,
  connecting,
  paused,
  reconnecting,
  displaced,
  secure,
  exited,
  error,
}

sealed class SurfaceEvent {
  const SurfaceEvent(this.surface);

  final int surface;
}

class SurfaceCloseRequested extends SurfaceEvent {
  const SurfaceCloseRequested(super.surface);
}

class SurfaceFocusChanged extends SurfaceEvent {
  const SurfaceFocusChanged(super.surface, {required this.focused});

  final bool focused;
}

class SurfaceVisibilityChanged extends SurfaceEvent {
  const SurfaceVisibilityChanged(super.surface, {required this.visible});

  final bool visible;
}

class SurfaceFirstFrame extends SurfaceEvent {
  const SurfaceFirstFrame(super.surface);
}

class SurfaceNeedsKeyframe extends SurfaceEvent {
  const SurfaceNeedsKeyframe(super.surface);
}

/// A native window's content area changed size (the user resized it, it
/// went full screen or moved to a display with another scale) or was first
/// laid out: [width]×[height] in points, [scale] backing pixels per point.
class SurfaceResized extends SurfaceEvent {
  const SurfaceResized(
    super.surface, {
    required this.width,
    required this.height,
    required this.scale,
  });

  final double width;
  final double height;
  final double scale;
}

/// The window can't decode the stream; [missingDecoder] when there is no
/// decoder at all on this computer (Linux without FFmpeg), else a bad
/// frame it will get past with the next keyframe.
class SurfaceDecodeError extends SurfaceEvent {
  const SurfaceDecodeError(super.surface, {required this.missingDecoder});

  final bool missingDecoder;
}

/// The user acted on an overlay: resume a paused window, bring back a
/// displaced app.
class SurfaceAction extends SurfaceEvent {
  const SurfaceAction(super.surface, {required this.resume});

  final bool resume;
}

/// The user set the window's [volume] (0..1) with its own control.
class SurfaceVolumeChanged extends SurfaceEvent {
  const SurfaceVolumeChanged(super.surface, {required this.volume});

  final double volume;
}

/// Where streamed windows are shown: native desktop windows (FFI) or Flutter
/// textures (phones and tablets, where the viewer page draws the chrome).
abstract interface class StreamSurfaceBackend {
  /// Flutter widgets host the video (the UI pushes a viewer page).
  bool get flutterHosted;

  Stream<SurfaceEvent> get events;

  /// [reflow]: the other side lays the window out for this window's size,
  /// so it resizes freely (`WSN_FLAG_REFLOW`).
  Future<int> create({
    required String title,
    required int width,
    required int height,
    bool hud = false,
    bool reflow = false,
  });

  void setVisual(int surface, SurfaceVisual visual, String message);

  /// The window's sound level, 0 (muted) to 1. Phones and tablets leave it
  /// to the system volume.
  void setVolume(int surface, double volume);

  /// Words the native windows show themselves (their volume control).
  void setStrings({
    required String volume,
    required String mute,
    required String unmute,
  });
  void setHud(int surface, String text);

  /// The streamed app's icon (PNG), for the window's title bar and Dock.
  void setIcon(int surface, Uint8List png);
  void focus(int surface);
  Future<void> destroy(int surface);

  /// decoded fps, dropped, decode ms, queued, presented (empty if unknown).
  List<double> stats(int surface);
  bool snapshot(int surface, String path, {int maxEdge = 0});

  /// The last presented frame as JPEG, its longer edge at most [maxEdge]
  /// (0: full size); null when there is none yet or the platform can't.
  Future<Uint8List?> snapshotJpeg(int surface, {int maxEdge = 0});

  /// Visual state per surface, for Flutter-hosted chrome.
  ValueListenable<SurfaceVisual>? visualOf(int surface);

  static StreamSurfaceBackend? forPlatform() {
    if (Platform.isAndroid || Platform.isIOS) {
      return TextureSurfaceBackend();
    }
    final bindings = WindowStreamNativeBootstrap.bindings();
    return bindings == null ? null : NativeWindowBackend(bindings);
  }
}

class NativeWindowBackend implements StreamSurfaceBackend {
  NativeWindowBackend(this._bindings) {
    _callable = NativeCallable<WsnWindowCallbackNative>.listener(_onEvent);
    _bindings.setWindowCallback(_callable!.nativeFunction);
  }

  final WindowStreamNativeBindings _bindings;
  NativeCallable<WsnWindowCallbackNative>? _callable;
  final _events = StreamController<SurfaceEvent>.broadcast();

  @override
  bool get flutterHosted => false;

  @override
  Stream<SurfaceEvent> get events => _events.stream;

  void _onEvent(int surface, int kind, double a, double b, double c, double d) {
    final event = switch (kind) {
      WsnWindowEvent.closeRequested => SurfaceCloseRequested(surface),
      WsnWindowEvent.focus => SurfaceFocusChanged(surface, focused: a != 0),
      WsnWindowEvent.visibility => SurfaceVisibilityChanged(
        surface,
        visible: a != 0,
      ),
      WsnWindowEvent.firstFrame => SurfaceFirstFrame(surface),
      WsnWindowEvent.needKeyframe => SurfaceNeedsKeyframe(surface),
      WsnWindowEvent.action => SurfaceAction(surface, resume: a == 1),
      WsnWindowEvent.volume => SurfaceVolumeChanged(
        surface,
        volume: a.clamp(0.0, 1.0),
      ),
      WsnWindowEvent.decodeError => SurfaceDecodeError(
        surface,
        missingDecoder: a == 1,
      ),
      WsnWindowEvent.resized when a > 0 && b > 0 => SurfaceResized(
        surface,
        width: a,
        height: b,
        scale: c > 0 ? c : 1,
      ),
      _ => null,
    };
    if (event != null && !_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  Future<int> create({
    required String title,
    required int width,
    required int height,
    bool hud = false,
    bool reflow = false,
  }) async {
    return _bindings.surfaceCreate(
      title,
      videoWidth: width,
      videoHeight: height,
      flags: (hud ? WsnFlag.showHud : 0) | (reflow ? WsnFlag.reflow : 0),
    );
  }

  @override
  void setVisual(int surface, SurfaceVisual visual, String message) {
    _bindings.surfaceSetVisual(surface, visual.index, message);
  }

  @override
  void setVolume(int surface, double volume) =>
      _bindings.surfaceSetVolume(surface, volume);

  @override
  void setStrings({
    required String volume,
    required String mute,
    required String unmute,
  }) =>
      _bindings.setStrings({'volume': volume, 'mute': mute, 'unmute': unmute});

  @override
  void setHud(int surface, String text) =>
      _bindings.surfaceSetHud(surface, text);

  @override
  void setIcon(int surface, Uint8List png) =>
      _bindings.surfaceSetIcon(surface, png);

  @override
  void focus(int surface) => _bindings.surfaceFocus(surface);

  @override
  Future<void> destroy(int surface) async => _bindings.surfaceDestroy(surface);

  @override
  List<double> stats(int surface) => _bindings.surfaceStats(surface);

  @override
  bool snapshot(int surface, String path, {int maxEdge = 0}) =>
      _bindings.surfaceSnapshot(surface, path, maxEdge: maxEdge);

  @override
  Future<Uint8List?> snapshotJpeg(int surface, {int maxEdge = 0}) async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'wsn_snapshot_${surface}_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    try {
      if (!snapshot(surface, file.path, maxEdge: maxEdge) ||
          !await file.exists()) {
        return null;
      }
      return await file.readAsBytes();
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  @override
  ValueListenable<SurfaceVisual>? visualOf(int surface) => null;

  void dispose() {
    _bindings.setWindowCallback(nullptr);
    _callable?.close();
    _callable = null;
    unawaited(_events.close());
  }
}

/// Phones and tablets: each surface is a hardware decoder feeding a Flutter
/// texture; the surface id is the texture id.
class TextureSurfaceBackend implements StreamSurfaceBackend {
  final _events = StreamController<SurfaceEvent>.broadcast();
  final _surfaces = <int, TextureStreamSurface>{};
  final _visuals = <int, ValueNotifier<SurfaceVisual>>{};
  final _subscriptions = <int, StreamSubscription<TextureSurfaceEvent>>{};
  final _firstFrame = <int>{};

  @override
  bool get flutterHosted => true;

  @override
  Stream<SurfaceEvent> get events => _events.stream;

  @override
  Future<int> create({
    required String title,
    required int width,
    required int height,
    bool hud = false,
    bool reflow = false,
  }) async {
    final surface = await TextureStreamSurface.create(
      width: width,
      height: height,
    );
    final id = surface.textureId;
    _surfaces[id] = surface;
    _visuals[id] = ValueNotifier(SurfaceVisual.connecting);
    _subscriptions[id] = surface.events.listen((event) {
      switch (event) {
        case TextureNeedsKeyframe():
          _events.add(SurfaceNeedsKeyframe(id));
        case TextureVideoSize():
          if (_firstFrame.add(id)) {
            _events.add(SurfaceFirstFrame(id));
          }
        case TextureDecoderError():
          _events.add(SurfaceNeedsKeyframe(id));
      }
    });
    return id;
  }

  @override
  void setVisual(int surface, SurfaceVisual visual, String message) {
    _visuals[surface]?.value = visual;
  }

  /// The phone's volume buttons set it.
  @override
  void setVolume(int surface, double volume) {}

  @override
  void setStrings({
    required String volume,
    required String mute,
    required String unmute,
  }) {}

  @override
  void setHud(int surface, String text) {}

  /// The viewer page shows its own chrome.
  @override
  void setIcon(int surface, Uint8List png) {}

  @override
  void focus(int surface) {}

  @override
  Future<void> destroy(int surface) async {
    await _subscriptions.remove(surface)?.cancel();
    _visuals.remove(surface)?.dispose();
    _firstFrame.remove(surface);
    await _surfaces.remove(surface)?.dispose();
  }

  /// What the decoder last pushed (iOS reports it every second).
  @override
  List<double> stats(int surface) =>
      _surfaces[surface]?.latestStats ?? const [];

  @override
  bool snapshot(int surface, String path, {int maxEdge = 0}) => false;

  @override
  Future<Uint8List?> snapshotJpeg(int surface, {int maxEdge = 0}) async =>
      _surfaces[surface]?.snapshot(maxEdge: maxEdge);

  @override
  ValueListenable<SurfaceVisual>? visualOf(int surface) => _visuals[surface];

  /// Lets the viewer page tell the coordinator the user closed or tapped.
  void userClosed(int surface) => _events.add(SurfaceCloseRequested(surface));

  void userResumed(int surface) =>
      _events.add(SurfaceAction(surface, resume: true));

  void visibilityChanged(int surface, {required bool visible}) =>
      _events.add(SurfaceVisibilityChanged(surface, visible: visible));
}
