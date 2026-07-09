import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
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
                const SizedBox(width: 8),
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(2),
                    child: OutlinedButton.icon(
                      key: RemoteInputAdaptiveWorkspace.openDetailsButtonKey,
                      onPressed: () => _showPanelSheet(
                        label: widget.detailsPanelLabel,
                        panelBuilder: () => widget.detailsPanel,
                        panelKey: RemoteInputAdaptiveWorkspace.detailsPanelKey,
                      ),
                      icon: const Icon(Icons.info_outline_rounded),
                      label: Text(widget.detailsPanelLabel),
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
                      tooltip: widget.detailsPanelLabel,
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

typedef RemoteInputScreenMoveCallback = void Function(
  RemoteInputEdge direction,
  bool coarse,
);

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
    this.onActivate,
    this.onToggle,
    this.onMove,
  });

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

  @override
  State<RemoteInputScreenBlock> createState() => _RemoteInputScreenBlockState();
}

class _RemoteInputScreenBlockState extends State<RemoteInputScreenBlock> {
  bool _focused = false;
  bool _hovered = false;

  bool get _interactive =>
      widget.onActivate != null ||
      widget.onToggle != null ||
      widget.onMove != null;

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
        : widget.selected || _focused
            ? colorScheme.primary
            : palette.borderSubtle;
    final background = widget.local
        ? colorScheme.primary.withValues(alpha: 0.08)
        : widget.selected || _hovered
            ? colorScheme.primary.withValues(alpha: 0.10)
            : palette.surfaceMuted;
    final tapAction = widget.onActivate ?? widget.onToggle;

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: _semanticLabel,
      button: _interactive,
      enabled: _interactive,
      selected: widget.selected,
      focusable: _interactive,
      focused: _focused,
      onTap: tapAction,
      child: FocusableActionDetector(
        enabled: _interactive,
        mouseCursor:
            _interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onFocusChange: (focused) => setState(() => _focused = focused),
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowLeft):
              _MoveRemoteScreenIntent(RemoteInputEdge.left, false),
          SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
              _MoveRemoteScreenIntent(RemoteInputEdge.left, true),
          SingleActivator(LogicalKeyboardKey.arrowRight):
              _MoveRemoteScreenIntent(RemoteInputEdge.right, false),
          SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
              _MoveRemoteScreenIntent(RemoteInputEdge.right, true),
          SingleActivator(LogicalKeyboardKey.arrowUp):
              _MoveRemoteScreenIntent(RemoteInputEdge.top, false),
          SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
              _MoveRemoteScreenIntent(RemoteInputEdge.top, true),
          SingleActivator(LogicalKeyboardKey.arrowDown):
              _MoveRemoteScreenIntent(RemoteInputEdge.bottom, false),
          SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
              _MoveRemoteScreenIntent(RemoteInputEdge.bottom, true),
          SingleActivator(LogicalKeyboardKey.space):
              _ToggleRemoteScreenIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
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
          child: AnimatedContainer(
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
              border: Border.all(
                color: borderColor,
                width: widget.selected || _focused ? 2 : 1,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showTitle =
                    constraints.maxWidth >= 44 && constraints.maxHeight >= 22;
                final showSubtitle =
                    constraints.maxWidth >= 84 && constraints.maxHeight >= 48;
                final horizontalPadding =
                    constraints.maxWidth >= 96 ? 12.0 : 4.0;
                final verticalPadding =
                    constraints.maxHeight >= 64 ? 10.0 : 2.0;
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
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.center,
                                child: Text(
                                  widget.title,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            if (showSubtitle) ...<Widget>[
                              const SizedBox(height: 4),
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.center,
                                  child: Text(
                                    widget.resolution,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: palette.textMuted),
                                  ),
                                ),
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
              },
            ),
          ),
        ),
      ),
    );
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
