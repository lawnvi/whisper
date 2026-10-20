import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helper/device_form_factor.dart';
import '../helper/local.dart';
import '../helper/toast.dart' show appNavigatorKey;
import '../model/LocalDatabase.dart';
import '../page/remote_files/files_drag.dart'
    show FilesFolderPromises, filesVirtualClipboard;
import '../page/remote_files/files_model.dart';
import '../page/window_stream/flow_open.dart' show flowWindowRoute;
import '../remote_files/fs_client.dart';
import '../remote_files/fs_host.dart';
import '../remote_files/fs_host_files.dart';
import '../remote_files/fs_paths.dart';
import '../remote_files/fs_platform.dart';
import '../remote_files/mount/remote_mounts.dart';
import '../socket/svrmanager.dart';
import '../state/connection_attempt.dart';
import '../state/pairing_request.dart';
import '../state/peer_endpoint.dart';
import '../window_stream/android/window_activity.dart';
import '../window_stream/core/window_input_event.dart';
import '../window_stream/core/window_source.dart';
import '../window_stream/core/window_stream_models.dart';
import '../window_stream/remote/remote_peer_source.dart';
import '../window_stream/remote/window_stream_control.dart';
import '../window_stream/remote/window_stream_host.dart';
import '../window_stream/window_stream_coordinator.dart';

/// Debug-only VM service extensions (`ext.whisper.*`) that drive window
/// streaming, the file browser, pairing and a few settings without touching
/// the UI, so test devices can be scripted with `tool/ws_drive.dart`.
///
/// Every call answers a JSON object: `{"ok": true, ...}` or
/// `{"ok": false, "error": "...", "type": "..."}`. Parameters arrive as
/// strings; a `json` parameter holding an object is merged in first, so
/// lists and nested values can be passed too. Never registered in release
/// builds (main: `if (kDebugMode) registerAutomationHooks();`).
void registerAutomationHooks() {
  if (_registered || !kDebugMode) {
    return;
  }
  _registered = true;
  for (final MapEntry(key: name, value: hook) in automationHooks.entries) {
    developer.registerExtension('ext.whisper.$name', (method, raw) async {
      Map<String, Object?> body;
      try {
        body = {'ok': true, ...await hook(HookParams.from(raw))};
      } catch (error) {
        body = {
          'ok': false,
          'error': error is HookError ? error.message : '$error',
          'type': error.runtimeType.toString(),
        };
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode(body, toEncodable: _encodable),
      );
    });
  }
}

bool _registered = false;

typedef AutomationHook =
    Future<Map<String, Object?>> Function(HookParams params);

/// Every hook by name (without the `ext.whisper.` prefix).
@visibleForTesting
final Map<String, AutomationHook> automationHooks = {
  'help': (_) async => {'methods': automationHooks.keys.toList()..sort()},
  // Window streaming: viewer side.
  'ws.start': _wsStart,
  'ws.sources': _wsSources,
  'ws.catalog': _wsCatalog,
  'ws.thumbnail': _wsThumbnail,
  'ws.icon': _wsIcon,
  'ws.open': _wsOpen,
  'ws.sessions': _wsSessions,
  'ws.state': _wsState,
  'ws.stats': _wsStats,
  'ws.input': _wsInput,
  'ws.viewport': _wsViewport,
  'ws.inset': _wsInset,
  'ws.snapshot': _wsSnapshot,
  'ws.focus': _wsFocus,
  'ws.pause': (params) => _wsLifecycle(params, 'pause'),
  'ws.resume': (params) => _wsLifecycle(params, 'resume'),
  'ws.stop': (params) => _wsLifecycle(params, 'stop'),
  'ws.closeWindow': _wsCloseWindow,
  'ws.offers': _wsOffers,
  'ws.acceptOffer': _wsAcceptOffer,
  'ws.dismissOffer': _wsDismissOffer,
  'ws.diagnostics': _wsDiagnostics,
  'ws.logTail': _wsLogTail,
  // Window streaming: host side.
  'ws.hostStatus': _wsHostStatus,
  'ws.localWindows': _wsLocalWindows,
  'ws.quality': _wsQuality,
  'ws.localThumbnail': _wsLocalThumbnail,
  'ws.offer': _wsOffer,
  'ws.hostStreams': (_) async => {
    'streams': WindowStreamHost.shared.debugStreams(),
  },
  // File browser.
  'files.roots': _filesRoots,
  'files.browse': _filesBrowse,
  'files.thumb': _filesThumb,
  'files.mkdir': _filesMkdir,
  'files.rename': _filesRename,
  'files.trash': _filesTrash,
  'files.copy': _filesCopy,
  'files.clipboard': _filesClipboard,
  'files.folderOut': _filesFolderOut,
  'files.hash': _filesHash,
  'files.pending': _filesPending,
  'files.answer': _filesAnswer,
  'files.close': _filesClose,
  'files.mount': _filesMount,
  'files.unmount': _filesUnmount,
  'files.mounts': _filesMounts,
  'files.mountHere': _filesMountHere,
  // Transfers.
  'transfers.get': _transfersGet,
  'transfers.cancel': _transfersCancel,
  'transfers.cancelAt': _transfersCancelAt,
  // Peers and pairing.
  'peers.list': _peersList,
  'peers.connect': _peersConnect,
  'peers.disconnect': _peersDisconnect,
  'peers.trust': _peersTrust,
  'peers.pending': _peersPending,
  'peers.accept': (params) => _peersAnswer(params, true),
  'peers.reject': (params) => _peersAnswer(params, false),
  // Settings.
  'settings.get': _settingsGet,
  'settings.set': _settingsSet,
};

