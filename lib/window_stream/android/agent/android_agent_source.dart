import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../adb/adb_host_client.dart';
import '../../core/window_input_event.dart';
import '../../core/window_source.dart';
import '../../core/window_stream_models.dart';
import '../android_device_props.dart';
import '../scrcpy/scrcpy_compat_source.dart' show StreamTransportPort;
import '../scrcpy/scrcpy_protocol.dart';
import 'agent_control_client.dart';
import 'agent_launch.dart';
import 'agent_wire.dart';

/// Android source backed by whisper-agent: one persistent shell-side
/// process per phone serves every window (virtual displays, encoders,
/// per-app audio, input), plus icons, recents with snapshots, pause and the
/// UI tree. The agent gives this desktop's windows back to the phone 20 s
/// after this desktop goes away, so a crash never strands apps on hidden
/// displays; the agent itself stays for the phone's other viewers.
class AndroidAgentSource implements WindowSource, ClosesTasks {
  AndroidAgentSource._({
    required this.adb,
    required this.serial,
    required this.props,
    required this.port,
    required AgentControlClient control,
    required Uint8List token,
    required int localPort,
    required Set<String> agentCapabilities,
  }) : _control = control,
       _token = token,
       _localPort = localPort,
       info = SourceInfo(
         id: props.stableId,
         name: props.displayName,
         model: props.model,
         osVersion: props.release,
         platform: WindowStreamPlatform.android,
         capabilities: SourceCapabilities(
           appIcons: agentCapabilities.contains('icons'),
           recents: agentCapabilities.contains('tasks'),
           taskSnapshots: agentCapabilities.contains('snapshots'),
           moveTask: true,
           detachesFromSourceScreen: true,
           suspend: agentCapabilities.contains('suspend'),
           perAppAudio: agentCapabilities.contains('perAppAudio'),
           audio: agentCapabilities.contains('perAppAudio'),
           uiTree: agentCapabilities.contains('uiTree'),
           resizeReflow: true,
         ),
       ) {
    _events = control.events.listen(_onEvent);
    unawaited(control.done.then((_) => _onDisconnected()));
  }

  /// Connects to the phone's persistent whisper-agent, starting it first
  /// when none runs (or replacing an older build that streams nothing).
  /// The agent outlives this desktop and serves every other device too:
  /// the phone's own Whisper offers its windows to desktops without adb
  /// through it. Session agents and fallback servers an older Whisper left
  /// behind still hold virtual displays, so they are ended first.
  static Future<AndroidAgentSource> launch({
    required AdbHostClient adb,
    required AdbDevice device,
    required AndroidDeviceProps props,
    required AgentSidecar sidecar,
    required Future<Uint8List> Function() jarBytes,
    required StreamTransportPort port,
    String viewerName = '',
  }) async {
    if (props.sdk < 29) {
      throw const WindowStreamFailure(WindowStreamFailureReason.androidTooOld);
    }
    if (sidecar.protocol != AgentWire.protocolVersion) {
      throw WindowStreamFailure(
        WindowStreamFailureReason.serverStartFailed,
        'bundled agent speaks protocol ${sidecar.protocol}',
      );
    }
    final serial = device.serial;
    final probe = AgentLaunch.parseProbe(
      (await adb.shell(serial, AgentLaunch.probeScript(sidecar))).stdout,
      sidecar,
    );
    var running = probe.running;
    if (running != null &&
        (!running.hasToken ||
            await _replaceIfOlder(adb, serial, running, sidecar))) {
      running = null;
    }
    if (running == null) {
      if (!probe.jarPresent) {
        await adb.push(serial, await jarBytes(), sidecar.devicePath);
      }
      final started = await adb.shell(
        serial,
        AgentLaunch.startScript(sidecar),
        timeout: const Duration(seconds: 12),
      );
      running = AgentLaunch.parseStart(started.stdout);
      if (running == null || !running.hasToken) {
        throw WindowStreamFailure(
          WindowStreamFailureReason.serverStartFailed,
          'agent did not start: ${started.stdout} ${started.stderr}',
        );
      }
    }
    if (running.protocol != AgentWire.protocolVersion) {
      throw WindowStreamFailure(
        WindowStreamFailureReason.serverStartFailed,
        'phone runs agent protocol ${running.protocol}',
      );
    }
    int? localPort;
    try {
      localPort = await adb.forward(serial, 'localabstract:${running.socket}');
      final control = await AgentControlClient.connect(
        port: localPort,
        token: running.token,
      );
      // The name appears in the phone's "being streamed" notice.
      final hello = await control.call('hello', {'viewer': viewerName});
      if (hello is! Map || hello['protocol'] != AgentWire.protocolVersion) {
        await control.close();
        throw WindowStreamFailure(
          WindowStreamFailureReason.serverStartFailed,
          'unexpected agent hello: $hello',
        );
      }
      final capabilities = {
        for (final value in (hello['capabilities'] as List? ?? const []))
          '$value',
      };
      return AndroidAgentSource._(
        adb: adb,
        serial: serial,
        props: props,
        port: port,
        control: control,
        token: running.token,
        localPort: localPort,
        agentCapabilities: capabilities,
      );
    } catch (error) {
      if (localPort != null) {
        try {
          await adb.killForward(serial, localPort);
        } catch (_) {
          // The device may already be gone.
        }
      }
      if (error is WindowStreamFailure) {
        rethrow;
      }
      throw WindowStreamFailure(
        WindowStreamFailureReason.serverStartFailed,
        '$error',
      );
    }
  }

