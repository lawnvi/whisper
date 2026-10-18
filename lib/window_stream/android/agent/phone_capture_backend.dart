import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'dart:ui' show PlatformDispatcher, Size;

import 'package:flutter/foundation.dart';

import '../../core/media_packet.dart';
import '../../core/window_input_event.dart';
import '../../core/window_stream_models.dart';
import '../../pipeline/native_input_decoder.dart';
import '../../remote/window_stream_control.dart';
import '../../remote/window_stream_host.dart';
import '../../window_stream_log.dart';
import '../scrcpy/scrcpy_input_mapper.dart';
import '../scrcpy/scrcpy_protocol.dart';
import 'agent_control_client.dart';
import 'agent_link.dart';
import 'agent_wire.dart';
import 'phone_agent_link.dart';

/// This phone's own apps and tasks offered to other Whisper peers, with
/// whisper-agent (running as the shell user) as the capture and input
/// backend. Desktops without adb reach the phone only through this: the
/// agent streams a task on a virtual display sized to the viewer's window,
/// exactly as the adb path does, and the picture, sound and input travel
/// the ordinary `/window` route.
///
/// Media never leaves the agent decoded: the agent's H.264 (scrcpy framing)
/// is reframed into [CaptureVideo] and its per-app PCM into [CaptureAudio],
/// both passed straight to the host. One agent serves every viewer at once,
/// each with its own stream number and virtual display.
class PhoneCaptureBackend implements WindowCaptureBackend {
  PhoneCaptureBackend._();

  static final PhoneCaptureBackend shared = PhoneCaptureBackend._();

  /// The viewer sees this when the agent is not running: "open Whisper on
  /// the phone and turn on window flow".
  static const String agentNotRunning = 'agentNotRunning';

  void Function(CaptureEvent event)? _onEvent;
  AgentLinkInfo? _link;
  AgentControlClient? _control;
  Future<AgentControlClient?>? _connecting;
  Set<String> _capabilities = const {};
  StreamSubscription<AgentLinkInfo?>? _linkChanges;

  /// Whether a connect attempt lately found the agent. [supported] is read
  /// synchronously for every control message, so it reports this cached
  /// answer and refreshes it in the background.
  bool _available = false;

  final _streams = <int, _PhoneStream>{};
  final _apps = <String, String>{}; // package -> label
  int _nextCapture = 1;
  final _random = Random();

  @override
  bool get supported {
    // The feature exists on this phone whether or not the agent is up right
    // now: browse still answers, with [agentNotRunning] when it is down, so
    // a desktop shows "open Whisper and turn on window flow" guidance
    // instead of leaving the phone off its list.
    unawaited(_ensureConnected());
    return true;
  }

  @override
  bool get inputPermitted => true;

  @override
  bool get opensApps => true;

  @override
  bool get audioSupported => _capabilities.contains('perAppAudio');

  @override
  void attach(void Function(CaptureEvent event) onEvent) {
    _onEvent = onEvent;
    _linkChanges ??= PhoneAgentLink.changes.listen((link) {
      // A fresh agent: drop the old connection so the next use reconnects.
      _link = link;
      _available = false;
      final control = _control;
      _control = null;
      unawaited(control?.close());
    });
    unawaited(_ensureConnected());
  }

