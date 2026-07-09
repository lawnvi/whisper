import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../widget/app_empty_state.dart';
import 'remote_input_layout.dart';
import 'remote_input_protocol.dart';

enum RemoteInputWorkspacePaneLayout { compact, medium, expanded }

RemoteInputWorkspacePaneLayout paneLayoutForWidth(double width) {
  if (width < WhisperUi.compactWindowBreakpoint) {
    return RemoteInputWorkspacePaneLayout.compact;
  }
  if (width < WhisperUi.expandedWindowBreakpoint) {
    return RemoteInputWorkspacePaneLayout.medium;
  }
  return RemoteInputWorkspacePaneLayout.expanded;
}

RemoteInputScreenRect moveRemoteLayoutByKey(
  RemoteInputScreenRect layout, {
  required RemoteInputEdge direction,
  required bool coarse,
}) {
  final step = coarse ? 50 : 10;
  return switch (direction) {
    RemoteInputEdge.left => RemoteInputScreenRect(
        x: layout.x - step,
        y: layout.y,
        width: layout.width,
        height: layout.height,
      ),
    RemoteInputEdge.right => RemoteInputScreenRect(
        x: layout.x + step,
        y: layout.y,
        width: layout.width,
        height: layout.height,
      ),
    RemoteInputEdge.top => RemoteInputScreenRect(
        x: layout.x,
        y: layout.y - step,
        width: layout.width,
        height: layout.height,
      ),
    RemoteInputEdge.bottom => RemoteInputScreenRect(
        x: layout.x,
        y: layout.y + step,
        width: layout.width,
        height: layout.height,
      ),
  };
}

class RemoteInputAdaptiveWorkspace extends StatefulWidget {
  const RemoteInputAdaptiveWorkspace({
    super.key,
    required this.devicesPanelLabel,
    required this.detailsPanelLabel,
    required this.closePanelLabel,
    this.openDevicesPanelLabel,
    this.openDetailsPanelLabel,
    required this.devicePanel,
    required this.canvasPanel,
    required this.detailsPanel,
    this.onEscape,
  });

  static const devicePanelKey = ValueKey<String>(
    'remote-input-workspace-device-panel',
  );
  static const canvasPanelKey = ValueKey<String>(
    'remote-input-workspace-canvas-panel',
  );
  static const detailsPanelKey = ValueKey<String>(
    'remote-input-workspace-details-panel',
  );
  static const openDevicesButtonKey = ValueKey<String>(
    'remote-input-workspace-open-devices',
  );
  static const openDetailsButtonKey = ValueKey<String>(
    'remote-input-workspace-open-details',
  );

  final String devicesPanelLabel;
  final String detailsPanelLabel;
  final String closePanelLabel;
  final String? openDevicesPanelLabel;
  final String? openDetailsPanelLabel;
  final Widget devicePanel;
  final Widget canvasPanel;
  final Widget detailsPanel;
  final VoidCallback? onEscape;

  @override
  State<RemoteInputAdaptiveWorkspace> createState() =>
      _RemoteInputAdaptiveWorkspaceState();
}

