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
import '../android_task_list.dart';
import 'scrcpy_protocol.dart';

/// Sends control bytes and input to a stream's worker in the stream isolate.
abstract interface class StreamTransportPort {
  void control(String streamId, Uint8List bytes);
  void input(String streamId, WindowInputEvent event);
}

/// Android source built on the unmodified scrcpy-server: one server process
/// (one virtual display) per window. It lacks icons, snapshots, pause and
/// per-app audio, but needs nothing of ours on the phone, so it stays as the
/// fallback when the Whisper agent cannot run.
class ScrcpyCompatSource implements WindowSource {
  ScrcpyCompatSource._({
    required this.adb,
    required this.serial,
    required this.props,
    required this.port,
    required Future<Uint8List> Function() serverBytes,
  }) : _serverBytes = serverBytes,
       info = SourceInfo(
         id: props.stableId,
         name: props.displayName,
         model: props.model,
         osVersion: props.release,
         platform: WindowStreamPlatform.android,
         capabilities: SourceCapabilities(
           recents: true,
           moveTask: true,
           detachesFromSourceScreen: true,
           audio: props.sdk >= 30,
           resizeReflow: true,
         ),
       );

  /// Creates the source for a phone whose [props] were just read. Servers
  /// left behind by a previous run of this app (crash, force quit) still
  /// hold virtual displays with apps on them, so they are ended first; only
  /// call this once per phone, not per adb transport.
  static Future<ScrcpyCompatSource> create({
    required AdbHostClient adb,
    required AdbDevice device,
    required AndroidDeviceProps props,
    required Future<Uint8List> Function() serverBytes,
    required StreamTransportPort port,
  }) async {
    await adb.shell(
      device.serial,
      'for p in \$(pgrep -f ${shellProcessPattern('whisper-scrcpy')}); '
      'do pkill -P \$p; kill \$p; done',
    );
    return ScrcpyCompatSource._(
      adb: adb,
      serial: device.serial,
      props: props,
      port: port,
      serverBytes: serverBytes,
    );
  }

  final AdbHostClient adb;

  /// adb serial; changes with wireless reconnects, unlike [info.id].
  String serial;
  final AndroidDeviceProps props;
  final StreamTransportPort port;
  final Future<Uint8List> Function() _serverBytes;

  @override
  final SourceInfo info;

  final _state = ValueNotifier<SourceState>(SourceState.ready);
  final _random = Random.secure();
  List<AppEntry>? _apps;
  DateTime? _appsLoadedAt;
  final _streams = <String, ScrcpyStreamHandle>{};

  @override
  ValueListenable<SourceState> get state => _state;

  /// Pushes a private copy of the server for one launch. The server deletes
  /// its own jar when it starts (`cleanup=true`), so copies are never shared
  /// between launches that may overlap.
  Future<String> _pushServer() async {
    final bytes = await _serverBytes();
    final path =
        '/data/local/tmp/whisper-scrcpy-${_random.nextInt(0x7fffffff).toRadixString(16)}.jar';
    try {
      await adb.push(serial, bytes, path);
    } catch (error) {
      throw WindowStreamFailure(
        WindowStreamFailureReason.serverStartFailed,
        '$error',
      );
    }
    return path;
  }

  String _serverCommand(String jar, List<String> args) {
    return 'CLASSPATH=$jar app_process / ${ScrcpyProtocol.serverClass} '
        '${ScrcpyProtocol.serverVersion} ${args.join(' ')}';
  }

  @override
  Future<List<AppEntry>> apps({bool refresh = false}) async {
    final cached = _apps;
    final loadedAt = _appsLoadedAt;
    if (!refresh &&
        cached != null &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < const Duration(minutes: 2)) {
      return cached;
    }
    final jar = await _pushServer();
    final result = await adb.shell(
      serial,
      _serverCommand(jar, const ['list_apps=true', 'log_level=info']),
      timeout: const Duration(seconds: 40),
    );
    final apps = parseAppList(result.stdout);
    _apps = apps;
    _appsLoadedAt = DateTime.now();
    return apps;
  }

  /// Parses scrcpy's `list_apps` output: `* label   package` for system apps,
  /// `- label   package` for user apps.
  static List<AppEntry> parseAppList(String output) {
    final line = RegExp(r'^\s*([*-])\s+(.*?)\s+(\S+)\s*$');
    final apps = <AppEntry>[];
    for (final raw in const LineSplitter().convert(output)) {
      final match = line.firstMatch(raw);
      if (match == null) {
        continue;
      }
      final package = match.group(3)!;
      if (!package.contains('.')) {
        continue;
      }
      apps.add(
        AppEntry(
          id: package,
          label: match.group(2)!.trim().isEmpty
              ? package
              : match.group(2)!.trim(),
          system: match.group(1) == '*',
        ),
      );
    }
    apps.sort((a, b) => a.label.compareTo(b.label));
    return apps;
  }