/// A failure the caller made (bad parameter, unknown id).
class HookError implements Exception {
  const HookError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// String parameters from the VM service, plus an optional `json` object.
class HookParams {
  HookParams(this.values);

  factory HookParams.from(Map<String, String> raw) {
    final values = <String, Object?>{};
    final json = raw['json'];
    if (json != null && json.isNotEmpty) {
      final decoded = jsonDecode(json);
      if (decoded is! Map) {
        throw const HookError('json must be an object');
      }
      values.addAll(decoded.cast<String, Object?>());
    }
    for (final MapEntry(:key, :value) in raw.entries) {
      if (key != 'json' && key != 'isolateId') {
        values[key] = value;
      }
    }
    return HookParams(values);
  }

  final Map<String, Object?> values;

  bool has(String key) => values[key] != null;

  String string(String key) {
    final value = values[key];
    if (value == null) {
      throw HookError('missing $key');
    }
    return '$value';
  }

  String? optString(String key) => values[key]?.toString();

  int integer(String key) {
    final value = optInt(key);
    if (value == null) {
      throw HookError('missing or bad $key');
    }
    return value;
  }

  int? optInt(String key) {
    final value = values[key];
    return value is num ? value.toInt() : int.tryParse('${value ?? ''}');
  }

  double? optDouble(String key) {
    final value = values[key];
    return value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
  }

  double number(String key) {
    final value = optDouble(key);
    if (value == null) {
      throw HookError('missing or bad $key');
    }
    return value;
  }

  bool flag(String key, {bool fallback = false}) {
    final value = values[key];
    if (value is bool) {
      return value;
    }
    return switch ('${value ?? ''}'.toLowerCase()) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => fallback,
    };
  }

  /// A list given as JSON (inside `json`, or as a JSON string).
  List<Object?> list(String key) {
    final value = values[key];
    if (value is List) {
      return value;
    }
    if (value is String) {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded;
      }
    }
    throw HookError('$key must be a JSON list');
  }
}

Object? _encodable(Object? value) => switch (value) {
  Enum() => value.name,
  DateTime() => value.toIso8601String(),
  Uint8List() => base64Encode(value),
  _ => '$value',
};

// ------------------------------------------------------------- window stream

WindowStreamCoordinator get _streams => WindowStreamCoordinator.shared;

Future<Map<String, Object?>> _wsStart(HookParams params) async {
  await _streams.start();
  return {'supported': _streams.supported};
}

Map<String, Object?> _sourceJson(WindowSource source) => {
  'id': source.info.id,
  'name': source.info.name,
  'platform': source.info.platform.name,
  'kind': source is RemotePeerSource ? 'peer' : 'adb',
  'peerId': source is RemotePeerSource
      ? source.peerId
      : _streams.peerIdFor(source),
  'status': source.state.value.status.name,
  'failure': source.state.value.failure?.reason.name,
};

Future<Map<String, Object?>> _wsSources(HookParams params) async => {
  'sources': [for (final source in _streams.sources) _sourceJson(source)],
  'adbFailure': _streams.adbFailure?.reason.name,
};

/// `peer`: a Whisper peer id, a source id (`peer:…`, an adb phone's id) or
/// a source name.
WindowSource _source(HookParams params) {
  final key = params.string('peer');
  final byPeer = _streams.sourceForPeer(key);
  if (byPeer != null) {
    return byPeer;
  }
  for (final source in _streams.sources) {
    if (source.info.id == key || source.info.name == key) {
      return source;
    }
  }
  throw HookError('no window source $key');
}

Future<Map<String, Object?>> _wsCatalog(HookParams params) async {
  final source = _source(params);
  final tasks = await source.tasks();
  final apps = params.flag('apps', fallback: true)
      ? await source.apps()
      : const <AppEntry>[];
  return {
    'source': _sourceJson(source),
    'windows': [
      for (final task in tasks)
        {
          'id': task.id,
          'appId': task.appId,
          'label': task.label,
          'visible': task.visible,
          'streamed': task.streamed,
          'running': task.running,
        },
    ],
    'apps': [
      for (final app in apps)
        {
          'id': app.id,
          'label': app.label,
          'running': app.running,
          'system': app.system,
        },
    ],
  };
}

Future<Map<String, Object?>> _wsThumbnail(HookParams params) async {
  final source = _source(params);
  final id = params.integer('windowId');
  final jpeg = await source.snapshot(
    TaskEntry(id: id, appId: params.optString('appId') ?? '', label: ''),
  );
  return {'windowId': id, 'jpeg': jpeg == null ? null : base64Encode(jpeg)};
}

Future<Map<String, Object?>> _wsIcon(HookParams params) async {
  final png = await _source(params).icon(params.string('appId'));
  return {'png': png == null ? null : base64Encode(png)};
}

OpenTarget _target(HookParams params) {
  final windowId = params.optInt('windowId');
  if (windowId != null) {
    return OpenTask(
      TaskEntry(
        id: windowId,
        appId: params.optString('appId') ?? '',
        label: params.optString('label') ?? '',
      ),
    );
  }
  return OpenApp(params.string('appId'), label: params.optString('label'));
}

