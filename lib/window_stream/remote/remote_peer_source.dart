import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher, Size;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../helper/local.dart';
import '../../socket/packet_byte_transport.dart';
import '../../socket/session_upgrade_token_registry.dart';
import '../core/window_input_event.dart';
import '../core/window_source.dart';
import '../core/window_stream_models.dart';
import 'remote_window_worker.dart';
import 'window_stream_control.dart';

/// Sends a window-stream control message to a peer.
typedef WindowStreamPeerSender =
    Future<bool> Function(String peerId, WindowStreamControlMessage message);

/// Delivers input for a stream to wherever its transport runs.
typedef StreamInputPort =
    void Function(String streamId, WindowInputEvent event);

/// Viewer-side registry: every connected Whisper peer that offers windows,
/// plus routing of the host's control replies to the right source.
class WindowStreamViewer extends ChangeNotifier {
  WindowStreamViewer._();

  static final WindowStreamViewer shared = WindowStreamViewer._();

  WindowStreamPeerSender? sender;

  /// This device's peer id as seen by [peerId]'s session.
  String Function(String peerId)? localPeerId;
  StreamInputPort? inputPort;

  /// Set by the socket layer: issues a one-time `/window` token for a host
  /// that will dial this device ([WindowStreamMediaDial]). Unset (tests,
  /// no server), this viewer never offers `dialBack`.
  String? Function(String hostPeerId, String sessionId)? issueInboundToken;

  final _sources = <String, RemotePeerSource>{};

  /// Streams whose host dials this device, by session, until they end.
  final _inbound = <String, _InboundWindow>{};

  /// Whether [claim] is the token this viewer gave a host in its `dial`,
  /// for a stream still waiting for that host's socket.
  bool canAttachInbound(SessionUpgradeClaim claim) {
    final inbound = _inbound[claim.sessionId];
    return inbound != null &&
        inbound.awaiting &&
        claim.route == WhisperWindowSpec.route &&
        claim.namespace == WhisperWindowSpec.namespace &&
        claim.peerId == inbound.hostPeerId &&
        claim.matchesChannelBinding(inbound.binding);
  }

  /// Takes the host's authenticated `/window` socket and relays it to the
  /// stream isolate, which holds the packet keys.
  bool attachInbound(WebSocketChannel channel, SessionUpgradeClaim claim) {
    final inbound = _inbound[claim.sessionId];
    final ok = inbound != null && canAttachInbound(claim);
    claim.destroy();
    if (!ok) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    return inbound.attach(channel);
  }

  void _closeInbound(String sessionId) => _inbound.remove(sessionId)?.close();

  /// Windows other devices sent here ("送出去"), newest first, until opened,
  /// dismissed or two minutes old.
  final offers = ValueNotifier<List<WindowOffer>>(const []);

  List<RemotePeerSource> get sources => List.unmodifiable(_sources.values);

  void _addOffer(WindowOffer offer) {
    final now = DateTime.now();
    offers.value = [
      offer,
      for (final existing in offers.value)
        if (existing.window.id != offer.window.id &&
            now.difference(existing.receivedAt) < WindowOffer.lifetime)
          existing,
    ];
  }

  /// The user opened or dismissed [offer].
  void settleOffer(WindowOffer offer) {
    offers.value = [
      for (final existing in offers.value)
        if (!identical(existing, offer)) existing,
    ];
  }

  RemotePeerSource? sourceFor(String peerId) => _sources[peerId];

  /// A trusted peer that can host windows connected (or its profile changed).
  void peerAvailable({
    required String peerId,
    required String name,
    required WindowStreamPlatform platform,
    required String host,
    required int port,
  }) {
    final existing = _sources[peerId];
    if (existing != null) {
      existing._updateEndpoint(name: name, host: host, port: port);
      return;
    }
    _sources[peerId] = RemotePeerSource._(
      viewer: this,
      peerId: peerId,
      name: name,
      platform: platform,
      host: host,
      port: port,
    );
    notifyListeners();
  }

  void peerGone(String peerId) {
    offers.value = [
      for (final offer in offers.value)
        if (offer.source.peerId != peerId) offer,
    ];
    for (final entry in _inbound.entries.toList()) {
      if (entry.value.hostPeerId == peerId) {
        _closeInbound(entry.key);
      }
    }
    final source = _sources.remove(peerId);
    if (source != null) {
      source._disconnected();
      notifyListeners();
    }
  }

  /// Handles a control message from a host. [sendKey] and [receiveKey] are
  /// this device's media keys for that host, only used for `accept`.
  void handleControl(
    WindowStreamControlMessage message, {
    required String remotePeerId,
    required String remoteHost,
    required Uint8List sendKey,
    required Uint8List receiveKey,
  }) {
    if (message.hostPeerId != remotePeerId) {
      return;
    }
    _sources[remotePeerId]?._onControl(
      message,
      remoteHost: remoteHost,
      sendKey: sendKey,
      receiveKey: receiveKey,
    );
  }
}

/// One window another device sent to this one.
class WindowOffer {
  WindowOffer({
    required this.source,
    required this.window,
    this.thumbnail,
    this.icon,
  }) : receivedAt = DateTime.now();

