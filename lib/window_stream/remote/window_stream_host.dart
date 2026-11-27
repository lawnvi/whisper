import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_stream_native/window_stream_native.dart';

import '../../socket/bounded_binary_websocket_session.dart';
import '../../socket/bounded_outbound_queue.dart';
import '../../socket/media_channel_dial.dart';
import '../../socket/packet_byte_transport.dart';
import '../../socket/session_upgrade_token_registry.dart';
import '../android/agent/phone_capture_backend.dart';
import '../android/agent/phone_self_start.dart';
import '../core/window_stream_models.dart';
import '../window_stream_log.dart';
import 'host_audio.dart';
import 'window_capture_backend.dart';
import 'window_stream_control.dart';

export 'window_capture_backend.dart';

/// Sends a control message to a peer; returns false when it could not.
typedef WindowStreamControlSender =
    Future<bool> Function(WindowStreamControlMessage message);

/// Runs [action] with this device's media send key for [peerId].
typedef MediaSendKeyScope =
    T? Function<T>(String peerId, T Function(Uint8List key) action);

/// For a viewer this device dialled the Whisper session to: runs [action]
/// with that session's address (`ws://host:port`) and this device's media
/// keys for the viewer. Null when this device is not that session's client.
typedef MediaDialScope =
    T? Function<T>(
      String peerId,
      T Function(Uri base, Uint8List sendKey, Uint8List receiveKey) action,
    );

enum HostStreamState { awaitingMedia, live, closed }

/// The kind of screen a viewer shows windows on, from its `open`.
enum WindowStreamViewerKind {
  phone,
  tablet,
  desktop;

  /// Viewers before `viewerKind` existed were phones or tablets (a Mac
  /// viewer then also shared one display per viewer).
  static WindowStreamViewerKind? parse(Object? value) =>
      value is String ? values.asNameMap()[value] : null;
}

class _HostStream {
  _HostStream({required this.open, required this.window, required this.send})
    : sessionId = open.sessionId,
      viewerPeerId = open.viewerPeerId,
      viewerKind = WindowStreamViewerKind.parse(open.payload['viewerKind']),
      audio = open.payload['audio'] == true,
      dialBack = open.payload[WindowStreamMediaDial.dialBackKey] == true;

  /// The viewer's `open`; replies are built from it.
  final WindowStreamControlMessage open;
  final String sessionId;
  final String viewerPeerId;
  final RemoteWindowInfo window;
  final WindowStreamControlSender send;

  /// Null for viewers that predate the field.
  final WindowStreamViewerKind? viewerKind;

  /// The viewer asked for the window's sound (`"audio": true` in `open`).
  final bool audio;

  /// The viewer can take a `/window` dial from here (`"dialBack"` in
  /// `open`); [hostDials] when this host said it will.
  final bool dialBack;
  bool hostDials = false;
  bool dialing = false;

  /// Codes the window's sound for the viewer, once there is some.
  HostAudioEncoder? audioEncoder;

  /// This capture carries its app's sound to the viewer. One per viewer
  /// and app: two windows of one app would otherwise play it twice.
  bool audioOn = false;

  /// Sound chunks from the capture, those held back (paused, not live)
  /// and packets sent, for diagnostics.
  int audioIn = 0;
  int audioHeld = 0;
  int audioOut = 0;

  /// The viewer paused the stream (its window hidden): no sound either.
  bool paused = false;
  HostStreamState state = HostStreamState.awaitingMedia;
  int? captureId;
  PacketByteTransport? transport;
  BoundedBinaryWebSocketSession? input;
  AuthenticatedMediaPacketDecoder? inputDecoder;
  DateTime lastKeyframeAsk = DateTime.fromMillisecondsSinceEpoch(0);

  /// The viewer's screen in its points and its text scale (Aa); zero
  /// until it says.
  double viewportWidth = 0;
  double viewportHeight = 0;
  double viewportScale = 1;

  /// The viewer's pixels per point (2 on a Retina Mac); 0 until it says
  /// (older viewers never do).
  double pixelRatio = 0;

  /// The viewing device's name, for other viewers' lists.
  String viewerName = '';

  /// How much of the viewer's screen bottom its keyboard covers.
  double keyboardInset = 0;

  /// The picture quality the viewer chose (older viewers: the usual one).
  WindowStreamQuality quality = WindowStreamQuality.standard;

  /// Keeps the viewer's radio awake while the picture is still.
  Timer? tick;

  /// Video packets handed to the socket and not yet written.
  int videoInFlight = 0;
  bool busy = false;
  final sinceSent = Stopwatch();

  void readViewport(Map<String, Object?> payload) {
    final width = payload['viewportWidth'];
    final height = payload['viewportHeight'];
    final scale = payload['viewportScale'];
    if (width is num && height is num && width > 0 && height > 0) {
      viewportWidth = width.toDouble().clamp(160, 4096);
      viewportHeight = height.toDouble().clamp(160, 4096);
    }
    if (scale is num && scale > 0) {
      viewportScale = scale.toDouble().clamp(0.5, 2);
    }
    final ratio = payload['pixelRatio'];
    if (ratio is num && ratio > 0) {
      pixelRatio = ratio.toDouble().clamp(1, 4);
    }
    final keyboard = payload['keyboardInset'];
    keyboardInset = keyboard is num ? keyboard.toDouble().clamp(0, 0.8) : 0;
    if (payload['quality'] case final String name) {
      quality = WindowStreamQuality.fromName(name);
    }
  }

  /// The bit rate this stream is sent at.
  int get bitRate => quality.scale(WindowStreamHost.usualBitRate);
}

/// This device as a window source for other Whisper peers: desktops (macOS,
/// Windows and Linux) through their window_stream_native capture, Android
/// phones through whisper-agent (see [WindowCaptureBackend]).
/// Answers browse requests, accepts `open`, and once the viewer has dialled
/// `/window`, streams the window and replays the viewer's input on it.
class WindowStreamHost {
  WindowStreamHost._() : _backend = _platformBackend();

