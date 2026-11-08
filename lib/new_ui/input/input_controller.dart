import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/macos_permissions.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/input/input_rules.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_exit_shortcut.dart';
import 'package:whisper/remote_input/remote_input_failure_reason.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/new_ui/shell/shell_wake.dart';
import 'package:whisper/remote_input/remote_input_workspace_graph.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/theme/whisper_device_art.dart';

/// What the keyboard and mouse page needs from outside, so that it can be tested
/// without a network or a database. [InputBackend.live] is the real thing.
class InputBackend {
  const InputBackend({
    required this.localTopology,
    required this.refreshProfiles,
    required this.isConnected,
    required this.supportsGraph,
    required this.remoteTopology,
    required this.remoteTrusts,
    required this.localTrusts,
    required this.loadLayout,
    required this.saveLayout,
    required this.sendControl,
    required this.selfPeerId,
    required this.accessibilityDenied,
    required this.requestAccessibility,
    this.permissions,
  });

  factory InputBackend.live() {
    final socket = WsSvrManager();
    return InputBackend(
      localTopology: RemoteInputCoordinator.shared.displayTopology,
      refreshProfiles: () => Future.wait(
        socket.connectedPeerIds.map(
          (peerId) => socket.requestRemoteProfileRefresh(peerId: peerId),
        ),
      ),
      isConnected: socket.isConnectedTo,
      supportsGraph: socket.supportsRemoteInputWorkspaceGraphFor,
      remoteTopology: socket.remoteDisplayTopologyFor,
      remoteTrusts: socket.remotePeerTrustsPeer,
      localTrusts: (peerId) async =>
          (await LocalDatabase().fetchDevice(peerId))?.auth == true,
      loadLayout: LocalDatabase().fetchRemoteInputLayout,
      saveLayout: LocalDatabase().upsertRemoteInputLayout,
      sendControl: socket.sendRemoteInputControlTo,
      selfPeerId: () async => (await LocalSetting().instance()).uid,
      accessibilityDenied: () =>
          MacPermissions.supported &&
          MacPermissions.shared.stateOf(MacPermission.accessibility) ==
              MacPermissionState.denied,
      requestAccessibility: () =>
          MacPermissions.shared.request(MacPermission.accessibility),
      permissions: MacPermissions.supported ? MacPermissions.shared : null,
    );
  }

  final Future<RemoteInputTopology> Function() localTopology;
  final Future<void> Function() refreshProfiles;
  final bool Function(String peerId) isConnected;
  final bool Function(String peerId) supportsGraph;
  final RemoteInputTopology? Function(String peerId) remoteTopology;
  final bool Function(String peerId, String selfPeerId) remoteTrusts;
  final Future<bool> Function(String peerId) localTrusts;
  final Future<RemoteInputLayoutData?> Function(String peerId) loadLayout;
  final Future<void> Function(RemoteInputLayoutData layout) saveLayout;
  final RemoteInputPeerControlSender sendControl;
  final Future<String> Function() selfPeerId;
  final bool Function() accessibilityDenied;
  final Future<void> Function() requestAccessibility;

  /// Told when [accessibilityDenied] may have changed.
  final Listenable? permissions;
}

/// One screen on the canvas: a whole device, its displays drawn apart.
@immutable
class InputScreen {
  const InputScreen({
    required this.peerId,
    required this.name,
    required this.isSelf,
    required this.bounds,
    required this.displays,
    required this.device,
    required this.status,
  });

  final String peerId, name;
  final bool isSelf;
  final RemoteInputScreenRect bounds;

  /// Placed in the arrangement, like [bounds].
  final List<RemoteInputScreenRect> displays;

  /// Null for this device.
  final DeviceData? device;
  final InputScreenStatus status;
}

enum InputCandidateState { available, unsupported }

@immutable
class InputCandidate {
  const InputCandidate({required this.device, required this.state});

  final DeviceData device;
  final InputCandidateState state;

  bool get enabled => state == InputCandidateState.available;
}

/// What the line under the canvas is about.
sealed class InputFooter {
  const InputFooter();
}

class InputFooterHint extends InputFooter {
  const InputFooterHint();
}

class InputFooterExit extends InputFooter {
  const InputFooterExit(this.shortcut);