  static const lifetime = Duration(minutes: 2);

  final RemotePeerSource source;
  final RemoteWindowInfo window;
  final Uint8List? thumbnail;

  /// The app's icon, for when the window can't be pictured (minimized).
  final Uint8List? icon;
  final DateTime receivedAt;

  /// Opens it like any other window of that device.
  OpenTarget get target => OpenTask(
    TaskEntry(
      id: window.id,
      appId: window.appId,
      label: window.title.isEmpty || window.title == window.appName
          ? window.appName
          : '${window.appName} — ${window.title}',
    ),
  );
}

/// A Whisper peer's windows (a Mac today), seen from this device.
class RemotePeerSource implements WindowSource, ClosesTasks, ConfirmsTaskClose {
  RemotePeerSource._({
    required WindowStreamViewer viewer,
    required this.peerId,
    required String name,
    required WindowStreamPlatform platform,
    required String host,
    required int port,
  }) : _viewer = viewer,
       _host = host,
       _port = port,
       _info = SourceInfo(
         id: 'peer:$peerId',
         name: name,
         platform: platform,
         capabilities: const SourceCapabilities(
           appIcons: true,
           recents: true,
           taskSnapshots: true,
           suspend: true,
           resizeReflow: false,
           unicodeText: true,
         ),
       );

  final WindowStreamViewer _viewer;
  final String peerId;
  String _host;
  int _port;
  SourceInfo _info;
  final _state = ValueNotifier<SourceState>(SourceState.ready);
  static const _uuid = Uuid();

  String? _browseSession;
  Completer<List<RemoteWindowInfo>>? _catalog;

  /// A phone host's screen in its points: the shape a window of an app
  /// that has none yet opens in.
  Size? _hostScreen;
  List<RemoteWindowInfo> _windows = const [];
  DateTime _catalogAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Windows asked to close here, until the host says how it went.
  final _closing = <int, Completer<TaskCloseOutcome>>{};

  /// Windows the host said are gone. A list it sent just before noticing
  /// may still name one; it is left out for a few seconds.
  final _gone = <int, DateTime>{};
  static const _goneFor = Duration(seconds: 6);

  /// Installed apps on the host (with or without windows).
  List<({String id, String name, bool running})> _installed = const [];
  final _snapshotCache = <int, ({DateTime at, Uint8List jpeg})>{};
  final _icons = <String, Completer<Uint8List?>>{};
  final _iconRequests = _Limiter(4);
  final _thumbnailRequests = _Limiter(2);
  final _iconCache = <String, Uint8List>{};
  final _thumbnails = <int, Completer<Uint8List?>>{};
  final _opening = <String, Completer<RemoteStreamHandle>>{};
  final _streams = <String, RemoteStreamHandle>{};

  @override
  SourceInfo get info => _info;

  @override
  ValueListenable<SourceState> get state => _state;

  String get _local => _viewer.localPeerId?.call(peerId) ?? '';

  void _updateEndpoint({
    required String name,
    required String host,
    required int port,
  }) {
    _host = host;
    _port = port;
    if (name != _info.name) {
      _info = SourceInfo(
        id: _info.id,
        name: name,
        platform: _info.platform,
        capabilities: _info.capabilities,
      );
    }
  }

  Future<bool> _send(WindowStreamControlMessage message) {
    final sender = _viewer.sender;
    if (sender == null) {
      return Future.value(false);
    }
    return sender(peerId, message);
  }

  WindowStreamControlMessage _message(
    WindowStreamControlAction action,
    String sessionId, [
    Map<String, Object?> payload = const {},
  ]) {
    return WindowStreamControlMessage(
      action: action,
      sessionId: sessionId,
      viewerPeerId: _local,
      hostPeerId: peerId,
      payload: payload,
    );
  }