  /// Asks a running agent of another build to exit when this one is newer
  /// and it streams nothing; true when it went away.
  static Future<bool> _replaceIfOlder(
    AdbHostClient adb,
    String serial,
    AgentDaemonState running,
    AgentSidecar ours,
  ) async {
    if (running.jarSha == ours.jarSha256) {
      return false;
    }
    int? localPort;
    try {
      localPort = await adb.forward(serial, 'localabstract:${running.socket}');
      final control = await AgentControlClient.connect(
        port: localPort,
        token: running.token,
      );
      try {
        final status = await control.call(
          'status',
          const {},
          const Duration(seconds: 3),
        );
        final streams = status is Map && status['streams'] is int
            ? status['streams'] as int
            : 1;
        if (!AgentLaunch.shouldReplace(running, ours, streams: streams)) {
          return false;
        }
        await control.call('shutdown', const {}, const Duration(seconds: 3));
      } finally {
        await control.close();
      }
      // It releases its displays, then exits.
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final alive = await adb.shell(
          serial,
          'tr \'\\0\' \' \' < /proc/${running.pid}/cmdline 2>/dev/null',
        );
        if (!alive.stdout.contains('--daemon')) {
          return true;
        }
      }
      return false;
    } on AgentCallException {
      // Older protocol or busy: keep using it.
      return false;
    } catch (_) {
      return false;
    } finally {
      if (localPort != null) {
        try {
          await adb.killForward(serial, localPort);
        } catch (_) {
          // ignore
        }
      }
    }
  }

  final AdbHostClient adb;

  /// adb serial the agent was started through; its forward lives on this
  /// transport, so losing it ends the source.
  final String serial;
  final AndroidDeviceProps props;
  final StreamTransportPort port;

  @override
  final SourceInfo info;

  final AgentControlClient _control;
  final Uint8List _token;
  final int _localPort;
  late final StreamSubscription<AgentEvent> _events;
  final _state = ValueNotifier<SourceState>(SourceState.ready);
  final _streams = <int, AgentStreamHandle>{};
  final _icons = <String, Future<Uint8List?>>{};

  /// While anything streams: whether each stream's app is still on its
  /// display. An app closed on the phone (or from the recents here) leaves
  /// its display empty, and its window should go with it.
  Timer? _watch;
  bool _watching = false;
  List<AppEntry>? _apps;
  DateTime? _appsLoadedAt;

  /// Stream numbers are the agent's, shared with its other clients (the
  /// phone's Whisper, other desktops): start somewhere random.
  int _nextStream = 1 + Random.secure().nextInt(1 << 30);
  bool _disposed = false;

  @override
  ValueListenable<SourceState> get state => _state;

  Future<Object?> _call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    return _control.call(method, params);
  }

  @override
  Future<List<AppEntry>> apps({bool refresh = false}) async {
    final cached = _apps;
    final loadedAt = _appsLoadedAt;
    if (!refresh &&
        cached != null &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < const Duration(minutes: 1)) {
      return cached;
    }
    final result = await _call('apps') as List? ?? const [];
    final apps = [
      for (final item in result)
        if (item is Map && item['id'] is String)
          AppEntry(
            id: item['id'] as String,
            label: '${item['label'] ?? item['id']}',
            system: item['system'] == true,
          ),
    ]..sort((a, b) => a.label.compareTo(b.label));
    _apps = apps;
    _appsLoadedAt = DateTime.now();
    return apps;
  }

  @override
  Future<List<TaskEntry>> tasks() async {
    final result = await _call('tasks') as List? ?? const [];
    final labels = {
      for (final app in _apps ?? const <AppEntry>[]) app.id: app.label,
    };
    return [
      for (final item in result)
        if (item is Map &&
            item['taskId'] is int &&
            item['appId'] is String &&
            !props.homePackages.contains(item['appId']) &&
            item['appId'] != 'com.android.systemui')
          TaskEntry(
            id: item['taskId'] as int,
            appId: item['appId'] as String,
            label: labels[item['appId']] ?? item['appId'] as String,
            displayId: item['displayId'] is int && item['displayId'] as int >= 0
                ? item['displayId'] as int
                : null,
            visible: item['visible'] == true,
            streamed: item['streamed'] == true,
            running: item['running'] != false,
          ),
    ];
  }

  @override
  Future<Uint8List?> icon(String appId) {
    return _icons[appId] ??= () async {
      try {
        final result = await _call('icon', {'appId': appId, 'size': 192});
        final png = result is Map ? result['png'] : null;
        return png is String ? base64Decode(png) : null;
      } catch (_) {
        _icons.remove(appId);
        return null;
      }
    }();
  }

  @override
  Future<Uint8List?> snapshot(TaskEntry task) async {
    try {
      final result = await _call('snapshot', {
        'taskId': task.id,
        'maxEdge': 720,
      });
      final jpeg = result is Map ? result['jpeg'] : null;
      return jpeg is String ? base64Decode(jpeg) : null;
    } catch (_) {
      return null;
    }
  }

  /// The accessibility tree of [displayId] (a stream's display), as the
  /// agent reports it: windows with nested nodes (class, resource id, text,
  /// description, bounds in display pixels, flag bits).
  Future<Map<String, dynamic>> uiTree(int displayId) async {
    final result = await _control.call('uiTree', {
      'displayId': displayId,
    }, const Duration(seconds: 10));
    return (result as Map).cast<String, dynamic>();
  }

  @override
  Future<StreamHandle> open(OpenTarget target, StreamOptions options) async {
    if (_disposed) {
      throw const WindowStreamFailure(
        WindowStreamFailureReason.deviceDisconnected,
      );
    }
    final stream = _nextStream++;
    final audio = options.audio && info.capabilities.perAppAudio;
    final width = options.displayWidth;
    final height = options.displayHeight;
    try {
      await _call('open', {
        'stream': stream,
        'appId': target.appId,
        if (target case OpenTask(:final task) when task.running)
          'taskId': task.id,
        if (width != null && height != null) 'width': width,
        if (width != null && height != null) 'height': height,
        if (options.displayDpi != null) 'dpi': options.displayDpi,
        'bitRate': options.videoBitRate,
        'maxFps': options.maxFps,
        'audio': audio,
      });
    } on AgentCallException catch (error) {
      throw WindowStreamFailure(
        WindowStreamFailureReason.serverStartFailed,
        error.message,
      );
    }
    final handle = AgentStreamHandle._(
      source: this,
      stream: stream,
      target: target,
      bitRate: options.videoBitRate,
      transport: ScrcpySocketsSpec(
        port: _localPort,
        audio: audio,
        agentToken: _token,
        agentStream: stream,
      ),
    );
    _streams[stream] = handle;
    _watch ??= Timer.periodic(const Duration(seconds: 2), (_) => _checkApps());
    return handle;
  }

  Future<void> _checkApps() async {
    if (_streams.isEmpty) {
      _watch?.cancel();
      _watch = null;
      return;
    }
    if (_watching || _disposed) {
      return;
    }
    _watching = true;
    try {
      final result = await _call('tasks') as List? ?? const [];
      final occupied = {
        for (final item in result)
          if (item is Map && item['displayId'] is int) item['displayId'] as int,
      };
      for (final handle in List.of(_streams.values)) {
        handle._noteDisplay(occupied: occupied);
      }
    } catch (_) {
      // The agent's own events report it going away.
    } finally {
      _watching = false;
    }
  }

  /// Apps left behind that swallow every touch on the phone's own screen
  /// (see TouchGuard in the agent). The user decides whether to close them.
  final touchBlocked = StreamController<List<BlockedApp>>.broadcast();

  /// Closes the task blocking the phone (its app stays installed).
  Future<bool> repairTouch(int taskId) async =>
      await _control.call('repairTouch', {'taskId': taskId}) == true;

  /// Removes the task as swiping it away in the phone's recents would.
  @override
  Future<bool> closeTask(TaskEntry task) => repairTouch(task.id);

  void _onEvent(AgentEvent event) {
    if (event.name == 'touchBlocked') {
      final apps = [
        for (final app in (event.data['apps'] as List? ?? const []))
          if (app is Map && app['taskId'] is int && app['appId'] is String)
            BlockedApp(
              taskId: app['taskId'] as int,
              appId: app['appId'] as String,
            ),
      ];
      if (apps.isNotEmpty) {
        touchBlocked.add(apps);
      }
      return;
    }
    final stream = event.data['stream'];
    final handle = stream is int ? _streams[stream] : null;
    if (handle == null) {
      return;
    }
    switch (event.name) {
      case 'launched':
        final display = event.data['displayId'];
        handle.displayId = display is int ? display : null;
      case 'closed':
        handle._onAgentClosed();
    }
  }

  void _onDisconnected() {
    for (final handle in List.of(_streams.values)) {
      handle._onAgentClosed(
        failure: const WindowStreamFailure(
          WindowStreamFailureReason.deviceDisconnected,
        ),
      );
    }
    if (!_disposed) {
      _state.value = const SourceState(
        SourceStatus.unavailable,
        failure: WindowStreamFailure(
          WindowStreamFailureReason.deviceDisconnected,
        ),
      );
    }
  }

  void _forget(AgentStreamHandle handle) {
    _streams.remove(handle.stream);
    if (_streams.isEmpty) {
      _watch?.cancel();
      _watch = null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _watch?.cancel();
    _watch = null;
    for (final stream in List.of(_streams.values)) {
      await stream.close();
    }
    // The persistent agent stays: the phone's own Whisper and other
    // devices use it too. Closing this session releases its windows.
    await _events.cancel();
    await _control.close();
    try {
      await adb.killForward(serial, _localPort);
    } catch (_) {
      // The device may already be gone.
    }
    _state.value = const SourceState(SourceStatus.unavailable);
    await touchBlocked.close();
  }
}