class _RemoteInputAdaptiveWorkspaceState
    extends State<RemoteInputAdaptiveWorkspace> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _panelRevision = ValueNotifier<int>(0);

  @override
  void didUpdateWidget(covariant RemoteInputAdaptiveWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _panelRevision.value += 1;
      }
    });
  }

  @override
  void dispose() {
    _panelRevision.dispose();
    super.dispose();
  }

  void _handleEscape() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold?.isDrawerOpen ?? false) {
      scaffold!.closeDrawer();
      return;
    }
    if (scaffold?.isEndDrawerOpen ?? false) {
      scaffold!.closeEndDrawer();
      return;
    }
    widget.onEscape?.call();
  }

  Future<void> _showPanelSheet({
    required String label,
    required Widget Function() panelBuilder,
    required Key panelKey,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.82,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: widget.closePanelLabel,
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: _panelRevision,
                builder: (context, _, __) => KeyedSubtree(
                  key: panelKey,
                  child: panelBuilder(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
      },
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return switch (paneLayoutForWidth(constraints.maxWidth)) {
              RemoteInputWorkspacePaneLayout.compact => _buildCompact(context),
              RemoteInputWorkspacePaneLayout.medium =>
                _buildMedium(context, constraints.maxWidth),
              RemoteInputWorkspacePaneLayout.expanded =>
                _buildExpanded(constraints.maxWidth),
            };
          },
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context) {
    return Column(
      children: <Widget>[
        Material(
          color: context.whisperPalette.surfaceElevated,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: Semantics(
                      label: widget.openDevicesPanelLabel ??
                          widget.devicesPanelLabel,
                      button: true,
                      excludeSemantics: true,
                      onTap: () => _showPanelSheet(
                        label: widget.devicesPanelLabel,
                        panelBuilder: () => widget.devicePanel,
                        panelKey: RemoteInputAdaptiveWorkspace.devicePanelKey,
                      ),
                      child: OutlinedButton.icon(
                        key: RemoteInputAdaptiveWorkspace.openDevicesButtonKey,
                        onPressed: () => _showPanelSheet(
                          label: widget.devicesPanelLabel,
                          panelBuilder: () => widget.devicePanel,
                          panelKey: RemoteInputAdaptiveWorkspace.devicePanelKey,
                        ),
                        icon: const Icon(Icons.devices_outlined),
                        label: Text(widget.devicesPanelLabel),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(2),
                    child: Semantics(
                      label: widget.openDetailsPanelLabel ??
                          widget.detailsPanelLabel,
                      button: true,
                      excludeSemantics: true,
                      onTap: () => _showPanelSheet(
                        label: widget.detailsPanelLabel,
                        panelBuilder: () => widget.detailsPanel,
                        panelKey: RemoteInputAdaptiveWorkspace.detailsPanelKey,
                      ),
                      child: OutlinedButton.icon(
                        key: RemoteInputAdaptiveWorkspace.openDetailsButtonKey,
                        onPressed: () => _showPanelSheet(
                          label: widget.detailsPanelLabel,
                          panelBuilder: () => widget.detailsPanel,
                          panelKey:
                              RemoteInputAdaptiveWorkspace.detailsPanelKey,
                        ),
                        icon: const Icon(Icons.info_outline_rounded),
                        label: Text(widget.detailsPanelLabel),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: KeyedSubtree(
            key: RemoteInputAdaptiveWorkspace.canvasPanelKey,
            child: widget.canvasPanel,
          ),
        ),
      ],
    );
  }

  Widget _buildMedium(BuildContext context, double width) {
    final deviceWidth = (width * 0.3).clamp(240.0, 280.0);
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      drawerEnableOpenDragGesture: false,
      endDrawerEnableOpenDragGesture: false,
      endDrawer: Drawer(
        width: 280,
        shape: const RoundedRectangleBorder(),
        child: SafeArea(
          child: KeyedSubtree(
            key: RemoteInputAdaptiveWorkspace.detailsPanelKey,
            child: widget.detailsPanel,
          ),
        ),
      ),
      body: Row(
        children: <Widget>[
          SizedBox(
            width: deviceWidth,
            child: KeyedSubtree(
              key: RemoteInputAdaptiveWorkspace.devicePanelKey,
              child: widget.devicePanel,
            ),
          ),
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: KeyedSubtree(
                    key: RemoteInputAdaptiveWorkspace.canvasPanelKey,
                    child: widget.canvasPanel,
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1000),
                    child: IconButton.filledTonal(
                      key: RemoteInputAdaptiveWorkspace.openDetailsButtonKey,
                      tooltip: widget.openDetailsPanelLabel ??
                          widget.detailsPanelLabel,
                      onPressed: () =>
                          _scaffoldKey.currentState?.openEndDrawer(),
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(
                          WhisperUi.minInteractiveSize,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            WhisperUi.radiusLarge,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.info_outline_rounded),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpanded(double width) {
    final deviceWidth = (width * 0.2).clamp(240.0, 280.0);
    final detailsWidth = (width * 0.21).clamp(260.0, 300.0);
    return Row(
      children: <Widget>[
        SizedBox(
          width: deviceWidth,
          child: KeyedSubtree(
            key: RemoteInputAdaptiveWorkspace.devicePanelKey,
            child: widget.devicePanel,
          ),
        ),
        Expanded(
          child: KeyedSubtree(
            key: RemoteInputAdaptiveWorkspace.canvasPanelKey,
            child: widget.canvasPanel,
          ),
        ),
        SizedBox(
          width: detailsWidth,
          child: KeyedSubtree(
            key: RemoteInputAdaptiveWorkspace.detailsPanelKey,
            child: widget.detailsPanel,
          ),
        ),
      ],
    );
  }
}

class RemoteInputDeviceTargetItem {
  const RemoteInputDeviceTargetItem({
    required this.id,
    required this.name,
    required this.status,
    required this.selected,
    required this.focused,
    required this.onToggle,
    required this.onInspect,
  });

  final String id;
  final String name;
  final String status;
  final bool selected;
  final bool focused;
  final VoidCallback onToggle;
  final VoidCallback onInspect;
}

class RemoteInputDevicePanel extends StatelessWidget {
  const RemoteInputDevicePanel({
    super.key,
    required this.title,
    required this.emptyTitle,
    required this.emptyBody,
    required this.inspectTooltip,
    required this.items,
  });

  final String title;
  final String emptyTitle;
  final String emptyBody;
  final String inspectTooltip;
  final List<RemoteInputDeviceTargetItem> items;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(right: BorderSide(color: palette.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? AppEmptyState(
                    icon: Icons.keyboard_alt_outlined,
                    title: emptyTitle,
                    body: emptyBody,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return FocusTraversalOrder(
                        order: NumericFocusOrder(10 + index.toDouble()),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _RemoteInputDeviceTargetRow(
                            item: item,
                            inspectTooltip: inspectTooltip,
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
}

class _RemoteInputDeviceTargetRow extends StatelessWidget {
  const _RemoteInputDeviceTargetRow({
    required this.item,
    required this.inspectTooltip,
  });

  final RemoteInputDeviceTargetItem item;
  final String inspectTooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return Material(
      color: item.focused
          ? colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(WhisperUi.radiusMedium),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Semantics(
                container: true,
                excludeSemantics: true,
                label: '${item.name}, ${item.status}',
                button: true,
                enabled: true,
                toggled: item.selected,
                onTap: item.onToggle,
                child: InkWell(
                  excludeFromSemantics: true,
                  onTap: item.onToggle,
                  borderRadius: BorderRadius.circular(WhisperUi.radiusMedium),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Row(
                      children: <Widget>[
                        IgnorePointer(
                          child: ExcludeFocus(
                            child: ExcludeSemantics(
                              child: Checkbox(
                                value: item.selected,
                                onChanged: (_) => item.onToggle(),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                item.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.status,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: palette.textMuted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: inspectTooltip,
              onPressed: item.onInspect,
              style: IconButton.styleFrom(
                fixedSize: const Size.square(WhisperUi.minInteractiveSize),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
                ),
              ),
              icon: const Icon(Icons.center_focus_strong_rounded),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class RemoteInputWorkspaceCanvasPanel extends StatelessWidget {
  const RemoteInputWorkspaceCanvasPanel({
    super.key,
    required this.title,
    required this.hasConflict,
    required this.conflictLabel,
    required this.empty,
    required this.emptyTitle,
    required this.emptyBody,
    required this.child,
  });

  final String title;
  final bool hasConflict;
  final String conflictLabel;
  final bool empty;
  final String emptyTitle;
  final String emptyBody;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (hasConflict)
                Semantics(
                  liveRegion: true,
                  excludeSemantics: true,
                  label: conflictLabel,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: palette.warning,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          conflictLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
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
                borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
                child: empty
                    ? AppEmptyState(
                        icon: Icons.desktop_access_disabled_outlined,
                        title: emptyTitle,
                        body: emptyBody,
                      )
                    : child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class RemoteInputWorkspaceDetail {
  const RemoteInputWorkspaceDetail({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;
}

class RemoteInputWorkspaceDetailsPanel extends StatelessWidget {
  const RemoteInputWorkspaceDetailsPanel({
    super.key,
    required this.title,
    required this.emptyTitle,
    required this.emptyBody,
    this.deviceName,
    this.address,
    this.details = const <RemoteInputWorkspaceDetail>[],
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  }) : assert(
          (actionLabel == null && actionIcon == null && onAction == null) ||
              (actionLabel != null && actionIcon != null && onAction != null),
        );

  final String title;
  final String emptyTitle;
  final String emptyBody;
  final String? deviceName;
  final String? address;
  final List<RemoteInputWorkspaceDetail> details;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(left: BorderSide(color: palette.borderSubtle)),
      ),
      child: deviceName == null
          ? AppEmptyState(
              icon: Icons.info_outline_rounded,
              title: emptyTitle,
              body: emptyBody,
            )
          : ListView(
              padding: const EdgeInsets.all(18),
              children: <Widget>[
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 18),
                Text(
                  deviceName!,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (address != null) ...<Widget>[
                  const SizedBox(height: 8),
                  SelectableText(
                    address!,
                    style: TextStyle(color: palette.textMuted),
                  ),
                ],
                const SizedBox(height: 18),
                for (final detail in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          detail.label,
                          style: TextStyle(color: palette.textMuted),
                        ),
                        const SizedBox(height: 4),
                        Text(detail.value),
                      ],
                    ),
                  ),
                if (onAction != null) ...<Widget>[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: onAction,
                    icon: Icon(actionIcon),
                    label: Text(actionLabel!),
                  ),
                ],
              ],
            ),
    );
  }
}

class RemoteInputWorkspaceStatusBar extends StatelessWidget {
  const RemoteInputWorkspaceStatusBar({
    super.key,
    required this.status,
  });

  final String status;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(top: BorderSide(color: palette.borderSubtle)),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        heightFactor: 1,
        child: Text(
          status,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.textMuted),
        ),
      ),
    );
  }
}

typedef RemoteInputScreenMoveCallback = void Function(
  RemoteInputEdge direction,
  bool coarse,
);

Rect remoteInputHitRectForVisualRect(Rect visualRect) {
  final width = visualRect.width < WhisperUi.minInteractiveSize
      ? WhisperUi.minInteractiveSize
      : visualRect.width;
  final height = visualRect.height < WhisperUi.minInteractiveSize
      ? WhisperUi.minInteractiveSize
      : visualRect.height;
  return Rect.fromCenter(
    center: visualRect.center,
    width: width,
    height: height,
  );
}

class RemoteInputPositionedScreenBlock extends StatelessWidget {
  const RemoteInputPositionedScreenBlock({
    super.key,
    required this.visualRect,
    required this.title,
    required this.resolution,
    required this.roleLabel,
    required this.selectedLabel,
    required this.conflictLabel,
    required this.selected,
    required this.conflict,
    required this.local,
    this.onActivate,
    this.onToggle,
    this.onMove,
    this.onPanUpdate,
    this.onPanEnd,
  });

  final Rect visualRect;
  final String title;
  final String resolution;
  final String roleLabel;
  final String selectedLabel;
  final String conflictLabel;
  final bool selected;
  final bool conflict;
  final bool local;
  final VoidCallback? onActivate;
  final VoidCallback? onToggle;
  final RemoteInputScreenMoveCallback? onMove;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;

  @override
  Widget build(BuildContext context) {
    final hitRect = remoteInputHitRectForVisualRect(visualRect);
    return Positioned.fromRect(
      rect: hitRect,
      child: RemoteInputScreenBlock(
        visualSize: visualRect.size,
        title: title,
        resolution: resolution,
        roleLabel: roleLabel,
        selectedLabel: selectedLabel,
        conflictLabel: conflictLabel,
        selected: selected,
        conflict: conflict,
        local: local,
        onActivate: onActivate,
        onToggle: onToggle,
        onMove: onMove,
        onPanUpdate: onPanUpdate,
        onPanEnd: onPanEnd,
      ),
    );
  }
}

class RemoteInputScreenBlock extends StatefulWidget {
  const RemoteInputScreenBlock({
    super.key,
    required this.title,
    required this.resolution,
    required this.roleLabel,
    required this.selectedLabel,
    required this.conflictLabel,
    required this.selected,
    required this.conflict,
    required this.local,
    this.visualSize,
    this.onActivate,
    this.onToggle,
    this.onMove,
    this.onPanUpdate,
    this.onPanEnd,
  });

  static const focusRingKey = ValueKey<String>(
    'remote-input-screen-focus-ring',
  );
  static const visualSurfaceKey = ValueKey<String>(
    'remote-input-screen-visual-surface',
  );

  final String title;
  final String resolution;
  final String roleLabel;
  final String selectedLabel;
  final String conflictLabel;
  final bool selected;
  final bool conflict;
  final bool local;
  final Size? visualSize;
  final VoidCallback? onActivate;
  final VoidCallback? onToggle;
  final RemoteInputScreenMoveCallback? onMove;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;

  @override
  State<RemoteInputScreenBlock> createState() => _RemoteInputScreenBlockState();
}

class _RemoteInputScreenBlockState extends State<RemoteInputScreenBlock> {
  bool _focused = false;
  bool _hovered = false;

  bool get _interactive =>
      widget.onActivate != null ||
      widget.onToggle != null ||
      widget.onMove != null ||
      widget.onPanUpdate != null;

  String get _semanticLabel => <String>[
        widget.title,
        widget.resolution,
        widget.roleLabel,
        if (widget.selected) widget.selectedLabel,
        if (widget.conflict) widget.conflictLabel,
      ].join(', ');

  void _move(RemoteInputEdge direction, bool coarse) {
    widget.onMove?.call(direction, coarse);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    final reducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final borderColor = widget.conflict
        ? palette.warning
        : widget.selected
            ? colorScheme.primary
            : palette.borderSubtle;
    final background = widget.local
        ? colorScheme.primary.withValues(alpha: 0.08)
        : widget.selected || _hovered
            ? colorScheme.primary.withValues(alpha: 0.10)
            : palette.surfaceMuted;
    final tapAction = widget.onActivate ?? widget.onToggle;
    final shortcuts = <ShortcutActivator, Intent>{
      if (widget.onMove != null) ...<ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const _MoveRemoteScreenIntent(RemoteInputEdge.left, false),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
            const _MoveRemoteScreenIntent(RemoteInputEdge.left, true),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const _MoveRemoteScreenIntent(RemoteInputEdge.right, false),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
            const _MoveRemoteScreenIntent(RemoteInputEdge.right, true),
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const _MoveRemoteScreenIntent(RemoteInputEdge.top, false),
        const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
            const _MoveRemoteScreenIntent(RemoteInputEdge.top, true),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const _MoveRemoteScreenIntent(RemoteInputEdge.bottom, false),
        const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
            const _MoveRemoteScreenIntent(RemoteInputEdge.bottom, true),
      },
      if (widget.onToggle != null)
        const SingleActivator(LogicalKeyboardKey.space):
            const _ToggleRemoteScreenIntent(),
      if (tapAction != null)
        const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
    };

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: _semanticLabel,
      button: tapAction != null,
      enabled: _interactive,
      selected: widget.selected,
      focusable: _interactive,
      focused: _focused,
      onTap: tapAction,
      child: FocusableActionDetector(
        enabled: _interactive,
        mouseCursor: widget.onPanUpdate != null
            ? SystemMouseCursors.move
            : _interactive
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
        onFocusChange: (focused) {
          if (_focused != focused) {
            setState(() => _focused = focused);
          }
        },
        onShowHoverHighlight: (hovered) {
          if (_hovered != hovered) {
            setState(() => _hovered = hovered);
          }
        },
        shortcuts: shortcuts,
        actions: <Type, Action<Intent>>{
          _MoveRemoteScreenIntent: CallbackAction<_MoveRemoteScreenIntent>(
            onInvoke: (intent) {
              _move(intent.direction, intent.coarse);
              return null;
            },
          ),
          _ToggleRemoteScreenIntent: CallbackAction<_ToggleRemoteScreenIntent>(
            onInvoke: (_) {
              widget.onToggle?.call();
              return null;
            },
          ),
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              tapAction?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: tapAction,
          onPanUpdate: widget.onPanUpdate,
          onPanEnd: widget.onPanEnd,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final requestedSize = widget.visualSize ?? constraints.biggest;
              final targetWidth = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : requestedSize.width < WhisperUi.minInteractiveSize
                      ? WhisperUi.minInteractiveSize
                      : requestedSize.width;
              final targetHeight = constraints.hasBoundedHeight
                  ? constraints.maxHeight
                  : requestedSize.height < WhisperUi.minInteractiveSize
                      ? WhisperUi.minInteractiveSize
                      : requestedSize.height;
              final visualWidth =
                  requestedSize.width.clamp(1, targetWidth).toDouble();
              final visualHeight =
                  requestedSize.height.clamp(1, targetHeight).toDouble();
              final visualLeft = (targetWidth - visualWidth) / 2;
              final visualTop = (targetHeight - visualHeight) / 2;

              return SizedBox(
                width: targetWidth,
                height: targetHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned(
                      left: visualLeft - 4,
                      top: visualTop - 4,
                      width: visualWidth + 8,
                      height: visualHeight + 8,
                      child: IgnorePointer(
                        child: Container(
                          key: RemoteInputScreenBlock.focusRingKey,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              WhisperUi.radiusLarge,
                            ),
                            border: Border.all(
                              color: _focused
                                  ? colorScheme.primary
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: visualLeft,
                      top: visualTop,
                      width: visualWidth,
                      height: visualHeight,
                      child: AnimatedContainer(
                        key: RemoteInputScreenBlock.visualSurfaceKey,
                        duration: reducedMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        decoration: BoxDecoration(
                          color: background,
                          borderRadius: BorderRadius.circular(
                            WhisperUi.radiusLarge,
                          ),
                          border: Border.all(
                            color: borderColor,
                            width: widget.selected ? 2 : 1,
                          ),
                        ),
                        child: LayoutBuilder(
                          builder: _buildVisualContent,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildVisualContent(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: palette.textMuted,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final titleExtent = _lineExtent(titleStyle, scaler);
    final subtitleExtent = _lineExtent(subtitleStyle, scaler);
    final horizontalPadding = constraints.maxWidth >= 96 ? 12.0 : 4.0;
    final verticalPadding = constraints.maxHeight >= 64 ? 10.0 : 2.0;
    final showTitle = constraints.maxWidth >= 44 &&
        constraints.maxHeight >= titleExtent + verticalPadding * 2;
    final showSubtitle = constraints.maxWidth >= 84 &&
        constraints.maxHeight >=
            titleExtent + subtitleExtent + verticalPadding * 2 + 4;
    if (!showTitle) {
      return const SizedBox.expand();
    }

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              verticalPadding,
              horizontalPadding + (widget.conflict ? 24 : 0),
              verticalPadding,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
                if (showSubtitle) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    widget.resolution,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: subtitleStyle,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (widget.conflict &&
            constraints.maxWidth >= 44 &&
            constraints.maxHeight >= 44)
          Positioned(
            top: 4,
            right: 4,
            child: Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: palette.warning,
            ),
          ),
      ],
    );
  }

  double _lineExtent(TextStyle? style, TextScaler scaler) {
    final fontSize = style?.fontSize ?? 14;
    return scaler.scale(fontSize) * (style?.height ?? 1.2);
  }
}

class _MoveRemoteScreenIntent extends Intent {
  const _MoveRemoteScreenIntent(this.direction, this.coarse);

  final RemoteInputEdge direction;
  final bool coarse;
}

class _ToggleRemoteScreenIntent extends Intent {
  const _ToggleRemoteScreenIntent();
}