  final String shortcut;
}

class InputFooterNoTargets extends InputFooter {
  const InputFooterNoTargets();
}

class InputFooterPermission extends InputFooter {
  const InputFooterPermission();
}

class InputFooterFailed extends InputFooter {
  const InputFooterFailed();
}

class InputFooterScreen extends InputFooter {
  const InputFooterScreen({
    required this.screen,
    required this.side,
    required this.failure,
  });

  final InputScreen screen;
  final InputSide side;

  /// Why it says 没有连上, with a retry beside it. Null when it is fine.
  final InputFailure? failure;
}

/// One state for the page, the device card and the tray: where the screens are,
/// who is arranged, why some are not connected. Positions and membership are
/// saved in `RemoteInputLayout` (`enabled` says it is on the canvas), everything
/// else comes from the coordinators.
class ShellInputController extends ChangeNotifier {
  ShellInputController({
    required RemoteInputWorkspaceCoordinator workspace,
    required RemoteInputCoordinator runtime,
    required InputBackend backend,
    bool macHotkey = false,
  }) : _workspace = workspace,
       _runtime = runtime,
       _backend = backend,
       _macHotkey = macHotkey {
    _workspace.addListener(notifyListeners);
    _runtime.addListener(notifyListeners);
  }

  static final ShellInputController shared = ShellInputController(
    workspace: RemoteInputWorkspaceCoordinator.shared,
    runtime: RemoteInputCoordinator.shared,
    backend: InputBackend.live(),
    macHotkey: defaultTargetPlatform == TargetPlatform.macOS,
  );

  static const _rootPlaceholder = '__local_controller__';

  final RemoteInputWorkspaceCoordinator _workspace;
  final RemoteInputCoordinator _runtime;
  final InputBackend _backend;
  final bool _macHotkey;

  List<DeviceData> _desktops = const [];
  final Map<String, RemoteInputLayoutData> _layouts = {};
  RemoteInputTopology _local = RemoteInputTopology.fallback();
  String _selfId = _rootPlaceholder;
  String _selfName = '';
  String? _selected;
  Map<String, InputFailure> _excluded = const {};
  RemoteInputFailureReason? _startFailure;
  bool _starting = false;
  int _attached = 0;
  int _refreshGeneration = 0;
  Future<void> _queue = Future<void>.value();

  // ---- Reading ----

  String get selfId => _selfId;

  /// The switch: on while sharing, and from the moment it was asked for.
  bool get on => _liveSource || _starting;

  bool get _liveSource => _workspace.isControllerLive || _legacyLive;

  bool get _legacyLive {
    final state = _runtime.state;
    return state.role == RemoteInputRuntimeRole.source &&
        state.status != RemoteInputRuntimeStatus.idle &&
        state.status != RemoteInputRuntimeStatus.failed;
  }

  /// `state.role == sink`: this device is being controlled. Who by, else null.
  String? get controlledBy {
    final state = _runtime.state;
    if (state.role != RemoteInputRuntimeRole.sink ||
        state.status == RemoteInputRuntimeStatus.idle ||
        state.status == RemoteInputRuntimeStatus.failed ||
        state.peerId.isEmpty) {
      return null;
    }
    return state.peerId;
  }

  bool get permissionNeeded =>
      _backend.accessibilityDenied() ||
      _startFailure == RemoteInputFailureReason.permission;

  String? get selected => _selected;

  /// Where the arrow is: on the screen it has gone to, otherwise this one.
  String get pointerPeerId {
    final active = _workspace.snapshot.activePeerId;
    return active.isNotEmpty && _isPlaced(active) ? active : _selfId;
  }

  bool get switchEnabled => on || _controllable.isNotEmpty;

  Iterable<DeviceData> get _placedDevices =>
      _desktops.where((device) => _isPlaced(device.uid));

  /// Only a connected device is on this page: one that is away keeps its saved
  /// place for when it comes back, but takes up no room meanwhile.
  bool _isPlaced(String peerId) {
    final layout = _layouts[peerId];
    if (layout == null || !layout.enabled) return false;
    // An old version cannot join: it waits among the candidates, marked.
    return _backend.isConnected(peerId) && _backend.supportsGraph(peerId);
  }