class AgentStreamHandle implements StreamHandle {
  AgentStreamHandle._({
    required this.source,
    required this.stream,
    required this.target,
    required this.transport,
    required int bitRate,
  }) : _bitRate = bitRate;

  @override
  final AndroidAgentSource source;

  /// The agent's stream number.
  final int stream;
  @override
  final OpenTarget target;
  @override
  final StreamTransportSpec transport;
  final int _bitRate;

  final _state = ValueNotifier<StreamState>(
    const StreamState(StreamStatus.opening),
  );
  WindowStreamFailure? _failure;
  bool _closing = false;
  QualityTier _tier = QualityTier.focused;

  /// The phone display showing this stream, once the app is on it.
  int? displayId;

  /// Checks in a row that found no app on [displayId].
  int _emptyChecks = 0;

  /// Two empty checks in a row (an app switching pages can leave the
  /// display empty for a moment): the app was closed, so is its window.
  void _noteDisplay({required Set<int> occupied}) {
    final display = displayId;
    if (display == null || _closing || _state.value.isTerminal) {
      return;
    }
    if (occupied.contains(display)) {
      _emptyChecks = 0;
      return;
    }
    _emptyChecks += 1;
    if (_emptyChecks >= 2) {
      _state.value = _state.value.copyWith(status: StreamStatus.appExited);
      unawaited(close());
    }
  }