  /// A host over [backend], for tests.
  @visibleForTesting
  WindowStreamHost.withBackend(WindowCaptureBackend backend)
    : _backend = backend;

  static final WindowStreamHost shared = WindowStreamHost._();

  static WindowCaptureBackend _platformBackend() =>
      Platform.isAndroid ? PhoneCaptureBackend.shared : NativeCaptureBackend();

  static const String route = '/window';
  static const String namespace = 'window-stream';

  /// A stream's bit rate at the standard quality.
  static const int usualBitRate = 12000000;
  static const int maxInputMessageBytes = 8 * 1024;

  /// Where windows, pictures and input go: the desktop's native capture or
  /// the phone's agent.
  final WindowCaptureBackend _backend;
  bool _attached = false;
  final _streams = <String, _HostStream>{};

  /// Goes up whenever a window starts or stops being shown somewhere.
  final hostedChanged = ValueNotifier<int>(0);
  final _streamByCapture = <int, _HostStream>{};
  List<RemoteWindowInfo> _lastCatalog = const [];

  /// The screen the backend reported with its catalog (a phone's), passed
  /// on to viewers.
  Map<String, Object?>? _screen;

  /// App ids this host itself listed (installed apps and apps with
  /// windows). A viewer may only name one of these: on Windows an app id
  /// can be a path, and a path from a viewer must never be run or read.
  Set<String> _knownApps = const {};

  /// Whether [appId] is one this host listed; asks the system again once
  /// when the list is stale.
  Future<bool> _isKnownApp(String appId) async {
    if (_knownApps.contains(appId)) {
      return true;
    }
    await _catalogWindows();
    return _knownApps.contains(appId);
  }

  /// Whether [windowId] is a window this host listed, with the list and the
  /// lock state fresh enough to answer for.
  Future<bool> _isListedWindow(int windowId) async {
    if (!_lastCatalog.any((window) => window.id == windowId)) {
      await _catalogWindows();
    }
    return _lastCatalog.any((window) => window.id == windowId);
  }

  int _catalogError = 0;

  /// What the last failed catalog tells a viewer (`reason` of its error).
  String _catalogReason = '';
  bool _locked = false;

  /// Each thumbnail is a short screen capture, and every capture lights the
  /// menu-bar recording indicator. They run one at a time and are reused
  /// for [_thumbnailLifetime], so browsing shows the indicator once instead
  /// of flashing it every few seconds.
  final _thumbnails = <int, ({DateTime at, Uint8List jpeg})>{};
  Future<void> _thumbnailQueue = Future.value();
  static const _thumbnailLifetime = Duration(minutes: 2);
  final _icons = <String, Uint8List>{};

  /// Whether this device can offer windows at all. Asked for every control
  /// message; backends answer from a cache.
  bool get supported => _backend.supported;

  static bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Input can be replayed (macOS: Accessibility permission granted).
  bool get inputPermitted => _backend.inputPermitted;

  bool get hasActiveStreams => _streams.isNotEmpty;

  /// Set by the socket layer: sends a control message to a peer, and this
  /// device's id as that peer knows it. Used to start "送出去".
  Future<bool> Function(String peerId, WindowStreamControlMessage message)?
  sender;
  String Function(String peerId)? localPeerId;

  /// Set by the socket layer: the session address and media keys for a
  /// viewer this device dialled (see [WindowStreamMediaDial]).
  MediaDialScope? dialScope;

  /// Phones dial their viewers when they can (they are often unreachable).
  @visibleForTesting
  static bool? debugIsPhone;
  static bool get _isPhone =>
      debugIsPhone ?? (Platform.isAndroid || Platform.isIOS);
  static const _uuid = Uuid();

  /// This desktop's windows that can be sent to another device.
  Future<List<RemoteWindowInfo>> localWindows() async =>
      await _catalogWindows() ?? const [];

  /// A thumbnail of one of this desktop's windows (cached, see [_thumbnail]).
  Future<Uint8List?> localThumbnail(int windowId, {int maxEdge = 480}) =>
      _thumbnail(windowId, maxEdge);

  /// An installed app's icon as PNG (cached).
  Future<Uint8List?> localIcon(String appId) async {
    final cached = _icons[appId];
    if (cached != null) {
      return cached;
    }
    final result = await _request(
      (backend) => backend.requestIcon(appId, size: 128),
    );
    if (!result.ok) {
      return null;
    }
    return _icons[appId] = result.bytes;
  }

  /// "送出去": asks [peerId] to show [window]. The other device shows a
  /// banner; when its user taps it, it opens the window like any other.
  Future<bool> offer(String peerId, RemoteWindowInfo window) async {
    final send = sender;
    final local = localPeerId?.call(peerId) ?? '';
    if (send == null || local.isEmpty) {
      return false;
    }
    final jpeg = await _thumbnail(window.id, 360);
    final icon = await localIcon(window.appId);
    return send(
      peerId,
      WindowStreamControlMessage(
        action: WindowStreamControlAction.offer,
        sessionId: _uuid.v4(),
        viewerPeerId: peerId,
        hostPeerId: local,
        payload: {
          'window': window.toJson(),
          if (jpeg != null) 'thumbnail': base64Encode(jpeg),
          if (icon != null) 'icon': base64Encode(icon),
        },
      ),
    );
  }

  /// Brings the native side up early on every desktop: setting the capture
  /// callback is what makes it put back windows an earlier run left
  /// stranded (between displays on macOS, off screen on Windows, on a
  /// virtual monitor on Linux), even when capture itself is unavailable.
  void start() {
    if (_isDesktop) {
      _attachNative();
      unawaited(_loadSharing());
    } else if (Platform.isAndroid) {
      // The phone's agent link comes up with the app, so desktops see
      // why there is nothing yet instead of an empty list.
      _attachNative();
      unawaited(_loadSharing());
      PhoneSelfStart.shared.attach();
    }
  }