  Iterable<DeviceData> get _controllable => _placedDevices;

  /// Connected devices that are not on the canvas. Phones never get here.
  List<InputCandidate> get candidates {
    final list = <InputCandidate>[];
    for (final device in _desktops) {
      if (_isPlaced(device.uid) || !_backend.isConnected(device.uid)) continue;
      list.add(
        InputCandidate(
          device: device,
          state: _backend.supportsGraph(device.uid)
              ? InputCandidateState.available
              : InputCandidateState.unsupported,
        ),
      );
    }
    return list;
  }

  /// This device first, then everything arranged.
  List<InputScreen> get screens => [
    _selfScreen,
    ..._placedDevices.map(_screenOf),
  ];

  InputScreen get _selfScreen {
    final node = _rootNode;
    return InputScreen(
      peerId: _selfId,
      name: _selfName,
      isSelf: true,
      bounds: node.bounds,
      displays: [for (final d in node.placedDisplays) d.rect],
      device: null,
      status: InputScreenStatus.none,
    );
  }

  InputScreen _screenOf(DeviceData device) {
    final peerId = device.uid;
    final node = _nodeOf(device);
    final snapshot = _workspace.snapshot;
    return InputScreen(
      peerId: peerId,
      name: device.name,
      isSelf: false,
      bounds: node.bounds,
      displays: [for (final d in node.placedDisplays) d.rect],
      device: device,
      status: inputScreenStatus(
        excluded: _excluded.containsKey(peerId),
        isActive: snapshot.activePeerId == peerId,
        target: snapshot.targets[peerId],
        live: _workspace.isControllerLive,
      ),
    );
  }

  /// A candidate being dragged in has no place yet, only a shape.
  InputScreen? previewScreen(String peerId) {
    final device = _deviceOf(peerId);
    if (device == null || _layouts[peerId] == null) return null;
    return _screenOf(device);
  }

  InputFooter get footer {
    final selected = _selected;
    final device = selected == null ? null : _deviceOf(selected);
    if (device != null && _isPlaced(device.uid)) {
      final screen = _screenOf(device);
      return InputFooterScreen(
        screen: screen,
        side: inputSideOf(_rootNode.bounds, screen.bounds),
        failure: screen.status == InputScreenStatus.notConnected
            ? _failureOf(device.uid)
            : null,
      );
    }
    if (permissionNeeded) return const InputFooterPermission();
    if (_startFailure != null ||
        _workspace.snapshot.status == RemoteInputWorkspaceStatus.failed &&
            _workspace.snapshot.targets.isEmpty) {
      return const InputFooterFailed();
    }
    if (on) {
      return InputFooterExit(remoteInputReleaseHotkeyLabel(macOS: _macHotkey));
    }
    if (_controllable.isEmpty && !candidates.any((c) => c.enabled)) {
      return const InputFooterNoTargets();
    }
    return const InputFooterHint();
  }

  InputFailure _failureOf(String peerId) {
    final excluded = _excluded[peerId];
    if (excluded != null) return excluded;
    final target = _workspace.snapshot.targets[peerId];
    return inputFailureFromWire(target?.errorMessage ?? '');
  }

  DeviceData? _deviceOf(String peerId) {
    for (final device in _desktops) {
      if (device.uid == peerId) return device;
    }
    return null;
  }

  // ---- Geometry ----

  RemoteInputWorkspaceNode get _rootNode => RemoteInputWorkspaceNode(
    peerId: _selfId,
    topology: _local,
    offsetX: 0,
    offsetY: 0,
    isController: true,
  );

  RemoteInputWorkspaceNode _nodeOf(
    DeviceData device, {
    RemoteInputLayoutData? layout,
  }) {
    final place = layout ?? _layouts[device.uid]!;
    final topology =
        _backend.remoteTopology(device.uid) ??
        RemoteInputTopology(
          platform: device.platform,
          displays: [
            RemoteInputDisplay(
              displayId: '${device.uid}-screen',
              name: device.name,
              x: 0,
              y: 0,
              width: place.width,
              height: place.height,
              scale: 1,
              isPrimary: true,
            ),
          ],
          updatedAt: 0,
        );
    final remote = topology.virtualBounds;
    return RemoteInputWorkspaceNode(
      peerId: device.uid,
      topology: topology,
      offsetX: place.x - remote.x,
      offsetY: place.y - remote.y,
    );
  }