/// Opens like the UI does: a native window on desktops; on phones and
/// tablets the viewer page (or Android's task of its own).
Future<WindowStreamSession> _openOnScreen(
  WindowSource source,
  OpenTarget target,
) async {
  final session = await _streams.open(source, target);
  if (session.flutterHosted) {
    if (!(NativeWindowActivity.supports(session) &&
        await NativeWindowActivity.open(session, coordinator: _streams))) {
      final navigator = appNavigatorKey.currentState;
      if (navigator != null) {
        unawaited(navigator.push(flowWindowRoute(session)));
      }
    }
  }
  return session;
}

Future<Map<String, Object?>> _wsOpen(HookParams params) async {
  final session = await _openOnScreen(_source(params), _target(params));
  return _sessionJson(session);
}

Map<String, Object?> _sessionJson(WindowStreamSession session) {
  final state = session.state;
  final handle = session.handle;
  return {
    'stream': session.id,
    'surface': session.surface,
    'flutterHosted': session.flutterHosted,
    'title': handle.title,
    'source': _sourceJson(session.source),
    'status': state.status.name,
    'failure': state.failure?.reason.name,
    'failureDetail': state.failure?.detail,
    'videoWidth': state.videoWidth,
    'videoHeight': state.videoHeight,
    'focused': session.focused,
    'visible': session.visible,
    'firstFrameShown': session.firstFrameShown,
    if (session.windowSize != null)
      'window': {
        'width': session.windowSize!.width,
        'height': session.windowSize!.height,
        'scale': session.windowScale,
      },
    if (handle is RemoteStreamHandle) ...{
      'windowId': handle.window.id,
      'viewport': {
        'width': handle.viewport.width,
        'height': handle.viewport.height,
        'textScale': RemoteViewport.scale,
      },
      'textFocus': handle.textFocus.value,
    },
  };
}

WindowStreamSession _session(HookParams params) {
  final id = params.string('stream');
  final session = _streams.sessionById(id);
  if (session != null) {
    return session;
  }
  // A unique prefix is enough, like git hashes.
  final matches = [
    for (final session in _streams.sessions)
      if (session.id.startsWith(id)) session,
  ];
  if (matches.length == 1) {
    return matches.single;
  }
  throw HookError('no stream $id');
}

Future<Map<String, Object?>> _wsSessions(HookParams params) async => {
  'sessions': [for (final session in _streams.sessions) _sessionJson(session)],
};

Future<Map<String, Object?>> _wsState(HookParams params) async =>
    _sessionJson(_session(params));

Future<Map<String, Object?>> _wsStats(HookParams params) async {
  final session = _session(params);
  final native = _streams.backend?.stats(session.surface) ?? const <double>[];
  const names = [
    'decodedFps',
    'dropped',
    'decodeMs',
    'queued',
    'presented',
    'audioRestarts',
    'audioResyncs',
    'audioLeadMs',
    'audioLatencyMs',
  ];
  final transport = session.stats;
  return {
    'stream': session.id,
    'native': {
      for (var i = 0; i < native.length && i < names.length; i++)
        names[i]: native[i],
    },
    'transport': transport == null
        ? null
        : {
            'videoFps': transport.videoFps,
            'videoKbps': transport.videoKbps,
            'audioKbps': transport.audioKbps,
            'droppedBeforeDecode': transport.droppedBeforeDecode,
            'rttMs': transport.rttMs,
          },
  };
}

