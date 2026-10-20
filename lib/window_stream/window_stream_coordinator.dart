import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../helper/local.dart';
import '../l10n/app_localizations.dart';
import 'adb/adb_host_client.dart';
import 'adb/adb_locator.dart';
import 'android/agent/agent_wire.dart';
import 'android/agent/android_agent_source.dart';
import 'android/android_device_props.dart';
import 'android/phone_trust.dart';
import 'android/scrcpy/scrcpy_compat_source.dart';
import 'core/window_input_event.dart';
import 'core/window_source.dart';
import 'core/window_stream_models.dart';
import 'pipeline/stream_isolate.dart';
import 'pipeline/surface_backend.dart';
import 'window_stream_log.dart';
import 'remote/remote_peer_source.dart';

/// Texts the native windows show over the video. Set from the UI so they
/// follow the app's language.
class WindowStreamStrings {
  const WindowStreamStrings({
    this.connecting = '',
    this.paused = '',
    this.reconnecting = '',
    this.displaced = '',
    this.secureBlocked = '',
    this.appExited = '',
    this.disconnected = '',
    this.deviceSeparator = ' · ',
    this.decoderMissing = '',
    this.volume = 'Volume',
    this.mute = 'Mute',
    this.unmute = 'Unmute',
    this.failure,
  });

  factory WindowStreamStrings.of(AppLocalizations l10n) {
    return WindowStreamStrings(
      connecting: l10n.windowStreamConnecting,
      paused: l10n.windowStreamPaused,
      reconnecting: l10n.windowStreamReconnecting,
      displaced: l10n.windowStreamDisplaced,
      secureBlocked: l10n.windowStreamSecureBlocked,
      appExited: l10n.windowStreamAppExited,
      disconnected: l10n.windowStreamDisconnected,
      decoderMissing: l10n.windowStreamDecoderMissing,
      volume: l10n.windowStreamVolume,
      mute: l10n.windowStreamMute,
      unmute: l10n.windowStreamUnmute,
      failure: (reason, source) => windowStreamFailureText(
        l10n,
        reason,
        platform: source.platform,
        device: source.name,
      ),
    );
  }

  /// Why a window ended, for its overlay; null until the UI set the texts.
  final String Function(WindowStreamFailureReason reason, SourceInfo source)?
  failure;

  final String connecting;
  final String paused;
  final String reconnecting;
  final String displaced;
  final String secureBlocked;
  final String appExited;
  final String disconnected;
  final String deviceSeparator;

  /// No video decoder on this computer (Linux without FFmpeg).
  final String decoderMissing;

  /// The native windows' volume control.
  final String volume;
  final String mute;
  final String unmute;
}

/// A device seen by adb, with its source once it is usable.
class WindowStreamDevice {
  const WindowStreamDevice({
    required this.adb,
    this.source,
    this.failure,
    this.peerId,
  });

  final AdbDevice adb;
  final WindowSource? source;
  final WindowStreamFailure? failure;

  /// The phone's Whisper peer id, as its Whisper reported it over adb.
  final String? peerId;
}

/// Public view of one open streamed window.
class WindowStreamSession {
  WindowStreamSession._(this.handle, this.surface, this.flutterHosted);

  final StreamHandle handle;

  /// Native window id on desktops, texture id on phones and tablets.
  final int surface;

  /// The UI shows this session in a Flutter page (texture) rather than a
  /// native window.
  final bool flutterHosted;
  bool focused = false;
  bool visible = true;
  bool firstFrameShown = false;
  bool muted = false;
  TransportStats? stats;

  /// The native window's last reported content size (points) and scale.
  Size? windowSize;
  double windowScale = 1;
  Timer? _resizeDebounce;

  /// The picture's size when the window opened.
  Size _openedVideo = Size.zero;

  /// An Android window here (adb): its display's pixels per window point and
  /// largest edge, taken once the window first matched the picture.
  double? _pixelsPerPoint;
  double _maxDisplayEdge = 0;
  DateTime _videoSizeChangedAt = DateTime.fromMillisecondsSinceEpoch(0);
  final _viewportChanges = <DateTime>[];
  DateTime _lastKeyframeRequest = DateTime.fromMillisecondsSinceEpoch(0);
  int _audioRestarts = 0;
  int _hudTicks = 0;
  DateTime? _suspendedAt;

  String get id => handle.id;
  StreamState get state => handle.state.value;
  WindowSource get source => handle.source;
}

