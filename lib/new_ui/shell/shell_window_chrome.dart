import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:whisper/helper/toast.dart' show appNavigatorKey;
import 'package:whisper/new_ui/shell/shell_island.dart';
import 'package:whisper/new_ui/shell/shell_island_sources.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';
import 'package:whisper/widget/island/island_center.dart';
import 'package:whisper/widget/island/island_sources.dart';
import 'package:window_manager/window_manager.dart';

/// Where the island has to keep clear of, as the shell measures it.
class ShellIslandPlacement {
  const ShellIslandPlacement({
    required this.controlsLeft,
    required this.titleRight,
  });

  final double controlsLeft, titleRight;

  @override
  bool operator ==(Object other) =>
      other is ShellIslandPlacement &&
      other.controlsLeft == controlsLeft &&
      other.titleRight == titleRight;

  @override
  int get hashCode => Object.hash(controlsLeft, titleRight);
}

/// What the shell tells the layer above the navigator. Null below the desktop
/// size classes, where the phone's stack has neither.
final shellIslandPlacement = ValueNotifier<ShellIslandPlacement?>(null);

/// What stays on top of everything in a window: the window buttons, like the
/// system's own, and the island. Above the navigator, so a sheet's scrim covers
/// neither, as surfaces.md「窗口外壳」asks.
class ShellWindowChrome extends StatefulWidget {
  const ShellWindowChrome({super.key, required this.child, this.debugLayer});

  final Widget child;

  /// Put in the layer above the navigator, for tests.
  @visibleForTesting
  final Widget? debugLayer;

  @override
  State<ShellWindowChrome> createState() => _ShellWindowChromeState();
}

class _ShellWindowChromeState extends State<ShellWindowChrome>
    with WindowListener {
  late final IslandCenter _center = _installCenter();
  bool _maximized = false;

  static IslandCenter _installCenter() {
    final center = IslandSetup.install(appNavigatorKey);
    installShellIslandSources(center);
    return center;
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_syncMaximized());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    bool maximized;
    try {
      maximized = await windowManager.isMaximized();
    } on Object {
      return;
    }
    if (mounted && maximized != _maximized) {
      _maximized = maximized;
      _layer.markNeedsBuild();
    }
  }

  @override
  void onWindowMaximize() => unawaited(_syncMaximized());

  @override
  void onWindowUnmaximize() => unawaited(_syncMaximized());

  Widget _buttons(
    BuildContext context,
    List<WindowButton> buttons,
    WindowButtonStyle style,
  ) {
    final l10n = context.shellL10n;
    return WindowButtons(
      buttons: buttons,
      style: style,
      maximized: _maximized,
      onPressed: (button) => unawaited(switch (button) {
        WindowButton.minimize => windowManager.minimize(),
        WindowButton.maximize =>
          _maximized ? windowManager.unmaximize() : windowManager.maximize(),
        WindowButton.close => windowManager.close(),
      }),
      label: (button, maximized) => switch (button) {
        WindowButton.minimize => l10n.shellWindowMinimize,
        WindowButton.maximize =>
          maximized ? l10n.shellWindowRestore : l10n.shellWindowMaximize,
        WindowButton.close => l10n.shellWindowClose,
      },
    );
  }

  /// Above the navigator there is no [Overlay] to borrow, and what is in this
  /// layer has tooltips: without one of its own, hovering a window button throws,
  /// and a release build shows a grey box in its place.
  late final OverlayEntry _layer = OverlayEntry(builder: _buildLayer);

  @override
  void didUpdateWidget(ShellWindowChrome old) {
    super.didUpdateWidget(old);
    if (old.debugLayer != widget.debugLayer) _layer.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      Overlay(initialEntries: [_layer]),
    ],
  );

  Widget _buildLayer(BuildContext context) {
    final mac = Platform.isMacOS;
    return Stack(
      fit: StackFit.expand,
      children: [
        ?widget.debugLayer,
        ValueListenableBuilder<ShellIslandPlacement?>(
          valueListenable: shellIslandPlacement,
          builder: (context, placement, _) {
            if (placement == null) return const SizedBox.shrink();
            return ValueListenableBuilder<WindowButtonLayout>(
              valueListenable: WhisperWindow.buttonLayout,
              builder: (context, layout, _) {
                final style = WhisperWindow.buttonStyle;
                final right = mac
                    ? 0.0
                    : WindowButtons.widthOf(style, layout.right.length);
                final width = MediaQuery.sizeOf(context).width;
                return Stack(
                  children: [
                    ShellIsland(
                      center: _center,
                      windowWidth: width,
                      controlsLeft: placement.controlsLeft,
                      titleRight: placement.titleRight,
                      buttonsLeft: width - right,
                      buttonsBottom: right > 0
                          ? WindowButtons.heightOf(style)
                          : 0,
                    ),
                    if (!mac && layout.left.isNotEmpty)
                      Positioned(
                        top: 0,
                        left: 0,
                        child: _buttons(context, layout.left, style),
                      ),
                    if (!mac && layout.right.isNotEmpty)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: _buttons(context, layout.right, style),
                      ),
                    if (Platform.isWindows && !_maximized)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: WindowTopResizeEdge(),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }
}