  Future<List<RemoteWindowInfo>> _browse() async {
    final pending = _catalog;
    if (pending != null && !pending.isCompleted) {
      return pending.future;
    }
    final completer = Completer<List<RemoteWindowInfo>>();
    _catalog = completer;
    // One browse session per connection: refreshes reuse it, so periodic
    // updates don't pile up control sessions on either side.
    final session = _browseSession ??= _uuid.v4();
    // Right after (re)connecting the session may still be authenticating;
    // give it a moment rather than failing the first look at this device.
    var sent = false;
    for (var attempt = 0; attempt < 15 && !sent; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      sent = await _send(_message(WindowStreamControlAction.browse, session));
    }
    if (!sent) {
      _catalog = null;
      throw const WindowStreamFailure(
        WindowStreamFailureReason.connectionFailed,
      );
    }
    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        _catalog = null;
        throw const WindowStreamFailure(
          WindowStreamFailureReason.connectionFailed,
          'catalog timeout',
        );
      },
    );
  }

  @override
  Future<List<AppEntry>> apps({bool refresh = false}) async {
    final windows = await _browse();
    final apps = <String, AppEntry>{};
    for (final window in windows) {
      apps.putIfAbsent(
        window.appId,
        () => AppEntry(id: window.appId, label: window.appName, running: true),
      );
    }
    for (final app in _installed) {
      apps.putIfAbsent(
        app.id,
        () => AppEntry(id: app.id, label: app.name, running: app.running),
      );
    }
    final list = apps.values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return list;
  }

  @override
  Future<List<TaskEntry>> tasks() async {
    // Window lists change as the host is used; re-read them every few
    // seconds (listing windows does not capture the screen).
    final stale =
        DateTime.now().difference(_catalogAt) > const Duration(seconds: 5);
    final windows = _windows.isEmpty || stale ? await _browse() : _windows;
    final streamed = {for (final stream in _streams.values) stream.window.id};
    final local = _local;
    return [
      for (final window in windows)
        TaskEntry(
          id: window.id,
          appId: window.appId,
          label: window.title.isEmpty || window.title == window.appName
              ? window.appName
              : '${window.appName} — ${window.title}',
          visible: window.active,
          streamed: streamed.contains(window.id),
          shownOn:
              window.viewerId == null ||
                  window.viewerId == local ||
                  streamed.contains(window.id)
              ? null
              : _deviceName(window),
        ),
    ];
  }

  /// This device's name as other devices list it ('' when unknown).
  static Future<String> _localName() async {
    try {
      return await LocalSetting().deviceDisplayName();
    } catch (_) {
      return '';
    }
  }

  /// The device [window] is shown on, as the host or this viewer knows it.
  String _deviceName(RemoteWindowInfo window) {
    final name = window.viewerName;
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return _viewer.sourceFor(window.viewerId!)?.info.name ?? '';
  }

  /// Closes [task]'s window on the host (its close button).
  @override
  Future<bool> closeTask(TaskEntry task) async =>
      await closeTaskAndWait(task) != TaskCloseOutcome.failed;

  /// Closes [task]'s window on the host, as its close button would, and
  /// answers once the host has seen it go, or seen it stay (an app asking
  /// whether to save). Hosts that never answer are asked for their list.
  @override
  Future<TaskCloseOutcome> closeTaskAndWait(TaskEntry task) async {
    final pending = _closing[task.id];
    if (pending != null) {
      return pending.future;
    }
    final session = _browseSession;
    if (session == null) {
      return TaskCloseOutcome.failed;
    }
    final answer = _closing[task.id] = Completer<TaskCloseOutcome>();
    final sent = await _send(
      _message(WindowStreamControlAction.closeWindow, session, {
        'windowId': task.id,
      }),
    );
    if (!sent) {
      _closing.remove(task.id);
      return TaskCloseOutcome.failed;
    }
    return answer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () async {
        _closing.remove(task.id);
        try {
          final windows = await _browse();
          return windows.any((window) => window.id == task.id)
              ? TaskCloseOutcome.stillOpen
              : TaskCloseOutcome.closed;
        } catch (_) {
          return TaskCloseOutcome.failed;
        }
      },
    );
  }

  void _closeAnswered(int windowId, {required bool closed}) {
    if (closed) {
      _gone[windowId] = DateTime.now();
      _windows = [
        for (final window in _windows)
          if (window.id != windowId) window,
      ];
    }
    final answer = _closing.remove(windowId);
    if (answer != null && !answer.isCompleted) {
      answer.complete(
        closed ? TaskCloseOutcome.closed : TaskCloseOutcome.stillOpen,
      );
    }
  }

  @override
  Future<Uint8List?> icon(String appId) async {
    final cached = _iconCache[appId];
    if (cached != null) {
      return cached;
    }
    final session = _browseSession;
    if (session == null) {
      return null;
    }
    final pending = _icons[appId];
    if (pending != null) {
      return pending.future;
    }
    final completer = _icons[appId] = Completer<Uint8List?>();
    // A Mac lists ~100 apps; asking for every icon at once floods the
    // peer connection until it is dropped as overflowing.
    unawaited(
      _iconRequests.run(() async {
        if (completer.isCompleted || _browseSession != session) {
          return;
        }
        await _send(
          _message(WindowStreamControlAction.icon, session, {'appId': appId}),
        );
        await completer.future.timeout(
          const Duration(seconds: 8),
          onTimeout: () => null,
        );
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _icons.remove(appId);
        return null;
      },
    );
  }

  @override
  Future<Uint8List?> snapshot(TaskEntry task) async {
    final session = _browseSession;
    if (session == null) {
      return null;
    }
    // Every thumbnail is a screen capture on the host; reuse them a while.
    final cached = _snapshotCache[task.id];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 1)) {
      return cached.jpeg;
    }
    final pending = _thumbnails[task.id];
    if (pending != null) {
      return pending.future;
    }
    final completer = _thumbnails[task.id] = Completer<Uint8List?>();
    unawaited(
      _thumbnailRequests.run(() async {
        if (completer.isCompleted || _browseSession != session) {
          return;
        }
        await _send(
          _message(WindowStreamControlAction.thumbnail, session, {
            'windowId': task.id,
            'maxEdge': 480,
          }),
        );
        await completer.future.timeout(
          const Duration(seconds: 8),
          onTimeout: () => null,
        );
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _thumbnails.remove(task.id);
        return null;
      },
    );
  }

  @override
  Future<StreamHandle> open(OpenTarget target, StreamOptions options) async {
    final windows = _windows.isEmpty ? await _browse() : _windows;
    RemoteWindowInfo? window;
    for (final candidate in windows) {
      final matches = switch (target) {
        OpenTask(:final task) => candidate.id == task.id,
        OpenApp(:final appId) => candidate.appId == appId,
      };
      if (matches) {
        window = candidate;
        break;
      }
    }
    if (window == null && target is OpenTask) {
      // A window sent over ("送出去") may be newer than our last list.
      window = RemoteWindowInfo(
        id: target.task.id,
        appId: target.task.appId,
        appName: target.task.label,
        title: '',
        width: 0,
        height: 0,
      );
    }
    if (window == null && target is OpenApp) {
      // No window yet: the host starts the app and streams its first one,
      // a phone's in the shape of its screen.
      window = RemoteWindowInfo(
        id: 0,
        appId: target.appId,
        appName: target.label ?? _labelOf(target.appId),
        title: '',
        width: _hostScreen?.width.round() ?? 0,
        height: _hostScreen?.height.round() ?? 0,
      );
    }
    if (window == null) {
      throw const WindowStreamFailure(WindowStreamFailureReason.appNotFound);
    }
    final session = _uuid.v4();
    final completer = Completer<RemoteStreamHandle>();
    _opening[session] = completer;
    final handle = RemoteStreamHandle._(
      source: this,
      id: session,
      target: target,
      window: window,
    );
    _pendingHandles[session] = handle;
    await RemoteViewport.load();
    // Phones and tablets show the window full screen; a desktop in a native
    // window of its own, sized from the window's shape (see
    // [RemoteViewport.desktopWindow]); the host lays the window out for
    // that size from the first frame.
    final screen = options.displayWidth != null && options.displayHeight != null
        ? Size(
            options.displayWidth!.toDouble(),
            options.displayHeight!.toDouble(),
          )
        : RemoteViewport.isDesktop
        ? RemoteViewport.desktopWindow(window.width, window.height)
        : RemoteViewport.screen();
    handle._viewport = screen;
    handle._pixelRatio = RemoteViewport.pixelRatio;
    final viewerName = await _localName();
    final sent = await _send(
      _message(WindowStreamControlAction.open, session, {
        if (window.id != 0) 'windowId': window.id else 'appId': window.appId,
        'viewportWidth': screen.width.round(),
        'viewportHeight': screen.height.round(),
        'viewportScale': RemoteViewport.scale,
        'pixelRatio': handle._pixelRatio,
        'viewerKind': RemoteViewport.viewerKind,
        // Other viewers' lists say where the window is.
        'viewerName': viewerName,
        // The window's sound, coded as WindowStreamPacket audio packets
        // (hosts that don't know the key send none).
        'audio': true,
        // A host that can't be reached may dial this device instead.
        if (_viewer.issueInboundToken != null)
          WindowStreamMediaDial.dialBackKey: true,
      }),
    );
    if (!sent) {
      _opening.remove(session);
      _pendingHandles.remove(session);
      throw const WindowStreamFailure(
        WindowStreamFailureReason.connectionFailed,
      );
    }
    return completer.future.timeout(
      Duration(seconds: window.id == 0 ? 16 : 10),
      onTimeout: () {
        _opening.remove(session);
        _pendingHandles.remove(session);
        throw const WindowStreamFailure(
          WindowStreamFailureReason.connectionFailed,
          'open timeout',
        );
      },
    );
  }

  final _pendingHandles = <String, RemoteStreamHandle>{};

  /// Host-side conditions that stay until someone fixes them there.
  static const _persistentHostFailures = {
    WindowStreamFailureReason.capturePermission,
    WindowStreamFailureReason.helperUnavailable,
    WindowStreamFailureReason.desktopUnsupported,
    WindowStreamFailureReason.hostUnsupported,
    WindowStreamFailureReason.agentNotRunning,
  };

  String _labelOf(String appId) {
    for (final app in _installed) {
      if (app.id == appId) {
        return app.name;
      }
    }
    return appId;
  }

  void _onControl(
    WindowStreamControlMessage message, {
    required String remoteHost,
    required Uint8List sendKey,
    required Uint8List receiveKey,
  }) {
    final payload = message.payload;
    switch (message.action) {
      case WindowStreamControlAction.catalog:
        if (message.sessionId != _browseSession) {
          return;
        }
        final now = DateTime.now();
        _gone.removeWhere((_, at) => now.difference(at) > _goneFor);
        _windows = [
          for (final entry in (payload['windows'] as List? ?? const []))
            RemoteWindowInfo.fromJson((entry as Map).cast<String, Object?>()),
        ].where((window) => !_gone.containsKey(window.id)).toList();
        _installed = [
          for (final entry in (payload['apps'] as List? ?? const []))
            if (entry is Map && entry['appId'] is String)
              (
                id: entry['appId'] as String,
                name: entry['name'] is String
                    ? entry['name'] as String
                    : entry['appId'] as String,
                running: entry['running'] == true,
              ),
        ];
        _catalogAt = DateTime.now();
        final screen = payload['screen'];
        _hostScreen =
            screen is Map && screen['width'] is num && screen['height'] is num
            ? Size(
                (screen['width'] as num).toDouble(),
                (screen['height'] as num).toDouble(),
              )
            : null;
        // Still listed while locked, but nothing can be opened until unlock.
        _state.value = payload['locked'] == true
            ? const SourceState(
                SourceStatus.ready,
                failure: WindowStreamFailure(
                  WindowStreamFailureReason.sourceLocked,
                ),
              )
            : SourceState.ready;
        final completer = _catalog;
        _catalog = null;
        if (completer != null && !completer.isCompleted) {
          completer.complete(_windows);
        }
      case WindowStreamControlAction.icon:
        final appId = payload['appId'];
        final png = payload['png'];
        if (appId is String && png is String) {
          final bytes = base64Decode(png);
          _iconCache[appId] = bytes;
          _icons.remove(appId)?.complete(bytes);
        }
      case WindowStreamControlAction.thumbnail:
        final windowId = payload['windowId'];
        final jpeg = payload['jpeg'];
        if (windowId is int && jpeg is String) {
          final bytes = base64Decode(jpeg);
          _snapshotCache[windowId] = (at: DateTime.now(), jpeg: bytes);
          _thumbnails.remove(windowId)?.complete(bytes);
        }
      case WindowStreamControlAction.accept:
        final completer = _opening.remove(message.sessionId);
        final handle = _pendingHandles.remove(message.sessionId);
        if (completer == null || handle == null) {
          return;
        }
        final port = message.transportPort ?? _port;
        final hostDials = payload[WindowStreamMediaDial.hostDialsKey] == true;
        final inboundToken = hostDials
            ? _viewer.issueInboundToken?.call(peerId, message.sessionId)
            : null;
        if (hostDials && inboundToken == null) {
          // Asked to take a dial this device can't take: no stream.
          unawaited(handle._sendStop());
          completer.completeError(
            const WindowStreamFailure(
              WindowStreamFailureReason.connectionFailed,
              'no inbound token',
            ),
          );
          return;
        }
        final uri = Uri(
          scheme: 'ws',
          host: remoteHost.isNotEmpty ? remoteHost : _host,
          port: port,
          path: 'window',
          queryParameters: {
            'session': message.sessionId,
            'token': inboundToken ?? message.transportToken,
          },
        );
        if (inboundToken != null) {
          final inbound = _InboundWindow(
            hostPeerId: peerId,
            binding: mediaPacketChannelBindingFromUri(uri),
          );
          _viewer._inbound[message.sessionId] = inbound;
          handle._transport = InboundWhisperWindowSpec(
            uri: uri,
            sessionId: message.sessionId,
            viewerPeerId: _local,
            sendKey: sendKey,
            receiveKey: receiveKey,
            port: inbound.port,
          );
          // The host dials once it has the token; the stream isolate waits
          // for its socket (InboundWhisperWindowSpec.connectTimeout).
          unawaited(
            _send(
              _message(
                WindowStreamControlAction.dial,
                message.sessionId,
              ).withTransport(inboundToken),
            ),
          );
        } else {
          handle._transport = WhisperWindowSpec(
            uri: uri,
            sessionId: message.sessionId,
            viewerPeerId: _local,
            sendKey: sendKey,
            receiveKey: receiveKey,
          );
        }
        final width = payload['width'];
        final height = payload['height'];
        final windowId = payload['windowId'];
        if (windowId is int && windowId != handle.window.id) {
          // Opened by app: now we know which window the host picked.
          final old = handle.window;
          handle.window = RemoteWindowInfo(
            id: windowId,
            appId: old.appId,
            appName: old.appName,
            title: old.title,
            width: width is int ? width : 0,
            height: height is int ? height : 0,
          );
        }
        if (width is int && height is int) {
          handle._state.value = handle._state.value.copyWith(
            videoWidth: width,
            videoHeight: height,
          );
        }
        _streams[message.sessionId] = handle;
        completer.complete(handle);
      case WindowStreamControlAction.reject:
      case WindowStreamControlAction.error:
        final completer = _opening.remove(message.sessionId);
        _pendingHandles.remove(message.sessionId);
        final failure = WindowStreamFailure(
          windowStreamFailureForWire(payload['reason'])!,
          '${payload['reason']}',
        );
        if (completer != null && !completer.isCompleted) {
          completer.completeError(failure);
        }
        if (message.sessionId == _browseSession) {
          final catalog = _catalog;
          _catalog = null;
          if (catalog != null && !catalog.isCompleted) {
            catalog.completeError(failure);
          }
          // Something to fix over there (a permission, the GNOME helper):
          // say so above the device's windows until a catalog comes back.
          if (_persistentHostFailures.contains(failure.reason)) {
            _state.value = SourceState(SourceStatus.ready, failure: failure);
          }
        }
        _streams.remove(message.sessionId)?._remoteClosed(failure);
      case WindowStreamControlAction.stop:
        // A capture that failed on the host (permission, an elevated
        // window…) ends with its reason; the window says why.
        final reason = windowStreamFailureForWire(
          payload['reason'],
          stopping: true,
        );
        _streams
            .remove(message.sessionId)
            ?._remoteClosed(
              reason == null
                  ? null
                  : WindowStreamFailure(reason, '${payload['reason']}'),
            );
      case WindowStreamControlAction.offer:
        final window = payload['window'];
        if (window is! Map) {
          return;
        }
        Uint8List? image(Object? value) =>
            value is String && value.length < 400000
            ? base64Decode(value)
            : null;
        _viewer._addOffer(
          WindowOffer(
            source: this,
            window: RemoteWindowInfo.fromJson(window.cast<String, Object?>()),
            thumbnail: image(payload['thumbnail']),
            icon: image(payload['icon']),
          ),
        );
      case WindowStreamControlAction.closeResult:
        final windowId = payload['windowId'];
        if (message.sessionId == _browseSession && windowId is int) {
          _closeAnswered(windowId, closed: payload['outcome'] == 'closed');
        }
      case WindowStreamControlAction.browse ||
          WindowStreamControlAction.open ||
          WindowStreamControlAction.pause ||
          WindowStreamControlAction.resume ||
          WindowStreamControlAction.keyframe ||
          WindowStreamControlAction.viewport ||
          WindowStreamControlAction.closeWindow ||
          WindowStreamControlAction.dial:
        // Viewer-to-host messages; ignore if echoed back.
        break;
    }
  }

  void _disconnected() {
    _state.value = const SourceState(SourceStatus.unavailable);
    _browseSession = null;
    for (final answer in _closing.values) {
      if (!answer.isCompleted) {
        answer.complete(TaskCloseOutcome.failed);
      }
    }
    _closing.clear();
    for (final stream in _streams.values.toList()) {
      stream._remoteClosed(
        const WindowStreamFailure(WindowStreamFailureReason.deviceDisconnected),
      );
    }
    _streams.clear();
    for (final completer in _opening.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const WindowStreamFailure(
            WindowStreamFailureReason.deviceDisconnected,
          ),
        );
      }
    }
    _opening.clear();
  }

  @override
  Future<void> dispose() async {
    for (final stream in _streams.values.toList()) {
      await stream.close();
    }
  }
}

