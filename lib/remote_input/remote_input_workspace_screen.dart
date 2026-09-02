import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

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
import 'package:whisper/widget/glass_dialog.dart';

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
  static const double _detailsPanelBreakpoint = 1240;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
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

  DeviceData? get _focusedDevice =>
      _devices.where((device) => device.uid == _focusedPeerId).firstOrNull;

  bool get _usesDetailsDrawer =>
      MediaQuery.sizeOf(context).width < _detailsPanelBreakpoint;

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
    final connectedDeviceIds = connectedDevices
        .map((device) => device.uid)
        .toSet();
    final desiredTargetPeerIds = workspaceSnapshot.isControllerLive
        ? workspaceSnapshot.targets.keys
              .where(connectedDeviceIds.contains)
              .toList(growable: false)
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
    final colors = Theme.of(context).colorScheme;
    final status = _workspaceStatusPresentation(l10n);
    final focused = _focusedDevice;
    final useDetailsDrawer = _usesDetailsDrawer;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: palette.surfaceCanvas,
      appBar: AppBar(
        toolbarHeight: 68,
        backgroundColor: palette.surfaceCanvas,
        titleSpacing: 4,
        title: Row(
          children: [
            Text(l10n.remoteInputWorkspaceTitle),
            if (MediaQuery.sizeOf(context).width >= 820) ...[
              const SizedBox(width: 14),
              Flexible(child: _WorkspaceStatusChip(status: status)),
            ],
          ],
        ),
        leading: CupertinoNavigationBarBackButton(
          onPressed: () => Navigator.of(context).pop(),
          color: colors.onSurface,
        ),
        actions: [
          if (useDetailsDrawer && focused != null)
            IconButton(
              tooltip: l10n.remoteInputWorkspaceDetailsTitle,
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              icon: const Icon(Icons.info_outline_rounded),
            ),
          _buildWorkspaceToggleButton(l10n),
          const SizedBox(width: 16),
        ],
      ),
      endDrawer: useDetailsDrawer && focused != null
          ? Drawer(
              width: math.min(360, MediaQuery.sizeOf(context).width * 0.88),
              elevation: 0,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  child: _buildDetailsPanel(l10n),
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : LayoutBuilder(
                builder: (context, constraints) {
                  final showDetails =
                      constraints.maxWidth >= _detailsPanelBreakpoint &&
                      focused != null;
                  final devicePanelWidth = math.min(
                    252.0,
                    math.max(210.0, constraints.maxWidth * 0.19),
                  );
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: devicePanelWidth,
                          child: _buildDevicePanel(l10n),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: _buildCanvasPanel(l10n)),
                        if (showDetails) ...[
                          const SizedBox(width: 12),
                          SizedBox(width: 288, child: _buildDetailsPanel(l10n)),
                        ],
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildWorkspaceToggleButton(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final isLive = _workspaceCoordinator.snapshot.isControllerLive;
    final icon = _starting
        ? const SizedBox.square(
            dimension: 16,
            child: CupertinoActivityIndicator(radius: 8),
          )
        : Icon(isLive ? Icons.stop_rounded : Icons.play_arrow_rounded);
    final label = Text(
      isLive ? l10n.remoteInputWorkspaceStop : l10n.remoteInputWorkspaceStart,
    );
    if (isLive) {
      return OutlinedButton.icon(
        onPressed: _starting ? null : _toggleWorkspace,
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.danger,
          backgroundColor: palette.surfaceMuted.withValues(alpha: 0.42),
          side: BorderSide(color: palette.borderSubtle),
          shape: const StadiumBorder(),
        ),
        icon: icon,
        label: label,
      );
    }
    return FilledButton.icon(
      onPressed: _starting ? null : _toggleWorkspace,
      style: FilledButton.styleFrom(shape: const StadiumBorder()),
      icon: icon,
      label: label,
    );
  }

  Widget _buildDevicePanel(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final colors = Theme.of(context).colorScheme;
    final graph = _workspaceGraph();
    final reachablePeerIds = _reachablePeerIds(graph);
    return WhisperGlassSurface(
      borderRadius: BorderRadius.circular(20),
      shadowOffset: const Offset(0, 8),
      showTopHighlight: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Row(
              children: [
                Icon(
                  Icons.devices_other_rounded,
                  size: 19,
                  color: colors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.remoteInputWorkspaceSelectTargets,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_devices.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: palette.surfaceMuted.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${_selectedPeerIds.length}/${_devices.length}',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _devices.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: palette.surfaceMuted.withValues(
                                alpha: 0.58,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.desktop_windows_outlined,
                              color: palette.textMuted,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            l10n.remoteInputWorkspaceNoTargets,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            l10n.remoteInputWorkspaceNoTargetsHint,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      final selected = _selectedPeerIds.contains(device.uid);
                      final focused = _focusedPeerId == device.uid;
                      final snapshot =
                          _workspaceCoordinator.snapshot.targets[device.uid];
                      final status = _workspacePeerStatusLabel(
                        l10n,
                        device,
                        snapshot: snapshot,
                        graph: graph,
                        reachablePeerIds: reachablePeerIds,
                      );
                      final statusColor = _peerStatusColor(
                        device,
                        graph: graph,
                        reachablePeerIds: reachablePeerIds,
                      );
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: focused
                              ? palette.surfaceMuted.withValues(alpha: 0.50)
                              : Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: focused
                                  ? colors.primary.withValues(alpha: 0.28)
                                  : palette.borderSubtle,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _focusDevice(device),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: selected,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (value) {
                                      unawaited(
                                        _setDeviceSelected(
                                          device,
                                          selected: value == true,
                                        ),
                                      );
                                    },
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          device.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Container(
                                              width: 7,
                                              height: 7,
                                              decoration: BoxDecoration(
                                                color: statusColor,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                status,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: palette.textMuted,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip:
                                        l10n.remoteInputWorkspaceFocusTarget,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        _focusDevice(device, openDetails: true),
                                    icon: Icon(
                                      Icons.info_outline_rounded,
                                      size: 19,
                                      color: focused
                                          ? colors.primary
                                          : palette.textMuted,
                                    ),
                                  ),
                                ],
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

  void _focusDevice(DeviceData device, {bool openDetails = false}) {
    setState(() {
      _focusedPeerId = device.uid;
    });
    if (openDetails && _usesDetailsDrawer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scaffoldKey.currentState?.openEndDrawer();
        }
      });
    }
  }

  Color _peerStatusColor(
    DeviceData device, {
    required RemoteInputWorkspaceGraph graph,
    required Set<String> reachablePeerIds,
  }) {
    final palette = context.whisperPalette;
    if (!_socketManager.isConnectedTo(device.uid) ||
        !reachablePeerIds.contains(device.uid)) {
      return palette.textMuted;
    }
    if (!_socketManager.supportsRemoteInputWorkspaceGraphFor(device.uid) ||
        graph.conflictingPeerIds.contains(device.uid)) {
      return palette.warning;
    }
    return palette.trusted;
  }

  Widget _buildCanvasPanel(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final colors = Theme.of(context).colorScheme;
    final selectedDevices = _devices
        .where((device) => _selectedPeerIds.contains(device.uid))
        .toList(growable: false);
    final graph = _workspaceGraph();
    final reachablePeerIds = _reachablePeerIds(graph);
    return WhisperGlassSurface(
      borderRadius: BorderRadius.circular(20),
      shadowOffset: const Offset(0, 8),
      showTopHighlight: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted.withValues(alpha: 0.58),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.space_dashboard_outlined,
                    size: 19,
                    color: palette.textMuted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.remoteInputWorkspaceCanvasTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.remoteInputWorkspaceCanvasHint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (graph.conflictingPeerIds.isNotEmpty)
                  _WorkspaceNoticeChip(
                    icon: Icons.warning_amber_rounded,
                    label: l10n.remoteInputWorkspaceConflict,
                    color: palette.warning,
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.borderSubtle),
          Expanded(
            child: ColoredBox(
              color: palette.surfaceCanvas.withValues(alpha: 0.56),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _WorkspaceGridPainter(
                        color: palette.borderSubtle.withValues(alpha: 0.62),
                      ),
                    ),
                  ),
                  Positioned.fill(
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
                  if (_devices.isNotEmpty && selectedDevices.isEmpty)
                    Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: _WorkspaceNoticeChip(
                          icon: Icons.touch_app_outlined,
                          label: l10n.remoteInputWorkspaceSelectTargetHint,
                          color: colors.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
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
              badge: AppLocalizations.of(
                context,
              )!.remoteInputWorkspaceLocalBadge,
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
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
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
                    badge: AppLocalizations.of(
                      context,
                    )!.remoteInputWorkspaceRemoteBadge,
                    selected: _focusedPeerId == device.uid,
                    conflict: conflict,
                    local: false,
                    reachable: reachable,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailsPanel(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final colors = Theme.of(context).colorScheme;
    final focused = _focusedDevice;
    final snapshot = focused == null
        ? null
        : _workspaceCoordinator.snapshot.targets[focused.uid];
    final graph = _workspaceGraph();
    final reachablePeerIds = _reachablePeerIds(graph);
    final statusLabel = focused == null
        ? l10n.remoteInputWorkspaceNoTargets
        : _workspacePeerStatusLabel(
            l10n,
            focused,
            snapshot: snapshot,
            graph: graph,
            reachablePeerIds: reachablePeerIds,
          );
    final statusColor = focused == null
        ? palette.textMuted
        : _peerStatusColor(
            focused,
            graph: graph,
            reachablePeerIds: reachablePeerIds,
          );
    return WhisperGlassSurface(
      borderRadius: BorderRadius.circular(20),
      shadowOffset: const Offset(0, 8),
      showTopHighlight: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: focused == null
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 19,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          l10n.remoteInputWorkspaceDetailsTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (_usesDetailsDrawer)
                        IconButton(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).closeButtonTooltip,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded, size: 20),
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: palette.surfaceMuted.withValues(alpha: 0.58),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(
                      Icons.desktop_windows_rounded,
                      color: palette.textMuted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    focused.name,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _WorkspaceNoticeChip(
                      icon: statusColor == palette.trusted
                          ? Icons.check_circle_outline_rounded
                          : Icons.info_outline_rounded,
                      label: statusLabel,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: palette.surfaceMuted.withValues(alpha: 0.58),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: palette.borderSubtle),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lan_outlined,
                          size: 17,
                          color: palette.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${focused.host}:${focused.port}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 2),
                    decoration: BoxDecoration(
                      color: palette.surfaceMuted.withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        _DetailRow(
                          label: l10n.remoteInputLayoutTitle,
                          value: _focusedLayoutSummary(_layouts[focused.uid]),
                        ),
                        _DetailRow(
                          label: l10n.remoteInputWorkspaceState,
                          value: statusLabel,
                        ),
                      ],
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
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  _WorkspaceStatusPresentation _workspaceStatusPresentation(
    AppLocalizations l10n,
  ) {
    final palette = context.whisperPalette;
    final snapshot = _workspaceCoordinator.snapshot;
    return switch (snapshot.status) {
      RemoteInputWorkspaceStatus.offering => _WorkspaceStatusPresentation(
        icon: Icons.hourglass_top_rounded,
        label: l10n.remoteInputWorkspaceStatusOffering,
        color: palette.warning,
      ),
      RemoteInputWorkspaceStatus.armed => _WorkspaceStatusPresentation(
        icon: Icons.radar_rounded,
        label: l10n.remoteInputWorkspaceStatusArmed,
        color: palette.connected,
      ),
      RemoteInputWorkspaceStatus.active => _WorkspaceStatusPresentation(
        icon: Icons.mouse_rounded,
        label: l10n.remoteInputWorkspaceStatusActive(_activeTargetName()),
        color: palette.trusted,
      ),
      RemoteInputWorkspaceStatus.failed => _WorkspaceStatusPresentation(
        icon: Icons.error_outline_rounded,
        label: l10n.remoteInputWorkspaceStatusFailed(
          _failureDetail(l10n, snapshot.errorMessage),
        ),
        color: palette.danger,
      ),
      RemoteInputWorkspaceStatus.idle => _WorkspaceStatusPresentation(
        icon: Icons.pause_circle_outline_rounded,
        label: l10n.remoteInputWorkspaceStatusIdle,
        color: palette.textMuted,
      ),
    };
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

class _WorkspaceStatusPresentation {
  const _WorkspaceStatusPresentation({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;
}

class _WorkspaceStatusChip extends StatelessWidget {
  const _WorkspaceStatusChip({required this.status});

  final _WorkspaceStatusPresentation status;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Tooltip(
      message: status.label,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: palette.surfaceMuted.withValues(alpha: 0.56),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: palette.borderSubtle),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(status.icon, size: 15, color: status.color),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                status.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceNoticeChip extends StatelessWidget {
  const _WorkspaceNoticeChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.54),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceGridPainter extends CustomPainter {
  const _WorkspaceGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const spacing = 28.0;
    for (var y = spacing / 2; y < size.height; y += spacing) {
      for (var x = spacing / 2; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WorkspaceGridPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _ScreenBlock extends StatelessWidget {
  const _ScreenBlock({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.selected,
    required this.conflict,
    required this.local,
    required this.reachable,
  });

  final String title;
  final String subtitle;
  final String badge;
  final bool selected;
  final bool conflict;
  final bool local;
  final bool reachable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final isDark = theme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final glassGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: highContrast
          ? [palette.surfaceElevated, palette.surfaceElevated]
          : isDark
          ? [
              palette.surfaceElevated.withValues(alpha: 0.76),
              palette.surfaceElevated.withValues(alpha: 0.60),
            ]
          : [
              Colors.white.withValues(alpha: 0.70),
              Colors.white.withValues(alpha: 0.52),
            ],
    );
    final blurSigma = highContrast ? 0.0 : 18.0;
    final borderWidth = selected || conflict ? 2.0 : 1.0;
    final borderColor = conflict
        ? palette.warning
        : selected
        ? colorScheme.primary
        : highContrast
        ? colorScheme.onSurface.withValues(alpha: 0.42)
        : Colors.white.withValues(alpha: isDark ? 0.18 : 0.92);
    return Semantics(
      selected: selected,
      label: '$badge, $title, $subtitle',
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: reachable || local ? 1 : 0.48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                gradient: glassGradient,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor, width: borderWidth),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showTitle =
                      constraints.maxWidth >= 44 && constraints.maxHeight >= 22;
                  final showSubtitle =
                      constraints.maxWidth >= 84 && constraints.maxHeight >= 48;
                  final showChrome =
                      constraints.maxWidth >= 118 &&
                      constraints.maxHeight >= 66;
                  final horizontalPadding = constraints.maxWidth >= 96
                      ? 12.0
                      : 4.0;
                  final verticalPadding = constraints.maxHeight >= 64
                      ? 10.0
                      : 2.0;
                  if (!showTitle) {
                    return const SizedBox.expand();
                  }
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Padding(
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
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
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
                        ),
                      ),
                      if (showChrome)
                        Positioned(
                          left: 10,
                          top: 9,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: (isDark ? Colors.white : Colors.black)
                                  .withValues(alpha: isDark ? 0.08 : 0.045),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              badge,
                              style: TextStyle(
                                color: palette.textMuted,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      if (showChrome && (selected || conflict || !reachable))
                        Positioned(
                          right: 10,
                          top: 9,
                          child: Icon(
                            conflict
                                ? Icons.warning_amber_rounded
                                : !reachable
                                ? Icons.link_off_rounded
                                : Icons.check_circle_rounded,
                            size: 16,
                            color: conflict
                                ? palette.warning
                                : !reachable
                                ? palette.textMuted
                                : colorScheme.primary,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
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
