import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../window_stream/core/window_source.dart';
import '../../window_stream/core/window_stream_models.dart';
import '../../window_stream/remote/remote_peer_source.dart';
import '../../window_stream/window_stream_coordinator.dart';

/// Everything the Flow Space shows for one source.
class FlowSourceView {
  FlowSourceView(this.source);

  final WindowSource source;
  List<AppEntry>? apps;
  List<TaskEntry> tasks = const [];
  final icons = <String, Uint8List>{};
  final snapshots = <int, Uint8List>{};
  bool loading = false;
  WindowStreamFailure? failure;

  /// Tasks closed here a moment ago; a list read just before they went may
  /// still name them.
  final closed = <int, DateTime>{};
}

/// UI-side model of the Flow Space: which device is selected, its apps,
/// recents, icons and snapshots, and live thumbnails of open windows.
/// Fetching is paced so remote devices are not flooded.
class FlowSpaceController extends ChangeNotifier {
  FlowSpaceController({WindowStreamCoordinator? coordinator, this.focusPeerId})
    : coordinator = coordinator ?? WindowStreamCoordinator.shared {
    this.coordinator.addListener(_onCoordinator);
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    _onCoordinator();
  }

  final WindowStreamCoordinator coordinator;

  /// Opened from a device's page: select that device once it shows up.
  final String? focusPeerId;
  late final Timer _refresh;
  final _views = <String, FlowSourceView>{};
  final _windowThumbnails = <String, Uint8List>{};
  final _iconRequests = <String>{};
  final _snapshotRequests = <String>{};
  String? _selectedId;
  int _tickCount = 0;
  bool _disposed = false;
  Directory? _thumbDir;

  List<WindowSource> get sources => coordinator.sources;

  /// Connected devices that only take windows from here (an iPad): no
  /// windows of their own to list, only "送到".
  List<WindowStreamPeer> get sendOnly => [
    for (final peer in WindowStreamViewer.shared.targets)
      if (coordinator.sourceForPeer(peer.peerId) == null) peer,
  ];

  static String _sendId(String peerId) => 'send:$peerId';

  /// The send-only device chosen, or the first one when nothing else is
  /// there to choose.
  WindowStreamPeer? get selectedTarget {
    final targets = sendOnly;
    for (final peer in targets) {
      if (_sendId(peer.peerId) == _selectedId) {
        return peer;
      }
    }
    return sources.isEmpty ? targets.firstOrNull : null;
  }

  WindowSource? get selected {
    final all = sources;
    if (all.isEmpty || selectedTarget != null) {
      return null;
    }
    return all.firstWhere(
      (source) => source.info.id == _selectedId,
      orElse: () => all.first,
    );
  }

  FlowSourceView? get selectedView {
    final source = selected;
    return source == null ? null : _viewFor(source);
  }

  List<WindowStreamSession> get sessions => coordinator.sessions;

  Uint8List? windowThumbnail(WindowStreamSession session) =>
      _windowThumbnails[session.id];

  void select(WindowSource source) {
    if (_selectedId == source.info.id) {
      return;
    }
    _selectedId = source.info.id;
    notifyListeners();
    unawaited(_load(source));
  }

  void selectTarget(WindowStreamPeer peer) {
    final id = _sendId(peer.peerId);
    if (_selectedId == id) {
      return;
    }
    _selectedId = id;
    notifyListeners();
  }

  FlowSourceView _viewFor(WindowSource source) {
    final existing = _views[source.info.id];
    if (existing != null && identical(existing.source, source)) {
      return existing;
    }
    final view = FlowSourceView(source);
    _views[source.info.id] = view;
    return view;
  }

  void _onCoordinator() {
    if (_disposed) {
      return;
    }
    final focus = focusPeerId;
    if (_selectedId == null && focus != null) {
      _selectedId =
          coordinator.sourceForPeer(focus)?.info.id ??
          (sendOnly.any((peer) => peer.peerId == focus)
              ? _sendId(focus)
              : null);
    }
    final source = selected;
    if (source != null) {
      final view = _viewFor(source);
      if (view.apps == null && !view.loading && view.failure == null) {
        unawaited(_load(source));
      }
    }
    notifyListeners();
  }