class RemoteStreamHandle implements StreamHandle {
  RemoteStreamHandle._({
    required this.source,
    required this.id,
    required this.target,
    required this.window,
  });

  @override
  final RemotePeerSource source;
  @override
  final String id;
  @override
  final OpenTarget target;
  RemoteWindowInfo window;
  StreamTransportSpec? _transport;

  /// The screen this window is shown on, in logical points.
  Size _viewport = Size.zero;
  Size get viewport => _viewport;

  /// This screen's pixels per point, so the host sends no more than that.
  double _pixelRatio = 1;
  final _state = ValueNotifier<StreamState>(
    const StreamState(StreamStatus.opening),
  );
  bool _closed = false;
  DateTime _lastKeyframe = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  String get title => window.title.isEmpty ? window.appName : window.title;

  @override
  ValueListenable<StreamState> get state => _state;

  @override
  StreamTransportSpec get transport => _transport!;

  @override
  void onTransportEvent(StreamTransportEvent event) {
    switch (event) {
      case TransportConnected():
        _state.value = _state.value.copyWith(status: StreamStatus.live);
      case TransportVideoSize(:final width, :final height):
        _state.value = _state.value.copyWith(
          videoWidth: width,
          videoHeight: height,
        );
      case TransportEnded(:final failure):
        _remoteClosed(failure);
        unawaited(_sendStop());
      case TransportTextFocus(:final typing):
        textFocus.value = typing;
      case TransportAudioState() || TransportClipboard() || TransportStats():
        break;
    }
  }