  /// Where [peerId] would land if it were let go with its corner at [x], [y].
  math.Point<int>? snapFor(String peerId, int x, int y) {
    final device = _deviceOf(peerId);
    final layout = _layouts[peerId];
    if (device == null || layout == null) return null;
    final moving = _nodeOf(
      device,
      layout: layout.copyWith(x: x, y: y),
    );
    final landed = inputSnap(
      moving: moving,
      root: _rootNode,
      others: _placedDevices.map((d) => _nodeOf(d)),
    );
    if (landed == null) return null;
    final bounds = landed.bounds;
    return math.Point(bounds.x, bounds.y);
  }

  /// Everything the pointer can no longer reach goes back next to something.
  /// Returns the layouts that moved, to be saved.
  List<RemoteInputLayoutData> _reattach() {
    final nodes = {
      for (final device in _placedDevices) device.uid: _nodeOf(device),
    };
    if (nodes.isEmpty) return const [];
    final placed = inputReattach(root: _rootNode, nodes: nodes);
    final moved = <RemoteInputLayoutData>[];
    placed.forEach((peerId, node) {
      final current = _layouts[peerId]!;
      final bounds = node.bounds;
      if (current.x == bounds.x &&
          current.y == bounds.y &&
          current.width == bounds.width &&
          current.height == bounds.height) {
        return;
      }
      final next = current.copyWith(
        x: bounds.x,
        y: bounds.y,
        width: bounds.width,
        height: bounds.height,
        layoutVersion: 3,
        layoutJson: '',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _layouts[peerId] = next;
      moved.add(next);
    });
    return moved;
  }

  // ---- Loading ----

  /// The page is on screen. [devices] may include phones; they are ignored.
  void attach({required List<DeviceData> devices, required DeviceData? self}) {
    if (_attached++ == 0) _backend.permissions?.addListener(notifyListeners);
    updateDevices(devices: devices, self: self, force: true);
  }

  void detach() {
    if (--_attached == 0) _backend.permissions?.removeListener(notifyListeners);
  }

  /// When the list changes. Reloads only if someone came or went.
  void updateDevices({
    required List<DeviceData> devices,
    required DeviceData? self,
    bool force = false,
  }) {
    final desktops = [
      for (final device in devices)
        if (!deviceKindFor(device.platform).handheld) device,
    ];
    if (self != null) _selfName = self.name;
    final signature = _signatureOf(desktops);
    final same = !force && signature == _signature;
    _desktops = desktops;
    if (same) {
      notifyListeners();
      return;
    }
    _signature = signature;
    unawaited(_refresh());
  }

  /// Who is here, and what their screens are now. If one of them changes,
  /// the arrangement is worked out again (`surfaces.md`「键鼠」的冲突).
  String _signatureOf(List<DeviceData> desktops) => [
    for (final device in desktops)
      [
        device.uid,
        _backend.isConnected(device.uid),
        _backend.supportsGraph(device.uid),
        for (final display
            in _backend.remoteTopology(device.uid)?.displays ??
                const <RemoteInputDisplay>[])
          '${display.displayId}:${display.x},${display.y},'
              '${display.width},${display.height}',
      ].join(' '),
  ].join('\n');

  String _signature = '';

  /// The screens of this device changed.
  Future<void> refreshLocalTopology() async {
    final topology = await _readLocalTopology();
    _local = topology;
    notifyListeners();
  }

  Future<RemoteInputTopology> _readLocalTopology() async {
    try {
      final topology = await _backend.localTopology();
      return topology.isNotEmpty ? topology : RemoteInputTopology.fallback();
    } on Object {
      return RemoteInputTopology.fallback();
    }
  }

  /// What is known is on the canvas at once. Asking the others for their
  /// screens can take a while, and only refines it.
  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    final profiles = () async {
      try {
        await _backend.refreshProfiles();
      } on Object {
        // Whatever is known is still worth showing.
      }
    }();
    _local = await _readLocalTopology();
    _selfId = await _backend.selfPeerId();
    if (generation != _refreshGeneration) return;
    await _loadLayouts(generation);
    if (generation != _refreshGeneration) return;
    await profiles;
    if (generation != _refreshGeneration) return;
    _signature = _signatureOf(_desktops);
    await _loadLayouts(generation);
    if (generation != _refreshGeneration) return;
    await _syncLive();
  }

