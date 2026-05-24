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
  List<DeviceData> _devices = const <DeviceData>[];
  String _focusedPeerId = '';
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

  String _displaySizeLabel(RemoteInputDisplay display) {
    return '${display.width} x ${display.height}';
  }

  String _displaySizeLabelForLayout(RemoteInputLayoutData layout) {
    return '${layout.width} x ${layout.height}';
  }

  Future<void> _loadWorkspace() async {
    final localTopology = await _loadLocalTopology();
    final devices = _socketManager.connectedRemoteInputDevices(
      preferredPeerId: widget.preferredPeerId,
    );
    final workspaceSnapshot = _workspaceCoordinator.snapshot;
    final connectedDeviceIds = devices.map((device) => device.uid).toSet();
    final connectedLiveTargetPeerIds = workspaceSnapshot.isControllerLive
        ? workspaceSnapshot.liveTargetPeerIds
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
      _devices = devices;
      _layouts
        ..clear()
        ..addAll(nextLayouts);
      if (connectedLiveTargetPeerIds.isNotEmpty) {
        _selectedPeerIds
          ..clear()
          ..addAll(connectedLiveTargetPeerIds);
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
      _loading = false;
    });
  }

  Future<RemoteInputLayoutData> _ensureLayout(
    DeviceData device, {
    required int index,
    required RemoteInputTopology localTopology,
  }) async {
    final saved = await LocalDatabase().fetchRemoteInputLayout(device.uid);
    if (saved != null) {
      final next = _reanchorLegacyDefaultLayout(
        saved,
        device: device,
        index: index,
        localTopology: localTopology,
      );
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
      layoutVersion: 1,
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
    final isLegacyDefault = saved.x == legacyX &&
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

  _WorkspaceDefaultLayoutAnchor _defaultLayoutAnchor(
    DeviceData device, {
    required int index,
    required RemoteInputTopology localTopology,
  }) {
    final source = localTopology.primaryDisplay;
    final remote = _socketManager.remoteDisplayTopologyFor(device.uid);
    final remotePrimary = remote?.primaryDisplay;
    final width = remotePrimary?.width ?? 900;
    final height = remotePrimary?.height ?? 600;
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
    final localDisplays = _localDisplays;
    final rects = <RemoteInputScreenRect>[
      ...localDisplays.map((display) => display.rect),
    ];
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
    final availableWidth = math.max(1.0, width - 48);
    final availableHeight = math.max(1.0, height - 48);
    final scale = math
        .min(
          availableWidth / bounds.width,
          availableHeight / bounds.height,
        )
        .clamp(0.001, 1.0);
    final offsetX = (width - bounds.width * scale) / 2 - bounds.left * scale;
    final offsetY = (height - bounds.height * scale) / 2 - bounds.top * scale;

    Offset toCanvas(int x, int y) {
      return Offset(offsetX + x * scale, offsetY + y * scale);
    }

    Size toSize(int w, int h) {
      return Size(
        math.max(1.0, w * scale),
        math.max(1.0, h * scale),
      );
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
          subtitle: _peerScreenSubtitle(layout),
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
                    value: _focusedLayoutSummary(_layouts[focused.uid]),
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
    final layout = _layouts[device.uid] ??
        await _ensureLayout(
          device,
          index: 0,
          localTopology: _localTopology,
        );
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
    final plan = _topologySharingPlanForDevice(
          device,
          layout,
          _localTopology,
        ) ??
        _legacySharingPlan(layout);
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
    final localTopology = await _loadLocalTopology();
    if (mounted) {
      setState(() {
        _localTopology = localTopology;
      });
    }
    return _topologySharingPlanForDevice(device, layout, localTopology) ??
        _legacySharingPlan(
          layout,
          localTopology: localTopology,
        );
  }

  _WorkspaceSharingPlan? _topologySharingPlanForDevice(
    DeviceData device,
    RemoteInputLayoutData layout,
    RemoteInputTopology localTopology,
  ) {
    final savedLayout = layout.savedLayout;
    if (savedLayout != null &&
        _socketManager.supportsRemoteInputTopologyFor(device.uid)) {
      final remoteTopology =
          _socketManager.remoteDisplayTopologyFor(device.uid);
      if (remoteTopology != null) {
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
    return null;
  }

  _WorkspaceSharingPlan? _legacySharingPlan(
    RemoteInputLayoutData layout, {
    RemoteInputTopology? localTopology,
  }) {
    final topology = localTopology ?? _localTopology;
    _WorkspaceSharingPlan? best;
    for (final display in topology.displays) {
      final plan = _legacySharingPlanForDisplay(
        layout,
        localDisplay: display,
        localDisplays: topology.displays,
      );
      if (plan == null) {
        continue;
      }
      final currentLength = plan.edgeMappings.first.sourceLength;
      final bestLength = best?.edgeMappings.first.sourceLength ?? -1;
      if (best == null || currentLength > bestLength) {
        best = plan;
      }
    }
    return best;
  }

  _WorkspaceSharingPlan? _legacySharingPlanForDisplay(
    RemoteInputLayoutData layout, {
    required RemoteInputDisplay localDisplay,
    required List<RemoteInputDisplay> localDisplays,
  }) {
    final sourceDisplay = localDisplay;
    final sourceRect = sourceDisplay.rect;
    final peer = RemoteInputScreenRect(
      x: layout.x,
      y: layout.y,
      width: layout.width,
      height: layout.height,
    );
    final edge = RemoteInputLayoutGeometry.adjacentEdge(
      local: sourceRect,
      peer: peer,
    );
    if (edge == null) {
      return null;
    }
    final isVertical =
        edge == RemoteInputEdge.left || edge == RemoteInputEdge.right;
    final start = isVertical
        ? math.max(sourceRect.top, peer.top)
        : math.max(sourceRect.left, peer.left);
    final end = isVertical
        ? math.min(sourceRect.bottom, peer.bottom)
        : math.min(sourceRect.right, peer.right);
    if (end <= start) {
      return null;
    }
    if (!_isLocalOuterEdge(
      display: sourceDisplay,
      edge: edge,
      segmentStart: start,
      segmentEnd: end,
      displays: localDisplays,
    )) {
      return null;
    }
    final sinkOffset = isVertical ? layout.y : layout.x;
    final sinkEdge = _oppositeEdge(edge);
    final mapping = RemoteInputEdgeMapping(
      routeId: '${layout.peerId}-${edge.name}-$start-$end',
      sourceDisplayId: sourceDisplay.displayId,
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
    final snapped = _snapToNearestLocalDisplay(layout);
    final updatedLayoutJson = _layoutJsonForSnappedLayout(layout, snapped);
    final next = layout.copyWith(
      peerName: device.name,
      x: snapped.x,
      y: snapped.y,
      layoutVersion: updatedLayoutJson.isEmpty ? 1 : 2,
      layoutJson: updatedLayoutJson,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await LocalDatabase().upsertRemoteInputLayout(next);
    if (!mounted) {
      return;
    }
    setState(() {
      _layouts[device.uid] = next;
    });
    await _restartControllerWorkspaceIfLive();
  }

  String _layoutJsonForSnappedLayout(
    RemoteInputLayoutData layout,
    RemoteInputScreenRect snapped,
  ) {
    final remoteTopology = _socketManager.remoteDisplayTopologyFor(
      layout.peerId,
    );
    if (remoteTopology == null || remoteTopology.isEmpty) {
      return '';
    }
    final preferredSinkDisplayId = layout.savedLayout?.sinkDisplayId ??
        remoteTopology.primaryDisplay.displayId;
    final sinkDisplay = remoteTopology.displayById(preferredSinkDisplayId) ??
        remoteTopology.primaryDisplay;
    final sourceTopology = _localTopology.isNotEmpty
        ? _localTopology
        : RemoteInputTopology.fallback();
    final savedLayout =
        RemoteInputLayoutGeometry.savedLayoutForTranslatedSinkTopology(
      sourceTopology: sourceTopology,
      sinkTopology: remoteTopology,
      sinkOffsetX: snapped.x - sinkDisplay.x,
      sinkOffsetY: snapped.y - sinkDisplay.y,
      preferredSinkDisplayId: preferredSinkDisplayId,
      edgeTolerance: layout.edgeThresholdPx,
    );
    return savedLayout?.toJsonString() ?? '';
  }

  Future<void> _restartControllerWorkspaceIfLive() async {
    final snapshot = _workspaceCoordinator.snapshot;
    if (!snapshot.isControllerLive) {
      return;
    }
    final sourcePeerId = snapshot.sourcePeerId.isNotEmpty
        ? snapshot.sourcePeerId
        : (await LocalSetting().instance()).uid;
    final livePeerIds = snapshot.liveTargetPeerIds.toSet();
    final targets = <RemoteInputWorkspaceTargetRequest>[];
    for (final device in _devices) {
      if (!livePeerIds.contains(device.uid) ||
          !_socketManager.isConnectedTo(device.uid)) {
        continue;
      }
      final request = await _targetRequestForDevice(
        device,
        sourcePeerId: sourcePeerId,
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
    await _workspaceCoordinator.startControllerWorkspace(
      sourcePeerId: sourcePeerId,
      targets: targets,
      sendControlTo: _socketManager.sendRemoteInputControlTo,
    );
  }

  RemoteInputScreenRect _snapToNearestLocalDisplay(
    RemoteInputLayoutData layout,
  ) {
    final peer = RemoteInputScreenRect(
      x: layout.x,
      y: layout.y,
      width: layout.width,
      height: layout.height,
    );
    _WorkspaceSnapCandidate? best;
    final displays = _localDisplays;
    for (final display in displays) {
      for (final edge in RemoteInputEdge.values) {
        final candidate = _snapCandidateForLocalDisplay(
          display: display,
          edge: edge,
          peer: peer,
          displays: displays,
        );
        if (candidate == null) {
          continue;
        }
        if (best == null || candidate.score < best.score) {
          best = candidate;
        }
      }
    }
    return best?.rect ?? peer;
  }

  _WorkspaceSnapCandidate? _snapCandidateForLocalDisplay({
    required RemoteInputDisplay display,
    required RemoteInputEdge edge,
    required RemoteInputScreenRect peer,
    required List<RemoteInputDisplay> displays,
  }) {
    final rect = _snappedRectForEdge(
      local: display.rect,
      peer: peer,
      edge: edge,
    );
    final candidateDisplay = RemoteInputDisplay(
      displayId: 'candidate',
      name: '',
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
      scale: 1,
      isPrimary: false,
    );
    final segment = RemoteInputLayoutGeometry.sharedEdgeSegment(
      source: display,
      sourceEdge: edge,
      sinkInLayout: candidateDisplay,
      sinkEdge: _oppositeEdge(edge),
    );
    if (segment == null ||
        !_isLocalOuterEdge(
          display: display,
          edge: edge,
          segmentStart: segment.start,
          segmentEnd: segment.end,
          displays: displays,
        )) {
      return null;
    }
    final dx = rect.x - peer.x;
    final dy = rect.y - peer.y;
    return _WorkspaceSnapCandidate(
      rect: rect,
      score: dx * dx + dy * dy,
    );
  }

  RemoteInputScreenRect _snappedRectForEdge({
    required RemoteInputScreenRect local,
    required RemoteInputScreenRect peer,
    required RemoteInputEdge edge,
  }) {
    switch (edge) {
      case RemoteInputEdge.left:
        return RemoteInputScreenRect(
          x: local.left - peer.width,
          y: _clampInt(peer.y, local.top - peer.height + 1, local.bottom - 1),
          width: peer.width,
          height: peer.height,
        );
      case RemoteInputEdge.right:
        return RemoteInputScreenRect(
          x: local.right,
          y: _clampInt(peer.y, local.top - peer.height + 1, local.bottom - 1),
          width: peer.width,
          height: peer.height,
        );
      case RemoteInputEdge.top:
        return RemoteInputScreenRect(
          x: _clampInt(peer.x, local.left - peer.width + 1, local.right - 1),
          y: local.top - peer.height,
          width: peer.width,
          height: peer.height,
        );
      case RemoteInputEdge.bottom:
        return RemoteInputScreenRect(
          x: _clampInt(peer.x, local.left - peer.width + 1, local.right - 1),
          y: local.bottom,
          width: peer.width,
          height: peer.height,
        );
    }
  }

  bool _isLocalOuterEdge({
    required RemoteInputDisplay display,
    required RemoteInputEdge edge,
    required int segmentStart,
    required int segmentEnd,
    required List<RemoteInputDisplay> displays,
  }) {
    return RemoteInputLayoutGeometry.isOuterEdgeSegment(
      display: display,
      edge: edge,
      displays: displays,
      segmentStart: segmentStart,
      segmentEnd: segmentEnd,
    );
  }

  int _clampInt(int value, int minimum, int maximum) {
    if (value < minimum) {
      return minimum;
    }
    if (value > maximum) {
      return maximum;
    }
    return value;
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
    final plan = _legacySharingPlan(layout);
    return _edgeLabel(l10n, plan?.layoutEdge);
  }

  String _peerScreenSubtitle(RemoteInputLayoutData layout) {
    return '${_edgeLabelForLayout(layout)} / ${_displaySizeLabelForLayout(layout)}';
  }

  String _focusedLayoutSummary(RemoteInputLayoutData? layout) {
    if (layout == null) {
      return AppLocalizations.of(context)!.remoteInputEdgeNotAdjacent;
    }
    return _peerScreenSubtitle(layout);
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

class _WorkspaceSnapCandidate {
  const _WorkspaceSnapCandidate({
    required this.rect,
    required this.score,
  });

  final RemoteInputScreenRect rect;
  final int score;
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