  static const _sharingKey = 'window_stream.share_windows';

  /// Whether trusted devices may see and use this computer's windows (the
  /// setting; on unless the user turned it off).
  bool get sharingAllowed => _sharingAllowed;
  bool _sharingAllowed = true;

  Future<void> _loadSharing() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _sharingAllowed = prefs.getBool(_sharingKey) ?? true;
    } catch (_) {
      // No preferences (tests): allowed, as before.
    }
  }

  /// Turns window sharing on or off; off ends every window being shown
  /// elsewhere right away.
  Future<void> setSharingAllowed(bool allowed) async {
    _sharingAllowed = allowed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sharingKey, allowed);
    if (!allowed) {
      for (final stream in _streams.values.toList()) {
        await _stop(stream, notify: true);
      }
    }
  }

  /// Hands the backend this host's event sink, whether or not capture is
  /// supported here (on desktops this is what puts back stranded windows).
  void _attachNative() {
    if (_attached) {
      return;
    }
    _attached = true;
    _backend.attach(_onCaptureEvent);
  }

  /// Whether windows can be offered now, with the backend attached.
  bool _ready() {
    if (!supported) {
      return false;
    }
    _attachNative();
    return true;
  }

  /// Why this device can't offer windows right now, or null when it can.
  /// The backend asks its capture even when unsupported: the answer
  /// explains it (see [WindowStreamCaptureCode]).
  Future<WindowStreamFailureReason?> unavailableReason() {
    _attachNative();
    return _backend.unavailableReason();
  }

  Future<CaptureResult> _request(
    Future<CaptureResult> Function(WindowCaptureBackend) start,
  ) {
    if (!_ready()) {
      return Future.value(CaptureResult.failed(WsnCaptureError.unsupported));
    }
    return start(_backend);
  }

  void _onCaptureEvent(CaptureEvent event) {
    final stream = _streamByCapture[event.capture];
    if (stream == null) {
      // Not about one stream (windows put back on the desktop, say).
      if (event is CaptureNote) {
        WindowStreamLog.write('host ${event.text}');
      }
      return;
    }
    switch (event) {
      case CaptureNote(:final text):
        _log(stream, text);
      case CaptureVideo(
        :final payload,
        :final ptsUs,
        :final config,
        :final key,
      ):
        _sendVideo(stream, payload, ptsUs: ptsUs, config: config, key: key);
      case CaptureSize(:final width, :final height):
        unawaited(
          stream.transport?.send(
            WindowStreamPacket.size(width, height),
            kind: OutboundPacketKind.control,
          ),
        );
      case CaptureTextFocus(:final flags):
        _log(stream, flags == 1 ? 'focus: text field' : 'focus: no text field');
        unawaited(
          stream.transport?.send(
            WindowStreamPacket.textFocus(typing: flags == 1),
            kind: OutboundPacketKind.control,
          ),
        );
      case CaptureAudio(:final pcm, :final ptsUs, :final rate, :final channels):
        _onAudio(stream, pcm, ptsUs, rate, channels);
      case CaptureEnded(:final gone, :final code, :final reason):
        // The viewer shows why (permission, helper, elevated…); a window
        // that went away just closes.
        final wire = gone || code == WindowStreamCaptureCode.notFound
            ? 'windowGone'
            : reason ?? WindowStreamCaptureCode.wireReason(code);
        unawaited(_stop(stream, notify: true, reason: wire));
    }
  }

  /// The window's sound (PCM s16le, interleaved), on the video's clock,
  /// for a stream whose viewer asked for it ([_HostStream.audio]): coded
  /// with Opus and sent ahead of the video. None while paused.
  void _onAudio(
    _HostStream stream,
    Uint8List pcm,
    int ptsUs,
    int rate,
    int channels,
  ) {
    final transport = stream.transport;
    stream.audioIn++;
    if (!stream.audioOn ||
        stream.paused ||
        transport == null ||
        stream.state != HostStreamState.live) {
      stream.audioHeld++;
      return;
    }
    final encoder = stream.audioEncoder ??= HostAudioEncoder(
      send: (packet) {
        stream.audioOut++;
        unawaited(transport.send(packet, kind: OutboundPacketKind.audio));
      },
    );
    encoder.add(pcm, ptsUs: ptsUs, sampleRate: rate, channels: channels);
  }

  void _sendVideo(
    _HostStream stream,
    Uint8List payload, {
    required int ptsUs,
    required bool config,
    required bool key,
  }) {
    final transport = stream.transport;
    if (transport == null || stream.state != HostStreamState.live) {
      return;
    }
    stream.sinceSent.reset();
    // Two frames waiting is enough: beyond that every frame only adds
    // delay. The encoder then skips frames until the socket catches up.
    stream.videoInFlight++;
    _setBusy(stream, stream.videoInFlight >= 2);
    final sent = transport.send(
      WindowStreamPacket.video(
        payload,
        ptsUs: ptsUs,
        flags:
            (config ? WindowStreamPacket.flagConfig : 0) |
            (key ? WindowStreamPacket.flagKey : 0),
      ),
      kind: config
          ? OutboundPacketKind.videoConfig
          : key
          ? OutboundPacketKind.videoKey
          : OutboundPacketKind.videoDelta,
    );
    unawaited(
      sent.whenComplete(() {
        stream.videoInFlight--;
        if (stream.videoInFlight == 0) {
          _setBusy(stream, false);
        }
      }),
    );
  }

  void _setBusy(_HostStream stream, bool busy) {
    final capture = stream.captureId;
    if (capture == null || stream.busy == busy) {
      return;
    }
    stream.busy = busy;
    _backend.captureSetBusy(capture, busy);
  }

  void _askKeyframe(_HostStream stream) {
    final now = DateTime.now();
    if (now.difference(stream.lastKeyframeAsk) <
        const Duration(milliseconds: 250)) {
      return;
    }
    stream.lastKeyframeAsk = now;
    final capture = stream.captureId;
    if (capture != null) {
      _backend.captureRequestKeyframe(capture);
    }
  }

  // ---------------------------------------------------------------- control

  /// Handles a control message from a viewer. [send] replies to that viewer.
  Future<void> handleControl(
    WindowStreamControlMessage message, {
    required String remotePeerId,
    required WindowStreamControlSender send,
  }) async {
    if (message.viewerPeerId != remotePeerId) {
      return;
    }
    switch (message.action) {
      case WindowStreamControlAction.browse:
        await _answerCatalog(message, send);
      case WindowStreamControlAction.icon:
        final appId = message.payload['appId'];
        if (appId is! String || appId.isEmpty || !await _isKnownApp(appId)) {
          return;
        }
        var png = _icons[appId];
        if (png == null) {
          final result = await _request(
            (backend) => backend.requestIcon(appId, size: 128),
          );
          if (!result.ok) {
            return;
          }
          png = _icons[appId] = result.bytes;
        }
        await send(
          message.reply(
            WindowStreamControlAction.icon,
            payload: {'appId': appId, 'png': base64Encode(png)},
          ),
        );
      case WindowStreamControlAction.thumbnail:
        final windowId = message.payload['windowId'];
        final maxEdge = message.payload['maxEdge'];
        // Only windows this host listed, and never while it is locked.
        if (windowId is! int || !await _isListedWindow(windowId)) {
          return;
        }
        final edge = maxEdge is int ? maxEdge.clamp(64, 1024) : 480;
        final jpeg = await _thumbnail(windowId, edge);
        if (jpeg != null) {
          await send(
            message.reply(
              WindowStreamControlAction.thumbnail,
              payload: {'windowId': windowId, 'jpeg': base64Encode(jpeg)},
            ),
          );
        }
      case WindowStreamControlAction.open:
        await _open(message, send);
      case WindowStreamControlAction.pause:
      case WindowStreamControlAction.resume:
        final stream = _streams[message.sessionId];
        final capture = stream?.captureId;
        if (stream != null && capture != null) {
          stream.paused = message.action == WindowStreamControlAction.pause;
          _backend.captureSetPaused(capture, stream.paused);
        }
      case WindowStreamControlAction.keyframe:
        final stream = _streams[message.sessionId];
        if (stream != null) {
          _askKeyframe(stream);
        }
      case WindowStreamControlAction.viewport:
        final stream = _streams[message.sessionId];
        if (stream != null) {
          final bitRate = stream.bitRate;
          stream.readViewport(message.payload);
          _applyViewport(stream);
          final capture = stream.captureId;
          if (capture != null && stream.bitRate != bitRate) {
            _log(stream, 'quality ${stream.quality.name}');
            _backend.captureSetBitRate(capture, stream.bitRate);
          }
        }
      case WindowStreamControlAction.closeWindow:
        // Only a window this viewer was shown, as its close button would.
        final windowId = message.payload['windowId'];
        if (windowId is! int) {
          return;
        }
        if (!await _isListedWindow(windowId)) {
          await _tellClose(message, send, windowId, closed: true);
          return;
        }
        final window = _lastCatalog.firstWhere((w) => w.id == windowId);
        if (_ready()) {
          _backend.captureCloseWindow(window.id, window.pid);
        }
        unawaited(_watchClose(message, send, window));
      case WindowStreamControlAction.dial:
        final stream = _streams[message.sessionId];
        if (stream != null) {
          await _dialViewer(stream, message.transportToken);
        }
      case WindowStreamControlAction.stop:
      case WindowStreamControlAction.error:
      case WindowStreamControlAction.reject:
        final stream = _streams[message.sessionId];
        if (stream != null) {
          await _stop(stream, notify: false);
        }
      case WindowStreamControlAction.catalog:
      case WindowStreamControlAction.accept:
      case WindowStreamControlAction.offer:
      case WindowStreamControlAction.closeResult:
        // Host-to-viewer messages; never valid from a viewer.
        break;
    }
  }

  /// How long a closing window may take before the viewer hears it is still
  /// open, unless it shows a dialog first.
  static const _closeGrace = Duration(milliseconds: 2500);

  /// How long a window that stayed open is watched for closing after all
  /// (its app asked whether to save, and someone answered here).
  static const _closeWatch = Duration(minutes: 2);

  /// Watches [window] after it was asked to close: tells the viewer the
  /// moment it is gone, or that it stayed open once it shows a dialog (or
  /// after [_closeGrace]), and still tells it if it closes later on.
  Future<void> _watchClose(
    WindowStreamControlMessage message,
    WindowStreamControlSender send,
    RemoteWindowInfo window,
  ) async {
    final started = DateTime.now();
    final before = {for (final other in _lastCatalog) other.id};
    var toldOpen = false;
    while (true) {
      await Future<void>.delayed(
        toldOpen
            ? const Duration(seconds: 1)
            : const Duration(milliseconds: 120),
      );
      final windows = await _catalogWindows();
      if (windows == null) {
        if (DateTime.now().difference(started) > _closeWatch) {
          return;
        }
        continue;
      }
      final still = windows.where((w) => w.id == window.id).firstOrNull;
      if (still == null) {
        await _tellClose(message, send, window.id, closed: true);
        return;
      }
      if (toldOpen) {
        if (DateTime.now().difference(started) > _closeWatch) {
          return;
        }
        continue;
      }
      // A save sheet or dialog: the window's own flag where the platform
      // reports one, else a new window of the same app.
      final dialog =
          still.modal ||
          windows.any((w) => w.pid == window.pid && !before.contains(w.id));
      if (dialog || DateTime.now().difference(started) >= _closeGrace) {
        toldOpen = true;
        await _tellClose(message, send, window.id, closed: false);
      }
    }
  }

  Future<void> _tellClose(
    WindowStreamControlMessage message,
    WindowStreamControlSender send,
    int windowId, {
    required bool closed,
  }) async {
    try {
      await send(
        message.reply(
          WindowStreamControlAction.closeResult,
          payload: {
            'windowId': windowId,
            'outcome': closed ? 'closed' : 'open',
          },
        ),
      );
    } catch (_) {
      // The viewer went away; nothing to tell.
    }
  }

  Future<Uint8List?> _thumbnail(int windowId, int edge) {
    if (_locked) {
      return Future.value();
    }
    final cached = _thumbnails[windowId];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _thumbnailLifetime) {
      return Future.value(cached.jpeg);
    }
    final result = _thumbnailQueue.then((_) async {
      final again = _thumbnails[windowId];
      if (again != null &&
          DateTime.now().difference(again.at) < _thumbnailLifetime) {
        return again.jpeg;
      }
      final capture = await _request(
        (backend) => backend.requestThumbnail(windowId, edge),
      );
      if (!capture.ok) {
        return null;
      }
      _thumbnails[windowId] = (at: DateTime.now(), jpeg: capture.bytes);
      return capture.bytes;
    });
    _thumbnailQueue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<RemoteWindowInfo>?> _catalogWindows({
    List<Map<String, Object?>>? appsOut,
  }) async {
    final result = await _request((backend) => backend.requestCatalog());
    _catalogError = result.error;
    _catalogReason = result.wireReason;
    if (!result.ok) {
      return null;
    }
    final json = jsonDecode(utf8.decode(result.bytes)) as Map<String, Object?>;
    final windows = [
      for (final entry in (json['windows'] as List? ?? const []))
        RemoteWindowInfo.fromJson((entry as Map).cast<String, Object?>()),
    ];
    _lastCatalog = windows;
    _locked = json['locked'] == true;
    final screen = json['screen'];
    _screen = screen is Map ? screen.cast<String, Object?>() : null;
    _knownApps = {
      for (final window in windows) window.appId,
      for (final entry in (json['apps'] as List? ?? const []))
        if (entry is Map && (entry['bundleId'] ?? entry['appId']) is String)
          entry['bundleId'] ?? entry['appId'] as String,
    };
    _thumbnails.removeWhere(
      (id, _) => !windows.any((window) => window.id == id),
    );
    // macOS names apps by bundle id; Windows (AppUserModelID or exe path)
    // and Linux (desktop file id) call it appId.
    appsOut?.addAll([
      for (final entry in (json['apps'] as List? ?? const []))
        if (entry is Map && (entry['bundleId'] ?? entry['appId']) is String)
          {
            'appId': entry['bundleId'] ?? entry['appId'],
            'name': entry['name'] is String ? entry['name'] : '',
            'running': entry['running'] == true,
          },
    ]);
    return windows;
  }

  /// The stream a listed window is in, if any.
  _HostStream? _streamOf(int windowId) {
    for (final stream in _streams.values) {
      if (stream.window.id == windowId &&
          stream.state != HostStreamState.closed) {
        return stream;
      }
    }
    return null;
  }

  Future<void> _answerCatalog(
    WindowStreamControlMessage message,
    WindowStreamControlSender send,
  ) async {
    final apps = <Map<String, Object?>>[];
    final windows = await _catalogWindows(appsOut: apps);
    if (windows == null) {
      await send(
        message.reply(
          WindowStreamControlAction.error,
          payload: {'reason': _catalogReason},
        ),
      );
      return;
    }
    await send(
      message.reply(
        WindowStreamControlAction.catalog,
        payload: {
          'windows': [
            for (final window in windows)
              {
                ...window.toJson(),
                // Where it is shown now: a window is in one place at a time.
                if (_streamOf(window.id) case final stream?) ...{
                  'viewer': stream.viewerPeerId,
                  if (stream.viewerName.isNotEmpty)
                    'viewerName': stream.viewerName,
                },
              },
          ],
          'apps': apps,
          'input': inputPermitted,
          'locked': _locked,
          // A phone's screen in its points, the shape its apps are made for.
          if (_screen case final screen?) 'screen': screen,
        },
      ),
    );
  }

  /// A window of [appId], starting the app (or asking it for a window) when
  /// it has none, and waiting up to 8 s for one to appear.
  Future<RemoteWindowInfo?> _windowOfApp(String appId) async {
    RemoteWindowInfo? find(List<RemoteWindowInfo>? windows) {
      for (final window in windows ?? const <RemoteWindowInfo>[]) {
        if (window.appId == appId) {
          return window;
        }
      }
      return null;
    }

    final before = await _catalogWindows();
    final existing = find(before);
    if (existing != null) {
      return existing;
    }
    // A desktop app's window may not say which listed app it belongs to
    // (Windows: a shortcut's id against the program's path). Failing that,
    // the window that came, or that came to the front, after the launch.
    final known = {for (final window in before ?? const <RemoteWindowInfo>[]) window.id};
    final wasActive = {
      for (final window in before ?? const <RemoteWindowInfo>[])
        if (window.active) window.id,
    };
    RemoteWindowInfo? arrived(List<RemoteWindowInfo>? windows) {
      final all = windows ?? const <RemoteWindowInfo>[];
      final fresh = all.where((window) => !known.contains(window.id));
      return fresh.where((window) => window.active).firstOrNull ??
          fresh.firstOrNull ??
          all
              .where(
                (window) => window.active && !wasActive.contains(window.id),
              )
              .firstOrNull;
    }

    if (_backend.opensApps) {
      // The phone starts the app on the stream's own display once the
      // viewer dials; nothing to wait for here.
      return _backend.appWindow(appId);
    }
    final launched = await _request((backend) => backend.launchApp(appId));
    if (!launched.ok) {
      return null;
    }
    final started = DateTime.now();
    final deadline = started.add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final windows = await _catalogWindows();
      // The app's own window first; another only once it had a moment.
      final window =
          find(windows) ??
          (DateTime.now().difference(started) > const Duration(seconds: 1)
              ? arrived(windows)
              : null);
      if (window != null) {
        return window;
      }
    }
    return null;
  }

  Future<void> _open(
    WindowStreamControlMessage message,
    WindowStreamControlSender send,
  ) async {
    // Fresh window list and lock state: the viewer's may be seconds old. A
    // list that timed out falls back to the last one; a definite "no"
    // (permission, helper, …) is the viewer's answer.
    if (await _catalogWindows() == null &&
        _catalogError != WindowStreamCaptureCode.unknown) {
      await send(
        message.reply(
          WindowStreamControlAction.reject,
          payload: {'reason': _catalogReason},
        ),
      );
      return;
    }
    if (_locked) {
      await send(
        message.reply(
          WindowStreamControlAction.reject,
          payload: {'reason': 'locked'},
        ),
      );
      return;
    }
    final windowId = message.payload['windowId'];
    final appId = message.payload['appId'];
    RemoteWindowInfo? window;
    if (windowId is int) {
      for (final candidate in _lastCatalog) {
        if (candidate.id == windowId) {
          window = candidate;
          break;
        }
      }
    } else if (appId is String &&
        appId.isNotEmpty &&
        await _isKnownApp(appId)) {
      window = await _windowOfApp(appId);
    }
    if (window == null || !_ready()) {
      await send(
        message.reply(
          WindowStreamControlAction.reject,
          payload: {'reason': 'notFound'},
        ),
      );
      return;
    }
    // One capture per window, so it isn't staged twice: the same viewer
    // opening it again (it reconnected, or reopened it before the old
    // stream ended) replaces its stream; another viewer takes the window
    // over, and the one that had it is told where it went.
    for (final old in _streams.values.toList()) {
      if (old.window.id == window.id && old.sessionId != message.sessionId) {
        await _stop(
          old,
          notify: true,
          reason: old.viewerPeerId == message.viewerPeerId ? '' : 'movedAway',
        );
      }
    }
    final name = message.payload['viewerName'];
    final stream = _HostStream(open: message, window: window, send: send)
      ..readViewport(message.payload)
      ..viewerName = name is String && name.length <= 80 ? name : '';
    // A phone that opened the session itself may not be reachable from the
    // viewer; it dials the viewer instead, where the viewer can take it.
    stream.hostDials =
        stream.dialBack &&
        _isPhone &&
        dialScope?.call(
              stream.viewerPeerId,
              (base, sendKey, receiveKey) => true,
            ) ==
            true;
    _streams[message.sessionId] = stream;
    hostedChanged.value++;
    final accepted = await send(
      message.reply(
        WindowStreamControlAction.accept,
        payload: {
          // An app the phone starts has no task yet ([appWindow]).
          if (window.id > 0) 'windowId': window.id,
          'width': window.width,
          'height': window.height,
          'input': inputPermitted,
          if (stream.hostDials) WindowStreamMediaDial.hostDialsKey: true,
        },
      ),
    );
    if (!accepted) {
      _streams.remove(message.sessionId);
      hostedChanged.value++;
      return;
    }
    // The viewer must dial within the token's lifetime.
    Timer(const Duration(seconds: 30), () {
      if (stream.state == HostStreamState.awaitingMedia) {
        unawaited(_stop(stream, notify: true, reason: 'timeout'));
      }
    });
  }

  // ---------------------------------------------------------------- media

  bool canAttachClaim(SessionUpgradeClaim claim) {
    final stream = _streams[claim.sessionId];
    return stream != null &&
        stream.state == HostStreamState.awaitingMedia &&
        !stream.dialing &&
        claim.route == route &&
        claim.namespace == namespace &&
        claim.peerId == stream.viewerPeerId;
  }

  /// Takes over an authenticated `/window` socket. Video is encrypted with
  /// this device's own media send key (the viewer decrypts with its receive
  /// key); the viewer's input arrives under the claim's key. Using the
  /// claim's key in both directions would reuse nonces.
  bool attachChannel(
    WebSocketChannel channel, {
    required SessionUpgradeClaim claim,
    required MediaSendKeyScope sendKeyScope,
  }) {
    final stream = _streams[claim.sessionId];
    if (stream == null || !_ready() || !canAttachClaim(claim)) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    final encoder = claim.withMediaPacketContext(
      (_, channelBinding) => sendKeyScope(
        stream.viewerPeerId,
        (sendKey) => AuthenticatedMediaPacketEncoder(
          route: route,
          namespace: namespace,
          sessionId: claim.sessionId,
          mediaMacKey: sendKey,
          channelBinding: channelBinding,
          maxPayloadBytes:
              WindowStreamPacket.headerBytes +
              WindowStreamPacket.maxVideoPayload,
        ),
      ),
    );
    if (encoder == null) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    final decoder = claim.withMediaPacketContext(
      (mediaMacKey, channelBinding) => AuthenticatedMediaPacketDecoder(
        route: route,
        namespace: namespace,
        sessionId: claim.sessionId,
        mediaMacKey: mediaMacKey,
        channelBinding: channelBinding,
        maxPayloadBytes: maxInputMessageBytes,
      ),
    );
    _attachMedia(stream, channel, encoder: encoder, decoder: decoder);
    return true;
  }

  /// The viewer's answer to `hostDials`: dials its `/window` with its
  /// one-time [token], proving it with this device's media send key (as a
  /// viewer proves its own when it dials). Keys per direction stay as when
  /// the viewer dials: video under this device's send key, input under its
  /// receive key, both bound to the token.
  Future<void> _dialViewer(_HostStream stream, String token) async {
    final scope = dialScope;
    if (!stream.hostDials ||
        stream.dialing ||
        stream.state != HostStreamState.awaitingMedia ||
        scope == null ||
        !_ready()) {
      return;
    }
    stream.dialing = true;
    ({
      Uri uri,
      Uint8List proofKey,
      AuthenticatedMediaPacketEncoder encoder,
      AuthenticatedMediaPacketDecoder decoder,
    })?
    prepared;
    try {
      prepared = scope(stream.viewerPeerId, (base, sendKey, receiveKey) {
        final uri = MediaRoute.window.uri(
          host: base.host,
          port: base.port,
          sessionId: stream.sessionId,
          token: token,
        );
        return (
          uri: uri,
          proofKey: Uint8List.fromList(sendKey),
          encoder: MediaRoute.window.encoder(
            uri,
            sessionId: stream.sessionId,
            sendKey: sendKey,
            maxPayloadBytes:
                WindowStreamPacket.headerBytes +
                WindowStreamPacket.maxVideoPayload,
          ),
          decoder: MediaRoute.window.decoder(
            uri,
            sessionId: stream.sessionId,
            receiveKey: receiveKey,
            maxPayloadBytes: maxInputMessageBytes,
          ),
        );
      });
    } on FormatException {
      prepared = null;
    }
    if (prepared == null) {
      _log(stream, 'cannot dial the viewer');
      await _stop(stream, notify: true, reason: 'connectionFailed');
      return;
    }
    final (:uri, :proofKey, :encoder, :decoder) = prepared;
    WebSocketChannel? channel;
    try {
      channel = await dialMediaChannel(
        uri,
        MediaRoute.window,
        sessionId: stream.sessionId,
        proverPeerId: stream.open.hostPeerId,
        proofKey: proofKey,
      );
    } catch (error) {
      channel = null;
      _log(stream, 'dialling the viewer failed: ${error.runtimeType}');
    } finally {
      proofKey.fillRange(0, proofKey.length, 0);
    }
    if (channel == null || stream.state != HostStreamState.awaitingMedia) {
      encoder.destroy();
      decoder.destroy();
      await channel?.sink.close().catchError((Object _) {});
      // The viewer's own wait ends with "could not connect".
      await _stop(stream, notify: false, reason: 'dial failed');
      return;
    }
    _log(stream, 'dialled the viewer');
    _attachMedia(stream, channel, encoder: encoder, decoder: decoder);
  }

  /// Streams [stream] over an authenticated `/window` socket, whichever side
  /// dialled it.
  void _attachMedia(
    _HostStream stream,
    WebSocketChannel channel, {
    required AuthenticatedMediaPacketEncoder encoder,
    required AuthenticatedMediaPacketDecoder decoder,
  }) {
    stream.inputDecoder = decoder;
    final video = stream.transport = PacketByteTransport.video(
      addStream: channel.sink.addStream,
      closeSink: () => channel.sink.close(),
      packetEncoder: encoder,
      onKeyframeNeeded: () => _askKeyframe(stream),
    );
    // A viewer that stopped reading (overflow, a write that never finished)
    // still holds the socket open: end the stream on that alone.
    unawaited(
      video.done.then((end) {
        if (end.isUnexpected && identical(stream.transport, video)) {
          unawaited(_stop(stream, notify: true, reason: end.reason.name));
        }
      }),
    );
    stream.input = BoundedBinaryWebSocketSession(
      channel: channel,
      maxMessageBytes:
          maxInputMessageBytes + AuthenticatedMediaPacketEnvelope.overheadBytes,
      onMessage: (bytes) => _onInput(stream, decoder.decode(bytes)),
      onClosed: () {
        decoder.destroy();
        unawaited(_stop(stream, notify: false));
      },
    );
    stream.state = HostStreamState.live;
    // Start after the upgrade's "ready" frame has been written: the first
    // send binds the socket sink.
    scheduleMicrotask(() {
      if (stream.state != HostStreamState.live) {
        return;
      }
      final capture = _backend.captureStart(
        CaptureRequest(
          window: stream.window,
          viewerPeerId: stream.viewerPeerId,
          maxEdge: 2560,
          fps: 60,
          bitRate: stream.bitRate,
          audio: stream.audio,
          viewportWidth: stream.viewportWidth,
          viewportHeight: stream.viewportHeight,
          viewportScale: stream.viewportScale,
          pixelRatio: stream.pixelRatio,
        ),
      );
      stream.captureId = capture;
      _streamByCapture[capture] = stream;
      _log(
        stream,
        'capturing "${stream.window.appName}" for a '
        '${stream.viewportWidth.round()}x${stream.viewportHeight.round()} '
        'screen at Aa ${stream.viewportScale}',
      );
      _backend.captureSetScreen(capture, _screenKeyFor(stream));
      // The window's sound plays over there, not here as well: the window
      // itself is out of sight on this device.
      _takeSound(stream);
      _applyViewport(stream);
      stream.sinceSent.start();
      stream.tick = Timer.periodic(const Duration(milliseconds: 30), (_) {
        if (stream.sinceSent.elapsedMilliseconds >= 30) {
          stream.sinceSent.reset();
          unawaited(
            stream.transport?.send(
              WindowStreamPacket.tick(),
              kind: OutboundPacketKind.control,
            ),
          );
        }
      });
    });
  }

  /// Which screen (virtual display) the capture is staged on. A phone or
  /// tablet shows one window at a time, so its windows take turns on one
  /// display. A desktop shows each window in a window of its own, all live
  /// at once, so each of its sessions gets a display.
  static int _screenKeyFor(_HostStream stream) => screenKeyForViewer(
    viewerPeerId: stream.viewerPeerId,
    sessionId: stream.sessionId,
    kind: stream.viewerKind,
  );

  @visibleForTesting
  static int screenKeyForViewer({
    required String viewerPeerId,
    required String sessionId,
    WindowStreamViewerKind? kind,
  }) => kind == WindowStreamViewerKind.desktop
      ? screenKey('$viewerPeerId#$sessionId')
      : screenKey(viewerPeerId);

  /// A stable number for [text] (FNV-1a), to key a display by.
  @visibleForTesting
  static int screenKey(String text) {
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode(text)) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash;
  }

  void _log(_HostStream stream, String message) {
    WindowStreamLog.write('host ${stream.sessionId.substring(0, 8)} $message');
  }

  /// Stages the window at the viewer's size (a virtual display on macOS).
  void _applyViewport(_HostStream stream) {
    final capture = stream.captureId;
    if (capture == null || stream.viewportWidth <= 0) {
      return;
    }
    if (stream.pixelRatio > 0) {
      _backend.captureSetPixelRatio(capture, stream.pixelRatio);
    }
    _backend.captureSetViewport(
      capture,
      stream.viewportWidth,
      stream.viewportHeight,
      stream.viewportScale,
    );
    _backend.captureSetInset(capture, stream.keyboardInset);
  }

  void _onInput(_HostStream stream, Uint8List bytes) {
    final capture = stream.captureId;
    if (capture == null) {
      return;
    }
    final packet = WindowStreamPacket.decode(bytes);
    if (packet is WindowStreamPing) {
      unawaited(
        stream.transport?.send(
          WindowStreamPacket.pong(packet.clockUs),
          kind: OutboundPacketKind.control,
        ),
      );
      return;
    }
    if (packet is! WindowStreamInput) {
      return;
    }
    _backend.captureInput(
      capture,
      kind: packet.kind,
      code: packet.code,
      modifiers: packet.modifiers,
      x: packet.x,
      y: packet.y,
      dx: packet.dx,
      dy: packet.dy,
      phase: packet.phase,
      text: packet.text,
    );
  }

  bool _sameSound(_HostStream a, _HostStream b) =>
      a.viewerPeerId == b.viewerPeerId &&
      (a.window.pid != 0
          ? a.window.pid == b.window.pid
          : a.window.appId == b.window.appId);

  /// Turns [stream]'s app sound on (the window's sound plays over there,
  /// not here as well: the window itself is out of sight on this device),
  /// unless another window of that app already brings it to that viewer.
  bool _takeSound(_HostStream stream) {
    final capture = stream.captureId;
    if (!stream.audio ||
        stream.audioOn ||
        capture == null ||
        stream.state == HostStreamState.closed ||
        !_backend.audioSupported) {
      return false;
    }
    if (_streams.values.any(
      (other) =>
          !identical(other, stream) &&
          other.audioOn &&
          _sameSound(other, stream),
    )) {
      return false;
    }
    _backend.captureSetAudio(capture, WsnCaptureAudio.onSilentHere);
    stream.audioOn = true;
    return true;
  }

  Future<void> _stop(
    _HostStream stream, {
    required bool notify,
    String reason = '',
  }) async {
    if (stream.state == HostStreamState.closed) {
      return;
    }
    stream.state = HostStreamState.closed;
    _log(stream, 'stopped${reason.isEmpty ? '' : ': $reason'}');
    stream.tick?.cancel();
    stream.audioEncoder?.close();
    _streams.remove(stream.sessionId);
    hostedChanged.value++;
    final capture = stream.captureId;
    if (capture != null) {
      _streamByCapture.remove(capture);
      _backend.captureStop(capture);
    }
    if (stream.audioOn) {
      stream.audioOn = false;
      // Another window of the same app to the same viewer carries on.
      for (final other in _streams.values) {
        if (_sameSound(other, stream) && _takeSound(other)) {
          break;
        }
      }
    }
    await stream.transport?.close();
    await stream.input?.close();
    if (notify) {
      await stream.send(
        stream.open.reply(
          WindowStreamControlAction.stop,
          payload: {'reason': reason},
        ),
      );
    }
  }

  /// A viewer disconnected: end its streams without telling it.
  Future<void> closePeer(String peerId) async {
    for (final stream
        in _streams.values.where((s) => s.viewerPeerId == peerId).toList()) {
      await _stop(stream, notify: false);
    }
  }

  /// This device's windows shown on [peerId] right now: what 拿回来 lists.
  List<({String sessionId, String title})> hostedFor(String peerId) => [
    for (final stream in _streams.values)
      if (stream.viewerPeerId == peerId)
        (
          sessionId: stream.sessionId,
          title: stream.window.title.isEmpty
              ? stream.window.appName
              : stream.window.title,
        ),
  ];

  /// Takes one back: the viewer is told, and its window closes.
  Future<void> bringBack(String sessionId) async {
    final stream = _streams[sessionId];
    if (stream != null) await _stop(stream, notify: true);
  }

  Future<void> closeAll() async {
    for (final stream in _streams.values.toList()) {
      await _stop(stream, notify: false);
    }
  }

  @visibleForTesting
  int get streamCount => _streams.length;

  /// What each hosted stream is doing, for debug tooling.
  List<Map<String, Object?>> debugStreams() => [
    for (final stream in _streams.values)
      {
        'sessionId': stream.sessionId,
        'viewerPeerId': stream.viewerPeerId,
        'viewerKind': stream.viewerKind?.name,
        'state': stream.state.name,
        'hostDials': stream.hostDials,
        'windowId': stream.window.id,
        'appId': stream.window.appId,
        'appName': stream.window.appName,
        'captureId': stream.captureId,
        'screenKey': _screenKeyFor(stream),
        'viewport': {
          'width': stream.viewportWidth,
          'height': stream.viewportHeight,
          'scale': stream.viewportScale,
          'keyboardInset': stream.keyboardInset,
        },
        'videoInFlight': stream.videoInFlight,
        'busy': stream.busy,
        'quality': stream.quality.name,
        'bitRate': stream.bitRate,
        'audio': {
          'asked': stream.audio,
          'on': stream.audioOn,
          'paused': stream.paused,
          'in': stream.audioIn,
          'held': stream.audioHeld,
          'out': stream.audioOut,
        },
      },
  ];
}