/// `kind`: down, move, up, cancel, click, doubleClick, rightClick, scroll,
/// key (down and up), keyDown, keyUp, text, paste, back, home, recents.
/// x/y are fractions of the picture (0–1); `code` a macOS key code,
/// `mods` WSN_MOD_* bits, `button` primary/secondary/middle.
Future<Map<String, Object?>> _wsInput(HookParams params) async {
  final session = _session(params);
  final kind = params.string('kind');
  final x = params.optDouble('x') ?? 0.5;
  final y = params.optDouble('y') ?? 0.5;
  final button = PointerButton.values.asNameMap()[params.optString('button')];
  final mods = params.optInt('mods') ?? 0;
  void send(WindowInputEvent event) => session.handle.sendInput(event);
  Future<void> click(PointerButton which) async {
    send(PointerInput(action: PointerAction.down, x: x, y: y, button: which));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    send(PointerInput(action: PointerAction.up, x: x, y: y, button: which));
  }

  switch (kind) {
    case 'down' || 'move' || 'up' || 'cancel':
      send(
        PointerInput(
          action: PointerAction.values.byName(kind),
          x: x,
          y: y,
          button: button ?? PointerButton.primary,
        ),
      );
    case 'click':
      await click(button ?? PointerButton.primary);
    case 'doubleClick':
      await click(button ?? PointerButton.primary);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await click(button ?? PointerButton.primary);
    case 'rightClick':
      await click(PointerButton.secondary);
    case 'scroll':
      send(
        ScrollInput(
          x: x,
          y: y,
          dx: params.optDouble('dx') ?? 0,
          dy: params.optDouble('dy') ?? 0,
          precise: params.flag('precise'),
        ),
      );
    case 'key' || 'keyDown' || 'keyUp':
      final code = params.integer('code');
      final characters = params.optString('text');
      if (kind != 'keyUp') {
        send(
          KeyInput(
            down: true,
            macKeyCode: code,
            characters: characters,
            modifiers: mods,
          ),
        );
      }
      if (kind == 'key') {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      if (kind != 'keyDown') {
        send(KeyInput(down: false, macKeyCode: code, modifiers: mods));
      }
    case 'text' || 'paste':
      send(TextInput(params.string('text'), paste: kind == 'paste'));
    case 'back' || 'home' || 'recents':
      send(NavigationInput(NavigationAction.values.byName(kind)));
    default:
      throw HookError('unknown input kind $kind');
  }
  return {'stream': session.id, 'kind': kind};
}

Future<Map<String, Object?>> _wsViewport(HookParams params) async {
  final session = _session(params);
  final handle = session.handle;
  await handle.setViewport(
    width: params.integer('width'),
    height: params.integer('height'),
  );
  final scale = params.optDouble('scale');
  if (scale != null) {
    if (handle is! RemoteStreamHandle) {
      throw const HookError('text scale needs a Whisper peer stream');
    }
    await handle.setTextScale(scale);
  }
  return _sessionJson(session);
}

Future<Map<String, Object?>> _wsInset(HookParams params) async {
  final handle = _session(params).handle;
  if (handle is! RemoteStreamHandle) {
    throw const HookError('keyboard inset needs a Whisper peer stream');
  }
  await handle.setKeyboardInset(params.number('fraction'));
  return {'stream': handle.id};
}

/// The window's last frame as JPEG: base64 in `jpeg`, or written to `path`
/// on this device when given.
Future<Map<String, Object?>> _wsSnapshot(HookParams params) async {
  final session = _session(params);
  final jpeg = await _streams.snapshotJpeg(
    session,
    maxEdge: params.optInt('maxEdge') ?? 0,
  );
  if (jpeg == null) {
    throw const HookError('no frame to snapshot (yet), or not supported here');
  }
  final path = params.optString('path');
  if (path != null) {
    await File(path).writeAsBytes(jpeg);
    return {'path': path, 'bytes': jpeg.length};
  }
  return {'jpeg': base64Encode(jpeg), 'bytes': jpeg.length};
}

Future<Map<String, Object?>> _wsFocus(HookParams params) async {
  _streams.focus(_session(params));
  return {};
}

Future<Map<String, Object?>> _wsLifecycle(
  HookParams params,
  String action,
) async {
  final session = _session(params);
  switch (action) {
    case 'pause':
      await _streams.pause(session);
    case 'resume':
      await _streams.resume(session);
    default:
      await _streams.close(session);
  }
  return {'stream': session.id, 'status': session.state.status.name};
}

Future<Map<String, Object?>> _wsCloseWindow(HookParams params) async {
  final source = _source(params);
  if (source is! ClosesTasks) {
    throw const HookError('this source cannot close windows');
  }
  final task = TaskEntry(id: params.integer('windowId'), appId: '', label: '');
  // How it went on the host (closed, or still open asking to save), where
  // the source can say; else only that the request went out.
  if (source is ConfirmsTaskClose) {
    final outcome = await (source as ConfirmsTaskClose).closeTaskAndWait(task);
    return {
      'sent': outcome != TaskCloseOutcome.failed,
      'outcome': outcome.name,
    };
  }
  final closed = await (source as ClosesTasks).closeTask(task);
  return {'sent': closed};
}

List<WindowOffer> get _offers => WindowStreamViewer.shared.offers.value;

Map<String, Object?> _offerJson(int index, WindowOffer offer) => {
  'index': index,
  'peerId': offer.source.peerId,
  'device': offer.source.info.name,
  'windowId': offer.window.id,
  'appId': offer.window.appId,
  'appName': offer.window.appName,
  'title': offer.window.title,
  'receivedAt': offer.receivedAt,
  'thumbnail': offer.thumbnail != null,
};

Future<Map<String, Object?>> _wsOffers(HookParams params) async => {
  'offers': [
    for (var i = 0; i < _offers.length; i++) _offerJson(i, _offers[i]),
  ],
};

WindowOffer _offer(HookParams params) {
  final offers = _offers;
  final windowId = params.optInt('windowId');
  if (windowId != null) {
    for (final offer in offers) {
      if (offer.window.id == windowId) {
        return offer;
      }
    }
    throw HookError('no offer of window $windowId');
  }
  final index = params.optInt('index') ?? 0;
  if (index < 0 || index >= offers.length) {
    throw const HookError('no such offer');
  }
  return offers[index];
}

Future<Map<String, Object?>> _wsAcceptOffer(HookParams params) async {
  final offer = _offer(params);
  WindowStreamViewer.shared.settleOffer(offer);
  final session = await _openOnScreen(offer.source, offer.target);
  return _sessionJson(session);
}

Future<Map<String, Object?>> _wsDismissOffer(HookParams params) async {
  final offer = _offer(params);
  WindowStreamViewer.shared.settleOffer(offer);
  return {'windowId': offer.window.id};
}

Future<Map<String, Object?>> _wsDiagnostics(HookParams params) async {
  final lines = _streams.diagnostics;
  final count = params.optInt('n') ?? 100;
  return {
    'lines': lines.sublist(lines.length > count ? lines.length - count : 0),
  };
}

/// The last `n` lines of window_stream.log (both the current and the
/// previous file when the current one is short).
Future<Map<String, Object?>> _wsLogTail(HookParams params) async {
  final count = (params.optInt('n') ?? 200).clamp(1, 5000);
  final dir = await getApplicationSupportDirectory();
  final lines = <String>[];
  for (final name in ['window_stream.log', 'window_stream.1.log']) {
    final file = File(p.join(dir.path, name));
    if (!await file.exists()) {
      continue;
    }
    final text = await file.readAsString();
    lines.insertAll(0, const LineSplitter().convert(text));
    if (lines.length >= count) {
      break;
    }
  }
  return {
    'path': p.join(dir.path, 'window_stream.log'),
    'lines': lines.sublist(lines.length > count ? lines.length - count : 0),
  };
}

Future<Map<String, Object?>> _wsHostStatus(HookParams params) async {
  final host = WindowStreamHost.shared;
  return {
    'platform': Platform.operatingSystem,
    'supported': host.supported,
    'inputPermitted': host.inputPermitted,
    'unavailableReason': (await host.unavailableReason())?.name,
    'streams': host.debugStreams().length,
  };
}

Future<Map<String, Object?>> _wsLocalWindows(HookParams params) async => {
  'windows': [
    for (final window in await WindowStreamHost.shared.localWindows())
      {...window.toJson(), 'pid': window.pid},
  ],
};

/// Sets how sharp windows come here (`quality`: smooth, standard, high,
/// best), for every open one at once; without it, says the current one.
Future<Map<String, Object?>> _wsQuality(HookParams params) async {
  final coordinator = WindowStreamCoordinator.shared;
  final name = params.optString('quality');
  if (name != null) {
    await coordinator.setQuality(WindowStreamQuality.fromName(name));
  }
  return {'quality': coordinator.quality.value.name};
}

/// A picture of one of this desktop's windows by id, listed or not (to see
/// what an app's extra windows hold).
Future<Map<String, Object?>> _wsLocalThumbnail(HookParams params) async {
  final jpeg = await WindowStreamHost.shared.localThumbnail(
    params.integer('windowId'),
    maxEdge: params.optInt('maxEdge') ?? 480,
  );
  return {
    'bytes': jpeg?.length ?? 0,
    if (jpeg != null) 'jpeg': base64Encode(jpeg),
  };
}

Future<Map<String, Object?>> _wsOffer(HookParams params) async {
  final peer = params.string('peer');
  final windowId = params.integer('windowId');
  RemoteWindowInfo? window;
  for (final candidate in await WindowStreamHost.shared.localWindows()) {
    if (candidate.id == windowId) {
      window = candidate;
      break;
    }
  }
  if (window == null) {
    throw HookError('no local window $windowId');
  }
  if (!WsSvrManager().canOfferWindowsTo(peer)) {
    throw HookError('$peer does not take windows (not connected, too old)');
  }
  return {'sent': await WindowStreamHost.shared.offer(peer, window)};
}

// -------------------------------------------------------------- file browser

FsHostFiles get _localFiles => FileBrowseHost.shared.files;
final _fileClients = <String, RemoteFilesClient>{};

bool _isLocal(String peer) => peer.isEmpty || peer == 'local';

Future<RemoteFilesClient> _fileClient(String peer) async {
  final client = _fileClients[peer] ??= RemoteFilesClient(peer);
  try {
    await client.open();
  } catch (_) {
    _fileClients.remove(peer);
    rethrow;
  }
  return client;
}

Map<String, Object?> _entryJson(FsEntry entry) => {
  'name': entry.name,
  'dir': entry.isDir,
  'size': entry.size,
  'modifiedMs': entry.modifiedMs,
  'hidden': entry.hidden,
  'link': entry.isLink,
};

Future<Map<String, Object?>> _filesRoots(HookParams params) async {
  final peer = params.optString('peer') ?? 'local';
  if (_isLocal(peer)) {
    await _localFiles.refreshRoots();
    return {
      'platform': Platform.operatingSystem,
      'trash': FsPlatform.hasTrash,
      'roots': [
        for (final root in _localFiles.resolver.roots)
          {
            ...root.toJson(),
            'directory': root.directory,
            'shortcuts': [
              for (final shortcut in root.shortcuts)
                {'kind': shortcut.kind, 'path': shortcut.path},
            ],
          },
      ],
    };
  }
  final info = (await _fileClient(peer)).info!;
  return {
    'platform': info.platform,
    'trash': info.hasTrash,
    'roots': [
      for (final root in info.roots)
        {
          'id': root.id,
          'shortcuts': [
            for (final shortcut in root.shortcuts)
              {'kind': shortcut.kind, 'path': shortcut.path},
          ],
        },
    ],
  };
}

Future<Map<String, Object?>> _filesBrowse(HookParams params) async {
  final peer = params.optString('peer') ?? 'local';
  final root = params.string('root');
  final path = params.optString('path') ?? '';
  final offset = params.optInt('offset') ?? 0;
  final hidden = params.flag('hidden');
  final page = _isLocal(peer)
      ? await _localFiles.list(root, path, offset: offset, showHidden: hidden)
      : await (await _fileClient(
          peer,
        )).list(root, path, offset: offset, showHidden: hidden);
  return {
    'total': page.total,
    'offset': page.offset,
    'entries': [for (final entry in page.entries) _entryJson(entry)],
  };
}

Future<Map<String, Object?>> _filesThumb(HookParams params) async {
  final peer = params.optString('peer') ?? 'local';
  final root = params.string('root');
  final path = params.string('path');
  final size = params.optInt('size') ?? 256;
  final jpeg = _isLocal(peer)
      ? await FsPlatform.thumbnail(
          await _localFiles.resolver.resolveExisting(root, path),
          size: size,
        )
      : await (await _fileClient(peer)).thumbnail(root, path, size: size);
  return {'jpeg': jpeg == null ? null : base64Encode(jpeg)};
}

Future<Map<String, Object?>> _filesMkdir(HookParams params) async {
  final peer = params.optString('peer') ?? 'local';
  final root = params.string('root');
  final parent = params.optString('parent') ?? '';
  final name = params.string('name');
  final path = _isLocal(peer)
      ? await _localFiles.mkdir(root, parent, name)
      : await (await _fileClient(peer)).mkdir(root, parent, name);
  return {'path': path};
}

Future<Map<String, Object?>> _filesRename(HookParams params) async {
  final peer = params.optString('peer') ?? 'local';
  final root = params.string('root');
  final path = params.string('path');
  final name = params.string('name');
  final renamed = _isLocal(peer)
      ? await _localFiles.rename(root, path, name)
      : await (await _fileClient(peer)).rename(root, path, name);
  return {'path': renamed};
}

/// To the trash where there is one; `permanent=true` deletes where there is
/// none (Android, iOS), as the UI does after asking.
Future<Map<String, Object?>> _filesTrash(HookParams params) async {
  final peer = params.optString('peer') ?? 'local';
  final root = params.string('root');
  final path = params.string('path');
  final permanent = params.flag('permanent');
  if (!_isLocal(peer)) {
    await (await _fileClient(peer)).remove(root, path, permanent: permanent);
    return {'removed': true};
  }
  if (FsPlatform.hasTrash) {
    final real = await _localFiles.resolver.resolveEntry(root, path);
    if (!await FsPlatform.trash(real)) {
      throw const HookError('the trash refused it');
    }
    return {'removed': true, 'trash': true};
  }
  if (!permanent) {
    throw const HookError('no trash here: pass permanent=true');
  }
  await _localFiles.deletePermanently(root, path);
  return {'removed': true, 'trash': false};
}

/// `direction=down`: `items` (JSON list of {root, path} on `peer`) into the
/// local folder `toRoot`/`toPath`. `direction=up`: local `items` into
/// `toRoot`/`toPath` on `peer`. Answers the transfer ids; they run as
/// ordinary transfers.
Future<Map<String, Object?>> _filesCopy(HookParams params) async {
  final peer = params.string('peer');
  final up = params.optString('direction') == 'up';
  final toRoot = params.string('toRoot');
  final toPath = params.optString('toPath') ?? '';
  final items = [
    for (final item in params.list('items'))
      if (item is Map && item['root'] is String && item['path'] is String)
        (root: item['root'] as String, path: item['path'] as String)
      else
        throw const HookError('items: [{"root": ..., "path": ...}]'),
  ];
  final client = await _fileClient(peer);
  if (up) {
    final paths = [
      for (final item in items)
        await _localFiles.resolver.resolveExisting(item.root, item.path),
    ];
    return {'transfers': await client.upload(paths, toRoot, toPath)};
  }
  final folder = await _localFiles.resolver.resolveExisting(toRoot, toPath);
  return {'transfers': await client.fetch(items, folder)};
}

/// The file browser of the last `files.clipboard`, kept for what pastes
/// its copy later.
FilesController? _clipboardBrowser;

/// The file browser's copy (⌘C) of another device's items, without the
/// window: what the system clipboard then holds is what other apps paste.
/// Waits while the other device asks whether to allow browsing.
Future<Map<String, Object?>> _filesClipboard(HookParams params) async {
  final peer = params.string('peer');
  final location = FilesLocation(
    peer,
    params.string('root'),
    params.optString('path') ?? '',
  );
  _clipboardBrowser?.dispose();
  // Starts on this device; opening the other one asks it once.
  final controller = _clipboardBrowser = FilesController();
  final device = controller.deviceById(peer);
  if (device == null) {
    throw HookError('cannot browse $peer');
  }
  await controller.open(device);
  await controller.go(location);
  for (final name in params.list('names')) {
    if (name is String) {
      controller.select(name, toggle: true);
    }
  }
  if (controller.selection.isEmpty) {
    throw const HookError('nothing selected');
  }
  controller.copySelection();
  return {
    'selected': controller.selection.toList(),
    'fetchedOnPaste': filesVirtualClipboard,
  };
}

/// Another device's folder `root`/`path` as a drag into Finder has it:
/// fetched into the empty folder `destination` (made here, as the runner
/// makes it where Finder asks). Waits for it.
Future<Map<String, Object?>> _filesFolderOut(HookParams params) async {
  final peer = params.string('peer');
  final path = params.string('path');
  final destination = params.string('destination');
  final controller = FilesController();
  try {
    final device = controller.deviceById(peer);
    if (device == null) {
      throw HookError('cannot browse $peer');
    }
    await controller.open(device);
    await Directory(destination).create();
    final item = FilesItem(
      FilesLocation(
        peer,
        params.string('root'),
        p.dirname(path) == '.' ? '' : p.dirname(path),
      ),
      p.basename(path),
      isDir: true,
    );
    await FilesFolderPromises.fill(controller, item, destination);
    return {'destination': destination};
  } finally {
    controller.dispose();
  }
}

/// SHA-256 of a local file (or of every file under a folder, by relative
/// path), to check copies.
Future<Map<String, Object?>> _filesHash(HookParams params) async {
  final real = await _localFiles.resolver.resolveExisting(
    params.string('root'),
    params.optString('path') ?? '',
  );
  Future<String> hashOf(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  if (await FileSystemEntity.isDirectory(real)) {
    final files = <String, Object?>{};
    await for (final entity in Directory(real).list(recursive: true)) {
      if (entity is File) {
        files[p.split(p.relative(entity.path, from: real)).join('/')] = {
          'sha256': await hashOf(entity),
          'size': await entity.length(),
        };
      }
    }
    return {'path': real, 'files': files};
  }
  final file = File(real);
  return {
    'path': real,
    'sha256': await hashOf(file),
    'size': await file.length(),
  };
}

Future<Map<String, Object?>> _filesPending(HookParams params) async {
  final pending = FileBrowseHost.shared.gate.pending;
  return {
    'pending': pending == null
        ? null
        : {'peerId': pending.peerId, 'device': pending.deviceName},
  };
}

/// Answers "‹device› wants to browse your files": deny, once or always.
Future<Map<String, Object?>> _filesAnswer(HookParams params) async {
  final gate = FileBrowseHost.shared.gate;
  final pending = gate.pending;
  if (pending == null) {
    throw const HookError('nobody is asking');
  }
  final decision = FileBrowseDecision.values.byName(
    params.optString('decision') ?? 'once',
  );
  gate.decide(decision);
  return {'peerId': pending.peerId, 'decision': decision.name};
}

Future<Map<String, Object?>> _filesClose(HookParams params) async {
  final client = _fileClients.remove(params.string('peer'));
  await client?.close();
  return {'closed': client != null};
}

/// Mounts `peer`'s files in the system's file manager (as `name`) without
/// opening a window there.
Future<Map<String, Object?>> _filesMount(HookParams params) async {
  final peer = params.string('peer');
  try {
    final mount = await RemoteMounts.shared.mount(
      peer,
      params.optString('name') ?? peer,
    );
    return {'mounted': true, 'path': mount.path};
  } on MountFailed catch (failed) {
    return {'mounted': false, 'failure': failed.failure.name};
  }
}

Future<Map<String, Object?>> _filesUnmount(HookParams params) async {
  final peer = params.string('peer');
  final was = RemoteMounts.shared.of(peer) != null;
  await RemoteMounts.shared.unmount(peer);
  return {'unmounted': was};
}

/// The device page's "挂载到本机" switch for `peer` (`on`: true/false).
Future<Map<String, Object?>> _filesMountHere(HookParams params) async {
  final peer = params.string('peer');
  final on = params.string('on') == 'true';
  try {
    final mount = await RemoteMounts.shared.setWanted(
      peer,
      params.optString('name') ?? peer,
      on,
    );
    return {'wanted': RemoteMounts.shared.wants(peer), 'path': mount?.path};
  } on MountFailed catch (failed) {
    return {
      'wanted': RemoteMounts.shared.wants(peer),
      'failure': failed.failure.name,
    };
  }
}

Future<Map<String, Object?>> _filesMounts(HookParams params) async => {
  'mounts': [
    for (final mount in RemoteMounts.shared.all)
      {'peer': mount.peerId, 'name': mount.name, 'path': mount.path},
  ],
  if (params.optString('peer') case final peer?) ...{
    'wanted': RemoteMounts.shared.wants(peer),
    'mounting': RemoteMounts.shared.isMounting(peer),
    'failure': RemoteMounts.shared.failureOf(peer)?.name,
  },
};

// ----------------------------------------------------------------- transfers

Future<Map<String, Object?>> _transfersGet(HookParams params) async {
  final id = params.string('id');
  final transfer = await LocalDatabase().fetchFileTransfer(id);
  if (transfer == null) {
    return {'id': id, 'known': false};
  }
  return {
    'id': id,
    'known': true,
    'direction': transfer.direction.name,
    'state': transfer.state.name,
    'size': transfer.size,
    'committed': transfer.committedBytes,
    'lastError': transfer.lastError,
  };
}

/// Stops a transfer as its stop button does.
Future<Map<String, Object?>> _transfersCancel(HookParams params) async {
  final id = params.string('id');
  await WsSvrManager().cancelTransfer(id);
  return {'id': id};
}

/// Stops transfer `id` once `bytes` of it are written (waiting up to
/// `waitMs`), as its stop button does mid-way.
Future<Map<String, Object?>> _transfersCancelAt(HookParams params) async {
  final id = params.string('id');
  final bytes = params.integer('bytes');
  final deadline = DateTime.now().add(
    Duration(milliseconds: params.optInt('waitMs') ?? 60000),
  );
  while (DateTime.now().isBefore(deadline)) {
    final transfer = await LocalDatabase().fetchFileTransfer(id);
    if (transfer != null && transfer.committedBytes >= bytes) {
      await WsSvrManager().cancelTransfer(id);
      return {'id': id, 'canceledAt': transfer.committedBytes};
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw HookError('$id did not reach $bytes bytes');
}

// --------------------------------------------------------------------- peers

Future<Map<String, Object?>> _peersList(HookParams params) async {
  final manager = WsSvrManager();
  final connected = manager.connectedPeerIds;
  final devices = await LocalDatabase().fetchAllDevice();
  final prefs = await SharedPreferences.getInstance();
  return {
    'self': {
      'uid': prefs.get('_uuid'),
      'name': prefs.get('_name'),
      'port': prefs.get('_port') ?? 10002,
      'formFactor': DeviceFormFactors.shared.local,
    },
    'connected': connected.toList(),
    'devices': [
      for (final device in devices)
        {
          'uid': device.uid,
          'name': device.name,
          'host': device.host,
          'port': device.port,
          'platform': device.platform,
          'trusted': device.auth,
          'online': device.online,
          'connected': connected.contains(device.uid),
          'connection': manager.connectionIdOf(device.uid),
          'windows': manager.canOfferWindowsTo(device.uid),
          'files': manager.canBrowseFilesOf(device.uid),
          'protocol': manager.remoteProfileFor(device.uid)?.protocolVersion,
          'formFactor': manager.remoteProfileFor(device.uid)?.formFactor,
          'tablet': DeviceFormFactors.shared.isTablet(device.uid),
        },
    ],
  };
}

/// Dials host:port like the manual-connect dialog. A new device then asks
/// for pairing on both sides: answer with `peers.accept` (here and there).
Future<Map<String, Object?>> _peersConnect(HookParams params) async {
  final host = params.string('host');
  final port = params.optInt('port') ?? 10002;
  final peerId = params.optString('peerId') ?? '';
  final request = ConnectionAttemptRequest(
    requestId: 'debug:$host:$port:${DateTime.now().microsecondsSinceEpoch}',
    endpoint: PeerEndpoint(host: host, port: port),
    expectedPeerId: peerId,
    mode: ConnectionAttemptMode.interactive,
  );
  // Pairing waits for a person (or peers.accept), so don't hold the call.
  final result = WsSvrManager().connectToServer(request);
  if (params.flag('wait')) {
    final done = await result.timeout(const Duration(seconds: 90));
    return {
      'status': done.status,
      'peerId': done.peerId,
      'reason': done.reason,
    };
  }
  unawaited(result.then((_) {}, onError: (Object _) {}));
  return {'requestId': request.requestId};
}

Future<Map<String, Object?>> _peersDisconnect(HookParams params) async {
  await WsSvrManager().disconnectPeer(params.string('peerId'));
  return {};
}

Future<Map<String, Object?>> _peersTrust(HookParams params) async {
  final ok = await WsSvrManager().setPeerTrust(
    params.string('peerId'),
    params.flag('trusted', fallback: true),
  );
  return {'changed': ok};
}

Future<Map<String, Object?>> _peersPending(HookParams params) async => {
  'pending': [
    for (final request in DebugPairingRequests.pending)
      {
        'peerId': request.device.uid,
        'device': request.device.name,
        'host': request.device.host,
        'code': request.pairingCode,
        'reason': request.reason.name,
        'mode': request.mode.name,
      },
  ],
};

/// Answers a pairing prompt (the newest, or `peerId`'s) as the user would.
/// `code`, when given, must match the code the prompt shows.
Future<Map<String, Object?>> _peersAnswer(HookParams params, bool allow) async {
  final peerId = params.optString('peerId');
  final request = DebugPairingRequests.take(peerId);
  if (request == null) {
    throw HookError('no pairing prompt${peerId == null ? '' : ' for $peerId'}');
  }
  final code = params.optString('code');
  if (allow && code != null && code != request.pairingCode) {
    DebugPairingRequests.add(request);
    throw const HookError('pairing code does not match');
  }
  request.presentation?.resolve(allow);
  return {'peerId': request.device.uid, 'allowed': allow};
}

/// Pairing prompts waiting for an answer, so debug tooling can answer them.
/// `WsSvrManager` hands each prompt over in debug builds (next to the UI
/// prompt); whichever answers first wins.
abstract final class DebugPairingRequests {
  static final _pending = <PairingRequest>[];

  static List<PairingRequest> get pending {
    _pending.removeWhere(
      (request) => request.presentation?.isDismissed ?? false,
    );
    return List.unmodifiable(_pending);
  }

  static void add(PairingRequest request) {
    if (!kDebugMode || request.presentation == null) {
      return;
    }
    _pending
      ..removeWhere((old) => old.device.uid == request.device.uid)
      ..add(request);
    request.presentation!.addDismissListener(() => _pending.remove(request));
  }

  static PairingRequest? take(String? peerId) {
    final candidates = pending;
    for (final request in candidates.reversed) {
      if (peerId == null || request.device.uid == peerId) {
        _pending.remove(request);
        return request;
      }
    }
    return null;
  }
}

// ------------------------------------------------------------------ settings

/// The settings automation may read and change, by name.
const _settingKeys = {
  'port': '_port',
  'name': '_name',
  'autoConnect': '_auto_connect_enabled',
  'clipboard': '_clipboard',
  'clipboardAutoSync': '_clipboard_auto_sync',
  'localization': '_localization',
  'castReceiver': '_cast_receiver_enabled',
};

Future<Map<String, Object?>> _settingsGet(HookParams params) async {
  final prefs = await SharedPreferences.getInstance();
  final key = params.optString('key');
  if (key != null) {
    final stored = _settingKeys[key];
    if (stored == null) {
      throw HookError('unknown setting $key (${_settingKeys.keys.join(', ')})');
    }
    return {key: prefs.get(stored)};
  }
  return {
    for (final MapEntry(:key, :value) in _settingKeys.entries)
      key: prefs.get(value),
  };
}

/// Changes one setting through the app's own setters. A new `port` takes
/// effect when Whisper starts again (the iOS simulator shares the Mac's
/// address, so it needs a port of its own).
Future<Map<String, Object?>> _settingsSet(HookParams params) async {
  final key = params.string('key');
  final settings = LocalSetting();
  switch (key) {
    case 'port':
      final port = params.integer('value');
      if (port < 1024 || port > 65535) {
        throw const HookError('port must be 1024–65535');
      }
      await settings.updatePort(port);
    case 'name':
      await settings.updateNickname(params.string('value'));
    case 'autoConnect':
      await settings.setAutoConnectEnabled(params.flag('value'));
    case 'clipboard':
      await settings.updateClipboard(params.flag('value'));
    case 'clipboardAutoSync':
      await settings.updateClipboardAutoSync(params.flag('value'));
    case 'localization':
      await settings.setLocalization(params.string('value'));
    case 'castReceiver':
      await settings.setCastReceiverEnabled(params.flag('value'));
    default:
      throw HookError('unknown setting $key (${_settingKeys.keys.join(', ')})');
  }
  return _settingsGet(HookParams({'key': key}));
}
