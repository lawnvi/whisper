import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:window_stream_native/window_stream_native.dart';

import '../core/window_stream_models.dart';
import '../pipeline/native_bootstrap.dart';
import 'window_stream_control.dart';

/// What a capture backend answers a request (catalog, icon, thumbnail,
/// launch) with: bytes, or a [WindowStreamCaptureCode] and, where the code
/// does not say it, the wire reason a viewer gets.
class CaptureResult {
  const CaptureResult(this.bytes) : error = 0, reason = null;

  CaptureResult.failed(this.error, {this.reason}) : bytes = Uint8List(0);

  final Uint8List bytes;
  final int error;

  /// A wire reason of the backend's own (`agentNotRunning`), else null.
  final String? reason;

  bool get ok => error == 0;

  /// The `reason` a viewer is told when this failed.
  String get wireReason =>
      reason ?? (ok ? '' : WindowStreamCaptureCode.wireReason(error));
}

/// Which window to capture and how, for [WindowCaptureBackend.captureStart].
class CaptureRequest {
  const CaptureRequest({
    required this.window,
    required this.viewerPeerId,
    required this.maxEdge,
    required this.fps,
    required this.bitRate,
    this.audio = false,
    this.viewportWidth = 0,
    this.viewportHeight = 0,
    this.viewportScale = 1,
    this.pixelRatio = 0,
  });

  /// A listed window, or [WindowCaptureBackend.appWindow]'s stand-in for
  /// an app to start.
  final RemoteWindowInfo window;
  final String viewerPeerId;
  final int maxEdge;
  final int fps;
  final int bitRate;

  /// The viewer asked for the window's sound. Backends that carry audio in
  /// the capture itself (Android, where the agent records per app) open it
  /// with sound; desktops turn it on with [WindowCaptureBackend.captureSetAudio].
  final bool audio;

  /// The viewer's screen, so a backend that lays the app out for it
  /// (Android's virtual display) opens at the right size; 0 keeps its own.
  final double viewportWidth;
  final double viewportHeight;
  final double viewportScale;

  /// The viewer's pixels per point; 0 when it did not say.
  final double pixelRatio;
}

/// Something a capture reports, as the native capture callback's kinds do.
/// [capture] is the id [WindowCaptureBackend.captureStart] returned, or 0
/// for news about no stream in particular.
sealed class CaptureEvent {
  const CaptureEvent(this.capture);

  final int capture;
}

class CaptureNote extends CaptureEvent {
  const CaptureNote(super.capture, this.text);

  final String text;
}

/// One H.264 access unit (Annex-B); [config] for parameter sets.
class CaptureVideo extends CaptureEvent {
  const CaptureVideo(
    super.capture,
    this.payload, {
    required this.ptsUs,
    required this.config,
    required this.key,
  });

  final Uint8List payload;
  final int ptsUs;
  final bool config;
  final bool key;
}

/// The picture's size changed.
class CaptureSize extends CaptureEvent {
  const CaptureSize(super.capture, this.width, this.height);

  final int width;
  final int height;
}

/// The window's keyboard focus moved: [flags] 1 into somewhere to type.
class CaptureTextFocus extends CaptureEvent {
  const CaptureTextFocus(super.capture, this.flags);

  final int flags;
}

/// The window's app sound: PCM s16le interleaved, pts on the video clock.
class CaptureAudio extends CaptureEvent {
  const CaptureAudio(
    super.capture,
    this.pcm, {
    required this.ptsUs,
    required this.rate,
    required this.channels,
  });

  final Uint8List pcm;
  final int ptsUs;
  final int rate;
  final int channels;
}

/// The capture ended: the window went away ([gone]) or it failed with
/// [code] (and, where the code does not say it, [reason]).
class CaptureEnded extends CaptureEvent {
  const CaptureEnded(
    super.capture, {
    this.gone = false,
    this.code = WindowStreamCaptureCode.unknown,
    this.reason,
  });

  final bool gone;
  final int code;
  final String? reason;
}

/// Where a host's windows come from. Mirrors the native capture ABI
/// (`wsn_capture_*`): desktops implement it with window_stream_native,
/// Android phones with whisper-agent ([PhoneCaptureBackend]).
abstract interface class WindowCaptureBackend {
  /// Windows can be offered at all (cheap; asked for every message).
  bool get supported;

  /// The viewer's input can be replayed.
  bool get inputPermitted;

  /// Opening an app without a window streams it straight away (Android:
  /// the agent starts it on the stream's display); otherwise the host
  /// launches it and waits for a window to list.
  bool get opensApps;

  /// Starts delivering [onEvent]; called once, early, even when
  /// [supported] is false.
  void attach(void Function(CaptureEvent event) onEvent);

