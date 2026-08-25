import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_failure_reason.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_graph.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/theme/app_theme.dart';

enum _RemoteInputWorkspaceUiDiagnostic { startFailed }

class RemoteInputWorkspaceScreen extends StatefulWidget {
  const RemoteInputWorkspaceScreen({
    super.key,
    required this.initialDevices,
    this.preferredPeerId = '',
  });

  final List<DeviceData> initialDevices;
  final String preferredPeerId;

  @override
  State<RemoteInputWorkspaceScreen> createState() =>
      _RemoteInputWorkspaceScreenState();
}

class _RemoteInputWorkspaceScreenState extends State<RemoteInputWorkspaceScreen>
    with WidgetsBindingObserver {
  final WsSvrManager _socketManager = WsSvrManager();
  final RemoteInputWorkspaceCoordinator _workspaceCoordinator =
      RemoteInputWorkspaceCoordinator.shared;
  final RemoteInputCoordinator _legacyCoordinator =
      RemoteInputCoordinator.shared;
  final Map<String, RemoteInputLayoutData> _layouts =
      <String, RemoteInputLayoutData>{};
  final Set<String> _selectedPeerIds = <String>{};
  RemoteInputTopology _localTopology = RemoteInputTopology.fallback();
  String _localPeerId = '';
  double _canvasScale = 1;
  List<DeviceData> _devices = const <DeviceData>[];
  String _focusedPeerId = '';
  String _draggingPeerId = '';
  RemoteInputLayoutData? _dragStartLayout;
  Offset _dragWorkspaceOffset = Offset.zero;
  bool _loading = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _devices = widget.initialDevices;
    _focusedPeerId = widget.preferredPeerId;
    _workspaceCoordinator.addListener(_handleWorkspaceChanged);
    unawaited(_loadWorkspace());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _workspaceCoordinator.removeListener(_handleWorkspaceChanged);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    unawaited(_refreshLocalTopology());
  }

  void _handleWorkspaceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<RemoteInputTopology> _loadLocalTopology() async {
    try {
      final topology = await _legacyCoordinator.displayTopology();
      return topology.isNotEmpty ? topology : RemoteInputTopology.fallback();
    } catch (_) {
      return RemoteInputTopology.fallback();
    }
  }

  Future<void> _refreshLocalTopology() async {
    final topology = await _loadLocalTopology();
    if (!mounted) {
      return;
    }
    setState(() {
      _localTopology = topology;
    });
  }

  List<RemoteInputDisplay> get _localDisplays {
    if (_localTopology.isNotEmpty) {
      return _localTopology.displays;
    }
    return RemoteInputTopology.fallback().displays;
  }

  RemoteInputWorkspaceNode _localWorkspaceNode(String peerId) {
    return RemoteInputWorkspaceNode(
      peerId: peerId,
      topology: _localTopology,
      offsetX: 0,
      offsetY: 0,
      isController: true,
    );
  }

  RemoteInputWorkspaceNode? _workspaceNodeForDevice(
    DeviceData device, {
    RemoteInputLayoutData? layoutOverride,
  }) {
    final layout = layoutOverride ?? _layouts[device.uid];
    if (layout == null) {
      return null;
    }
    final topology =
        _socketManager.remoteDisplayTopologyFor(device.uid) ??
        RemoteInputTopology(
          platform: device.platform,
          displays: <RemoteInputDisplay>[
            RemoteInputDisplay(
              displayId: '${device.uid}-screen',
              name: device.name,
              x: 0,
              y: 0,
              width: layout.width,
              height: layout.height,
              scale: 1,
              isPrimary: true,
            ),
          ],
          updatedAt: 0,
        );
    final remoteBounds = topology.virtualBounds;
    return RemoteInputWorkspaceNode(
      peerId: device.uid,
      topology: topology,
      offsetX: layout.x - remoteBounds.x,
      offsetY: layout.y - remoteBounds.y,
    );
  }

  RemoteInputWorkspaceGraph _workspaceGraph({String? localPeerId}) {
    final controllerPeerId =
        localPeerId ??
        (_localPeerId.isEmpty ? '__local_controller__' : _localPeerId);
    final nodes = <RemoteInputWorkspaceNode>[
      _localWorkspaceNode(controllerPeerId),
    ];
    for (final device in _devices) {
      if (!_selectedPeerIds.contains(device.uid)) {
        continue;
      }
      final node = _workspaceNodeForDevice(device);
      if (node != null) {
        nodes.add(node);
      }
    }
    return RemoteInputWorkspaceGraph.build(nodes);
  }

  Set<String> _reachablePeerIds(RemoteInputWorkspaceGraph graph) {
    final controllerPeerId = _localPeerId.isEmpty
        ? '__local_controller__'
        : _localPeerId;
    final allowed = <String>{controllerPeerId};
    for (final device in _devices) {
      if (_selectedPeerIds.contains(device.uid) &&
          _socketManager.isConnectedTo(device.uid) &&
          _socketManager.supportsRemoteInputWorkspaceGraphFor(device.uid)) {
        allowed.add(device.uid);
      }
    }
    return graph.reachableFrom(controllerPeerId, allowedPeerIds: allowed);
  }

  String _displaySizeLabel(RemoteInputDisplay display) {
    return '${display.width} x ${display.height}';
  }

  String _displaySizeLabelForLayout(RemoteInputLayoutData layout) {
    return '${layout.width} x ${layout.height}';
  }

  Future<void> _loadWorkspace() async {
    final localTopology = await _loadLocalTopology();
    final self = await LocalSetting().instance();
    final connectedDevices = _socketManager.connectedRemoteInputDevices(
      preferredPeerId: widget.preferredPeerId,
    );
    final workspaceSnapshot = _workspaceCoordinator.snapshot;
    final devices = <DeviceData>[...connectedDevices];
    if (workspaceSnapshot.isControllerLive) {
      final knownIds = devices.map((device) => device.uid).toSet();
      for (final peerId in workspaceSnapshot.targets.keys) {
        if (knownIds.add(peerId)) {
          final stored = await LocalDatabase().fetchDevice(peerId);
          if (stored != null) {
            devices.add(stored);
          }
        }
      }
    }
    final connectedDeviceIds = connectedDevices
        .map((device) => device.uid)
        .toSet();
    final desiredTargetPeerIds = workspaceSnapshot.isControllerLive
        ? workspaceSnapshot.targets.keys.toList(growable: false)
        : const <String>[];
    final nextLayouts = <String, RemoteInputLayoutData>{};
    for (var index = 0; index < devices.length; index++) {
      final device = devices[index];
      nextLayouts[device.uid] = await _ensureLayout(
        device,
        index: index,
        localTopology: localTopology,
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _localTopology = localTopology;
      _localPeerId = self.uid;
      _devices = devices;
      _layouts
        ..clear()
        ..addAll(nextLayouts);
      if (desiredTargetPeerIds.isNotEmpty) {
        _selectedPeerIds
          ..clear()
          ..addAll(desiredTargetPeerIds);
      } else if (_selectedPeerIds.isEmpty && devices.isNotEmpty) {
        _selectedPeerIds.add(
          widget.preferredPeerId.isNotEmpty &&
                  devices.any((device) => device.uid == widget.preferredPeerId)
              ? widget.preferredPeerId
              : devices.first.uid,
        );
      }
      if (workspaceSnapshot.activePeerId.isNotEmpty &&
          _selectedPeerIds.contains(workspaceSnapshot.activePeerId)) {
        _focusedPeerId = workspaceSnapshot.activePeerId;
      } else if ((_focusedPeerId.isEmpty ||
              !connectedDeviceIds.contains(_focusedPeerId)) &&
          _selectedPeerIds.isNotEmpty) {
        _focusedPeerId = _selectedPeerIds.first;
      }
    });
    final layoutChanged = await _magnetizeSelectedLayouts();
    if (layoutChanged && workspaceSnapshot.isControllerLive) {
      await _restartControllerWorkspaceIfLive();
    }
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<RemoteInputLayoutData> _ensureLayout(
    DeviceData device, {
    required int index,
    required RemoteInputTopology localTopology,
  }) async {
    final saved = await LocalDatabase().fetchRemoteInputLayout(device.uid);
    if (saved != null) {
      var next = _reanchorLegacyDefaultLayout(
        saved,
        device: device,
        index: index,
        localTopology: localTopology,
      );
      next = _normalizeRemoteTopologyLayout(next, device: device);
      if (next != saved) {
        await LocalDatabase().upsertRemoteInputLayout(next);
      }
      return next;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final anchor = _defaultLayoutAnchor(
      device,
      index: index,
      localTopology: localTopology,
    );
    final layout = RemoteInputLayoutData(
      peerId: device.uid,
      peerName: device.name,
      x: anchor.x,
      y: anchor.y,
      width: anchor.width,
      height: anchor.height,
      enabled: true,
      autoActivate: false,
      autoRole: RemoteInputAutoRole.source.name,
      layoutVersion: 3,
      layoutJson: '',
      edgeThresholdPx: 6,
      releaseHotkey: 'ctrl+alt+esc',
      updatedAt: now,
    );
    await LocalDatabase().upsertRemoteInputLayout(layout);
    return layout;
  }

  RemoteInputLayoutData _reanchorLegacyDefaultLayout(
    RemoteInputLayoutData saved, {
    required DeviceData device,
    required int index,
    required RemoteInputTopology localTopology,
  }) {
    if (saved.layoutJson.isNotEmpty || saved.layoutVersion != 1) {
      return saved;
    }
    final legacyX = index.isEven ? 1000 : -900;
    final legacyY = (index ~/ 2) * 620;
    final isLegacyDefault =
        saved.x == legacyX &&
        saved.y == legacyY &&
        saved.width == 900 &&
        saved.height == 600;
    if (!isLegacyDefault) {
      return saved;
    }
    final anchor = _defaultLayoutAnchor(
      device,
      index: index,
      localTopology: localTopology,
    );
    if (saved.x == anchor.x &&
        saved.y == anchor.y &&
        saved.width == anchor.width &&
        saved.height == anchor.height) {
      return saved;
    }
    return saved.copyWith(
      peerName: device.name,
      x: anchor.x,
      y: anchor.y,
      width: anchor.width,
      height: anchor.height,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  RemoteInputLayoutData _normalizeRemoteTopologyLayout(
    RemoteInputLayoutData layout, {
    required DeviceData device,
  }) {
    final remote = _socketManager.remoteDisplayTopologyFor(device.uid);
    if (remote == null || remote.isEmpty) {
      return layout;
    }
    final savedLayout = layout.savedLayout;
    final placed = savedLayout == null
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
            sinkOffsetX: savedLayout.sinkOffsetX,
            sinkOffsetY: savedLayout.sinkOffsetY,
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

  _WorkspaceDefaultLayoutAnchor _defaultLayoutAnchor(
    DeviceData device, {
    required int index,
    required RemoteInputTopology localTopology,
  }) {
    final source = localTopology.primaryDisplay;
    final remote = _socketManager.remoteDisplayTopologyFor(device.uid);
    final remoteBounds = remote?.virtualBounds;
    final width = remoteBounds?.width ?? 900;
    final height = remoteBounds?.height ?? 600;
    final rowStep = height + 20 > 620 ? height + 20 : 620;
    return _WorkspaceDefaultLayoutAnchor(
      x: index.isEven ? source.right : source.left - width,
      y: source.top + (index ~/ 2) * rowStep,
      width: width,
      height: height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.whisperPalette;
    return Scaffold(
      backgroundColor: palette.surfaceCanvas,
      appBar: AppBar(
        title: Text(l10n.remoteInputWorkspaceTitle),
        leading: CupertinoNavigationBarBackButton(
          onPressed: () => Navigator.of(context).pop(),
          color: Theme.of(context).colorScheme.onSurface,
        ),
        actions: [
          TextButton.icon(
            onPressed: _starting ? null : _toggleWorkspace,
            icon: Icon(
              _workspaceCoordinator.snapshot.isControllerLive
                  ? Icons.stop_rounded
                  : Icons.play_arrow_rounded,
            ),
            label: Text(
              _workspaceCoordinator.snapshot.isControllerLive
                  ? l10n.remoteInputWorkspaceStop
                  : l10n.remoteInputWorkspaceStart,
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : Row(
                children: [
                  SizedBox(width: 260, child: _buildDevicePanel(l10n)),
                  Expanded(child: _buildCanvasPanel(l10n)),
                  SizedBox(width: 280, child: _buildDetailsPanel(l10n)),
                ],
              ),
      ),
      bottomNavigationBar: _buildStatusBar(l10n),
    );
  }

  Widget _buildDevicePanel(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final graph = _workspaceGraph();
    final reachablePeerIds = _reachablePeerIds(graph);
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(right: BorderSide(color: palette.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Text(
              l10n.remoteInputWorkspaceSelectTargets,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: _devices.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        l10n.remoteInputWorkspaceNoTargets,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: palette.textMuted),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      final selected = _selectedPeerIds.contains(device.uid);
                      final focused = _focusedPeerId == device.uid;
                      final snapshot =
                          _workspaceCoordinator.snapshot.targets[device.uid];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: focused
                              ? Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.08)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: CheckboxListTile(
                            value: selected,
                            onChanged: (value) {
                              unawaited(
                                _setDeviceSelected(
                                  device,
                                  selected: value == true,
                                ),
                              );
                            },
                            onFocusChange: (_) {},
                            title: Text(
                              device.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              _workspacePeerStatusLabel(
                                l10n,
                                device,
                                snapshot: snapshot,
                                graph: graph,
                                reachablePeerIds: reachablePeerIds,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                            secondary: IconButton(
                              tooltip: l10n.remoteInputWorkspaceFocusTarget,
                              onPressed: () {
                                setState(() {
                                  _focusedPeerId = device.uid;
                                });
                              },
                              icon: const Icon(
                                Icons.center_focus_strong_rounded,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasPanel(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final selectedDevices = _devices
        .where((device) => _selectedPeerIds.contains(device.uid))
        .toList(growable: false);
    final graph = _workspaceGraph();
    final reachablePeerIds = _reachablePeerIds(graph);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.remoteInputWorkspaceCanvasTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (graph.conflictingPeerIds.isNotEmpty)
                Text(
                  l10n.remoteInputWorkspaceConflict,
                  style: const TextStyle(color: Colors.orange),
                ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                border: Border.all(color: palette.borderSubtle),
                borderRadius: BorderRadius.circular(16),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return _buildScreenCanvas(
                      constraints,
                      selectedDevices: selectedDevices,
                      conflicts: graph.conflictingPeerIds,
                      reachablePeerIds: reachablePeerIds,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildScreenCanvas(
    BoxConstraints constraints, {
    required List<DeviceData> selectedDevices,
    required Set<String> conflicts,
    required Set<String> reachablePeerIds,
  }) {
    final localDisplays = _localDisplays;
    final rects = <RemoteInputScreenRect>[
      ...localDisplays.map((display) => display.rect),
    ];
    for (final device in selectedDevices) {
      final layout = _layouts[device.uid];
      if (layout != null) {
        rects.addAll(
          _peerDisplaysForLayout(device, layout).map((display) => display.rect),
        );
      }
    }
    final bounds = _boundsFor(rects);
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final availableWidth = math.max(1.0, width - 48);
    final availableHeight = math.max(1.0, height - 48);
    final scale = math
        .min(availableWidth / bounds.width, availableHeight / bounds.height)
        .clamp(0.001, 1.0);
    _canvasScale = scale;
    final offsetX = (width - bounds.width * scale) / 2 - bounds.left * scale;
    final offsetY = (height - bounds.height * scale) / 2 - bounds.top * scale;

    Offset toCanvas(int x, int y) {
      return Offset(offsetX + x * scale, offsetY + y * scale);
    }

    Size toSize(int w, int h) {
      return Size(math.max(1.0, w * scale), math.max(1.0, h * scale));
    }

    return Stack(
      children: [
        for (final display in localDisplays)
          Positioned(
            left: toCanvas(display.x, display.y).dx,
            top: toCanvas(display.x, display.y).dy,
            width: toSize(display.width, display.height).width,
            height: toSize(display.width, display.height).height,
            child: _ScreenBlock(
              title: display.name.isEmpty
                  ? AppLocalizations.of(context)!.remoteInputLocalScreen
                  : display.name,
              subtitle: _displaySizeLabel(display),
              selected: false,
              conflict: false,
              local: true,
              reachable: true,
            ),
          ),
        for (final device in selectedDevices)
          if (_layouts[device.uid] != null)
            _buildPeerScreenBlock(
              device,
              layout: _layouts[device.uid]!,
              toCanvas: toCanvas,
              toSize: toSize,
              scale: scale,
              conflict: conflicts.contains(device.uid),
              reachable: reachablePeerIds.contains(device.uid),
            ),
      ],
    );
  }

  List<RemoteInputDisplay> _peerDisplaysForLayout(
    DeviceData device,
    RemoteInputLayoutData layout,
  ) {
    final remote = _socketManager.remoteDisplayTopologyFor(device.uid);
    if (remote != null && remote.isNotEmpty) {
      return RemoteInputLayoutGeometry.placeSinkTopologyInBounds(
        sinkTopology: remote,
        bounds: RemoteInputScreenRect(
          x: layout.x,
          y: layout.y,
          width: layout.width,
          height: layout.height,
        ),
      ).displays;
    }
    return [
      RemoteInputDisplay(
        displayId: '${device.uid}-screen',
        name: device.name,
        x: layout.x,
        y: layout.y,
        width: layout.width,
        height: layout.height,
        scale: 1,
        isPrimary: true,
      ),
    ];
  }

  RemoteInputScreenRect _peerLayoutBounds(
    DeviceData device,
    RemoteInputLayoutData layout,
  ) {
    return _boundsFor(
      _peerDisplaysForLayout(
        device,
        layout,
      ).map((display) => display.rect).toList(growable: false),
    );
  }

  Widget _buildPeerScreenBlock(
    DeviceData device, {
    required RemoteInputLayoutData layout,
    required Offset Function(int x, int y) toCanvas,
    required Size Function(int w, int h) toSize,
    required double scale,
    required bool conflict,
    required bool reachable,
  }) {
    final displays = _peerDisplaysForLayout(device, layout);
    final bounds = _peerLayoutBounds(device, layout);
    final offset = toCanvas(bounds.x, bounds.y);
    final groupSize = toSize(bounds.width, bounds.height);
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      width: groupSize.width,
      height: groupSize.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          unawaited(_setDeviceSelected(device, selected: true));
        },
        onPanStart: (_) {
          setState(() {
            _focusedPeerId = device.uid;
            _selectedPeerIds.add(device.uid);
            _draggingPeerId = device.uid;
            _dragStartLayout = _layouts[device.uid] ?? layout;
            _dragWorkspaceOffset = Offset.zero;
          });
        },
        onPanUpdate: (details) {
          _updateDraggedLayout(device, delta: details.delta, scale: scale);
        },
        onPanEnd: (_) {
          _clearDragState();
          unawaited(_snapAndSaveLayout(device));
        },
        onPanCancel: () => _cancelDraggedLayout(device),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final display in displays)
              Positioned(
                left: (display.left - bounds.left) * scale,
                top: (display.top - bounds.top) * scale,
                width: math.max(1.0, display.width * scale),
                height: math.max(1.0, display.height * scale),
                child: _ScreenBlock(
                  title: display.name.isEmpty ? device.name : display.name,
                  subtitle: _displaySizeLabel(display),
                  selected: _focusedPeerId == device.uid,
                  conflict: conflict,
                  local: false,
                  reachable: reachable,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsPanel(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final focused = _devices
        .where((device) => device.uid == _focusedPeerId)
        .firstOrNull;
    final snapshot = focused == null
        ? null
        : _workspaceCoordinator.snapshot.targets[focused.uid];
    final graph = _workspaceGraph();
    final reachablePeerIds = _reachablePeerIds(graph);
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(left: BorderSide(color: palette.borderSubtle)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: focused == null
            ? Text(
                l10n.remoteInputWorkspaceNoTargets,
                style: TextStyle(color: palette.textMuted),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.remoteInputWorkspaceDetailsTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    focused.name,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${focused.host}:${focused.port}',
                    style: TextStyle(color: palette.textMuted),
                  ),
                  const SizedBox(height: 18),
                  _DetailRow(
                    label: l10n.remoteInputLayoutTitle,
                    value: _focusedLayoutSummary(_layouts[focused.uid]),
                  ),
                  _DetailRow(
                    label: l10n.remoteInputWorkspaceState,
                    value: _workspacePeerStatusLabel(
                      l10n,
                      focused,
                      snapshot: snapshot,
                      graph: graph,
                      reachablePeerIds: reachablePeerIds,
                    ),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: () {
                      unawaited(
                        _setDeviceSelected(
                          focused,
                          selected: !_selectedPeerIds.contains(focused.uid),
                        ),
                      );
                    },
                    icon: Icon(
                      _selectedPeerIds.contains(focused.uid)
                          ? Icons.visibility_off_rounded
                          : Icons.add_rounded,
                    ),
                    label: Text(
                      _selectedPeerIds.contains(focused.uid)
                          ? l10n.remoteInputWorkspaceRemoveTarget
                          : l10n.remoteInputWorkspaceAddTarget,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildStatusBar(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final snapshot = _workspaceCoordinator.snapshot;
    final status = switch (snapshot.status) {
      RemoteInputWorkspaceStatus.offering =>
        l10n.remoteInputWorkspaceStatusOffering,
      RemoteInputWorkspaceStatus.armed => l10n.remoteInputWorkspaceStatusArmed,
      RemoteInputWorkspaceStatus.active =>
        l10n.remoteInputWorkspaceStatusActive(_activeTargetName()),
      RemoteInputWorkspaceStatus.failed =>
        l10n.remoteInputWorkspaceStatusFailed(
          _failureDetail(l10n, snapshot.errorMessage),
        ),
      RemoteInputWorkspaceStatus.idle => l10n.remoteInputWorkspaceStatusIdle,
    };
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(top: BorderSide(color: palette.borderSubtle)),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: palette.textMuted),
      ),
    );
  }

  Future<void> _toggleWorkspace() async {
    final l10n = AppLocalizations.of(context)!;
    if (_workspaceCoordinator.snapshot.isControllerLive) {
      await _workspaceCoordinator.stopControllerWorkspace(
        sendControlTo: _socketManager.sendRemoteInputControlTo,
      );
      showAppToast(l10n.remoteInputStopped);
      return;
    }
    if (_selectedPeerIds.isEmpty) {
      showAppToast(l10n.remoteInputWorkspaceNoTargets);
      return;
    }
    final legacyState = _legacyCoordinator.state;
    if (legacyState.status != RemoteInputRuntimeStatus.idle &&
        legacyState.status != RemoteInputRuntimeStatus.failed) {
      showAppToast(l10n.remoteInputStopCurrentFirst);
      return;
    }
    if (!isDesktop() || !supportsNativeRemoteInput()) {
      showAppToast(l10n.remoteInputLocalUnsupported);
      return;
    }
    setState(() {
      _starting = true;
    });
    try {
      final self = await LocalSetting().instance();
      _localPeerId = self.uid;
      final graph = _workspaceGraph(localPeerId: self.uid);
      final reachablePeerIds = _reachablePeerIds(graph);
      final activeGraph = RemoteInputWorkspaceGraph.build(
        graph.nodes.values.where(
          (node) => reachablePeerIds.contains(node.peerId),
        ),
      );
      final targets = <RemoteInputWorkspaceTargetRequest>[];
      for (final device in _devices) {
        if (!_selectedPeerIds.contains(device.uid) ||
            !reachablePeerIds.contains(device.uid)) {
          continue;
        }
        final request = await _targetRequestForDevice(
          device,
          sourcePeerId: self.uid,
          graph: activeGraph,
        );
        if (request != null) {
          targets.add(request);
        }
      }
      if (targets.isEmpty) {
        showAppToast(l10n.remoteInputLayoutRequired);
        return;
      }
      await _workspaceCoordinator.startControllerWorkspace(
        sourcePeerId: self.uid,
        targets: targets,
        sendControlTo: _socketManager.sendRemoteInputControlTo,
        workspaceRoutes: activeGraph.routes,
      );
      showAppToast(l10n.remoteInputEnabledMoveToEdge);
    } catch (error) {
      final reason = remoteInputFailureReasonFor(
        error,
        context: RemoteInputFailureContext.protocol,
      );
      privacyLog
          .event(PrivacyEvent.remoteInputDiagnostic, <PrivacyField, Object>{
            PrivacyField.kind: _RemoteInputWorkspaceUiDiagnostic.startFailed,
            PrivacyField.reason: reason,
            PrivacyField.errorType: privacyLog.errorType(error),
          });
      showAppToast(l10n.remoteInputFailed(_failureDetail(l10n, reason.name)));
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
        });
      }
    }
  }

  Future<RemoteInputWorkspaceTargetRequest?> _targetRequestForDevice(
    DeviceData device, {
    required String sourcePeerId,
    required RemoteInputWorkspaceGraph graph,
  }) async {
    final layout =
        _layouts[device.uid] ??
        await _ensureLayout(device, index: 0, localTopology: _localTopology);
    final storedDevice = await LocalDatabase().fetchDevice(device.uid);
    final localTrustsRemote = storedDevice?.auth == true;
    final remoteTrustsLocal = _socketManager.remotePeerTrustsPeer(
      device.uid,
      sourcePeerId,
    );
    final incomingRoutes = graph.routes
        .where((route) => route.sinkPeerId == device.uid)
        .toList(growable: false);
    if (incomingRoutes.isEmpty) {
      return null;
    }
    final captureMappings = graph.routes
        .where(
          (route) =>
              route.sourcePeerId == sourcePeerId &&
              route.sinkPeerId == device.uid,
        )
        .map((route) => route.mapping)
        .toList(growable: false);
    final injectionMappings = incomingRoutes
        .map((route) => route.mapping)
        .toList(growable: false);
    final primary = incomingRoutes.first.mapping;
    return RemoteInputWorkspaceTargetRequest(
      peerId: device.uid,
      peerName: device.name,
      host: device.host,
      port: device.port,
      layoutEdge: primary.sourceEdge,
      releaseHotkey: layout.releaseHotkey,
      isMutuallyTrusted: localTrustsRemote && remoteTrustsLocal,
      remoteCanInject: _socketManager.supportsRemoteInputWorkspaceGraphFor(
        device.uid,
      ),
      sourceDisplayId: primary.sourceDisplayId,
      sourceEdge: primary.sourceEdge,
      sourceSegmentStart: primary.sourceSegmentStart,
      sourceSegmentEnd: primary.sourceSegmentEnd,
      sinkDisplayId: primary.sinkDisplayId,
      sinkEdge: primary.sinkEdge,
      sinkSegmentStart: primary.sinkSegmentStart,
      sinkSegmentEnd: primary.sinkSegmentEnd,
      edgeMappings: captureMappings,
      injectionMappings: injectionMappings,
    );
  }

  Future<void> _setDeviceSelected(
    DeviceData device, {
    required bool selected,
  }) async {
    if (!mounted) {
      return;
    }
    final changed = selected
        ? _selectedPeerIds.add(device.uid)
        : _selectedPeerIds.remove(device.uid);
    setState(() {
      if (selected) {
        _focusedPeerId = device.uid;
      }
    });
    if (!changed) {
      return;
    }
    if (selected) {
      await _snapAndSaveLayout(device);
    } else {
      await _restartControllerWorkspaceIfLive();
    }
  }

  void _updateDraggedLayout(
    DeviceData device, {
    required Offset delta,
    required double scale,
  }) {
    final origin = _draggingPeerId == device.uid ? _dragStartLayout : null;
    if (origin == null || scale <= 0) {
      return;
    }
    _dragWorkspaceOffset += Offset(delta.dx / scale, delta.dy / scale);
    final raw = origin.copyWith(
      x: origin.x + _dragWorkspaceOffset.dx.round(),
      y: origin.y + _dragWorkspaceOffset.dy.round(),
    );
    final moving = _workspaceNodeForDevice(device, layoutOverride: raw);
    if (moving == null) {
      return;
    }
    final controllerPeerId = _localPeerId.isEmpty
        ? '__local_controller__'
        : _localPeerId;
    final root = _localWorkspaceNode(controllerPeerId);
    final otherNodes = <RemoteInputWorkspaceNode>[root];
    for (final other in _devices) {
      if (other.uid == device.uid || !_selectedPeerIds.contains(other.uid)) {
        continue;
      }
      final node = _workspaceNodeForDevice(other);
      if (node != null) {
        otherNodes.add(node);
      }
    }
    final otherGraph = RemoteInputWorkspaceGraph.build(otherNodes);
    final reachable = otherGraph.reachableFrom(controllerPeerId);
    final anchors = otherNodes.where((node) => reachable.contains(node.peerId));
    final snap = RemoteInputWorkspaceSnapper.snap(
      moving: moving,
      anchors: anchors,
      canvasScale: _canvasScale,
      minimumSharedEdge: RemoteInputWorkspaceMagnetizer.minimumSharedEdge,
    );
    final snapped = (snap?.node ?? moving).bounds;
    setState(() {
      _focusedPeerId = device.uid;
      _layouts[device.uid] = raw.copyWith(
        x: snapped.x,
        y: snapped.y,
        width: snapped.width,
        height: snapped.height,
      );
    });
  }

  void _clearDragState() {
    _draggingPeerId = '';
    _dragStartLayout = null;
    _dragWorkspaceOffset = Offset.zero;
  }

  void _cancelDraggedLayout(DeviceData device) {
    final origin = _draggingPeerId == device.uid ? _dragStartLayout : null;
    if (origin != null && mounted) {
      setState(() {
        _layouts[device.uid] = origin;
      });
    }
    _clearDragState();
  }

  Future<bool> _magnetizeSelectedLayouts({
    String preferredPeerId = '',
    bool persistPreferred = false,
  }) async {
    final controllerPeerId = _localPeerId.isEmpty
        ? '__local_controller__'
        : _localPeerId;
    final root = _localWorkspaceNode(controllerPeerId);
    final devicesByPeerId = <String, DeviceData>{
      for (final device in _devices) device.uid: device,
    };
    final nodes = <RemoteInputWorkspaceNode>[];
    for (final peerId in _selectedPeerIds) {
      final device = devicesByPeerId[peerId];
      if (device == null) {
        continue;
      }
      final node = _workspaceNodeForDevice(device);
      if (node != null) {
        nodes.add(node);
      }
    }
    if (nodes.isEmpty) {
      return false;
    }
    final connected = RemoteInputWorkspaceMagnetizer.connectAll(
      root: root,
      nodes: nodes,
      canvasScale: _canvasScale,
      preferredPeerId: preferredPeerId,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, RemoteInputLayoutData>{};
    for (final node in connected.values) {
      if (node.isController) {
        continue;
      }
      final current = _layouts[node.peerId];
      final device = devicesByPeerId[node.peerId];
      if (current == null || device == null) {
        continue;
      }
      final bounds = node.bounds;
      final geometryChanged =
          current.x != bounds.x ||
          current.y != bounds.y ||
          current.width != bounds.width ||
          current.height != bounds.height;
      if (!geometryChanged &&
          !(persistPreferred && node.peerId == preferredPeerId)) {
        continue;
      }
      updates[node.peerId] = current.copyWith(
        peerName: device.name,
        x: bounds.x,
        y: bounds.y,
        width: bounds.width,
        height: bounds.height,
        layoutVersion: 3,
        layoutJson: '',
        updatedAt: now,
      );
    }
    if (updates.isEmpty) {
      return false;
    }
    if (mounted) {
      setState(() {
        _layouts.addAll(updates);
      });
    }
    await Future.wait(
      updates.values.map(LocalDatabase().upsertRemoteInputLayout),
    );
    return true;
  }

  Future<void> _snapAndSaveLayout(DeviceData device) async {
    await _magnetizeSelectedLayouts(
      preferredPeerId: device.uid,
      persistPreferred: true,
    );
    await _restartControllerWorkspaceIfLive();
  }

  Future<void> _restartControllerWorkspaceIfLive() async {
    final snapshot = _workspaceCoordinator.snapshot;
    if (!snapshot.isControllerLive) {
      return;
    }
    final sourcePeerId = snapshot.sourcePeerId.isNotEmpty
        ? snapshot.sourcePeerId
        : (await LocalSetting().instance()).uid;
    _localPeerId = sourcePeerId;
    final graph = _workspaceGraph(localPeerId: sourcePeerId);
    final reachablePeerIds = _reachablePeerIds(graph);
    final activeGraph = RemoteInputWorkspaceGraph.build(
      graph.nodes.values.where(
        (node) => reachablePeerIds.contains(node.peerId),
      ),
    );
    final targets = <RemoteInputWorkspaceTargetRequest>[];
    for (final device in _devices) {
      if (!reachablePeerIds.contains(device.uid)) {
        continue;
      }
      final request = await _targetRequestForDevice(
        device,
        sourcePeerId: sourcePeerId,
        graph: activeGraph,
      );
      if (request != null) {
        targets.add(request);
      }
    }
    if (targets.isEmpty) {
      await _workspaceCoordinator.stopControllerWorkspace(
        sendControlTo: _socketManager.sendRemoteInputControlTo,
      );
      return;
    }
    final updated = await _workspaceCoordinator.updateControllerWorkspaceRoutes(
      targets: targets,
      workspaceRoutes: activeGraph.routes,
      sendControlTo: _socketManager.sendRemoteInputControlTo,
    );
    if (updated) {
      return;
    }
    await _workspaceCoordinator.startControllerWorkspace(
      sourcePeerId: sourcePeerId,
      targets: targets,
      sendControlTo: _socketManager.sendRemoteInputControlTo,
      workspaceRoutes: activeGraph.routes,
    );
  }

  RemoteInputScreenRect _boundsFor(List<RemoteInputScreenRect> rects) {
    var left = rects.first.left;
    var top = rects.first.top;
    var right = rects.first.right;
    var bottom = rects.first.bottom;
    for (final rect in rects.skip(1)) {
      left = math.min(left, rect.left);
      top = math.min(top, rect.top);
      right = math.max(right, rect.right);
      bottom = math.max(bottom, rect.bottom);
    }
    return RemoteInputScreenRect(
      x: left,
      y: top,
      width: math.max(1, right - left),
      height: math.max(1, bottom - top),
    );
  }

  String _peerScreenSubtitle(RemoteInputLayoutData layout) {
    return _displaySizeLabelForLayout(layout);
  }

  String _focusedLayoutSummary(RemoteInputLayoutData? layout) {
    if (layout == null) {
      return AppLocalizations.of(context)!.remoteInputEdgeNotAdjacent;
    }
    return _peerScreenSubtitle(layout);
  }

  String _targetStatusLabel(
    AppLocalizations l10n,
    RemoteInputWorkspaceTargetSnapshot? snapshot,
  ) {
    if (snapshot == null) {
      return l10n.remoteInputWorkspaceTargetIdle;
    }
    switch (snapshot.status) {
      case RemoteInputWorkspaceTargetStatus.offering:
        return l10n.remoteInputWorkspaceStatusOffering;
      case RemoteInputWorkspaceTargetStatus.connected:
        return l10n.remoteInputWorkspaceStatusArmed;
      case RemoteInputWorkspaceTargetStatus.failed:
        return l10n.remoteInputWorkspaceStatusFailed(
          _failureDetail(l10n, snapshot.errorMessage),
        );
      case RemoteInputWorkspaceTargetStatus.stopped:
        return l10n.remoteInputWorkspaceStatusIdle;
    }
  }

  String _workspacePeerStatusLabel(
    AppLocalizations l10n,
    DeviceData device, {
    required RemoteInputWorkspaceTargetSnapshot? snapshot,
    required RemoteInputWorkspaceGraph graph,
    required Set<String> reachablePeerIds,
  }) {
    if (_selectedPeerIds.contains(device.uid)) {
      if (!_socketManager.isConnectedTo(device.uid)) {
        return l10n.remoteInputWorkspaceDisconnected;
      }
      if (!_socketManager.supportsRemoteInputWorkspaceGraphFor(device.uid)) {
        return l10n.remoteInputWorkspaceUnsupported;
      }
      if (graph.conflictingPeerIds.contains(device.uid)) {
        return l10n.remoteInputWorkspaceConflict;
      }
      if (!reachablePeerIds.contains(device.uid)) {
        return l10n.remoteInputWorkspaceDisconnected;
      }
      if (snapshot == null) {
        return l10n.remoteInputWorkspaceReachable;
      }
    }
    return _targetStatusLabel(l10n, snapshot);
  }

  String _failureDetail(AppLocalizations l10n, String reason) {
    return switch (reason) {
      'trustRequired' => l10n.remoteInputRequiresMutualTrust,
      'unsupported' => l10n.remoteInputLocalUnsupported,
      'busy' => l10n.remoteInputStopCurrentFirst,
      _ => l10n.connectFailed,
    };
  }

  String _activeTargetName() {
    final activePeerId = _workspaceCoordinator.snapshot.activePeerId;
    for (final device in _devices) {
      if (device.uid == activePeerId) {
        return device.name;
      }
    }
    return activePeerId;
  }
}

class _WorkspaceDefaultLayoutAnchor {
  const _WorkspaceDefaultLayoutAnchor({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

class _ScreenBlock extends StatelessWidget {
  const _ScreenBlock({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.conflict,
    required this.local,
    required this.reachable,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final bool conflict;
  final bool local;
  final bool reachable;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final borderColor = conflict
        ? Colors.orange
        : selected
        ? colorScheme.primary
        : palette.borderSubtle;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: reachable || local ? 1 : 0.5,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: local
              ? colorScheme.primary.withValues(alpha: 0.08)
              : palette.surfaceMuted,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: selected ? 2 : 1),
          boxShadow: [
            if (selected)
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: 0.18),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showTitle =
                constraints.maxWidth >= 44 && constraints.maxHeight >= 22;
            final showSubtitle =
                constraints.maxWidth >= 84 && constraints.maxHeight >= 48;
            final horizontalPadding = constraints.maxWidth >= 96 ? 12.0 : 4.0;
            final verticalPadding = constraints.maxHeight >= 64 ? 10.0 : 2.0;
            if (!showTitle) {
              return const SizedBox.expand();
            }
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  if (showSubtitle) ...[
                    const SizedBox(height: 4),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: palette.textMuted)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