  @override
  Future<List<TaskEntry>> tasks() async {
    final result = await adb.shell(serial, 'am stack list');
    final labels = {
      for (final app in _apps ?? const <AppEntry>[]) app.id: app.label,
    };
    final streamedDisplays = {
      for (final stream in _streams.values)
        if (stream.displayId != null) stream.displayId!,
    };
    return [
      for (final task in AndroidTaskList.parse(result.stdout))
        if (!props.homePackages.contains(task.packageName) &&
            task.packageName != 'com.android.systemui')
          TaskEntry(
            id: task.taskId,
            appId: task.packageName,
            label: labels[task.packageName] ?? task.packageName,
            displayId: task.displayId,
            visible: task.visible,
            streamed: streamedDisplays.contains(task.displayId),
          ),
    ];
  }

  @override
  Future<Uint8List?> icon(String appId) async => null;

  @override
  Future<Uint8List?> snapshot(TaskEntry task) async => null;

  @override
  Future<StreamHandle> open(OpenTarget target, StreamOptions options) async {
    if (props.sdk < 29) {
      throw const WindowStreamFailure(WindowStreamFailureReason.androidTooOld);
    }
    final jar = await _pushServer();
    final scid = _random.nextInt(0x7fffffff);
    final socket = ScrcpyProtocol.socketName(scid);
    final localPort = await adb.forward(serial, 'localabstract:$socket');
    final audio = options.audio && props.sdk >= 30;
    final display =
        options.displayWidth != null && options.displayHeight != null
        ? '${options.displayWidth}x${options.displayHeight}'
              '${options.displayDpi == null ? '' : '/${options.displayDpi}'}'
        : '';
    final args = <String>[
      'scid=${scid.toRadixString(16).padLeft(8, '0')}',
      'log_level=info',
      'tunnel_forward=true',
      'video_codec=h264',
      'video_bit_rate=${options.videoBitRate}',
      'max_fps=${options.maxFps}',
      'audio=$audio',
      if (audio) 'audio_codec=raw',
      if (audio) 'audio_source=${props.sdk >= 33 ? 'playback' : 'output'}',
      'control=true',
      'new_display=$display',
      'vd_destroy_content=false',
      'vd_system_decorations=false',
      'display_ime_policy=hide',
      'keep_active=true',
      'send_device_meta=false',
      'send_dummy_byte=true',
      'clipboard_autosync=false',
      'power_off_on_close=false',
      'cleanup=true',
    ];
    final AdbShellSession session;
    try {
      session = await adb.shellSession(serial, _serverCommand(jar, args));
    } catch (error) {
      await _killForward(localPort);
      throw WindowStreamFailure(
        WindowStreamFailureReason.serverStartFailed,
        '$error',
      );
    }
    final id = 'scrcpy-${scid.toRadixString(16)}';
    final handle = ScrcpyStreamHandle._(
      id: id,
      scidHex: scid.toRadixString(16).padLeft(8, '0'),
      source: this,
      target: target,
      session: session,
      localPort: localPort,
      transport: ScrcpySocketsSpec(port: localPort, audio: audio),
    );
    _streams[id] = handle;
    return handle;
  }

  Future<void> _killForward(int localPort) async {
    try {
      await adb.killForward(serial, localPort);
    } catch (_) {
      // The device may already be gone.
    }
  }

  /// Moves an existing task onto the stream's display, or starts the app.
  Future<void> _launchInto(ScrcpyStreamHandle handle) async {
    final displayId = await handle.displayIdFuture.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    var taskId = switch (handle.target) {
      OpenTask(:final task) => task.id,
      OpenApp() => null,
    };
    if (taskId == null && displayId >= 0) {
      final existing = await tasks();
      for (final task in existing) {
        if (task.appId == handle.target.appId &&
            task.displayId != displayId &&
            !task.streamed) {
          taskId = task.id;
          break;
        }
      }
    }
    if (taskId != null && displayId >= 0) {
      final moved = await adb.shell(
        serial,
        'am display move-stack $taskId $displayId',
      );
      if (moved.ok && !moved.stdout.contains('Exception')) {
        return;
      }
    }
    port.control(handle.id, ScrcpyControl.startApp(handle.target.appId));
  }

  /// The task in front on the phone's own screen, with its base component.
  Future<({AndroidFrontTask front, String? component})?>
  _frontTaskOnPhone() async {
    try {
      final dump = await adb.shell(
        serial,
        r"dumpsys activity activities | grep -E '^Display #|^  \* Task\{'",
      );
      final front = AndroidTaskList.parseFrontTask(dump.stdout);
      if (front == null) {
        return null;
      }
      String? component;
      if (!front.isHome) {
        final list = await adb.shell(serial, 'am stack list');
        for (final task in AndroidTaskList.parse(list.stdout)) {
          if (task.taskId == front.taskId) {
            component = task.component;
            break;
          }
        }
      }
      return (front: front, component: component);
    } catch (_) {
      return null;
    }
  }