  /// The window's keyboard focus is somewhere to type (a phone shows its
  /// keyboard then).
  final textFocus = ValueNotifier<bool>(false);

  void _remoteClosed(WindowStreamFailure? failure) {
    if (_closed) {
      return;
    }
    _closed = true;
    source._streams.remove(id);
    source._viewer._closeInbound(id);
    _state.value = _state.value.copyWith(
      status: StreamStatus.closed,
      failure: failure,
    );
  }

  Future<void> _sendStop() {
    return source._send(source._message(WindowStreamControlAction.stop, id));
  }

  @override
  void sendInput(WindowInputEvent event) =>
      WindowStreamViewer.shared.inputPort?.call(id, event);

  @override
  void requestKeyframe() {
    final now = DateTime.now();
    if (now.difference(_lastKeyframe) < const Duration(milliseconds: 400)) {
      return;
    }
    _lastKeyframe = now;
    unawaited(
      source._send(source._message(WindowStreamControlAction.keyframe, id)),
    );
  }

  @override
  void setQuality(QualityTier tier) {}

  /// The viewer's screen turned or resized: the host fits the window again.
  @override
  Future<void> setViewport({required int width, required int height}) async {
    final next = Size(width.toDouble(), height.toDouble());
    if (_closed || width <= 0 || height <= 0 || next == _viewport) {
      return;
    }
    _viewport = next;
    await _sendViewport();
  }