/// Owns everything window streaming does on this device: discovery (adb
/// phones on desktops, Whisper peers that host windows everywhere), the
/// stream isolate, the surfaces and their lifecycle.
class WindowStreamCoordinator extends ChangeNotifier
    implements StreamTransportPort {
  WindowStreamCoordinator._();

  static final WindowStreamCoordinator shared = WindowStreamCoordinator._();

  AdbLocator locator = AdbLocator();
  WindowStreamStrings strings = const WindowStreamStrings();

  StreamSurfaceBackend? _backend;
  StreamSubscription<SurfaceEvent>? _backendEvents;
  StreamIsolate? _isolate;
  StreamSubscription<StreamIsolateEvent>? _isolateEvents;
  AdbHostClient? _adb;
  StreamSubscription<List<AdbDevice>>? _tracking;
  Timer? _retryTracking;
  Future<void>? _starting;
  bool _shutDown = false;
  Uint8List? _serverBytes;
  Uint8List? _agentBytes;
  AgentSidecar? _agentSidecar;
  final _agentLosses = <String, List<DateTime>>{};

  WindowStreamFailure? _adbFailure;
  final _devices = <String, WindowStreamDevice>{};
  final _sessions = <String, WindowStreamSession>{};
  final _sessionBySurface = <int, WindowStreamSession>{};
  final _creatingSources = <String>{};
  String _lastDeviceSummary = '';

  /// Recent lifecycle events for diagnostics (no user content).
  final diagnostics = <String>[];

  void _diag(String message) {
    final line =
        '${DateTime.now().toIso8601String().substring(11, 23)} $message';
    diagnostics.add(line);
    if (diagnostics.length > 200) {
      diagnostics.removeAt(0);
    }
    if (kDebugMode || Platform.isAndroid) {
      debugPrint('[window-stream] $line');
    }
    WindowStreamLog.write(line);
  }

  static bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Streamed windows can be shown on this device.
  bool get supported =>
      (_backend ?? StreamSurfaceBackend.forPlatform()) != null;

  /// Android phones over adb can be used as sources here.
  bool get adbSupported => _isDesktop;

  StreamSurfaceBackend? get backend => _backend;

  WindowStreamFailure? get adbFailure => _adbFailure;
  List<WindowStreamDevice> get devices => List.unmodifiable(_devices.values);
  List<WindowStreamSession> get sessions => List.unmodifiable(_sessions.values);

  /// Every usable source: adb phones and Whisper peers that host windows.
  ///
  /// A phone a desktop reaches both ways — its own adb forward and the
  /// phone's Whisper advertising `windowStreamSourceV1` — would otherwise
  /// appear twice. The adb path wins: it talks to the agent directly, one
  /// hop, without relaying through the phone's Whisper app, so the Whisper
  /// peer source for a phone already covered over adb is dropped.
  ///
  /// An adb phone counts only while its Whisper is connected here, as every
  /// other device does: the cable alone does not make it one to stream.
  List<WindowSource> get sources {
    final seen = <String>{};
    final adbPeerIds = <String>{
      for (final device in _devices.values)
        if (device.source != null && device.peerId != null) device.peerId!,
    };
    return [
      for (final device in _devices.values)
        if (device.source != null &&
            isAdbPhoneConnected(device) &&
            seen.add(device.source!.info.id))
          device.source!,
      for (final source in WindowStreamViewer.shared.sources)
        if (!adbPeerIds.contains(source.peerId)) source,
    ];
  }

  /// [device]'s Whisper is connected here (see [sources]).
  bool isAdbPhoneConnected(WindowStreamDevice device) {
    final peerId = device.peerId;
    return peerId != null && peerConnected(peerId);
  }

  /// Whether a Whisper peer is connected now.
  @visibleForTesting
  bool Function(String peerId) peerConnected =
      WindowStreamViewer.shared.isConnected;

  /// The Whisper peer an adb phone's source belongs to.
  String? peerIdFor(WindowSource source) {
    for (final device in _devices.values) {
      if (identical(device.source, source)) {
        return device.peerId;
      }
    }
    return null;
  }

  /// The source for a Whisper peer: its adb phone or the peer itself.
  WindowSource? sourceForPeer(String peerId) {
    for (final device in _devices.values) {
      if (device.peerId == peerId &&
          device.source != null &&
          isAdbPhoneConnected(device)) {
        return device.source;
      }
    }
    return WindowStreamViewer.shared.sourceFor(peerId);
  }

  /// Windows open from [source]: the same device, even through a newer
  /// source object for it.
  List<WindowStreamSession> sessionsFor(WindowSource source) => _sessions.values
      .where((session) => session.handle.source.info.id == source.info.id)
      .toList();

  WindowStreamSession? sessionById(String id) => _sessions[id];

  void updateStrings(AppLocalizations l10n) {
    strings = WindowStreamStrings.of(l10n);
    _pushStrings();
  }

  void _pushStrings() => _backend?.setStrings(
    volume: strings.volume,
    mute: strings.mute,
    unmute: strings.unmute,
  );

  /// The picture quality windows are streamed at here, as last chosen.
  final quality = ValueNotifier<WindowStreamQuality>(
    WindowStreamQuality.fallback,
  );
  static const _qualityKey = 'window_stream.quality';
  Future<void>? _qualityLoaded;

  /// Reads the quality chosen before (once).
  Future<void> loadQuality() => _qualityLoaded ??= () async {
    try {
      final prefs = await SharedPreferences.getInstance();
      quality.value = WindowStreamQuality.fromName(
        prefs.getString(_qualityKey),
      );
    } catch (_) {
      // Settings unavailable: the default stands.
    }
  }();

  /// Streams every open window and every one opened later at [value].
  Future<void> setQuality(WindowStreamQuality value) async {
    quality.value = value;
    for (final session in _sessions.values) {
      session.handle.setStreamQuality(value);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qualityKey, value.name);
  }

  /// Starts discovery and the stream isolate. Idempotent.
  Future<void> start() {
    _shutDown = false;
    return _starting ??= _start().catchError((Object error) {
      _starting = null;
      throw error;
    });
  }

  Future<void> _start() async {
    final backend = StreamSurfaceBackend.forPlatform();
    if (backend == null) {
      throw const WindowStreamFailure(
        WindowStreamFailureReason.nativeUnavailable,
      );
    }
    _backend = backend;
    _pushStrings();
    _backendEvents = backend.events.listen(_onSurfaceEvent);
    _idleCheck ??= Timer.periodic(const Duration(minutes: 1), (_) {
      _closeIdleWindows();
    });
    final isolate = await StreamIsolate.spawn();
    _isolate = isolate;
    WindowStreamViewer.shared.inputPort = input;
    WindowStreamViewer.shared.addListener(notifyListeners);
    _isolateEvents = isolate.events.listen(_onIsolateEvent);
    if (_isDesktop) {
      await _startTracking();
    }
  }

  Future<void> _startTracking() async {
    _retryTracking?.cancel();
    try {
      _adb = await locator.ensureServer(client: _adb);
      _adbFailure = null;
    } on WindowStreamFailure catch (failure) {
      _adbFailure = failure;
      notifyListeners();
      _scheduleTrackingRetry();
      return;
    }
    await _tracking?.cancel();
    _tracking = _adb!.trackDevices().listen(
      _onDevices,
      onError: (Object error) {
        _adbFailure = WindowStreamFailure(
          WindowStreamFailureReason.adbServerFailed,
          '$error',
        );
        notifyListeners();
        _scheduleTrackingRetry();
      },
      onDone: _scheduleTrackingRetry,
    );
    notifyListeners();
  }

  void _scheduleTrackingRetry() {
    if (_shutDown) {
      return;
    }
    _retryTracking?.cancel();
    _retryTracking = Timer(const Duration(seconds: 3), () {
      unawaited(_startTracking());
    });
  }

  /// Retries after the user fixed something (installed adb, allowed USB
  /// debugging…).
  Future<void> retry() => _startTracking();

  void _onDevices(List<AdbDevice> all) {
    // adb keeps wireless phones it once saw as "offline" for a long time;
    // only phones that are there now (or waiting for "allow debugging")
    // belong in the list.
    final list = [
      for (final device in all)
        if (device.state != AdbDeviceState.offline &&
            device.state != AdbDeviceState.other)
          device,
    ];
    final summary = all
        .map((d) => '${d.usb ? 'usb' : 'net'}:${d.state.name}')
        .join(',');
    if (summary != _lastDeviceSummary) {
      _lastDeviceSummary = summary;
      _diag('devices $summary');
    }
    final present = {for (final device in list) device.serial: device};
    for (final serial in _devices.keys.toList()) {
      if (present.containsKey(serial)) {
        continue;
      }
      final gone = _devices.remove(serial);
      final source = gone?.source;
      if (source == null) {
        continue;
      }
      // Another transport of the same phone may still be connected.
      WindowStreamDevice? remaining;
      for (final other in _devices.values) {
        if (identical(other.source, source)) {
          remaining = other;
          break;
        }
      }
      if (remaining != null) {
        if (source is ScrcpyCompatSource && source.serial == serial) {
          source.serial = remaining.adb.serial;
          continue;
        }
        if (source is! AndroidAgentSource || source.serial != serial) {
          continue;
        }
        // The agent's forward lived on the transport that went away; start
        // it again through the one that is left.
        for (final entry in _devices.entries.toList()) {
          if (identical(entry.value.source, source)) {
            _devices[entry.key] = WindowStreamDevice(adb: entry.value.adb);
          }
        }
      }
      _closeSessionsOf(source);
      unawaited(source.dispose());
    }
    for (final device in list) {
      final existing = _devices[device.serial];
      _devices[device.serial] = WindowStreamDevice(
        adb: device,
        source: device.ready ? existing?.source : null,
        failure: existing?.failure,
        peerId: existing?.peerId,
      );
      if (device.ready && existing?.source == null) {
        unawaited(_createSource(device));
      }
    }
    notifyListeners();
  }

  Future<void> _createSource(AdbDevice device) async {
    final adb = _adb;
    if (adb == null || !_creatingSources.add(device.serial)) {
      return;
    }
    try {
      // Only phones whose Whisper is paired with this device and trusted.
      final trust = await trustCheck(adb, device.serial);
      final denied = trust.denied;
      if (denied != null) {
        if (_devices.containsKey(device.serial)) {
          _devices[device.serial] = WindowStreamDevice(
            adb: device,
            failure: WindowStreamFailure(denied),
            peerId: trust.peerId,
          );
        }
        _diag('device not trusted: ${denied.name}');
        _scheduleTrustRecheck();
        return;
      }
      final props = await AndroidDeviceProps.read(
        adb,
        device.serial,
        fallbackModel: device.model,
      );
      // The same phone can be reachable over USB and wireless debugging at
      // once (two adb serials); keep one source per phone.
      WindowSource? twin;
      for (final other in _devices.values) {
        final candidate = other.source;
        if (candidate != null && candidate.info.id == props.stableId) {
          twin = candidate;
          break;
        }
      }
      final source = twin ?? await _launchAndroidSource(adb, device, props);
      if (twin is ScrcpyCompatSource && device.usb) {
        twin.serial = device.serial;
      }
      if (twin == null && source is AndroidAgentSource) {
        source.state.addListener(() => _onAgentLost(source));
        source.touchBlocked.stream.listen(
          (apps) => _touchAlerts.add(PhoneTouchAlert(source, apps)),
        );
      }
      if (_devices.containsKey(device.serial)) {
        _devices[device.serial] = WindowStreamDevice(
          adb: device,
          source: source,
          peerId: trust.peerId,
        );
      }
    } catch (error) {
      _devices[device.serial] = WindowStreamDevice(
        adb: device,
        failure: error is WindowStreamFailure
            ? error
            : WindowStreamFailure(
                WindowStreamFailureReason.connectionFailed,
                '$error',
              ),
      );
    } finally {
      _creatingSources.remove(device.serial);
      notifyListeners();
    }
  }

  final _touchAlerts = StreamController<PhoneTouchAlert>.broadcast();

  /// A phone whose own screen stopped taking touches because of an app our
  /// streaming left behind; the UI asks whether to close it.
  Stream<PhoneTouchAlert> get touchAlerts => _touchAlerts.stream;

  /// Decides whether an adb phone may be streamed (see [PhoneTrust]).
  @visibleForTesting
  PhoneTrustCheck trustCheck = PhoneTrust.check;
  Timer? _trustRecheck;

  /// Pairing happens in Whisper while the phone stays plugged in: look
  /// again every few seconds until every refused phone is let in or gone.
  void _scheduleTrustRecheck() {
    _trustRecheck ??= Timer.periodic(const Duration(seconds: 4), (_) {
      final refused = [
        for (final entry in _devices.values)
          if (entry.source == null &&
              entry.adb.ready &&
              (entry.failure?.reason ==
                      WindowStreamFailureReason.untrustedDevice ||
                  entry.failure?.reason ==
                      WindowStreamFailureReason.whisperMissing))
            entry.adb,
      ];
      if (refused.isEmpty || _shutDown) {
        _trustRecheck?.cancel();
        _trustRecheck = null;
        return;
      }
      for (final device in refused) {
        unawaited(_createSource(device));
      }
    });
  }

  /// The agent died or its connection dropped while the phone is still
  /// there: start it again, or use the fallback if it keeps failing.
  void _onAgentLost(AndroidAgentSource source) {
    if (_shutDown || source.state.value.status != SourceStatus.unavailable) {
      return;
    }
    final affected = [
      for (final entry in _devices.entries)
        if (identical(entry.value.source, source)) entry.value.adb,
    ];
    if (affected.isEmpty) {
      return; // Already replaced or removed.
    }
    final now = DateTime.now();
    final losses = _agentLosses.putIfAbsent(source.info.id, () => [])
      ..removeWhere((time) => now.difference(time) > const Duration(minutes: 2))
      ..add(now);
    _diag('agent lost (${losses.length} in 2 min)');
    for (final device in affected) {
      _devices[device.serial] = WindowStreamDevice(adb: device);
    }
    _closeSessionsOf(source);
    unawaited(source.dispose());
    notifyListeners();
    Timer(const Duration(seconds: 1), () {
      final device = affected.first;
      if (!_shutDown && _devices[device.serial]?.source == null) {
        unawaited(_createSource(device));
      }
    });
  }

  /// whisper-agent when it starts, else the stock scrcpy-server fallback.
  Future<WindowSource> _launchAndroidSource(
    AdbHostClient adb,
    AdbDevice device,
    AndroidDeviceProps props,
  ) async {
    final losses = _agentLosses[props.stableId] ?? const <DateTime>[];
    if (losses.length >= 3) {
      _diag('agent keeps failing, using scrcpy fallback');
      return ScrcpyCompatSource.create(
        adb: adb,
        device: device,
        props: props,
        serverBytes: _loadServerBytes,
        port: this,
      );
    }
    try {
      final source = await AndroidAgentSource.launch(
        adb: adb,
        device: device,
        props: props,
        sidecar: await _loadAgentSidecar(),
        jarBytes: _loadAgentBytes,
        port: this,
        viewerName: await LocalSetting().deviceDisplayName(),
      );
      _diag('agent ready sdk=${props.sdk}');
      return source;
    } catch (error) {
      _diag('agent failed, using scrcpy fallback: $error');
      return ScrcpyCompatSource.create(
        adb: adb,
        device: device,
        props: props,
        serverBytes: _loadServerBytes,
        port: this,
      );
    }
  }

  Future<AgentSidecar> _loadAgentSidecar() async {
    return _agentSidecar ??= AgentSidecar.fromJson(
      jsonDecode(
            await rootBundle.loadString(
              'assets/window_stream/whisper-agent.json',
            ),
          )
          as Map<String, dynamic>,
    );
  }

  Future<Uint8List> _loadAgentBytes() async {
    final cached = _agentBytes;
    if (cached != null) {
      return cached;
    }
    final data = await rootBundle.load(
      'assets/window_stream/whisper-agent.jar',
    );
    return _agentBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  }

  Future<Uint8List> _loadServerBytes() async {
    final cached = _serverBytes;
    if (cached != null) {
      return cached;
    }
    final data = await rootBundle.load(
      'assets/window_stream/scrcpy-server-v5.0.1',
    );
    return _serverBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  }

  /// Opens [target] from [source] in a new window (native on desktops, a
  /// texture for the viewer page on phones and tablets).
  Future<WindowStreamSession> open(
    WindowSource source,
    OpenTarget target, {
    StreamOptions options = const StreamOptions(),
  }) async {
    await start();
    final backend = _backend!;
    final isolate = _isolate!;
    // One window in one place: one already open here comes forward.
    final open = openSessionFor(source, target);
    if (open != null) {
      backend.focus(open.surface);
      return open;
    }
    await loadQuality();
    final handle = await source.open(
      target,
      options.withQuality(quality.value),
    );
    final title =
        '${handle.title}${strings.deviceSeparator}${source.info.name}';
    final initial = handle.state.value;
    final videoWidth = initial.videoWidth ?? options.displayWidth ?? 1080;
    final videoHeight = initial.videoHeight ?? options.displayHeight ?? 2400;
    final surface = await backend.create(
      title: title,
      width: videoWidth,
      height: videoHeight,
      hud: kDebugMode,
      // The other side lays the window out for this window's size.
      reflow:
          handle is RemoteStreamHandle || source.info.capabilities.resizeReflow,
    );
    backend.setVisual(surface, SurfaceVisual.connecting, strings.connecting);
    // The app's own icon on its window (title bar, Dock when minimized).
    unawaited(
      source.icon(target.appId).then<void>((png) {
        if (png != null && _sessionBySurface.containsKey(surface)) {
          backend.setIcon(surface, png);
        }
      }, onError: (Object _) {}),
    );
    final session = WindowStreamSession._(
      handle,
      surface,
      backend.flutterHosted,
    );
    session._openedVideo = Size(videoWidth.toDouble(), videoHeight.toDouble());
    _sessions[handle.id] = session;
    _sessionBySurface[surface] = session;
    unawaited(_restoreVolume(session));
    handle.state.addListener(() => _onStreamState(session));
    // The window opened at the size the native picked for the picture's
    // shape; the host lays the window out for exactly that (the guess
    // sent with `open` may have been made before the shape was known).
    if (!backend.flutterHosted && handle is RemoteStreamHandle) {
      final planned = RemoteViewport.desktopWindow(videoWidth, videoHeight);
      unawaited(
        handle.setViewport(
          width: planned.width.round(),
          height: planned.height.round(),
        ),
      );
    }
    isolate.attach(
      streamId: handle.id,
      surface: surface,
      spec: handle.transport,
      scrollMode: _scrollModeFor(target.appId),
    );
    notifyListeners();
    return session;
  }

  /// The live window here showing [target] of [source], if any: the same
  /// task (or, opening an app, any of its windows) of the same device.
  WindowStreamSession? openSessionFor(WindowSource source, OpenTarget target) {
    for (final session in _sessions.values) {
      final open = session.handle.target;
      if (session.handle.source.info.id == source.info.id &&
          open.appId == target.appId &&
          (target is! OpenTask ||
              open is! OpenTask ||
              open.task.id == target.task.id) &&
          !session.state.isTerminal) {
        return session;
      }
    }
    return null;
  }

  /// Each app of each device keeps the volume last set in its window.
  static String _volumeKey(WindowStreamSession session) =>
      'window_stream.volume.${session.source.info.id}/'
      '${session.handle.target.appId}';

  Future<void> _restoreVolume(WindowStreamSession session) async {
    if (session.flutterHosted) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final volume = prefs.getDouble(_volumeKey(session));
    if (volume != null && _sessions.containsKey(session.id)) {
      _backend?.setVolume(session.surface, volume);
    }
  }

  Future<void> _saveVolume(WindowStreamSession session, double volume) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeKey(session), volume);
  }

  /// Short-video apps page with vertical swipes that ignore scroll events.
  ScrollMode _scrollModeFor(String appId) {
    const pagers = {
      'com.kylin.read',
      'com.phoenix.read',
      'com.ss.android.ugc.aweme',
      'com.smile.gifmaker',
      'com.kuaishou.nebula',
      'com.tencent.weishi',
    };
    return pagers.contains(appId) ? ScrollMode.drag : ScrollMode.wheel;
  }

  /// Writes the window's last frame as JPEG (thumbnails, text recognition).
  bool snapshot(WindowStreamSession session, String path, {int maxEdge = 0}) {
    return _backend?.snapshot(session.surface, path, maxEdge: maxEdge) ?? false;
  }

  /// The window's last frame as JPEG bytes, on desktops and on phones and
  /// tablets whose decoder can read it back (iOS); null otherwise.
  Future<Uint8List?> snapshotJpeg(
    WindowStreamSession session, {
    int maxEdge = 0,
  }) async => await _backend?.snapshotJpeg(session.surface, maxEdge: maxEdge);

  void focus(WindowStreamSession session) => _backend?.focus(session.surface);

  Future<void> pause(WindowStreamSession session) async {
    if (session.source.info.capabilities.suspend) {
      await session.handle.suspend();
    }
  }

  Future<void> resume(WindowStreamSession session) async {
    if (session.source.info.capabilities.suspend) {
      await session.handle.resume();
    }
  }

  Future<void> close(
    WindowStreamSession session, {
    CloseMode mode = CloseMode.returnToSource,
  }) {
    return _teardown(session, mode: mode);
  }

  Future<void> _teardown(
    WindowStreamSession session, {
    CloseMode mode = CloseMode.returnToSource,
  }) async {
    if (_sessions.remove(session.id) == null) {
      return;
    }
    _sessionBySurface.remove(session.surface);
    session._resizeDebounce?.cancel();
    _isolate?.detach(session.id);
    await _backend?.destroy(session.surface);
    notifyListeners();
    await session.handle.close(mode: mode);
  }

  Timer? _idleCheck;

  /// A window left paused in the phone's dock still holds a display and a
  /// running app on the other device; give that back after a while.
  static const idlePausedLimit = Duration(minutes: 10);

  void _closeIdleWindows() {
    final now = DateTime.now();
    for (final session in _sessions.values.toList()) {
      final since = session._suspendedAt;
      if (session.flutterHosted &&
          since != null &&
          now.difference(since) > idlePausedLimit) {
        _diag('stream ${session.id} closed after a long pause');
        unawaited(_teardown(session));
      }
    }
  }

  void _closeSessionsOf(WindowSource source) {
    for (final session in sessionsFor(source)) {
      unawaited(_teardown(session));
    }
  }

  void _onStreamState(WindowStreamSession session) {
    final backend = _backend;
    if (backend == null || !_sessions.containsKey(session.id)) {
      return;
    }
    final state = session.state;
    _diag(
      'stream ${session.id} -> ${state.status.name} ${state.failure ?? ''}',
    );
    session._suspendedAt = state.status == StreamStatus.suspended
        ? (session._suspendedAt ?? DateTime.now())
        : null;
    final surface = session.surface;
    switch (state.status) {
      case StreamStatus.opening:
        backend.setVisual(
          surface,
          SurfaceVisual.connecting,
          strings.connecting,
        );
      case StreamStatus.live:
        if (session.firstFrameShown) {
          backend.setVisual(surface, SurfaceVisual.live, '');
        }
      case StreamStatus.suspended:
        backend.setVisual(surface, SurfaceVisual.paused, strings.paused);
      case StreamStatus.reconnecting:
        backend.setVisual(
          surface,
          SurfaceVisual.reconnecting,
          strings.reconnecting,
        );
      case StreamStatus.displaced:
        backend.setVisual(surface, SurfaceVisual.displaced, strings.displaced);
      case StreamStatus.secureBlocked:
        backend.setVisual(surface, SurfaceVisual.secure, strings.secureBlocked);
      case StreamStatus.appExited:
        backend.setVisual(surface, SurfaceVisual.exited, strings.appExited);
      case StreamStatus.closed:
        final failure = state.failure;
        if (failure != null) {
          // Keep the window with an explanation; the user closes it.
          _isolate?.detach(session.id);
          backend.setVisual(
            surface,
            SurfaceVisual.error,
            _closedText(failure, session.source.info),
          );
          if (failure.reason == WindowStreamFailureReason.movedAway) {
            // It went to the other device on purpose: say so, then go.
            Timer(const Duration(milliseconds: 2500), () {
              if (_sessions.containsKey(session.id)) {
                unawaited(_teardown(session));
              }
            });
          }
        } else {
          unawaited(_teardown(session));
        }
    }
    notifyListeners();
  }

  /// What a window that ended with [failure] says: the host-side reason
  /// when there is something to do about it, else "disconnected".
  String _closedText(WindowStreamFailure failure, SourceInfo source) {
    switch (failure.reason) {
      case WindowStreamFailureReason.deviceDisconnected ||
          WindowStreamFailureReason.deviceOffline ||
          WindowStreamFailureReason.connectionFailed ||
          WindowStreamFailureReason.decoderFailed ||
          WindowStreamFailureReason.unknown:
        return strings.disconnected;
      default:
        return strings.failure?.call(failure.reason, source) ??
            strings.disconnected;
    }
  }

  void _onIsolateEvent(StreamIsolateEvent message) {
    final session = _sessions[message.streamId];
    if (session == null) {
      return;
    }
    final event = message.event;
    if (event is TransportVideoSize) {
      final before = session.state;
      if (before.videoWidth != null &&
          (before.videoWidth != event.width ||
              before.videoHeight != event.height)) {
        session._videoSizeChangedAt = DateTime.now();
      }
    }
    if (event is! TransportStats) {
      _diag(
        'transport ${message.streamId} ${event.runtimeType}'
        '${event is TransportEnded ? ' ${event.failure}' : ''}',
      );
    }
    if (event is TransportStats) {
      session.stats = event;
      _updateHud(session);
      return;
    }
    session.handle.onTransportEvent(event);
  }

  void _updateHud(WindowStreamSession session) {
    final backend = _backend;
    final stats = session.stats;
    if (backend == null || stats == null) {
      return;
    }
    // A window shown in Flutter (phones): what arrives, and the round trip.
    if (session.flutterHosted) {
      if (++session._hudTicks % 30 == 0) {
        _diag(
          'stream ${session.id} received fps=${stats.videoFps.round()} '
          'video=${stats.videoKbps.round()}kbps '
          'rtt=${stats.rttMs?.toStringAsFixed(1) ?? '-'}ms',
        );
      }
      return;
    }
    final native = backend.stats(session.surface);
    if (native.length > 8) {
      // Each restart is an audible gap: the network starved the renderer.
      final restarts = native[5].toInt();
      if (restarts > session._audioRestarts) {
        _diag(
          'stream ${session.id} audio restarts=$restarts '
          'resyncs=${native[6].toInt()} latency=${native[8].toInt()}ms',
        );
        session._audioRestarts = restarts;
      }
    }
    // A line every half minute, so the log shows how a stream went.
    if (++session._hudTicks % 30 == 0 && native.length > 8) {
      _diag(
        'stream ${session.id} fps=${native[0].toStringAsFixed(0)} '
        'dropped=${native[1].toInt()} decode=${native[2].toStringAsFixed(1)}ms '
        'video=${stats.videoKbps.round()}kbps audio=${stats.audioKbps.round()}kbps '
        'lead=${native[7].toStringAsFixed(0)}ms latency=${native[8].toInt()}ms',
      );
    }
    if (!kDebugMode) {
      return;
    }
    final decodeMs = native.length > 2 ? native[2] : 0.0;
    final dropped = native.length > 1 ? native[1].toInt() : 0;
    final shownFps = native.isNotEmpty ? native[0] : 0.0;
    final audio = native.length > 8 && stats.audioKbps > 0
        ? '  ♪ ${native[7].toStringAsFixed(0)}/${native[8].toInt()} ms'
              ' ×${native[5].toInt()}'
        : '';
    backend.setHud(
      session.surface,
      '${stats.videoFps.toStringAsFixed(0)}→${shownFps.toStringAsFixed(0)} fps  '
      '${(stats.videoKbps / 1000).toStringAsFixed(1)} Mbps  '
      '${decodeMs.toStringAsFixed(1)} ms  ×$dropped$audio',
    );
  }

  void _onSurfaceEvent(SurfaceEvent event) {
    final session = _sessionBySurface[event.surface];
    if (event is! SurfaceFocusChanged && event is! SurfaceVisibilityChanged) {
      _diag('surface ${event.surface} ${event.runtimeType}');
    }
    if (session == null) {
      if (event is SurfaceCloseRequested) {
        unawaited(_backend?.destroy(event.surface));
      }
      return;
    }
    switch (event) {
      case SurfaceCloseRequested():
        unawaited(_teardown(session));
      case SurfaceFocusChanged(:final focused):
        session.focused = focused;
        session.handle.setQuality(
          focused ? QualityTier.focused : QualityTier.background,
        );
      case SurfaceVisibilityChanged(:final visible):
        session.visible = visible;
        if (session.source.info.capabilities.suspend &&
            session.state.status != StreamStatus.closed) {
          unawaited(
            visible ? session.handle.resume() : session.handle.suspend(),
          );
        }
      case SurfaceFirstFrame():
        session.firstFrameShown = true;
        if (session.state.status == StreamStatus.live) {
          _backend?.setVisual(session.surface, SurfaceVisual.live, '');
        }
      case SurfaceNeedsKeyframe():
        final now = DateTime.now();
        if (now.difference(session._lastKeyframeRequest) >
            const Duration(milliseconds: 500)) {
          session._lastKeyframeRequest = now;
          session.handle.requestKeyframe();
        }
      case SurfaceAction(:final resume):
        if (resume) {
          unawaited(session.handle.resume());
        }
      case SurfaceResized(:final width, :final height, :final scale):
        _onWindowResized(session, Size(width, height), scale);
      case SurfaceVolumeChanged(:final volume):
        unawaited(_saveVolume(session, volume));
      case SurfaceDecodeError(:final missingDecoder):
        if (missingDecoder) {
          _backend?.setVisual(
            session.surface,
            SurfaceVisual.error,
            strings.decoderMissing,
          );
        }
    }
    notifyListeners();
  }

  /// A native window was resized (or first laid out). Another Whisper
  /// device fits the streamed window to it, as an app here would reflow; an
  /// Android phone over adb gives its display the window's shape at the
  /// density it opened with, so the app lays itself out again.
  void _onWindowResized(WindowStreamSession session, Size size, double scale) {
    session.windowSize = size;
    session.windowScale = scale;
    final handle = session.handle;
    if (session.flutterHosted) {
      return;
    }
    if (handle is RemoteStreamHandle) {
      handle.setPixelRatio(scale);
    } else if (!session.source.info.capabilities.resizeReflow) {
      return;
    }
    session._resizeDebounce?.cancel();
    session._resizeDebounce = Timer(
      const Duration(milliseconds: 250),
      () => _applyWindowSize(session),
    );
  }

  void _applyWindowSize(WindowStreamSession session) {
    final size = session.windowSize;
    if (size == null ||
        size.isEmpty ||
        !_sessions.containsKey(session.id) ||
        session.state.isTerminal) {
      return;
    }
    final handle = session.handle;
    final now = DateTime.now();
    final state = session.state;
    final videoWidth = state.videoWidth ?? 0;
    final videoHeight = state.videoHeight ?? 0;
    final matchesPicture =
        videoWidth > 0 &&
        videoHeight > 0 &&
        ((size.width / size.height) / (videoWidth / videoHeight) - 1).abs() <
            0.02;
    // A window that just followed a new picture shape reports that size;
    // passing it back would make the host re-layout in a loop.
    if (matchesPicture &&
        now.difference(session._videoSizeChangedAt) <
            const Duration(milliseconds: 1200)) {
      return;
    }
    final Size wanted;
    final Size current;
    if (handle is RemoteStreamHandle) {
      wanted = Size(size.width.roundToDouble(), size.height.roundToDouble());
      current = handle.viewport;
    } else {
      // The display's own density: pixels per point as the window first
      // showed the whole picture, never more pixels than it opened with.
      final perPoint = session._pixelsPerPoint ??= matchesPicture
          ? videoWidth / size.width
          : null;
      if (perPoint == null) {
        return;
      }
      if (session._maxDisplayEdge <= 0) {
        session._maxDisplayEdge = math.max(
          math.max(videoWidth, videoHeight).toDouble(),
          session._openedVideo.longestSide,
        );
      }
      wanted = androidDisplaySize(
        size,
        pixelsPerPoint: perPoint,
        maxEdge: session._maxDisplayEdge,
      );
      current = Size(videoWidth.toDouble(), videoHeight.toDouble());
    }
    if ((current.width - wanted.width).abs() < 2 &&
        (current.height - wanted.height).abs() < 2) {
      return;
    }
    session._viewportChanges.removeWhere(
      (at) => now.difference(at) > const Duration(seconds: 5),
    );
    if (session._viewportChanges.length >= 6) {
      _diag('stream ${session.id} resizing too often; keeping its size');
      return;
    }
    session._viewportChanges.add(now);
    _diag(
      'stream ${session.id} window ${size.width.round()}x'
      '${size.height.round()} @${session.windowScale}x -> '
      '${wanted.width.round()}x${wanted.height.round()}',
    );
    unawaited(
      handle.setViewport(
        width: wanted.width.round(),
        height: wanted.height.round(),
      ),
    );
  }

  /// The pixels of an Android display for a window of [window] points:
  /// [pixelsPerPoint] as it opened, the longer edge at most [maxEdge] (the
  /// phone's encoder made that much), both even.
  @visibleForTesting
  static Size androidDisplaySize(
    Size window, {
    required double pixelsPerPoint,
    required double maxEdge,
  }) {
    var width = window.width * pixelsPerPoint;
    var height = window.height * pixelsPerPoint;
    final longest = math.max(width, height);
    if (maxEdge > 0 && longest > maxEdge) {
      width *= maxEdge / longest;
      height *= maxEdge / longest;
    }
    int even(double value) => math.max(16, value.round() & ~1);
    return Size(even(width).toDouble(), even(height).toDouble());
  }

  // StreamTransportPort

  @override
  void control(String streamId, Uint8List bytes) =>
      _isolate?.control(streamId, bytes);

  @override
  void input(String streamId, WindowInputEvent event) =>
      _isolate?.input(streamId, event);

  /// Closes every window and stops discovery. Called on app exit.
  Future<void> shutdown() async {
    _shutDown = true;
    _retryTracking?.cancel();
    _idleCheck?.cancel();
    _idleCheck = null;
    _trustRecheck?.cancel();
    _trustRecheck = null;
    await _tracking?.cancel();
    _tracking = null;
    for (final session in _sessions.values.toList()) {
      await _teardown(session);
    }
    for (final device in _devices.values) {
      await device.source?.dispose();
    }
    _devices.clear();
    WindowStreamViewer.shared.removeListener(notifyListeners);
    await _isolateEvents?.cancel();
    await _isolate?.dispose();
    _isolate = null;
    await _backendEvents?.cancel();
    final backend = _backend;
    if (backend is NativeWindowBackend) {
      backend.dispose();
    }
    _backend = null;
    _starting = null;
  }
}