  Future<void> _loadLayouts(int generation) async {
    final loaded = <String, RemoteInputLayoutData>{};
    for (final (index, device) in _desktops.indexed) {
      final layout = await _loadLayout(device, index: index);
      if (generation != _refreshGeneration) return;
      if (layout != null) loaded[device.uid] = layout;
    }
    _layouts
      ..clear()
      ..addAll(loaded);
    final moved = _reattach();
    notifyListeners();
    await Future.wait(moved.map(_backend.saveLayout));
  }

  Future<RemoteInputLayoutData?> _loadLayout(
    DeviceData device, {
    required int index,
  }) async {
    final saved = await _backend.loadLayout(device.uid);
    if (saved != null) {
      final next = _normalized(saved, device);
      if (next != saved) await _backend.saveLayout(next);
      return next;
    }
    if (!_backend.isConnected(device.uid)) return null;
    final source = _local.primaryDisplay;
    final remote = _backend.remoteTopology(device.uid)?.virtualBounds;
    final width = remote?.width ?? 900;
    final height = remote?.height ?? 600;
    final rowStep = height + 20 > 620 ? height + 20 : 620;
    final layout = RemoteInputLayoutData(
      peerId: device.uid,
      peerName: device.name,
      x: index.isEven ? source.right : source.left - width,
      y: source.top + (index ~/ 2) * rowStep,
      width: width,
      height: height,
      // Waits among the candidates until it is put on the canvas.
      enabled: false,
      autoActivate: false,
      autoRole: RemoteInputAutoRole.source.name,
      layoutVersion: 3,
      layoutJson: '',
      edgeThresholdPx: 6,
      releaseHotkey: remoteInputReleaseHotkey,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _backend.saveLayout(layout);
    return layout;
  }

  /// What the screens are now, wherever it was left.
  RemoteInputLayoutData _normalized(
    RemoteInputLayoutData layout,
    DeviceData device,
  ) {
    final remote = _backend.remoteTopology(device.uid);
    if (remote == null || remote.isEmpty) return layout;
    final saved = layout.savedLayout;
    final placed = saved == null
        ? RemoteInputLayoutGeometry.placeSinkTopologyInBounds(
            sinkTopology: remote,
            bounds: RemoteInputScreenRect(
              x: layout.x,
              y: layout.y,
              width: layout.width,
              height: layout.height,
            ),
          )
        : RemoteInputLayoutGeometry.translatedSinkTopology(
            sinkTopology: remote,
            sinkOffsetX: saved.sinkOffsetX,
            sinkOffsetY: saved.sinkOffsetY,
          );
    final bounds = placed.bounds;
    if (layout.peerName == device.name &&
        layout.x == bounds.x &&
        layout.y == bounds.y &&
        layout.width == bounds.width &&
        layout.height == bounds.height) {
      return layout;
    }
    return layout.copyWith(
      peerName: device.name,
      x: bounds.x,
      y: bounds.y,
      width: bounds.width,
      height: bounds.height,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  // ---- Arranging ----

  /// Click toggles; a screen dropped or added comes selected.
  void select(String? peerId) {
    _selected = peerId == _selfId || peerId == _selected ? null : peerId;
    notifyListeners();
  }

  /// Puts a candidate on the canvas, right of everything, or lets it land at
  /// the given corner when it was dragged there.
  Future<void> add(String peerId) async {
    final layout = _layouts[peerId];
    if (layout == null) return;
    var left = _rootNode.bounds.right;
    var top = _rootNode.bounds.top;
    for (final device in _placedDevices) {
      final bounds = _nodeOf(device).bounds;
      left = math.max(left, bounds.right);
      top = math.min(top, bounds.top);
    }
    final snap = snapFor(peerId, left, top);
    await place(peerId, snap?.x ?? left, snap?.y ?? top);
  }

  Future<void> place(String peerId, int x, int y) async {
    final layout = _layouts[peerId];
    if (layout == null) return;
    final device = _deviceOf(peerId);
    final next = layout.copyWith(
      x: x,
      y: y,
      enabled: true,
      peerName: device?.name ?? layout.peerName,
      layoutVersion: 3,
      layoutJson: '',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _layouts[peerId] = next;
    _selected = peerId;
    final moved = _reattach();
    notifyListeners();
    await Future.wait([
      _backend.saveLayout(_layouts[peerId]!),
      for (final layout in moved)
        if (layout.peerId != peerId) _backend.saveLayout(layout),
    ]);
    await _syncLive();
  }

  Future<void> remove(String peerId) async {
    final layout = _layouts[peerId];
    if (layout == null) return;
    _layouts[peerId] = layout.copyWith(
      enabled: false,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _excluded = {
      for (final entry in _excluded.entries)
        if (entry.key != peerId) entry.key: entry.value,
    };
    if (_selected == peerId) _selected = null;
    final moved = _reattach();
    notifyListeners();
    await Future.wait([_layouts[peerId]!, ...moved].map(_backend.saveLayout));
    await _syncLive();
  }

  /// Arrow keys: a step, then the same landing rules as a drop.
  Future<void> nudge(String peerId, int dx, int dy) async {
    final device = _deviceOf(peerId);
    if (device == null || !_isPlaced(peerId)) return;
    final bounds = _nodeOf(device).bounds;
    final snap = snapFor(peerId, bounds.x + dx, bounds.y + dy);
    await place(peerId, snap?.x ?? bounds.x + dx, snap?.y ?? bounds.y + dy);
  }

  // ---- Sharing ----

  Future<void> openPermission() => _backend.requestAccessibility();

  /// Explicit, unlike sound: it takes over the pointer.
  Future<void> setOn(bool wanted) => _run(() async {
    if (wanted == _liveSource) return;
    if (!wanted) {
      _excluded = const {};
      _startFailure = null;
      notifyListeners();
      await _stop();
      return;
    }
    if (_backend.accessibilityDenied()) {
      // No effect, and the footer has to be free to say why.
      _selected = null;
      notifyListeners();
      return;
    }
    _starting = true;
    _startFailure = null;
    notifyListeners();
    // Screens of computers that are asleep: wake them, they join when back.
    unawaited(
      wakeDevices([
        for (final device in _placedDevices)
          if (!_backend.isConnected(device.uid)) device,
      ]),
    );
    try {
      await _start();
    } finally {
      _starting = false;
    }
  });

  /// Back to the same call with this one in it: it may have been trusted since.
  Future<void> retry(String peerId) => _run(() async {
    _startFailure = null;
    final plan = await _plan();
    _excluded = plan.excluded;
    if (!_workspace.isControllerLive) {
      if (plan.targets.isNotEmpty) await _begin(plan);
      return;
    }
    final updated = await _workspace.updateControllerWorkspaceRoutes(
      targets: plan.targets,
      workspaceRoutes: plan.routes,
      sendControlTo: _backend.sendControl,
      retryPeerIds: {peerId},
    );
    if (updated) {
      _sentPlan = _planSignature(plan);
    } else if (plan.targets.isNotEmpty) {
      await _begin(plan);
    }
  });

  Future<void> _start() async {
    final plan = await _plan();
    _excluded = plan.excluded;
    if (plan.targets.isEmpty) {
      // Nothing to start, and the screens now say why: show the first one's.
      if (plan.excluded.isNotEmpty) _selected = plan.excluded.keys.first;
      return;
    }
    await _begin(plan);
    final firstOut = plan.excluded.keys.firstOrNull;
    if (firstOut != null) _selected = firstOut;
  }

  Future<void> _begin(InputTargetPlan plan) async {
    try {
      await _workspace.startControllerWorkspace(
        sourcePeerId: await _backend.selfPeerId(),
        targets: plan.targets,
        sendControlTo: _backend.sendControl,
        workspaceRoutes: plan.routes,
      );
      _sentPlan = _planSignature(plan);
    } on Object catch (error) {
      _sentPlan = '';
      _startFailure = remoteInputFailureReasonFor(
        error,
        context: RemoteInputFailureContext.protocol,
      );
    }
  }

  Future<void> _stop() async {
    _sentPlan = '';
    if (_workspace.isControllerLive) {
      await _workspace.stopControllerWorkspace(
        sendControlTo: _backend.sendControl,
      );
    }
    if (_legacyLive) {
      final peerId = _runtime.state.peerId;
      await _runtime.stopSharing(
        sendControl: (control) => _backend.sendControl(peerId, control),
      );
    }
  }

  /// Stops being controlled by whoever is doing it.
  Future<void> stopBeingControlled() async {
    final peerId = controlledBy;
    if (peerId == null) return;
    await _runtime.stopSharing(
      sendControl: (control) => _backend.sendControl(peerId, control),
    );
  }

  Future<void> _syncLive() => _run(() async {
    if (!_workspace.isControllerLive) return;
    final plan = await _plan();
    _excluded = plan.excluded;
    if (plan.targets.isEmpty) {
      _sentPlan = '';
      await _workspace.stopControllerWorkspace(
        sendControlTo: _backend.sendControl,
      );
      return;
    }
    final signature = _planSignature(plan);
    if (signature == _sentPlan) return;
    final updated = await _workspace.updateControllerWorkspaceRoutes(
      targets: plan.targets,
      workspaceRoutes: plan.routes,
      sendControlTo: _backend.sendControl,
    );
    if (updated) {
      _sentPlan = signature;
    } else {
      await _begin(plan);
    }
  });

  /// What the workspace was last given. Each update restarts capture, which
  /// took a pointer that was on the other screen back to this one and left
  /// the two sides out of step: it crossed, came back, then would not cross.
  /// Every visit to the page and every rebuild of the device list updated it,
  /// with nothing changed. The old arrangement page only did on a change.
  String _sentPlan = '';

  static String _planSignature(InputTargetPlan plan) => jsonEncode({
    'targets': [
      for (final target in plan.targets)
        [
          target.peerId,
          target.peerName,
          target.host,
          target.port,
          target.layoutEdge.name,
          target.releaseHotkey,
          target.isMutuallyTrusted,
          target.remoteCanInject,
          target.path,
          target.sourceDisplayId,
          target.sourceEdge?.name,
          target.sourceSegmentStart,
          target.sourceSegmentEnd,
          target.sinkDisplayId,
          target.sinkEdge?.name,
          target.sinkSegmentStart,
          target.sinkSegmentEnd,
          [for (final mapping in target.edgeMappings) mapping.toJson()],
          [for (final mapping in target.injectionMappings) mapping.toJson()],
        ],
    ],
    'routes': [
      for (final route in plan.routes)
        [
          route.routeId,
          route.sourcePeerId,
          route.sinkPeerId,
          route.mapping.toJson(),
        ],
    ],
  });

  Future<InputTargetPlan> _plan() async {
    final selfId = await _backend.selfPeerId();
    _selfId = selfId;
    final members = <InputMember>[];
    for (final device in _placedDevices.toList(growable: false)) {
      final layout = _layouts[device.uid];
      if (layout == null) continue;
      members.add(
        InputMember(
          peerId: device.uid,
          name: device.name,
          host: device.host,
          port: device.port,
          releaseHotkey: layout.releaseHotkey,
          node: _nodeOf(device),
          connected: _backend.isConnected(device.uid),
          remoteCanInject: _backend.supportsGraph(device.uid),
          localTrusts: await _backend.localTrusts(device.uid),
          remoteTrusts: _backend.remoteTrusts(device.uid, selfId),
        ),
      );
    }
    return planInputTargets(
      sourcePeerId: selfId,
      root: _rootNode,
      members: members,
    );
  }

  Future<void> _run(Future<void> Function() change) {
    final next = _queue.then((_) async {
      try {
        await change();
      } on Object catch (error) {
        _startFailure = remoteInputFailureReasonFor(
          error,
          context: RemoteInputFailureContext.protocol,
        );
      } finally {
        notifyListeners();
      }
    });
    _queue = next;
    return next;
  }

  @override
  void dispose() {
    _workspace.removeListener(notifyListeners);
    _runtime.removeListener(notifyListeners);
    if (_attached > 0) {
      _backend.permissions?.removeListener(notifyListeners);
    }
    super.dispose();
  }
}