  /// The window moved to a screen of another density.
  Future<void> setPixelRatio(double ratio) async {
    if (_closed || ratio <= 0 || (ratio - _pixelRatio).abs() < 0.01) {
      return;
    }
    _pixelRatio = ratio;
    await _sendViewport();
  }

  /// Aa: Mac points per point of this screen; larger means bigger text.
  Future<void> setTextScale(double scale) async {
    await RemoteViewport.setScale(scale);
    if (!_closed) {
      await _sendViewport();
    }
  }

  /// The keyboard covers [fraction] of the picture's bottom (0: down): the
  /// window over there stops above it, as an app here would.
  Future<void> setKeyboardInset(double fraction) async {
    final next = fraction.clamp(0.0, 0.8);
    if (_closed || (next - _keyboardInset).abs() < 0.01) {
      return;
    }
    _keyboardInset = next;
    await _sendViewport();
  }

  double _keyboardInset = 0;

  Future<void> _sendViewport() => source._send(
    source._message(WindowStreamControlAction.viewport, id, {
      'viewportWidth': _viewport.width.round(),
      'viewportHeight': _viewport.height.round(),
      'viewportScale': RemoteViewport.scale,
      'pixelRatio': _pixelRatio,
      'keyboardInset': _keyboardInset,
    }),
  );

