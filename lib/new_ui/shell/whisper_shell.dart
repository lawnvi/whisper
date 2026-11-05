import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_first_device.dart';
import 'package:whisper/new_ui/shell/shell_device_page.dart';
import 'package:whisper/new_ui/shell/shell_palette.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_sidebar.dart';
import 'package:whisper/new_ui/shell/shell_touch.dart';
import 'package:whisper/new_ui/shell/shell_window_chrome.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';

/// docs/design/surfaces.md「窗口外壳」: the sidebar, a device's page, its card.
/// On a touch screen, and in a window under 600 wide, it is [ShellTouch]: phone
/// density, and a stack of pages when there is no room for a sidebar.
class WhisperShell extends StatefulWidget {
  const WhisperShell({super.key, required this.data, required this.actions});

  final ShellData data;
  final ShellActions actions;

  @override
  State<WhisperShell> createState() => _WhisperShellState();
}

class _WhisperShellState extends State<WhisperShell> {
  static const _sidebarWidth = 252.0;
  static const _cardWidth = 296.0;
  static const _cardGap = 10.0;

  final _order = StableDeviceOrder();
  final _titleKey = GlobalKey(), _controlsKey = GlobalKey();
  final Map<String, int> _tabByPeer = {};

  /// The device whose card is open. Only that one: choosing another closes it.
  String? _cardPeerId;

  /// What the card shows, kept while it leaves.
  DeviceData? _cardShown;

  List<String> get _orderedIds => _order.apply({
    for (final s in widget.data.sessions)
      s.device.uid: s.isConnected
          ? DevicePresence.connected
          : (s.isNearby ? DevicePresence.nearby : DevicePresence.away),
  });

  @override
  void didUpdateWidget(WhisperShell old) {
    super.didUpdateWidget(old);
    // Another device: its card does not come back with the first one.
    if (widget.data.selectedPeerId != _cardPeerId) _cardPeerId = null;
  }

  void _openCard(DeviceData device) {
    widget.actions.select(device.uid);
    setState(() => _cardPeerId = device.uid);
  }

  void _toggleCard(DeviceData device) => setState(
    () => _cardPeerId = _cardPeerId == device.uid ? null : device.uid,
  );

  void _closeCard() => setState(() => _cardPeerId = null);

  void _openPalette() => unawaited(
    showShellPalette(
      context,
      items: widget.actions.paletteItems(context),
      searchMessages: (query) => widget.actions.searchMessages(context, query),
    ),
  );