  /// [taskId] closed on its device: gone from here at once, not at the
  /// next refresh.
  void forgetTask(WindowSource source, int taskId) {
    final view = _views[source.info.id];
    if (view == null || _disposed) {
      return;
    }
    view.closed[taskId] = DateTime.now();
    view.tasks = [
      for (final task in view.tasks)
        if (task.id != taskId) task,
    ];
    view.snapshots.remove(taskId);
    notifyListeners();
  }

  Future<void> reload() async {
    final source = selected;
    if (source != null) {
      final view = _viewFor(source);
      view.failure = null;
      await _load(source, force: true);
    }
  }

  Future<void> _load(WindowSource source, {bool force = false}) async {
    final view = _viewFor(source);
    if (view.loading) {
      return;
    }
    view.loading = true;
    notifyListeners();
    try {
      view.apps = await source.apps(refresh: force);
      final tasks = await source.tasks();
      final now = DateTime.now();
      view.closed.removeWhere(
        (_, at) => now.difference(at) > const Duration(seconds: 6),
      );
      view.tasks = [
        for (final task in tasks)
          if (!view.closed.containsKey(task.id)) task,
      ];
      view.failure = null;
      _requestIcons(view);
      _requestSnapshots(view);
    } on WindowStreamFailure catch (failure) {
      view.failure = failure;
    } catch (error) {
      view.failure = WindowStreamFailure(
        WindowStreamFailureReason.unknown,
        '$error',
      );
    } finally {
      view.loading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _requestIcons(FlowSourceView view) {
    if (!view.source.info.capabilities.appIcons) {
      return;
    }
    final wanted = <String>{
      for (final task in view.tasks) task.appId,
      for (final app in view.apps ?? const <AppEntry>[]) app.id,
    };
    // Every one: a Mac lists more than a hundred apps, and the source sends
    // a few requests at a time, so asking for all does not flood it.
    for (final appId in wanted) {
      final key = '${view.source.info.id}/$appId';
      if (view.icons.containsKey(appId) || !_iconRequests.add(key)) {
        continue;
      }
      unawaited(
        view.source
            .icon(appId)
            .then((bytes) {
              if (bytes != null && !_disposed) {
                view.icons[appId] = bytes;
                notifyListeners();
              }
            })
            .whenComplete(() => _iconRequests.remove(key)),
      );
    }
  }

  void _requestSnapshots(FlowSourceView view, {bool refresh = false}) {
    if (!view.source.info.capabilities.taskSnapshots) {
      return;
    }
    for (final task in view.tasks.take(8)) {
      final key = '${view.source.info.id}/${task.id}';
      if ((!refresh && view.snapshots.containsKey(task.id)) ||
          !_snapshotRequests.add(key)) {
        continue;
      }
      unawaited(
        view.source
            .snapshot(task)
            .then((bytes) {
              if (bytes != null && !_disposed) {
                view.snapshots[task.id] = bytes;
                notifyListeners();
              }
            })
            .whenComplete(() => _snapshotRequests.remove(key)),
      );
    }
  }

  Future<void> _tick() async {
    if (_disposed) {
      return;
    }
    _tickCount++;
    final source = selected;
    if (source != null) {
      final view = _viewFor(source);
      if (!view.loading && view.failure == null) {
        try {
          view.tasks = await source.tasks();
          if (_tickCount % 4 == 0) {
            _requestSnapshots(view, refresh: true);
          } else {
            _requestSnapshots(view);
          }
          _requestIcons(view);
        } catch (_) {
          // Keep the last list; the device card shows connection problems.
        }
      }
    }
    await _refreshWindowThumbnails();
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _refreshWindowThumbnails() async {
    final sessions = coordinator.sessions
        .where((session) => !session.flutterHosted)
        .toList();
    if (sessions.isEmpty) {
      return;
    }
    final dir = _thumbDir ??= await Directory.systemTemp.createTemp(
      'whisper-window-thumbs',
    );
    for (final session in sessions) {
      final path = p.join(dir.path, '${session.surface}.jpg');
      if (coordinator.snapshot(session, path, maxEdge: 520)) {
        try {
          _windowThumbnails[session.id] = await File(path).readAsBytes();
        } catch (_) {
          // The next tick tries again.
        }
      }
    }
    _windowThumbnails.removeWhere(
      (id, _) => coordinator.sessionById(id) == null,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _refresh.cancel();
    coordinator.removeListener(_onCoordinator);
    final dir = _thumbDir;
    if (dir != null) {
      unawaited(dir.delete(recursive: true).catchError((Object _) => dir));
    }
    super.dispose();
  }
}