  /// Connects to the agent if a link is known and we are not connected.
  /// Returns the live control connection, or null when there is no agent.
  Future<AgentControlClient?> _ensureConnected() {
    final existing = _control;
    if (existing != null && !existing.isClosed) {
      return Future.value(existing);
    }
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<AgentControlClient?> _connect() async {
    final link = _link ??= await PhoneAgentLink.current();
    if (link == null) {
      _available = false;
      return null;
    }
    try {
      final control = await AgentControlClient.connectLink(link);
      final hello = await control.call('hello', const {});
      if (hello is! Map) {
        await control.close();
        _available = false;
        return null;
      }
      _capabilities = {
        for (final value in (hello['capabilities'] as List? ?? const []))
          '$value',
      };
      unawaited(
        control.done.then((_) {
          if (identical(_control, control)) {
            _control = null;
            _available = false;
          }
        }),
      );
      _control = control;
      _available = true;
      WindowStreamLog.write('phone agent link up ($link.port)');
      return control;
    } catch (error) {
      _available = false;
      _link = null; // The port may be stale; read it again next time.
      WindowStreamLog.write('phone agent link failed: $error');
      return null;
    }
  }

  @override
  Future<WindowStreamFailureReason?> unavailableReason() async {
    final control = await _ensureConnected();
    if (control == null) {
      // A code the viewer maps through the extra `reason` on the wire.
      return WindowStreamFailureReason.hostUnsupported;
    }
    return null;
  }

  @override
  Future<CaptureResult> requestCatalog() async {
    final control = await _ensureConnected();
    if (control == null) {
      return CaptureResult.failed(
        WindowStreamCaptureCode.unknown,
        reason: agentNotRunning,
      );
    }
    try {
      final apps = await control.call('apps') as List? ?? const [];
      final tasks = await control.call('tasks') as List? ?? const [];
      final screen = _screen().points;
      _apps
        ..clear()
        ..addEntries([
          for (final app in apps)
            if (app is Map && app['id'] is String)
              MapEntry(app['id'] as String, '${app['label'] ?? app['id']}'),
        ]);
      final windows = [
        for (final task in tasks)
          if (task is Map &&
              task['taskId'] is int &&
              task['appId'] is String &&
              task['appId'] != 'com.android.systemui')
            {
              'id': task['taskId'],
              'appId': task['appId'],
              'appName': _apps[task['appId']] ?? task['appId'],
              'title': _apps[task['appId']] ?? task['appId'],
              // Upright as the phone is held: the shape its apps are made
              // for, and the shape a desktop window opens in.
              'width': screen.width.round(),
              'height': screen.height.round(),
              'active': task['visible'] == true,
            },
      ];
      final appList = [
        for (final app in apps)
          if (app is Map && app['id'] is String)
            {
              'appId': app['id'],
              'name': '${app['label'] ?? app['id']}',
              'running': false,
            },
      ];
      return CaptureResult(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'windows': windows,
              'apps': appList,
              'locked': false,
              'screen': {
                'width': screen.width.round(),
                'height': screen.height.round(),
              },
            }),
          ),
        ),
      );
    } on AgentCallException {
      return CaptureResult.failed(
        WindowStreamCaptureCode.unknown,
        reason: agentNotRunning,
      );
    }
  }

  @override
  Future<CaptureResult> requestIcon(String appId, {int size = 128}) async {
    final control = await _ensureConnected();
    if (control == null) {
      return CaptureResult.failed(WindowStreamCaptureCode.unknown);
    }
    try {
      final result = await control.call('icon', {'appId': appId, 'size': size});
      final png = result is Map ? result['png'] : null;
      if (png is String) {
        return CaptureResult(base64Decode(png));
      }
    } on AgentCallException {
      // Falls through.
    }
    return CaptureResult.failed(WindowStreamCaptureCode.notFound);
  }

  @override
  Future<CaptureResult> requestThumbnail(int windowId, int maxEdge) async {
    final control = await _ensureConnected();
    if (control == null) {
      return CaptureResult.failed(WindowStreamCaptureCode.unknown);
    }
    try {
      final result = await control.call('snapshot', {
        'taskId': windowId,
        'maxEdge': maxEdge,
      });
      final jpeg = result is Map ? result['jpeg'] : null;
      if (jpeg is String) {
        return CaptureResult(base64Decode(jpeg));
      }
    } on AgentCallException {
      // Falls through.
    }
    return CaptureResult.failed(WindowStreamCaptureCode.notFound);
  }

  @override
  Future<CaptureResult> launchApp(String appId) async =>
      CaptureResult.failed(WindowStreamCaptureCode.unknown);

  /// Apps open straight onto a new display, so there is no window to wait
  /// for; a stand-in with a negative id marks "start this app".
  @override
  RemoteWindowInfo? appWindow(String appId) => RemoteWindowInfo(
    id: -(appId.hashCode & 0x7fffffff) - 1,
    appId: appId,
    appName: _apps[appId] ?? appId,
    title: _apps[appId] ?? appId,
    width: _screen().points.width.round(),
    height: _screen().points.height.round(),
  );

  /// This phone's screen, upright: in its points (dp) and in pixels.
  static ({Size points, Size pixels}) _screen() {
    final dispatcher = PlatformDispatcher.instance;
    final display = dispatcher.views.isNotEmpty
        ? dispatcher.views.first.display
        : dispatcher.displays.firstOrNull;
    if (display == null || display.devicePixelRatio <= 0) {
      return (points: const Size(412, 915), pixels: const Size(1080, 2400));
    }
    Size upright(Size size) => Size(size.shortestSide, size.longestSide);
    return (
      points: upright(display.size / display.devicePixelRatio),
      pixels: upright(display.size),
    );
  }

  @override
  void captureCloseWindow(int windowId, int pid) {
    // As swiping the task away in the phone's recents would (removeTask).
    unawaited(_quiet('repairTouch', {'taskId': windowId}));
  }

  @override
  int captureStart(CaptureRequest request) {
    final capture = _nextCapture++;
    final stream = _PhoneStream(
      capture: capture,
      agentStream: 1 + _random.nextInt(1 << 30),
      request: request,
    );
    _streams[capture] = stream;
    unawaited(_openStream(stream));
    return capture;
  }

  Future<void> _openStream(_PhoneStream stream) async {
    final control = await _ensureConnected();
    final link = _link;
    if (control == null || link == null || stream.closed) {
      _emit(CaptureEnded(stream.capture, reason: agentNotRunning));
      return;
    }
    final request = stream.request;
    final byTask = request.window.id > 0;
    final screen = _screen();
    final metrics = displayFor(
      viewport: Size(request.viewportWidth, request.viewportHeight),
      pixelRatio: request.pixelRatio,
      phonePoints: screen.points,
      phonePixels: screen.pixels,
    );
    final width = metrics?.width ?? 0;
    final height = metrics?.height ?? 0;
    final dpi = metrics?.dpi ?? 0;
    stream.displayWidth = width;
    stream.displayHeight = height;
    stream.dpi = dpi;
    stream.pixelRatio = request.pixelRatio;
    stream.maxEdge = screen.pixels.longestSide;
    try {
      await control.call('open', {
        'stream': stream.agentStream,
        'appId': request.window.appId,
        if (byTask) 'taskId': request.window.id,
        if (width > 0) 'width': width,
        if (height > 0) 'height': height,
        if (dpi > 0) 'dpi': dpi,
        'bitRate': request.bitRate,
        'maxFps': request.fps,
        'audio': request.audio && audioSupported,
      });
    } on AgentCallException catch (error) {
      _emit(CaptureEnded(stream.capture, reason: agentNotRunning));
      WindowStreamLog.write('phone open failed: ${error.message}');
      return;
    }
    if (stream.closed) {
      unawaited(_quiet('close', {'stream': stream.agentStream}));
      return;
    }
    try {
      stream.video = await AgentLink.connect(
        link,
        role: AgentWire.roleVideo,
        stream: stream.agentStream,
      );
      if (request.audio && audioSupported) {
        stream.audio = await AgentLink.connect(
          link,
          role: AgentWire.roleAudio,
          stream: stream.agentStream,
        );
      }
      stream.input = await AgentLink.connect(
        link,
        role: AgentWire.roleInput,
        stream: stream.agentStream,
      );
    } catch (error) {
      _emit(CaptureEnded(stream.capture, reason: agentNotRunning));
      await _closeStream(stream, tellAgent: true);
      return;
    }
    if (stream.closed) {
      await _closeStream(stream, tellAgent: true);
      return;
    }
    _pumpVideo(stream);
    _pumpAudio(stream);
  }

  /// The virtual display for a viewer's window of [viewport] points. The
  /// app keeps the layout it has on this phone: the phone's shorter side in
  /// dp across the window's shorter side. The picture has as many pixels as
  /// the viewer shows ([pixelRatio] per point; 1 when it did not say), at
  /// most this phone's own screen. Null without a viewport.
  @visibleForTesting
  static ({int width, int height, int dpi})? displayFor({
    required Size viewport,
    required double pixelRatio,
    required Size phonePoints,
    required Size phonePixels,
  }) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return null;
    }
    final dpPerPoint = (phonePoints.shortestSide / viewport.shortestSide).clamp(
      0.5,
      2.0,
    );
    final pixels = _pixelsFor(
      viewport,
      pixelRatio: pixelRatio,
      maxEdge: phonePixels.longestSide,
    );
    final dpi = (160 * pixels.width / (viewport.width * dpPerPoint))
        .round()
        .clamp(120, 640);
    return (width: pixels.width, height: pixels.height, dpi: dpi);
  }

  /// [viewport] points at [pixelRatio], the longer edge at most [maxEdge],
  /// both even.
  static ({int width, int height}) _pixelsFor(
    Size viewport, {
    required double pixelRatio,
    required double maxEdge,
  }) {
    final ratio = pixelRatio > 0 ? pixelRatio.clamp(1.0, 3.0) : 1.0;
    var width = viewport.width * ratio;
    var height = viewport.height * ratio;
    final longest = max(width, height);
    if (maxEdge > 0 && longest > maxEdge) {
      width *= maxEdge / longest;
      height *= maxEdge / longest;
    }
    int even(double value) => max(16, value.round() & ~1);
    return (width: even(width), height: even(height));
  }

  void _pumpVideo(_PhoneStream stream) {
    final connection = stream.video;
    if (connection == null) {
      return;
    }
    final parser = ScrcpyMediaParser(
      _VideoListener(this, stream),
      expectDummyByte: true,
    );
    stream.videoSub = connection.input.listen(
      parser.add,
      onError: (Object _) => _onAgentSocketGone(stream),
      onDone: () => _onAgentSocketGone(stream),
      cancelOnError: true,
    );
  }

  void _pumpAudio(_PhoneStream stream) {
    final connection = stream.audio;
    if (connection == null) {
      return;
    }
    final parser = ScrcpyMediaParser(_AudioListener(this, stream));
    stream.audioSub = connection.input.listen(
      parser.add,
      onError: (Object _) {},
      onDone: () {},
      cancelOnError: true,
    );
  }

  void _onAgentSocketGone(_PhoneStream stream) {
    if (stream.closed) {
      return;
    }
    _emit(CaptureEnded(stream.capture, gone: true));
    unawaited(_closeStream(stream, tellAgent: false));
  }

  @override
  void captureStop(int capture) {
    final stream = _streams[capture];
    if (stream != null) {
      unawaited(_closeStream(stream, tellAgent: true));
    }
  }

  Future<void> _closeStream(
    _PhoneStream stream, {
    required bool tellAgent,
  }) async {
    if (stream.closed) {
      return;
    }
    stream.closed = true;
    _streams.remove(stream.capture);
    await stream.videoSub?.cancel();
    await stream.audioSub?.cancel();
    stream.video?.destroy();
    stream.audio?.destroy();
    stream.input?.destroy();
    if (tellAgent) {
      await _quiet('close', {'stream': stream.agentStream});
    }
  }

  @override
  void captureSetPaused(int capture, bool paused) {
    final stream = _streams[capture];
    if (stream != null) {
      unawaited(
        _quiet(paused ? 'suspend' : 'resume', {'stream': stream.agentStream}),
      );
    }
  }

  @override
  void captureRequestKeyframe(int capture) {
    final stream = _streams[capture];
    if (stream != null) {
      unawaited(_quiet('keyframe', {'stream': stream.agentStream}));
    }
  }

  @override
  void captureSetBusy(int capture, bool busy) {
    // The agent's encoder drops frames on its own when the link is slow.
  }

  @override
  void captureSetScreen(int capture, int screenKey) {
    // Each agent stream already has its own virtual display.
  }

  @override
  void captureSetViewport(
    int capture,
    double width,
    double height,
    double scale,
  ) {
    final stream = _streams[capture];
    final input = stream?.input;
    if (stream == null || input == null || width <= 0 || height <= 0) {
      return;
    }
    // The density the display opened with stays (the agent can't change
    // it): a bigger window shows more of the app, not bigger text.
    final pixels = _pixelsFor(
      Size(width, height),
      pixelRatio: stream.pixelRatio,
      maxEdge: stream.maxEdge,
    );
    final w = pixels.width;
    final h = pixels.height;
    if (w == stream.displayWidth && h == stream.displayHeight) {
      return;
    }
    stream.displayWidth = w;
    stream.displayHeight = h;
    input.socket.add(ScrcpyControl.resizeDisplay(w, h));
  }

  @override
  void captureSetInset(int capture, double fraction) {
    // A desktop viewer has no on-screen keyboard over the picture.
  }

  @override
  void captureSetPixelRatio(int capture, double ratio) {
    final stream = _streams[capture];
    if (stream != null && ratio > 0) {
      stream.pixelRatio = ratio;
    }
  }

  @override
  void captureSetAudio(int capture, int mode) {
    // Audio is chosen when the stream opens (the agent records per app).
  }

  Future<void> _quiet(String method, Map<String, Object?> params) async {
    final control = _control;
    if (control == null) {
      return;
    }
    try {
      await control.call(method, params);
    } on AgentCallException {
      // The stream or agent is going away.
    }
  }

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
  }) {
    final stream = _streams[capture];
    final input = stream?.input;
    if (stream == null || input == null) {
      return;
    }
    final event = NativeInputDecoder.decode(
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
    if (event == null) {
      return;
    }
    for (final message in stream.mapper.map(event)) {
      if (message.delay == Duration.zero) {
        input.socket.add(message.bytes);
      } else {
        Timer(message.delay, () {
          if (!stream.closed) {
            input.socket.add(message.bytes);
          }
        });
      }
    }
  }

  void _emit(CaptureEvent event) => _onEvent?.call(event);
}