/// See [WindowStreamCoordinator.touchAlerts].
class PhoneTouchAlert {
  const PhoneTouchAlert(this.source, this.apps);

  final AndroidAgentSource source;
  final List<BlockedApp> apps;
}

/// What to tell the user when a window can't be opened or ended with
/// [reason]. [platform] and [device] describe the device that hosts the
/// window, so the advice says what to do over there.
String windowStreamFailureText(
  AppLocalizations l10n,
  WindowStreamFailureReason reason, {
  WindowStreamPlatform? platform,
  String device = '',
}) {
  // "That device" when the device has no name yet, capitalized where it
  // starts a sentence.
  final named = device.isNotEmpty;
  final who = named ? device : l10n.windowStreamThatDevice;
  String text(String Function(String) message) {
    final out = message(who);
    return !named && out.startsWith(who)
        ? out[0].toUpperCase() + out.substring(1)
        : out;
  }

  return switch (reason) {
    WindowStreamFailureReason.adbUnavailable => l10n.windowStreamAdbMissing,
    WindowStreamFailureReason.adbServerFailed => l10n.windowStreamAdbFailed,
    WindowStreamFailureReason.deviceUnauthorized =>
      l10n.windowStreamUnauthorized,
    WindowStreamFailureReason.deviceOffline ||
    WindowStreamFailureReason.deviceDisconnected =>
      l10n.windowStreamDeviceOffline,
    WindowStreamFailureReason.injectPermissionDenied =>
      l10n.windowStreamInjectDenied,
    WindowStreamFailureReason.androidTooOld => l10n.windowStreamAndroidTooOld,
    WindowStreamFailureReason.nativeUnavailable => l10n.windowStreamUnsupported,
    WindowStreamFailureReason.untrustedDevice => l10n.windowStreamUntrusted,
    WindowStreamFailureReason.whisperMissing => l10n.windowStreamWhisperMissing,
    WindowStreamFailureReason.sourceLocked =>
      device.isEmpty
          ? l10n.windowStreamSourceLocked
          : text(l10n.windowStreamHostLocked),
    WindowStreamFailureReason.capturePermission => switch (platform) {
      WindowStreamPlatform.windows ||
      WindowStreamPlatform.linux => text(l10n.windowStreamHostPermission),
      _ =>
        device.isEmpty
            ? l10n.windowStreamCapturePermission
            : text(l10n.windowStreamHostPermissionMac),
    },
    WindowStreamFailureReason.helperUnavailable => text(
      l10n.windowStreamHostHelper,
    ),
    WindowStreamFailureReason.agentNotRunning => text(
      l10n.windowStreamPhoneServiceOff,
    ),
    WindowStreamFailureReason.movedAway => l10n.windowStreamMovedAway,
    WindowStreamFailureReason.desktopUnsupported => text(
      l10n.windowStreamHostDesktopUnsupported,
    ),
    WindowStreamFailureReason.elevatedWindow => text(
      l10n.windowStreamHostElevated,
    ),
    WindowStreamFailureReason.windowProtected => l10n.windowStreamHostProtected,
    WindowStreamFailureReason.encoderFailed => switch (platform) {
      // Linux encodes with the system FFmpeg, which may lack H.264.
      WindowStreamPlatform.linux => text(l10n.windowStreamHostEncoderLinux),
      _ => text(l10n.windowStreamHostEncoder),
    },
    WindowStreamFailureReason.hostUnsupported => switch (platform) {
      WindowStreamPlatform.windows => text(
        l10n.windowStreamHostUnsupportedWindows,
      ),
      WindowStreamPlatform.macos => text(l10n.windowStreamHostUnsupportedMac),
      WindowStreamPlatform.linux => text(
        l10n.windowStreamHostDesktopUnsupported,
      ),
      _ => text(l10n.windowStreamHostUnsupported),
    },
    _ => l10n.windowStreamOpenFailed,
  };
}