  @override
  String get id => 'agent-${source.info.id}-$stream';

  @override
  String get title {
    final label = switch (target) {
      OpenApp(:final label) => label,
      OpenTask(:final task) => task.label,
    };
    return label == null || label.isEmpty ? target.appId : label;
  }

  @override
  ValueListenable<StreamState> get state => _state;

  @override
  void onTransportEvent(StreamTransportEvent event) {
    switch (event) {
      case TransportConnected():
        if (_state.value.status == StreamStatus.opening) {
          _state.value = _state.value.copyWith(status: StreamStatus.live);
        }
      case TransportVideoSize(:final width, :final height):
        _state.value = _state.value.copyWith(
          videoWidth: width,
          videoHeight: height,
        );
      case TransportEnded(:final failure):
        _failure ??= failure;
        unawaited(close());
      case TransportAudioState() ||
          TransportClipboard() ||
          TransportStats() ||
          TransportTextFocus():
        break;
    }
  }

  @override
  void sendInput(WindowInputEvent event) => source.port.input(id, event);

  @override
  void requestKeyframe() {
    unawaited(_quietCall('keyframe'));
  }

  @override
  void setQuality(QualityTier tier) {
    if (tier == _tier) {
      return;
    }
    _tier = tier;
    final bitRate = switch (tier) {
      QualityTier.focused => _bitRate,
      QualityTier.background => max(1500000, _bitRate ~/ 2),
      QualityTier.minimal => 800000,
    };
    unawaited(_quietCall('bitRate', {'bitRate': bitRate}));
  }