class _PhoneStream {
  _PhoneStream({
    required this.capture,
    required this.agentStream,
    required this.request,
  });

  final int capture;
  final int agentStream;
  final CaptureRequest request;
  final mapper = ScrcpyInputMapper();

  AgentConnection? video;
  AgentConnection? audio;
  AgentConnection? input;
  StreamSubscription<Uint8List>? videoSub;
  StreamSubscription<Uint8List>? audioSub;
  int displayWidth = 0;
  int displayHeight = 0;
  int dpi = 0;

  /// The viewer's pixels per point, and the largest display edge (this
  /// phone's own screen).
  double pixelRatio = 0;
  double maxEdge = 0;
  bool audioConfigured = false;
  bool closed = false;
}

/// Reframes the agent's scrcpy H.264 into [CaptureVideo] for the host.
class _VideoListener implements ScrcpyMediaListener {
  _VideoListener(this._backend, this._stream);

  final PhoneCaptureBackend _backend;
  final _PhoneStream _stream;

  @override
  void onCodec(int codecId) {
    if (codecId != ScrcpyProtocol.codecH264) {
      _backend._emit(
        CaptureEnded(_stream.capture, code: WindowStreamCaptureCode.encoder),
      );
    }
  }

  @override
  void onSession(int width, int height) {
    _stream.mapper.frameWidth = width;
    _stream.mapper.frameHeight = height;
    _backend._emit(CaptureSize(_stream.capture, width, height));
  }