  @override
  Future<void> suspend() async {
    await source._send(source._message(WindowStreamControlAction.pause, id));
    if (!_closed) {
      _state.value = _state.value.copyWith(status: StreamStatus.suspended);
    }
  }

  @override
  Future<void> resume() async {
    await source._send(source._message(WindowStreamControlAction.resume, id));
    if (!_closed) {
      _state.value = _state.value.copyWith(status: StreamStatus.live);
    }
  }

  @override
  Future<void> close({CloseMode mode = CloseMode.returnToSource}) async {
    if (_closed) {
      return;
    }
    await _sendStop();
    _remoteClosed(null);
  }
}

/// The UI isolate's end of [InboundWindowRelay] for one stream: the host's
/// `/window` socket, once the Whisper server has checked its proof, and the
/// stream isolate's port. Packets pass through still encrypted.
class _InboundWindow {
  _InboundWindow({required this.hostPeerId, required this.binding}) {
    _fromWorker.listen(_onWorker);
  }

  final String hostPeerId;

  /// The token this viewer issued, as the packets' channel binding.
  final Uint8List binding;
  final _fromWorker = ReceivePort('window-inbound-relay');
  SendPort? _toWorker;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _reading;
  bool _closed = false;

  SendPort get port => _fromWorker.sendPort;

  bool get awaiting => !_closed && _channel == null;

  bool attach(WebSocketChannel channel) {
    if (!awaiting) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    _channel = channel;
    _relay();
    return true;
  }

  void _onWorker(Object? message) {
    if (message is SendPort) {
      _toWorker = message;
      _relay();
    } else if (message is Uint8List) {
      _channel?.sink.add(message);
    } else if (message == InboundWindowRelay.close) {
      close();
    }
  }

  void _relay() {
    final toWorker = _toWorker;
    final channel = _channel;
    if (toWorker == null || channel == null || _reading != null || _closed) {
      return;
    }
    toWorker.send(InboundWindowRelay.connected);
    _reading = channel.stream.listen(
      (message) {
        if (message is Uint8List) {
          toWorker.send(message);
        } else if (message is List<int>) {
          toWorker.send(Uint8List.fromList(message));
        }
      },
      onError: (Object _) {},
      onDone: close,
    );
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _toWorker?.send(InboundWindowRelay.closed);
    unawaited(_reading?.cancel());
    unawaited(_channel?.sink.close().catchError((Object _) {}));
    _fromWorker.close();
    binding.fillRange(0, binding.length, 0);
  }
}

/// Runs at most [limit] tasks at a time, in order.
class _Limiter {
  _Limiter(this.limit);

  final int limit;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  Future<void> run(Future<void> Function() task) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      await task();
    } catch (_) {
      // A failed request only costs its own icon or thumbnail.
    } finally {
      _running--;
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      }
    }
  }
}

/// The viewer's side of how big a streamed window is: the screen it is shown
/// on and the text scale (Aa) the user picked, remembered across sessions.
abstract final class RemoteViewport {
  static const steps = [0.5, 0.75, 1.0, 1.25, 1.5];
  static const _key = 'window_stream.text_scale';

  static double? _scale;
  static const _landscapeKey = 'window_stream.landscape';
  static bool? _landscape;

  /// Points of this screen per Mac point. Phones start a step below 1 so a
  /// typical Mac window fits; tablets at 1.
  static double get scale => _scale ?? (_isPhone ? 0.75 : 1.0);

  /// Whether windows show in landscape here. Phones start upright, the way
  /// they are held (and their recents read like a phone's); tablets on
  /// their side. The window's rotate button changes it, and it stays.
  static bool get landscape => _landscape ?? !_isPhone;