  void _openSelf() => unawaited(
    showShellSheet<void>(
      context,
      scrolls: false,
      builder: widget.actions.buildSelfPanel,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final order = _orderedIds;
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = WhisperLayout.resolve(
          size: constraints.biggest,
          touch: WhisperLayout.touchPlatform,
          features: MediaQuery.displayFeaturesOf(context),
        );
        if (layout.touch || layout.compact) {
          return ShellTouch(
            data: widget.data,
            actions: widget.actions,
            order: order,
            layout: layout,
            size: constraints.biggest,
          );
        }
        return _desktop(context, constraints.maxWidth, order);
      },
    );
  }

  Widget _desktop(BuildContext context, double width, List<String> order) {
    final mac = Platform.isMacOS;
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyK, meta: mac, control: !mac):
            _openPalette,
        SingleActivator(LogicalKeyboardKey.comma, meta: mac, control: !mac):
            widget.actions.openSettings,
        // Only while there is a card: otherwise Esc is for whoever else wants it.
        if (_cardPeerId != null)
          const SingleActivator(LogicalKeyboardKey.escape): _closeCard,
      },
      child: Focus(autofocus: true, child: _desktopBody(context, width, order)),
    );
  }

  /// Where the toolbar's title ends and its controls start, for the island.
  void _measureToolbar(double width) {
    double? edge(GlobalKey key, {required bool right}) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return null;
      final origin = box.localToGlobal(Offset.zero);
      return right ? origin.dx + box.size.width : origin.dx;
    }

    shellIslandPlacement.value = ShellIslandPlacement(
      titleRight: edge(_titleKey, right: true) ?? 0,
      controlsLeft: edge(_controlsKey, right: false) ?? double.infinity,
    );
  }

  Widget _desktopBody(BuildContext context, double width, List<String> order) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureToolbar(width);
    });
    final c = context.wc;
    final mac = Platform.isMacOS;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ValueListenableBuilder<bool>(
        valueListenable: WhisperWindow.hasMaterial,
        builder: (context, material, _) =>
            ValueListenableBuilder<WindowButtonLayout>(
              valueListenable: WhisperWindow.buttonLayout,
              builder: (context, layout, _) {
                final style = WhisperWindow.buttonStyle;
                final right = mac
                    ? 0.0
                    : WindowButtons.widthOf(style, layout.right.length);
                final left = mac
                    ? 0.0
                    : WindowButtons.widthOf(style, layout.left.length);
                final session = widget.data.selected;
                // A place that is not about one device: it steps aside, and is
                // there again on the way back.
                final cardDevice =
                    widget.data.place == ShellPlace.device &&
                        session != null &&
                        _cardPeerId == session.device.uid
                    ? session.device
                    : null;
                _cardShown = cardDevice ?? _cardShown;
                // Clear of the window buttons, wherever they are.
                final cardTop = mac || right == 0
                    ? 10.0
                    : (Platform.isLinux ? 44.0 : 40.0);
                final maxCard =
                    MediaQuery.sizeOf(context).height - cardTop - 10;
                Widget cardFrame(DeviceData device) => ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxCard),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(WhisperRadius.l),
                      boxShadow: WhisperShadow.e2(Theme.of(context).brightness),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(WhisperRadius.l),
                      child: widget.actions.buildCard(
                        context,
                        device,
                        _closeCard,
                      ),
                    ),
                  ),
                );
                return Stack(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: _sidebarWidth,
                          child: ColoredBox(
                            color: material ? c.sidebarVeil : c.sidebarSolid,
                            child: ShellSidebar(
                              data: widget.data,
                              actions: widget.actions,
                              order: order,
                              material: material,
                              leftButtonsWidth: left,
                              onOpenSearch: _openPalette,
                              onOpenSelf: _openSelf,
                              onOpenCard: _openCard,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 1 / MediaQuery.devicePixelRatioOf(context),
                          // Over the content's colour: nothing else is under it,
                          // and the desktop behind the window would show through.
                          child: ColoredBox(
                            color: Color.alphaBlend(c.sidebarEdge, c.content),
                          ),
                        ),
                        Expanded(
                          child: ColoredBox(
                            color: widget.data.place == ShellPlace.device
                                ? c.content
                                : c.canvas,
                            child: widget.data.place != ShellPlace.device
                                ? KeyedSubtree(
                                    key: ValueKey(widget.data.place),
                                    child: widget.actions.buildPlace(
                                      context,
                                      widget.data.place,
                                      right,
                                      titleKey: _titleKey,
                                      controlsKey: _controlsKey,
                                    ),
                                  )
                                : session == null
                                ? ToolbarBand(
                                    child: ShellFirstDevice(
                                      visible:
                                          widget.data.sessions.isEmpty &&
                                          !widget.data.loading,
                                      self: widget.data.self,
                                      onConnect: _openSelf,
                                    ),
                                  )
                                : ShellDevicePage(
                                    key: ValueKey(session.device.uid),
                                    session: session,
                                    actions: widget.actions,
                                    paired: widget.data.isPaired(
                                      session.device,
                                    ),
                                    connecting: widget.data
                                        .factsFor(session)
                                        .connecting,
                                    tab: _tabByPeer[session.device.uid] ?? 0,
                                    onTab: (i) => setState(
                                      () => _tabByPeer[session.device.uid] = i,
                                    ),
                                    cardOpen: cardDevice != null,
                                    onToggleCard: () =>
                                        _toggleCard(session.device),
                                    rightInset: right,
                                    titleKey: _titleKey,
                                    controlsKey: _controlsKey,
                                  ),
                          ),
                        ),
                      ],
                    ),
                    if (_cardShown != null)
                      // Floats over the content and slides in from the right:
                      // nothing under it reflows. A tap anywhere else closes it
                      // and still does what it does.
                      Positioned(
                        top: cardTop,
                        right: _cardGap,
                        width: _cardWidth,
                        child: SpringBuilder(
                          value: cardDevice == null ? 0 : 1,
                          from: 0,
                          spring: WhisperSprings.smooth,
                          child: TapRegion(
                            onTapOutside: (_) {
                              if (cardDevice != null &&
                                  !Navigator.of(
                                    context,
                                    rootNavigator: true,
                                  ).canPop()) {
                                _closeCard();
                              }
                            },
                            child: cardFrame(_cardShown!),
                          ),
                          builder: (context, x, child) => x < .004
                              ? const SizedBox.shrink()
                              : Transform.translate(
                                  offset: Offset(
                                    (1 - x.clamp(0, 1)) *
                                        (_cardWidth + _cardGap + 24),
                                    0,
                                  ),
                                  child: child,
                                ),
                        ),
                      ),
                  ],
                );
              },
            ),
      ),
    );
  }
}
