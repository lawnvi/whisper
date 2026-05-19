import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/theme/app_theme.dart';

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

class _RemoteInputWorkspaceScreenState
    extends State<RemoteInputWorkspaceScreen> {
  final WsSvrManager _socketManager = WsSvrManager();
  final RemoteInputWorkspaceCoordinator _workspaceCoordinator =
      RemoteInputWorkspaceCoordinator.shared;
  final RemoteInputCoordinator _legacyCoordinator =
      RemoteInputCoordinator.shared;
  final Map<String, RemoteInputLayoutData> _layouts =
      <String, RemoteInputLayoutData>{};
  final Set<String> _selectedPeerIds = <String>{};
  List<DeviceData> _devices = const <DeviceData>[];
  String _focusedPeerId = '';
  bool _loading = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _devices = widget.initialDevices;
    _focusedPeerId = widget.preferredPeerId;
    _workspaceCoordinator.addListener(_handleWorkspaceChanged);
    unawaited(_loadWorkspace());
  }

  @override
  void dispose() {
    _workspaceCoordinator.removeListener(_handleWorkspaceChanged);
    super.dispose();
  }

  void _handleWorkspaceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadWorkspace() async {
    final devices = _socketManager.connectedRemoteInputDevices(
      preferredPeerId: widget.preferredPeerId,
    );
    final nextLayouts = <String, RemoteInputLayoutData>{};
    for (var index = 0; index < devices.length; index++) {
      final device = devices[index];
      nextLayouts[device.uid] = await _ensureLayout(
        device,
        index: index,
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _devices = devices;
      _layouts
        ..clear()
        ..addAll(nextLayouts);
      if (_selectedPeerIds.isEmpty && devices.isNotEmpty) {
        _selectedPeerIds.add(
          widget.preferredPeerId.isNotEmpty &&
                  devices.any((device) => device.uid == widget.preferredPeerId)
              ? widget.preferredPeerId
              : devices.first.uid,
        );
      }
      if (_focusedPeerId.isEmpty && devices.isNotEmpty) {
        _focusedPeerId = _selectedPeerIds.first;
      }
      _loading = false;
    });
  }

  Future<RemoteInputLayoutData> _ensureLayout(
    DeviceData device, {
    required int index,
  }) async {
    final saved = await LocalDatabase().fetchRemoteInputLayout(device.uid);
    if (saved != null) {
      return saved;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final x = index.isEven ? 1000 : -900;
    final y = (index ~/ 2) * 620;
    final layout = RemoteInputLayoutData(
      peerId: device.uid,
      peerName: device.name,
      x: x,
      y: y,
      width: 900,
      height: 600,
      enabled: true,
      autoActivate: false,
      autoRole: RemoteInputAutoRole.source.name,
      layoutVersion: 1,
      layoutJson: '',
      edgeThresholdPx: 6,
      releaseHotkey: 'ctrl+alt+esc',
      updatedAt: now,
    );
    await LocalDatabase().upsertRemoteInputLayout(layout);
    return layout;
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
                  SizedBox(
                    width: 260,
                    child: _buildDevicePanel(l10n),
                  ),
                  Expanded(
                    child: _buildCanvasPanel(l10n),
                  ),
                  SizedBox(
                    width: 280,
                    child: _buildDetailsPanel(l10n),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: _buildStatusBar(l10n),
    );
  }

  Widget _buildDevicePanel(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(
          right: BorderSide(color: palette.borderSubtle),
        ),
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
                              ? Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.08)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: CheckboxListTile(
                            value: selected,
                            onChanged: (value) {
                              setState(() {
                                if (value == true) {
                                  _selectedPeerIds.add(device.uid);
                                  _focusedPeerId = device.uid;
                                } else {
                                  _selectedPeerIds.remove(device.uid);
                                }
                              });
                            },
                            onFocusChange: (_) {},
                            title: Text(
                              device.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              _targetStatusLabel(l10n, snapshot),
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
                              icon:
                                  const Icon(Icons.center_focus_strong_rounded),
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
    final validation = RemoteInputWorkspaceLayoutValidator.validateTargets(
      selectedDevices
          .map((device) => _requestPreviewForDevice(device))
          .whereType<RemoteInputWorkspaceTargetRequest>()
          .toList(growable: false),
    );
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
              if (validation.hasConflict)
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
                      conflicts: validation.conflictingPeerIds,
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
  }) {
    const local = RemoteInputScreenRect(x: 0, y: 0, width: 1000, height: 800);
    final rects = <RemoteInputScreenRect>[local];
    for (final device in selectedDevices) {
      final layout = _layouts[device.uid];
      if (layout != null) {
        rects.add(
          RemoteInputScreenRect(
            x: layout.x,
            y: layout.y,
            width: layout.width,
            height: layout.height,
          ),
        );
      }
    }
    final bounds = _boundsFor(rects);
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final scale = math
        .min(
          (width - 48) / bounds.width,
          (height - 48) / bounds.height,
        )
        .clamp(0.05, 1.0);
    final offsetX = (width - bounds.width * scale) / 2 - bounds.left * scale;
    final offsetY = (height - bounds.height * scale) / 2 - bounds.top * scale;

    Offset toCanvas(int x, int y) {
      return Offset(offsetX + x * scale, offsetY + y * scale);
    }

    Size toSize(int w, int h) {
      return Size(
        math.max(90, w * scale),
        math.max(64, h * scale),
      );
    }

    final localOffset = toCanvas(local.x, local.y);
    final localSize = toSize(local.width, local.height);
    return Stack(
      children: [
        Positioned(
          left: localOffset.dx,
          top: localOffset.dy,
          width: localSize.width,
          height: localSize.height,
          child: _ScreenBlock(
            title: AppLocalizations.of(context)!.remoteInputLocalScreen,
            subtitle: '1000 x 800',
            selected: false,
            conflict: false,
            local: true,
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
            ),
      ],
    );
  }

  Widget _buildPeerScreenBlock(
    DeviceData device, {
    required RemoteInputLayoutData layout,
    required Offset Function(int x, int y) toCanvas,
    required Size Function(int w, int h) toSize,
    required double scale,
    required bool conflict,
  }) {
    final offset = toCanvas(layout.x, layout.y);
    final size = toSize(layout.width, layout.height);
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      width: size.width,
      height: size.height,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _focusedPeerId = device.uid;
            _selectedPeerIds.add(device.uid);
          });
        },
        onPanUpdate: (details) {
          setState(() {
            _focusedPeerId = device.uid;
            _layouts[device.uid] = layout.copyWith(
              x: layout.x + (details.delta.dx / scale).round(),
              y: layout.y + (details.delta.dy / scale).round(),
            );
          });
        },
        onPanEnd: (_) {
          unawaited(_snapAndSaveLayout(device));
        },
        child: _ScreenBlock(
          title: device.name,
          subtitle: _edgeLabelForLayout(layout),
          selected: _focusedPeerId == device.uid,
          conflict: conflict,
          local: false,
        ),
      ),
    );
  }

  Widget _buildDetailsPanel(AppLocalizations l10n) {
    final palette = context.whisperPalette;
    final focused =
        _devices.where((device) => device.uid == _focusedPeerId).firstOrNull;
    final snapshot = focused == null
        ? null
        : _workspaceCoordinator.snapshot.targets[focused.uid];
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(
          left: BorderSide(color: palette.borderSubtle),
        ),
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
                    value: _edgeLabelForLayout(_layouts[focused.uid]),
                  ),
                  _DetailRow(
                    label: l10n.remoteInputWorkspaceState,
                    value: _targetStatusLabel(l10n, snapshot),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        if (_selectedPeerIds.contains(focused.uid)) {
                          _selectedPeerIds.remove(focused.uid);
                        } else {
                          _selectedPeerIds.add(focused.uid);
                        }
                      });
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
        l10n.remoteInputWorkspaceStatusFailed(snapshot.errorMessage),
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
      final targets = <RemoteInputWorkspaceTargetRequest>[];
      for (final device in _devices) {
        if (!_selectedPeerIds.contains(device.uid)) {
          continue;
        }
        final request = await _targetRequestForDevice(
          device,
          sourcePeerId: self.uid,
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
      );
      showAppToast(l10n.remoteInputEnabledMoveToEdge);
    } catch (error, stackTrace) {
      logger.e(
        'remote input workspace start failed',
        error: error,
        stackTrace: stackTrace,
      );
      showAppToast(l10n.remoteInputFailed(error.toString()));
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
  }) async {
    final layout =
        _layouts[device.uid] ?? await _ensureLayout(device, index: 0);
    final storedDevice = await LocalDatabase().fetchDevice(device.uid);
    final localTrustsRemote = storedDevice?.auth == true;
    final remoteTrustsLocal =
        _socketManager.remotePeerTrustsPeer(device.uid, sourcePeerId);
    final plan = await _sharingPlanForDevice(device, layout);
    if (plan == null) {
      return null;
    }
    return RemoteInputWorkspaceTargetRequest(
      peerId: device.uid,
      peerName: device.name,
      host: device.host,
      port: device.port,
      layoutEdge: plan.layoutEdge,
      releaseHotkey: layout.releaseHotkey,
      isMutuallyTrusted: localTrustsRemote && remoteTrustsLocal,
      remoteCanInject: _socketManager.supportsRemoteInputFor(device.uid),
      sourceDisplayId: plan.sourceDisplayId,
      sourceEdge: plan.sourceEdge,
      sourceSegmentStart: plan.sourceSegmentStart,
      sourceSegmentEnd: plan.sourceSegmentEnd,
      sinkDisplayId: plan.sinkDisplayId,
      sinkEdge: plan.sinkEdge,
      sinkSegmentStart: plan.sinkSegmentStart,
      sinkSegmentEnd: plan.sinkSegmentEnd,
      edgeMappings: plan.edgeMappings,
    );
  }

  RemoteInputWorkspaceTargetRequest? _requestPreviewForDevice(
    DeviceData device,
  ) {
    final layout = _layouts[device.uid];
    if (layout == null) {
      return null;
    }
    final plan = _legacySharingPlan(layout);
    if (plan == null) {
      return null;
    }
    return RemoteInputWorkspaceTargetRequest(
      peerId: device.uid,
      peerName: device.name,
      host: device.host,
      port: device.port,
      layoutEdge: plan.layoutEdge,
      releaseHotkey: layout.releaseHotkey,
      isMutuallyTrusted: true,
      remoteCanInject: true,
      sourceDisplayId: plan.sourceDisplayId,
      sourceEdge: plan.sourceEdge,
      sourceSegmentStart: plan.sourceSegmentStart,
      sourceSegmentEnd: plan.sourceSegmentEnd,
      sinkDisplayId: plan.sinkDisplayId,
      sinkEdge: plan.sinkEdge,
      sinkSegmentStart: plan.sinkSegmentStart,
      sinkSegmentEnd: plan.sinkSegmentEnd,
      edgeMappings: plan.edgeMappings,
    );
  }

  Future<_WorkspaceSharingPlan?> _sharingPlanForDevice(
    DeviceData device,
    RemoteInputLayoutData layout,
  ) async {
    final savedLayout = layout.savedLayout;
    if (savedLayout != null &&
        _socketManager.supportsRemoteInputTopologyFor(device.uid)) {
      final remoteTopology =
          _socketManager.remoteDisplayTopologyFor(device.uid);
      if (remoteTopology != null) {
        final localTopology = await _legacyCoordinator.displayTopology();
        final resolved = RemoteInputLayoutGeometry.resolveSavedLayout(
          savedLayout: savedLayout,
          sourceTopology: localTopology,
          sinkTopology: remoteTopology,
          edgeTolerance: layout.edgeThresholdPx,
        );
        if (resolved != null) {
          final mappings = resolved.edgeMappings;
          return _WorkspaceSharingPlan(
            layoutEdge: resolved.sharedSegment.sourceEdge,
            sourceDisplayId: resolved.sourceDisplay.displayId,
            sourceEdge: resolved.sharedSegment.sourceEdge,
            sourceSegmentStart: mappings.isEmpty
                ? resolved.sharedSegment.start
                : mappings
                    .map((mapping) => mapping.sourceSegmentStart)
                    .reduce(math.min),
            sourceSegmentEnd: mappings.isEmpty
                ? resolved.sharedSegment.end
                : mappings
                    .map((mapping) => mapping.sourceSegmentEnd)
                    .reduce(math.max),
            sinkDisplayId: resolved.sinkDisplay.displayId,
            sinkEdge: resolved.sharedSegment.sinkEdge,
            sinkSegmentStart: resolved.sinkSegmentStart,
            sinkSegmentEnd: resolved.sinkSegmentEnd,
            edgeMappings: mappings,
          );
        }
      }
    }
    return _legacySharingPlan(layout);
  }

  _WorkspaceSharingPlan? _legacySharingPlan(RemoteInputLayoutData layout) {
    const local = RemoteInputScreenRect(x: 0, y: 0, width: 1000, height: 800);
    final peer = RemoteInputScreenRect(
      x: layout.x,
      y: layout.y,
      width: layout.width,
      height: layout.height,
    );
    final edge = RemoteInputLayoutGeometry.adjacentEdge(
      local: local,
      peer: peer,
    );
    if (edge == null) {
      return null;
    }
    final isVertical =
        edge == RemoteInputEdge.left || edge == RemoteInputEdge.right;
    final start = isVertical
        ? math.max(local.top, peer.top)
        : math.max(local.left, peer.left);
    final end = isVertical
        ? math.min(local.bottom, peer.bottom)
        : math.min(local.right, peer.right);
    if (end <= start) {
      return null;
    }
    final sinkOffset = isVertical ? layout.y : layout.x;
    final sinkEdge = _oppositeEdge(edge);
    final mapping = RemoteInputEdgeMapping(
      routeId: '${layout.peerId}-${edge.name}-$start-$end',
      sourceDisplayId: 'local',
      sourceEdge: edge,
      sourceSegmentStart: start,
      sourceSegmentEnd: end,
      sinkDisplayId: '${layout.peerId}-screen',
      sinkEdge: sinkEdge,
      sinkSegmentStart: start - sinkOffset,
      sinkSegmentEnd: end - sinkOffset,
    );
    return _WorkspaceSharingPlan(
      layoutEdge: edge,
      sourceDisplayId: mapping.sourceDisplayId,
      sourceEdge: mapping.sourceEdge,
      sourceSegmentStart: mapping.sourceSegmentStart,
      sourceSegmentEnd: mapping.sourceSegmentEnd,
      sinkDisplayId: mapping.sinkDisplayId,
      sinkEdge: mapping.sinkEdge,
      sinkSegmentStart: mapping.sinkSegmentStart,
      sinkSegmentEnd: mapping.sinkSegmentEnd,
      edgeMappings: [mapping],
    );
  }

  Future<void> _snapAndSaveLayout(DeviceData device) async {
    final layout = _layouts[device.uid];
    if (layout == null) {
      return;
    }
    const local = RemoteInputScreenRect(x: 0, y: 0, width: 1000, height: 800);
    final snapped = RemoteInputLayoutGeometry.snapToNearestEdge(
      local: local,
      peer: RemoteInputScreenRect(
        x: layout.x,
        y: layout.y,
        width: layout.width,
        height: layout.height,
      ),
    );
    final next = layout.copyWith(
      peerName: device.name,
      x: snapped.x,
      y: snapped.y,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await LocalDatabase().upsertRemoteInputLayout(next);
    if (!mounted) {
      return;
    }
    setState(() {
      _layouts[device.uid] = next;
    });
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

  String _edgeLabelForLayout(RemoteInputLayoutData? layout) {
    final l10n = AppLocalizations.of(context)!;
    if (layout == null) {
      return l10n.remoteInputEdgeNotAdjacent;
    }
    final edge = RemoteInputLayoutGeometry.adjacentEdge(
      local: const RemoteInputScreenRect(x: 0, y: 0, width: 1000, height: 800),
      peer: RemoteInputScreenRect(
        x: layout.x,
        y: layout.y,
        width: layout.width,
        height: layout.height,
      ),
    );
    return _edgeLabel(l10n, edge);
  }

  String _edgeLabel(AppLocalizations l10n, RemoteInputEdge? edge) {
    switch (edge) {
      case RemoteInputEdge.left:
        return l10n.remoteInputEdgeLeft;
      case RemoteInputEdge.right:
        return l10n.remoteInputEdgeRight;
      case RemoteInputEdge.top:
        return l10n.remoteInputEdgeTop;
      case RemoteInputEdge.bottom:
        return l10n.remoteInputEdgeBottom;
      case null:
        return l10n.remoteInputEdgeNotAdjacent;
    }
  }

  RemoteInputEdge _oppositeEdge(RemoteInputEdge edge) {
    switch (edge) {
      case RemoteInputEdge.left:
        return RemoteInputEdge.right;
      case RemoteInputEdge.right:
        return RemoteInputEdge.left;
      case RemoteInputEdge.top:
        return RemoteInputEdge.bottom;
      case RemoteInputEdge.bottom:
        return RemoteInputEdge.top;
    }
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
        return l10n.remoteInputWorkspaceStatusFailed(snapshot.errorMessage);
      case RemoteInputWorkspaceTargetStatus.stopped:
        return l10n.remoteInputWorkspaceStatusIdle;
    }
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

class _WorkspaceSharingPlan {
  const _WorkspaceSharingPlan({
    required this.layoutEdge,
    required this.sourceDisplayId,
    required this.sourceEdge,
    required this.sourceSegmentStart,
    required this.sourceSegmentEnd,
    required this.sinkDisplayId,
    required this.sinkEdge,
    required this.sinkSegmentStart,
    required this.sinkSegmentEnd,
    required this.edgeMappings,
  });

  final RemoteInputEdge layoutEdge;
  final String sourceDisplayId;
  final RemoteInputEdge? sourceEdge;
  final int sourceSegmentStart;
  final int sourceSegmentEnd;
  final String sinkDisplayId;
  final RemoteInputEdge? sinkEdge;
  final int sinkSegmentStart;
  final int sinkSegmentEnd;
  final List<RemoteInputEdgeMapping> edgeMappings;
}

class _ScreenBlock extends StatelessWidget {
  const _ScreenBlock({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.conflict,
    required this.local,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final bool conflict;
  final bool local;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final borderColor = conflict
        ? Colors.orange
        : selected
            ? colorScheme.primary
            : palette.borderSubtle;
    return AnimatedContainer(
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
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
  });

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
            child: Text(
              label,
              style: TextStyle(color: palette.textMuted),
            ),
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