  /// When a virtual display goes away, some Android versions put its tasks in
  /// front on the phone (Android 13 does, 17 does not). Bring back whatever
  /// was in front so the streamed app only returns to the background.
  Future<void> _keepInBackground(
    int? streamedTaskId, {
    ({AndroidFrontTask front, String? component})? previousFront,
  }) async {
    if (streamedTaskId == null) {
      return;
    }
    for (var attempt = 0; attempt < 6; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final now = await _frontTaskOnPhone();
      if (now == null || now.front.taskId != streamedTaskId) {
        if (attempt > 1) {
          return;
        }
        continue;
      }
      final previous = previousFront;
      final command =
          previous == null ||
              previous.front.isHome ||
              previous.component == null
          ? 'am start -a android.intent.action.MAIN -c android.intent.category.HOME -f 0x10000000'
          : 'am start -n ${previous.component} -f 0x10200000';
      await adb.shell(serial, command);
      return;
    }
  }

  /// Task currently shown on [displayId], if any.
  Future<int?> _taskOnDisplay(int displayId) async {
    try {
      final dump = await adb.shell(
        serial,
        r"dumpsys activity activities | grep -E '^Display #|^  \* Task\{'",
      );
      return AndroidTaskList.parseFrontTask(
        dump.stdout,
        displayId: displayId,
      )?.taskId;
    } catch (_) {
      return null;
    }
  }

  void _forget(ScrcpyStreamHandle handle) {
    _streams.remove(handle.id);
  }

  @override
  Future<void> dispose() async {
    for (final stream in List.of(_streams.values)) {
      await stream.close();
    }
    _state.value = const SourceState(SourceStatus.unavailable);
  }
}

class ScrcpyStreamHandle implements StreamHandle {
  ScrcpyStreamHandle._({
    required this.id,
    required this.scidHex,
    required this.source,
    required this.target,
    required AdbShellSession session,
    required int localPort,
    required this.transport,
  }) : _session = session,
       _localPort = localPort {
    _output = session.output.listen(_onServerOutput);
    unawaited(
      session.exitCode.then((_) {
        if (_closed || _state.value.status == StreamStatus.closed) {
          return;
        }
        // The server went away without us closing it.
        _failure ??= WindowStreamFailure(
          WindowStreamFailureReason.serverStartFailed,
          _log.toString(),
        );
        unawaited(close());
      }),
    );
  }

  @override
  final String id;

  /// Session id of the server process, as passed on its command line.
  final String scidHex;
  @override
  final ScrcpyCompatSource source;
  @override
  final OpenTarget target;
  @override
  final StreamTransportSpec transport;

  final AdbShellSession _session;
  final int _localPort;
  late final StreamSubscription<String> _output;
  final _state = ValueNotifier<StreamState>(
    const StreamState(StreamStatus.opening),
  );
  final _displayId = Completer<int>();
  final _log = StringBuffer();
  WindowStreamFailure? _failure;
  bool _launched = false;
  bool _closed = false;

  int? displayId;
  Future<int> get displayIdFuture => _displayId.future;

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

  void _onServerOutput(String text) {
    if (_log.length < 8000) {
      _log.write(text);
    }
    final display = RegExp(r'New display: \S+ \(id=(\d+)\)').firstMatch(text);
    if (display != null && !_displayId.isCompleted) {
      displayId = int.parse(display.group(1)!);
      _displayId.complete(displayId);
    }
    if (text.contains('INJECT_EVENTS')) {
      _failure = const WindowStreamFailure(
        WindowStreamFailureReason.injectPermissionDenied,
      );
    }
  }

  @override
  void onTransportEvent(StreamTransportEvent event) {
    switch (event) {
      case TransportConnected():
        _state.value = _state.value.copyWith(status: StreamStatus.live);
        if (!_launched) {
          _launched = true;
          unawaited(source._launchInto(this));
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
  void requestKeyframe() => source.port.control(id, ScrcpyControl.resetVideo());

  @override
  void setQuality(QualityTier tier) {}

  @override
  Future<void> setViewport({required int width, required int height}) async {
    source.port.control(id, ScrcpyControl.resizeDisplay(width, height));
  }

  @override
  Future<void> suspend() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> close({CloseMode mode = CloseMode.returnToSource}) async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _output.cancel();
    final display = displayId;
    final streamedTask = display == null
        ? null
        : await source._taskOnDisplay(display);
    final front = await source._frontTaskOnPhone();
    await _session.close();
    // Closing the adb stream does not end the server; stop it explicitly so
    // its virtual display (and the app on it) is released.
    await source.adb.shell(
      source.serial,
      'pkill -f ${shellProcessPattern('scrcpy.Server ${ScrcpyProtocol.serverVersion} scid=$scidHex ')}',
    );
    await source._killForward(_localPort);
    if (mode == CloseMode.terminate) {
      await source.adb.shell(source.serial, 'am force-stop ${target.appId}');
    } else {
      await source._keepInBackground(streamedTask, previousFront: front);
    }
    source._forget(this);
    _state.value = _state.value.copyWith(
      status: StreamStatus.closed,
      failure: _failure,
    );
  }

  /// Server log for diagnostics (kept short, never shown to the user).
  String get serverLog => _log.toString();
}