  @override
  Future<void> setViewport({required int width, required int height}) async {
    source.port.control(id, ScrcpyControl.resizeDisplay(width, height));
  }

  @override
  Future<void> suspend() async {
    if (_state.value.status != StreamStatus.live) {
      return;
    }
    await _quietCall('suspend');
    _state.value = _state.value.copyWith(status: StreamStatus.suspended);
  }

  @override
  Future<void> resume() async {
    if (_state.value.status != StreamStatus.suspended) {
      return;
    }
    await _quietCall('resume');
    _state.value = _state.value.copyWith(status: StreamStatus.live);
  }

  Future<void> _quietCall(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (_closing) {
      return;
    }
    try {
      await source._call(method, {'stream': stream, ...params});
    } catch (_) {
      // The stream or the agent is going away; its own events report that.
    }
  }

  @override
  Future<void> close({CloseMode mode = CloseMode.returnToSource}) async {
    if (_closing) {
      return;
    }
    _closing = true;
    try {
      // The agent releases the display and keeps the app in the phone's
      // background (or stops it), then answers.
      await source._control.call('close', {
        'stream': stream,
        'terminate': mode == CloseMode.terminate,
      }, const Duration(seconds: 8));
    } catch (_) {
      // Already closed on the phone.
    }
    _finish();
  }

  void _onAgentClosed({WindowStreamFailure? failure}) {
    _failure ??= failure;
    _closing = true;
    _finish();
  }

  void _finish() {
    source._forget(this);
    if (_state.value.status != StreamStatus.closed) {
      _state.value = _state.value.copyWith(
        status: StreamStatus.closed,
        failure: _failure,
      );
    }
  }
}

/// An app whose leftover page blocks touches on the phone.
class BlockedApp {
  const BlockedApp({required this.taskId, required this.appId});

  final int taskId;
  final String appId;
}