  /// Why windows can't be offered, or null when they can.
  Future<WindowStreamFailureReason?> unavailableReason();

  /// JSON `{windows: [...], apps: [...], locked: bool}`.
  Future<CaptureResult> requestCatalog();
  Future<CaptureResult> requestIcon(String appId, {int size = 128});
  Future<CaptureResult> requestThumbnail(int windowId, int maxEdge);
  Future<CaptureResult> launchApp(String appId);

  /// For [opensApps] backends: a stand-in window for [appId] (id < 0).
  RemoteWindowInfo? appWindow(String appId);

  void captureCloseWindow(int windowId, int pid);

  /// Starts capturing; events about it carry the returned id.
  int captureStart(CaptureRequest request);
  void captureStop(int capture);
  void captureSetPaused(int capture, bool paused);
  void captureRequestKeyframe(int capture);
  void captureSetBusy(int capture, bool busy);
  void captureSetScreen(int capture, int screenKey);
  void captureSetViewport(
    int capture,
    double width,
    double height,
    double scale,
  );
  void captureSetInset(int capture, double fraction);

  /// The viewer's pixels per point: a host drawing the window at a higher
  /// density sends no more pixels than the viewer shows.
  void captureSetPixelRatio(int capture, double ratio);

  /// The encoder's bit rate from now on (the viewer chose a quality).
  void captureSetBitRate(int capture, int bitRate);

  /// [WsnCaptureAudio] mode; sound arrives as [CaptureAudio].
  void captureSetAudio(int capture, int mode);
  bool get audioSupported;

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
  });
}

/// The desktops' backend: window_stream_native over FFI. Requests answer
/// through the capture callback by request id.
class NativeCaptureBackend implements WindowCaptureBackend {
  WindowStreamNativeBindings? _bindings;
  NativeCallable<WsnCaptureCallbackNative>? _callback;
  void Function(CaptureEvent event)? _onEvent;
  final _pending = <int, Completer<CaptureResult>>{};

  static bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// The native answer is reused for a few seconds (a Linux helper that
  /// just came up is seen soon enough).
  @override
  bool get supported {
    final now = DateTime.now();
    final cached = _supported;
    if (cached != null && now.difference(_supportedAt) < _supportedLifetime) {
      return cached;
    }
    final bindings = WindowStreamNativeBootstrap.bindings();
    _supportedAt = now;
    return _supported = bindings != null && bindings.captureSupported() == 1;
  }

  bool? _supported;
  DateTime _supportedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _supportedLifetime = Duration(seconds: 5);

  @override
  bool get inputPermitted =>
      (_bindings ?? WindowStreamNativeBootstrap.bindings())
          ?.captureInputPermission() ==
      1;

  @override
  bool get opensApps => false;

  @override
  bool get audioSupported =>
      (_bindings ?? WindowStreamNativeBootstrap.bindings())
          ?.captureAudioSupported ==
      true;

  @override
  void attach(void Function(CaptureEvent event) onEvent) {
    _onEvent = onEvent;
    _attachNative();
  }

  /// The library with the capture callback set, whether or not capture is
  /// supported here: setting it is what makes the native put back windows
  /// an earlier run left stranded (between displays on macOS, off screen on
  /// Windows, on a virtual monitor on Linux).
  WindowStreamNativeBindings? _attachNative() {
    final existing = _bindings;
    if (existing != null) {
      return existing;
    }
    if (!_isDesktop) {
      return null;
    }
    final bindings = WindowStreamNativeBootstrap.bindings();
    if (bindings == null) {
      return null;
    }
    _bindings = bindings;
    _callback = NativeCallable<WsnCaptureCallbackNative>.listener(_onCapture);
    bindings.setCaptureCallback(_callback!.nativeFunction);
    return bindings;
  }

  WindowStreamNativeBindings? _ensureNative() =>
      supported ? _attachNative() : null;

  @override
  Future<WindowStreamFailureReason?> unavailableReason() async {
    if (!_isDesktop) {
      return WindowStreamFailureReason.hostUnsupported;
    }
    final bindings = _attachNative();
    if (bindings == null) {
      return WindowStreamFailureReason.hostUnsupported;
    }
    final result = await _requestWith(
      bindings,
      (native) => native.captureRequestCatalog(),
    );
    final fallback = supported
        ? null
        : WindowStreamFailureReason.hostUnsupported;
    if (result.ok) {
      return fallback;
    }
    // A native that does not explain itself (no answer, "unknown") is just
    // unsupported, or fine if it says it is supported.
    return windowStreamFailureForWire(
          WindowStreamCaptureCode.wireReason(result.error),
          stopping: true,
        ) ??
        fallback;
  }