  @override
  MediaPacketWriter beginPacket(int length) =>
      _EventWriter((payload, ptsUs, config, key) {
        if (!_stream.closed) {
          _backend._emit(
            CaptureVideo(
              _stream.capture,
              payload,
              ptsUs: ptsUs,
              config: config,
              key: key,
            ),
          );
        }
      });
}

/// Reframes the agent's RAW PCM into [CaptureAudio] for the host.
class _AudioListener implements ScrcpyMediaListener {
  _AudioListener(this._backend, this._stream);

  final PhoneCaptureBackend _backend;
  final _PhoneStream _stream;

  @override
  void onCodec(int codecId) {
    _stream.audioConfigured = codecId == ScrcpyProtocol.codecRaw;
  }

  @override
  void onSession(int width, int height) {}

  @override
  MediaPacketWriter beginPacket(int length) =>
      _EventWriter((payload, ptsUs, config, key) {
        if (!_stream.closed && _stream.audioConfigured && !config) {
          _backend._emit(
            CaptureAudio(
              _stream.capture,
              payload,
              ptsUs: ptsUs,
              rate: 48000,
              channels: 2,
            ),
          );
        }
      });
}

/// Collects one media packet's bytes and hands them to [_onCommit].
class _EventWriter implements MediaPacketWriter {
  _EventWriter(this._onCommit);

  final void Function(Uint8List payload, int ptsUs, bool config, bool key)
  _onCommit;
  final _bytes = BytesBuilder(copy: false);

  @override
  void write(Uint8List chunk) => _bytes.add(chunk);

  @override
  void commit({required int ptsUs, required bool config, required bool key}) =>
      _onCommit(_bytes.takeBytes(), ptsUs, config, key);

  @override
  void discard() => _bytes.clear();
}