  static Future<void> setLandscape(bool value) async {
    _landscape = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_landscapeKey, value);
  }

  static bool get _isPhone {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) {
      return false;
    }
    final view = views.first;
    final shortest = (view.physicalSize / view.devicePixelRatio).shortestSide;
    return shortest > 0 && shortest < 600;
  }

  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_key);
    if (saved != null && steps.contains(saved)) {
      _scale = saved;
    }
    _landscape = prefs.getBool(_landscapeKey);
  }

  static Future<void> setScale(double value) async {
    _scale = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, value);
  }

  /// This screen's pixels per point (the main display's on desktops).
  static double get pixelRatio {
    final dispatcher = PlatformDispatcher.instance;
    final views = dispatcher.views;
    final ratio = views.isNotEmpty
        ? (isDesktop
              ? views.first.display.devicePixelRatio
              : views.first.devicePixelRatio)
        : dispatcher.displays.firstOrNull?.devicePixelRatio;
    return ratio == null || ratio <= 0 ? 1 : ratio;
  }

  /// Windows show in native windows of their own here, not full screen.
  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// `viewerKind` in `open`: the host gives a desktop viewer one virtual
  /// display per window (all live at once) and a phone or tablet one
  /// display that its windows take turns on.
  static String get viewerKind => isDesktop
      ? 'desktop'
      : _isPhone
      ? 'phone'
      : 'tablet';

  /// The size, in points, of the native window a streamed window of
  /// [videoWidth]×[videoHeight] opens in on this desktop. Mirrors the
  /// natives' initial size (macOS `StreamWindowController`): the picture's
  /// shape at up to 900 points tall, at most 82 % of the work area's height
  /// and 60 % of its width. The native reports the real size once the
  /// window is up (`WSN_WINDOW_RESIZED`) and the host follows it.
  static Size desktopWindow(int videoWidth, int videoHeight) {
    final work = desktopWorkArea();
    return fitDesktopWindow(
      work,
      videoWidth > 0 && videoHeight > 0
          ? Size(videoWidth.toDouble(), videoHeight.toDouble())
          // Opened by app: no window yet, so guess an ordinary one.
          : const Size(1280, 800),
    );
  }

  @visibleForTesting
  static Size fitDesktopWindow(Size work, Size video) {
    final maxHeight = math.max(320.0, work.height * 0.82);
    final maxWidth = math.max(320.0, work.width * 0.6);
    var height = math.min(maxHeight, 900.0);
    var width = height * video.width / video.height;
    if (width > maxWidth) {
      width = maxWidth;
      height = width * video.height / video.width;
    }
    return Size(width.roundToDouble(), height.roundToDouble());
  }

  /// The main display's area for windows, in points: its size less the
  /// menu bar and Dock (macOS), taskbar (Windows) or top bar (GNOME). Flutter
  /// does not report work areas, so the system bars are typical sizes.
  static Size desktopWorkArea() {
    final dispatcher = PlatformDispatcher.instance;
    final screen = dispatcher.views.isNotEmpty
        ? dispatcher.views.first.display
        : dispatcher.displays.firstOrNull;
    if (screen == null || screen.devicePixelRatio <= 0) {
      return const Size(1440, 900);
    }
    final size = screen.size / screen.devicePixelRatio;
    final bars = Platform.isMacOS
        ? 34 + 80
        : Platform.isWindows
        ? 48
        : 32;
    return Size(size.width, math.max(320, size.height - bars));
  }

  /// The screen a window will be shown on, in logical points. On Android
  /// windows open full screen in their own activity, upright or on its side
  /// ([landscape]); elsewhere the screen as it is, without the system bars.
  static Size screen() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) {
      return Size.zero;
    }
    final view = views.first;
    final ratio = view.devicePixelRatio;
    if (Platform.isAndroid) {
      final size = view.physicalSize / ratio;
      return landscape
          ? Size(size.longestSide, size.shortestSide)
          : Size(size.shortestSide, size.longestSide);
    }
    if (Platform.isIOS) {
      // The viewer is full screen (immersive), upright or turned; what a
      // window can use is the screen less the sensor housing and the home
      // indicator (measured on an iPhone 17 Pro: 402×778 and 750×382).
      final size = view.physicalSize / ratio;
      final padding = view.viewPadding;
      final top = padding.top / ratio;
      final bottom = padding.bottom / ratio;
      if (_isPhone) {
        final faceId = bottom > 0;
        final housing = faceId ? top : 0.0;
        return landscape
            ? Size(
                size.longestSide - 2 * housing,
                size.shortestSide - (faceId ? 20 : 0),
              )
            : Size(size.shortestSide, size.longestSide - housing - bottom);
      }
      return Size(
        size.width - (padding.left + padding.right) / ratio,
        size.height - bottom,
      );
    }
    final padding = view.padding;
    return Size(
      (view.physicalSize.width - padding.left - padding.right) / ratio,
      (view.physicalSize.height - padding.top - padding.bottom) / ratio,
    );
  }
}