  Future<CaptureResult> _request(
    int Function(WindowStreamNativeBindings) start,
  ) {
    final bindings = _ensureNative();
    if (bindings == null) {
      return Future.value(CaptureResult.failed(WsnCaptureError.unsupported));
    }
    return _requestWith(bindings, start);
  }

  Future<CaptureResult> _requestWith(
    WindowStreamNativeBindings bindings,
    int Function(WindowStreamNativeBindings) start,
  ) {
    final completer = Completer<CaptureResult>();
    final id = start(bindings);
    _pending[id] = completer;
    return completer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        _pending.remove(id);
        return CaptureResult.failed(WsnCaptureError.unknown);
      },
    );
  }

  @override
  Future<CaptureResult> requestCatalog() =>
      _request((native) => native.captureRequestCatalog());

  @override
  Future<CaptureResult> requestIcon(String appId, {int size = 128}) =>
      _request((native) => native.captureRequestIcon(appId, size: size));

  @override
  Future<CaptureResult> requestThumbnail(int windowId, int maxEdge) =>
      _request((native) => native.captureRequestThumbnail(windowId, maxEdge));

  @override
  Future<CaptureResult> launchApp(String appId) =>
      _request((native) => native.captureLaunchApp(appId));

  @override
  RemoteWindowInfo? appWindow(String appId) => null;

  @override
  void captureCloseWindow(int windowId, int pid) =>
      _ensureNative()?.captureCloseWindow(windowId, pid);

  @override
  int captureStart(CaptureRequest request) => _ensureNative()!.captureStart(
    request.window.id,
    request.window.pid,
    request.maxEdge,
    request.fps,
    request.bitRate,
  );

  @override
  void captureStop(int capture) => _bindings?.captureStop(capture);

  @override
  void captureSetPaused(int capture, bool paused) =>
      _bindings?.captureSetPaused(capture, paused ? 1 : 0);

  @override
  void captureRequestKeyframe(int capture) =>
      _bindings?.captureRequestKeyframe(capture);

  @override
  void captureSetBusy(int capture, bool busy) =>
      _bindings?.captureSetBusy(capture, busy ? 1 : 0);

  @override
  void captureSetScreen(int capture, int screenKey) =>
      _bindings?.captureSetScreen(capture, screenKey);

  @override
  void captureSetViewport(
    int capture,
    double width,
    double height,
    double scale,
  ) => _bindings?.captureSetViewport(capture, width, height, scale);

  @override
  void captureSetPixelRatio(int capture, double ratio) =>
      _bindings?.captureSetPixelRatio(capture, ratio);

  @override
  void captureSetBitRate(int capture, int bitRate) =>
      _bindings?.captureSetBitRate(capture, bitRate);

  @override
  void captureSetInset(int capture, double fraction) =>
      _bindings?.captureSetInset(capture, fraction);

  @override
  void captureSetAudio(int capture, int mode) =>
      _bindings?.captureSetAudio(capture, mode);

  @override
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
  }) => _bindings?.captureInput(
    capture,
    kind: kind,
    code: code,
    modifiers: modifiers,
    x: x,
    y: y,
    dx: dx,
    dy: dy,
    phase: phase,
    text: text,
  );

  void _onCapture(
    int id,
    int kind,
    Pointer<Uint8> data,
    int length,
    int ptsUs,
    int flags,
    int width,
    int height,
  ) {
    final bindings = _bindings;
    final bytes = bindings == null || data == nullptr
        ? Uint8List(0)
        : bindings.takeBytes(data, length);
    final pending = _pending.remove(id);
    if (pending != null) {
      pending.complete(
        kind == WsnCaptureEvent.failed
            ? CaptureResult.failed(flags)
            : CaptureResult(bytes),
      );
      return;
    }
    final emit = _onEvent;
    if (emit == null) {
      return;
    }
    switch (kind) {
      case WsnCaptureEvent.note:
        emit(CaptureNote(id, utf8.decode(bytes, allowMalformed: true)));
      case WsnCaptureEvent.packet:
        emit(
          CaptureVideo(
            id,
            bytes,
            ptsUs: ptsUs,
            config: flags & WsnPacket.config != 0,
            key: flags & WsnPacket.key != 0,
          ),
        );
      case WsnCaptureEvent.size:
        emit(CaptureSize(id, width, height));
      case WsnCaptureEvent.textFocus:
        emit(CaptureTextFocus(id, flags));
      case WsnCaptureEvent.audio:
        emit(
          CaptureAudio(id, bytes, ptsUs: ptsUs, rate: width, channels: height),
        );
      case WsnCaptureEvent.stopped:
        emit(CaptureEnded(id, gone: true));
      case WsnCaptureEvent.failed:
        emit(CaptureEnded(id, code: flags));
    }
  }
}
